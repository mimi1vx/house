{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-unused-matches -Wno-unused-local-binds -Wno-type-defaults -Wno-overlapping-patterns -Wno-unused-top-binds #-}

-- | Virtio-console server — Endpoint + Grant, rx0+tx1, IRQ->Endpoint.
-- Lock order: conSem distinct from virtioSem/drvSem/nsSem/epSem; never hold conSem across nsRegister.
module Kernel.Driver.Virtio.Con.Server
  ( ConServer (..),
    conServerInit,
    conServerTeardown,
    conWrite,
    conRead,
    conWriteBytes,
    conReadBytes,
  )
where

import Control.Monad (forM_)
import Data.Bits (shiftL, (.&.), (.|.))
import Data.Char (chr)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64, Word8)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peek, poke)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Interrupts (spi)
import H.Monad (H, liftIO)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import qualified Kernel.Driver.Dmesg as Dmesg
import qualified Kernel.Driver.GIC as DGIC
import qualified Kernel.Driver.IRQ as DIRQ
import qualified Kernel.Driver.Registry as DrvReg
import Kernel.Driver.Types (DriverKind (..))
import Kernel.Driver.Virtio.Con.Device (conInvalidate, conPollUsed, conProbe, conSaveQueues, conSubmitRx, conSubmitTx)
import Kernel.Driver.Virtio.Con.Types (ConDevice (..), ConError (..))
import Kernel.Driver.Virtio.Queue (allocQueue, freeQueue, queueAvailPa, queueDescPa, queueUsedPa)
import qualified Kernel.IPC.Endpoint as IPC
import qualified Kernel.IPC.Grant as G
import qualified Kernel.IPC.Nameservice as NS
import Kernel.IPC.Types (Grant (..), Message (..))

foreign import ccall unsafe "virtio_transport_init" c_init :: Int -> Ptr Word32 -> Ptr Word32 -> IO Int

foreign import ccall unsafe "virtio_transport_set_features" c_set_features :: Int -> Word64 -> IO Int

foreign import ccall unsafe "virtio_transport_get_status" c_get_status :: Int -> Ptr Word32 -> IO Int

foreign import ccall unsafe "virtio_transport_set_status" c_set_status :: Int -> Word32 -> IO Int

foreign import ccall unsafe "virtio_transport_queue_max_q" c_qmax_q :: Int -> Int -> Ptr Word32 -> IO Int

foreign import ccall unsafe "virtio_transport_queue_setup_q" c_qsetup_q :: Int -> Int -> Word64 -> Word64 -> Word64 -> Word32 -> IO Int

foreign import ccall unsafe "virtio_transport_dc_flush" c_dc_flush :: Word64 -> Word64 -> IO ()

foreign import ccall unsafe "virtio_page_pa" c_pagePa :: Ptr Word8 -> Word64

foreign import ccall unsafe "house_uptime_ns" c_uptime_ns :: IO Word64

data ConServer = ConServer ConDevice
  deriving (Eq, Show)

{-# NOINLINE conMap #-}
conMap :: Ref (Map Int ConDevice)
conMap = unsafePerformH $ newRef Map.empty

{-# NOINLINE conSem #-}
conSem :: QSem
conSem = unsafePerformH $ newQSem 1

{-# NOINLINE conRxGrants #-}
conRxGrants :: Ref (Map Int (Map Word32 Grant))
conRxGrants = unsafePerformH $ newRef Map.empty

busyDelayUs :: Int -> H ()
busyDelayUs us = liftIO $ do
  t0 <- c_uptime_ns
  let target = t0 + fromIntegral us * 1000
  let loop = do
        t <- c_uptime_ns
        if t < target then loop else return ()
  loop

wantedMask :: Word64
wantedMask = (1 `shiftL` 32) + (1 `shiftL` 29)

slotValid :: Int -> Bool
slotValid n = n >= 0 && n < 8

-- | Init console server for slot.
conServerInit :: Int -> H (Either ConError ConDevice)
conServerInit slot
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = do
      mExisting <- withQSem conSem $ do m <- readRef conMap; return (Map.lookup slot m)
      case mExisting of
        Just _ -> return (Left (ConInvalidArg "already initialized"))
        Nothing -> do
          probeRes <- conProbe slot
          case probeRes of
            Left e -> return (Left e)
            Right () -> do
              initRes <- liftIO $ alloca $ \pLo -> alloca $ \pHi -> c_init slot pLo pHi
              if initRes /= 0
                then do Dmesg.dmesgLog ("con init slot " ++ show slot ++ " initRes=" ++ show initRes); return (Left (ConIoError initRes))
                else do
                  featRes <- liftIO $ c_set_features slot wantedMask
                  if featRes /= 0
                    then do _ <- liftIO $ c_set_status slot 0x80; Dmesg.dmesgLog ("con featRes slot " ++ show slot ++ "=" ++ show featRes); return (Left (ConIoError featRes))
                    else do
                      qmaxRxRes <- liftIO $ alloca $ \pMax -> do r <- c_qmax_q slot 0 pMax; if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
                      qmaxTxRes <- liftIO $ alloca $ \pMax -> do r <- c_qmax_q slot 1 pMax; if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
                      case (qmaxRxRes, qmaxTxRes) of
                        (Right qmaxRx, Right qmaxTx) -> do
                          let qsizeRx = min qmaxRx 64
                              qsizeTx = min qmaxTx 64
                          if qsizeRx == 0 || qsizeTx == 0
                            then return (Left (ConInvalidArg "QueueNumMax 0"))
                            else do
                              qrRx <- allocQueue qsizeRx
                              case qrRx of
                                Left _ -> return (Left ConNoSpace)
                                Right vqRx -> do
                                  qrTx <- allocQueue qsizeTx
                                  case qrTx of
                                    Left _ -> do freeQueue vqRx; return (Left ConNoSpace)
                                    Right vqTx -> do
                                      liftIO $ c_dc_flush (queueDescPa vqRx) 4096
                                      liftIO $ c_dc_flush (queueAvailPa vqRx) 4096
                                      liftIO $ c_dc_flush (queueUsedPa vqRx) 4096
                                      liftIO $ c_dc_flush (queueDescPa vqTx) 4096
                                      liftIO $ c_dc_flush (queueAvailPa vqTx) 4096
                                      liftIO $ c_dc_flush (queueUsedPa vqTx) 4096
                                      setupRx <- liftIO $ c_qsetup_q slot 0 (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) qsizeRx
                                      if setupRx /= 0
                                        then do freeQueue vqRx; freeQueue vqTx; Dmesg.dmesgLog ("con setupRx slot " ++ show slot ++ "=" ++ show setupRx); return (Left (ConIoError setupRx))
                                        else do
                                          setupTx <- liftIO $ c_qsetup_q slot 1 (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeTx
                                          if setupTx /= 0
                                            then do freeQueue vqRx; freeQueue vqTx; Dmesg.dmesgLog ("con setupTx slot " ++ show slot ++ "=" ++ show setupTx); return (Left (ConIoError setupTx))
                                            else do
                                              _ <- conSaveQueues slot (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeRx qsizeTx
                                              stRes <- liftIO $ alloca $ \pSt -> do
                                                _ <- c_get_status slot pSt
                                                st <- peek pSt
                                                let st2 = st .|. 4
                                                c_set_status slot st2
                                              if stRes /= 0
                                                then do freeQueue vqRx; freeQueue vqTx; return (Left (ConIoError stRes))
                                                else do
                                                  DGIC.enableSpi (fromIntegral (16 + slot))
                                                  ep <- IPC.newEndpoint
                                                  _ <- DIRQ.registerIrqForwarding (spi (fromIntegral (16 + slot))) ep
                                                  let intid = spi (fromIntegral (16 + slot))
                                                  let dev = ConDevice slot intid ep vqRx vqTx
                                                  rReg <- DrvReg.registerDriver ("virtio-con" ++ show slot) ep (Just intid) VirtioMMIO
                                                  case rReg of
                                                    Left _ -> do freeQueue vqRx; freeQueue vqTx; return (Left (ConInvalidArg "register failed"))
                                                    Right () -> do
                                                      withQSem conSem $ do m <- readRef conMap; writeRef conMap (Map.insert slot dev m)
                                                      withQSem conSem $ do gmap <- readRef conRxGrants; writeRef conRxGrants (Map.insert slot Map.empty gmap)
                                                      forM_ ([1 .. 4] :: [Int]) $ \_ -> do
                                                        mg <- G.grantAlloc
                                                        case mg of
                                                          Left _ -> return ()
                                                          Right g -> do
                                                            let gptr = grantPage g
                                                            rsub <- conSubmitRx slot gptr
                                                            case rsub of
                                                              Left _ -> G.grantFree g
                                                              Right reqId -> do
                                                                withQSem conSem $ do gm <- readRef conRxGrants; case Map.lookup slot gm of { Just inner -> writeRef conRxGrants (Map.insert slot (Map.insert reqId g inner) gm); Nothing -> return () }
                                                      Dmesg.dmesgLog ("con slot " ++ show slot ++ ": init ok qsize0=" ++ show qsizeRx ++ " qsize1=" ++ show qsizeTx)
                                                      return (Right dev)
                        _ -> return (Left (ConIoError 5))

-- | Teardown.
conServerTeardown :: Int -> H (Either ConError ())
conServerTeardown slot
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = do
      mDev <- withQSem conSem $ do
        m <- readRef conMap
        case Map.lookup slot m of
          Nothing -> return Nothing
          Just d -> do writeRef conMap (Map.delete slot m); return (Just d)
      case mDev of
        Nothing -> return (Left (ConInvalidArg "not initialized"))
        Just dev -> do
          grants <- withQSem conSem $ do
            gm <- readRef conRxGrants
            case Map.lookup slot gm of
              Just inner -> do writeRef conRxGrants (Map.delete slot gm); return (Map.elems inner)
              Nothing -> return []
          mapM_ G.grantFree grants
          DGIC.disableSpi (fromIntegral (16 + slot))
          case conEndpoint dev of
            ep -> do _ <- NS.nsUnregister ("virtio-con" ++ show slot); IPC.freeEndpoint ep; return ()
          _ <- DrvReg.unregisterDriver ("virtio-con" ++ show slot)
          freeQueue (conRxQueue dev)
          freeQueue (conTxQueue dev)
          _ <- liftIO $ c_set_status slot 0
          Dmesg.dmesgLog ("con slot " ++ show slot ++ ": teardown")
          return (Right ())

-- | Write String (truncated to Grant page).
conWrite :: Int -> String -> H (Either ConError ())
conWrite slot txt = conWriteBytes slot (map (fromIntegral . fromEnum) txt)

-- | Read pending bytes as String (empty when idle).
conRead :: Int -> H (Either ConError String)
conRead slot = do
  r <- conReadBytes slot
  case r of
    Left e -> return (Left e)
    Right bytes -> return (Right (map (chr . fromIntegral) bytes))

-- | Write bytes via TX queue (binary-safe, for mirror use).
conWriteBytes :: Int -> [Word8] -> H (Either ConError ())
conWriteBytes slot bytes
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = do
      mDev <- withQSem conSem $ do m <- readRef conMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (ConInvalidArg "not initialized"))
        Just _ -> do
          let n = min (length bytes) 4095
          if n == 0
            then return (Right ())
            else do
              mg <- G.grantAlloc
              case mg of
                Left _ -> return (Left ConNoSpace)
                Right g -> do
                  let ptr = grantPage g
                  liftIO $ mapM_ (\(i, b) -> poke (ptr `plusPtr` i) b) (zip [0 ..] (take n bytes))
                  rsub <- conSubmitTx slot ptr (fromIntegral n)
                  case rsub of
                    Left e -> do G.grantFree g; return (Left e)
                    Right reqId -> do
                      ok <- pollTx slot reqId 500
                      G.grantFree g
                      if ok then return (Right ()) else return (Left (ConIoError 99))

-- | Read one pending RX completion as bytes (binary-safe, [] when idle).
conReadBytes :: Int -> H (Either ConError [Word8])
conReadBytes slot
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = do
      mDev <- withQSem conSem $ do m <- readRef conMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (ConInvalidArg "not initialized"))
        Just _ -> do
          r <- conPollUsed slot 0
          case r of
            Left e -> return (Left e)
            Right Nothing -> return (Right [])
            Right (Just (cid, len)) -> do
              mg <- withQSem conSem $ do
                gm <- readRef conRxGrants
                case Map.lookup slot gm of
                  Just inner -> case Map.lookup cid inner of
                    Just g -> do
                      writeRef conRxGrants (Map.insert slot (Map.delete cid inner) gm)
                      return (Just g)
                    Nothing -> return Nothing
                  Nothing -> return Nothing
              case mg of
                Nothing -> return (Right [])
                Just g -> do
                  let ptr = grantPage g
                  conInvalidate (c_pagePa ptr) 4096
                  bytes <- liftIO $ mapM (\i -> peek (ptr `plusPtr` i) :: IO Word8) [0 .. min (fromIntegral len) 4095]
                  rsub <- conSubmitRx slot ptr
                  case rsub of
                    Left _ -> G.grantFree g
                    Right nid -> withQSem conSem $ do
                      gm <- readRef conRxGrants
                      case Map.lookup slot gm of
                        Just inner -> writeRef conRxGrants (Map.insert slot (Map.insert nid g inner) gm)
                        Nothing -> G.grantFree g
                  return (Right bytes)

pollTx :: Int -> Word32 -> Int -> H Bool
pollTx slot reqId tries
  | tries <= 0 = return False
  | otherwise = do
      busyDelayUs 2000
      r <- conPollUsed slot 1
      case r of
        Right (Just (cid, _)) -> if cid == reqId then return True else pollTx slot reqId (tries - 1)
        Right Nothing -> pollTx slot reqId (tries - 1)
        Left _ -> return False
