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
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
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
import Kernel.Driver.Virtio.Con.Device (conInvalidate, conPollUsed, conProbe, conSaveCtrlQueues, conSaveQueues, conSetPortQueues, conSubmitCtrlRx, conSubmitCtrlTx, conSubmitRx, conSubmitTx)
import Kernel.Driver.Virtio.Con.Types (ConDevice (..), ConError (..), ConKind (..), decodeCtrlEvent, portQueuesFor)
import Kernel.Driver.Virtio.Queue (VirtQueue (..), allocQueue, freeQueue, queueAvailPa, queueDescPa, queueSize, queueUsedPa)
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

-- | MULTIPORT feature bit (VIRTIO_CONSOLE_F_MULTIPORT), serial only.
serialFeatBit :: Word64
serialFeatBit = 1 `shiftL` 1

wantedMaskFor :: ConKind -> Word64
wantedMaskFor ConConsole = wantedMask
wantedMaskFor (ConSerial _) = wantedMask + serialFeatBit

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
            Right kind -> do
              initRes <- liftIO $ alloca $ \pLo -> alloca $ \pHi -> c_init slot pLo pHi
              if initRes /= 0
                then do Dmesg.dmesgLog ("con init slot " ++ show slot ++ " initRes=" ++ show initRes); return (Left (ConIoError initRes))
                else do
                  featRes <- liftIO $ c_set_features slot (wantedMaskFor kind)
                  if featRes /= 0
                    then do _ <- liftIO $ c_set_status slot 0x80; Dmesg.dmesgLog ("con featRes slot " ++ show slot ++ "=" ++ show featRes); return (Left (ConIoError featRes))
                    else do
                      case kind of
                        ConConsole -> do
                          portRes <- setupPortQueues slot 0 1
                          case portRes of
                            Left e -> return (Left e)
                            Right (vqRx, vqTx, qsizeRx, qsizeTx) -> do
                              _ <- conSaveQueues slot (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeRx qsizeTx
                              _ <- conSetPortQueues slot 0 1
                              stRes <- liftIO $ alloca $ \pSt -> do
                                _ <- c_get_status slot pSt
                                st <- peek pSt
                                let st2 = st .|. 4
                                c_set_status slot st2
                              if stRes /= 0
                                then do freeQueue vqRx; freeQueue vqTx; return (Left (ConIoError stRes))
                                else attachDevice slot kind vqRx vqTx Nothing
                        ConSerial _ -> do
                          ctrlRes <- setupSerialCtrl kind slot
                          case ctrlRes of
                            Left e -> return (Left e)
                            Right mCtrl@(Just _) -> do
                              stRes <- liftIO $ alloca $ \pSt -> do
                                _ <- c_get_status slot pSt
                                st <- peek pSt
                                let st2 = st .|. 4
                                c_set_status slot st2
                              if stRes /= 0
                                then do freeCtrl mCtrl; return (Left (ConIoError stRes))
                                else do
                                  didRes <- discoverPort slot
                                  case didRes of
                                    Left e -> do freeCtrl mCtrl; _ <- liftIO $ c_set_status slot 0; return (Left e)
                                    Right pid -> do
                                      openRes <- openPort slot pid
                                      case openRes of
                                        Left e -> do freeCtrl mCtrl; _ <- liftIO $ c_set_status slot 0; return (Left e)
                                        Right () -> do
                                          -- QEMU queue order: port 0 on 0/1, control on 2/3,
                                          -- port N>=1 on 2*N+2/2*N+3 (port 0 is reserved).
                                          case portQueuesFor pid of
                                            Nothing -> do freeCtrl mCtrl; _ <- liftIO $ c_set_status slot 0; return (Left (ConInvalidArg "port qidx"))
                                            Just (rxQ, txQ) -> do
                                              portRes <- setupPortQueues slot rxQ txQ
                                              case portRes of
                                                Left e -> do freeCtrl mCtrl; _ <- liftIO $ c_set_status slot 0; return (Left e)
                                                Right (vqRx, vqTx, qsizeRx, qsizeTx) -> do
                                                  _ <- conSaveQueues slot (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeRx qsizeTx
                                                  _ <- conSetPortQueues slot (fromIntegral rxQ) (fromIntegral txQ)
                                                  attachDevice slot kind vqRx vqTx mCtrl
                            Right Nothing -> return (Left (ConInvalidArg "serial ctrl missing"))

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
          freeCtrl (conCtrl dev)
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
                      ok <- pollTx slot 1 reqId 500
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

pollTx :: Int -> Int -> Word32 -> Int -> H Bool
pollTx slot qidx reqId tries
  | tries <= 0 = return False
  | otherwise = do
      busyDelayUs 2000
      r <- conPollUsed slot qidx
      case r of
        Right (Just (cid, _)) -> if cid == reqId then return True else pollTx slot qidx reqId (tries - 1)
        Right Nothing -> pollTx slot qidx reqId (tries - 1)
        Left _ -> return False

-- | Free serial control queues (console passes Nothing).
freeCtrl :: Maybe (VirtQueue, VirtQueue) -> H ()
freeCtrl Nothing = return ()
freeCtrl (Just (a, b)) = do freeQueue a; freeQueue b

-- | dmesg suffix for serial inits.
serialNote :: ConKind -> String
serialNote ConConsole = ""
serialNote (ConSerial p) = " serial ports=" ++ show p

-- | Serial control queues (q2/q3). Console yields Nothing; runs before
-- DRIVER_OK next to the port queue setup. Failures free what they took.
setupSerialCtrl :: ConKind -> Int -> H (Either ConError (Maybe (VirtQueue, VirtQueue)))
setupSerialCtrl ConConsole _ = return (Right Nothing)
setupSerialCtrl (ConSerial _) slot = do
  qmaxRxRes <- liftIO $ alloca $ \pMax -> do r <- c_qmax_q slot 2 pMax; if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
  qmaxTxRes <- liftIO $ alloca $ \pMax -> do r <- c_qmax_q slot 3 pMax; if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
  case (qmaxRxRes, qmaxTxRes) of
    (Right qmaxRx, Right qmaxTx) -> do
      let qsizeRx = min qmaxRx 64
          qsizeTx = min qmaxTx 64
      if qsizeRx == 0 || qsizeTx == 0
        then return (Left (ConInvalidArg "serial ctrl QueueNumMax 0"))
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
                  setupRx <- liftIO $ c_qsetup_q slot 2 (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) qsizeRx
                  if setupRx /= 0
                    then do freeQueue vqRx; freeQueue vqTx; Dmesg.dmesgLog ("con setupCtrlRx slot " ++ show slot ++ "=" ++ show setupRx); return (Left (ConIoError setupRx))
                    else do
                      setupTx <- liftIO $ c_qsetup_q slot 3 (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeTx
                      if setupTx /= 0
                        then do freeQueue vqRx; freeQueue vqTx; Dmesg.dmesgLog ("con setupCtrlTx slot " ++ show slot ++ "=" ++ show setupTx); return (Left (ConIoError setupTx))
                        else do
                          _ <- conSaveCtrlQueues slot (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeRx qsizeTx
                          return (Right (Just (vqRx, vqTx)))
    _ -> return (Left (ConIoError 5))

-- Virtio console control events (Linux UAPI virtio_console.h, which QEMU
-- includes): DEVICE_READY 0, PORT_ADD 1, PORT_READY 3, PORT_OPEN 6.
ctrlEvReady, ctrlEvAdd, ctrlEvPortReady, ctrlEvPortOpen :: Word32
ctrlEvReady = 0
ctrlEvAdd = 1
ctrlEvPortReady = 3
ctrlEvPortOpen = 6

-- | Control message bytes: {id LE32, event LE16, value LE16}.
pokeCtrl :: Ptr Word8 -> Word32 -> Word32 -> Word32 -> IO ()
pokeCtrl p i ev v = do
  poke (p `plusPtr` 0) (fromIntegral i :: Word8)
  poke (p `plusPtr` 1) (fromIntegral (i `shiftR` 8) :: Word8)
  poke (p `plusPtr` 2) (fromIntegral (i `shiftR` 16) :: Word8)
  poke (p `plusPtr` 3) (fromIntegral (i `shiftR` 24) :: Word8)
  poke (p `plusPtr` 4) (fromIntegral ev :: Word8)
  poke (p `plusPtr` 5) (fromIntegral (ev `shiftR` 8) :: Word8)
  poke (p `plusPtr` 6) (fromIntegral v :: Word8)
  poke (p `plusPtr` 7) (fromIntegral (v `shiftR` 8) :: Word8)

-- | Wait for the posted control-RX buffer to complete and parse the event
-- as (port id, event). Nothing on timeout, error, or short (< 8 B) reply.
waitCtrlEvent :: Int -> Word32 -> Ptr Word8 -> Int -> H (Maybe (Int, Int))
waitCtrlEvent slot rid ptr tries
  | tries <= 0 = return Nothing
  | otherwise = do
      busyDelayUs 2000
      r <- conPollUsed slot 2
      case r of
        Right (Just (cid, ulen)) ->
          if cid == rid
            then
              if ulen < 8
                then return Nothing
                else do
                  -- Device-written event bytes: invalidate-before-read, same as conReadBytes.
                  conInvalidate (c_pagePa ptr) 256
                  liftIO $ do
                    b0 <- peek (ptr `plusPtr` 0) :: IO Word8
                    b1 <- peek (ptr `plusPtr` 1) :: IO Word8
                    b2 <- peek (ptr `plusPtr` 2) :: IO Word8
                    b3 <- peek (ptr `plusPtr` 3) :: IO Word8
                    b4 <- peek (ptr `plusPtr` 4) :: IO Word8
                    b5 <- peek (ptr `plusPtr` 5) :: IO Word8
                    b6 <- peek (ptr `plusPtr` 6) :: IO Word8
                    b7 <- peek (ptr `plusPtr` 7) :: IO Word8
                    return (decodeCtrlEvent [b0, b1, b2, b3, b4, b5, b6, b7])
            else waitCtrlEvent slot rid ptr (tries - 1)
        Right Nothing -> waitCtrlEvent slot rid ptr (tries - 1)
        Left _ -> return Nothing

-- | Serial port discovery: DEVICE_READY, then take the first PORT_ADD id.
-- Port 0 is QEMU's reserved console stub; real virtserialport ids start at 1
-- and live on queues 2*id/2*id+1. The posted buffer is freed on completion;
-- on timeout it is leaked once (never freed while posted) and init fails.
discoverPort :: Int -> H (Either ConError Int)
discoverPort slot = do
  mgRx <- G.grantAlloc
  case mgRx of
    Left _ -> return (Left ConNoSpace)
    Right gRx -> do
      rsub <- conSubmitCtrlRx slot (grantPage gRx) 256
      case rsub of
        Left e -> do G.grantFree gRx; return (Left e)
        Right rid -> do
          mgTx <- G.grantAlloc
          case mgTx of
            Left _ -> do G.grantFree gRx; return (Left ConNoSpace)
            Right gTx -> do
              let ptr = grantPage gTx
              liftIO $ pokeCtrl ptr 0 ctrlEvReady 1
              r1 <- conSubmitCtrlTx slot ptr 8
              case r1 of
                Left e -> do G.grantFree gTx; G.grantFree gRx; return (Left e)
                Right tid -> do
                  ok <- pollTx slot 3 tid 500
                  G.grantFree gTx
                  if not ok
                    then do G.grantFree gRx; return (Left (ConIoError 99))
                    else do
                      mEv <- waitCtrlEvent slot rid (grantPage gRx) 500
                      case mEv of
                        Just (pid, ev) | ev == fromIntegral ctrlEvAdd && pid >= 0 && pid <= 31 -> do
                          G.grantFree gRx
                          Dmesg.dmesgLog ("con slot " ++ show slot ++ ": serial PORT_ADD id=" ++ show pid)
                          return (Right pid)
                        Just _ -> do G.grantFree gRx; return (Left (ConIoError 97))
                        Nothing -> return (Left (ConIoError 97))

-- | Serial port open: PORT_READY then PORT_OPEN for a discovered id.
-- QEMU marks guest_connected on OPEN, which unblocks both directions.
openPort :: Int -> Int -> H (Either ConError ())
openPort slot pid = do
  mg <- G.grantAlloc
  case mg of
    Left _ -> return (Left ConNoSpace)
    Right g -> do
      let ptr = grantPage g
          qpid = fromIntegral pid :: Word32
      liftIO $ pokeCtrl ptr qpid ctrlEvPortReady 1
      r1 <- conSubmitCtrlTx slot ptr 8
      case r1 of
        Left e -> do G.grantFree g; return (Left e)
        Right tid1 -> do
          ok1 <- pollTx slot 3 tid1 500
          if not ok1
            then do G.grantFree g; return (Left (ConIoError 99))
            else do
              liftIO $ pokeCtrl ptr qpid ctrlEvPortOpen 1
              r2 <- conSubmitCtrlTx slot ptr 8
              case r2 of
                Left e -> do G.grantFree g; return (Left e)
                Right tid2 -> do
                  ok2 <- pollTx slot 3 tid2 500
                  G.grantFree g
                  if ok2
                    then do Dmesg.dmesgLog ("con slot " ++ show slot ++ ": serial PORT_OPEN id=" ++ show pid); return (Right ())
                    else return (Left (ConIoError 99))

-- Allocates, flushes, and QueueReady-marks both queues. Cleans up on failure.

-- | Port queue pair setup for explicit transport indices (console 0/1,
-- serial port 0 on 0/1, port N>=1 on 2*N+2/2*N+3).
-- Allocates, flushes, and QueueReady-marks both queues. Cleans up on failure.
setupPortQueues :: Int -> Int -> Int -> H (Either ConError (VirtQueue, VirtQueue, Word32, Word32))
setupPortQueues slot rxQ txQ
  | not (slotValid slot) = return (Left ConBadSlot)
  | rxQ < 0 || rxQ > 127 || txQ < 0 || txQ > 127 = return (Left (ConInvalidArg "port qidx"))
  | otherwise = do
      qmaxRxRes <- liftIO $ alloca $ \pMax -> do r <- c_qmax_q slot rxQ pMax; if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
      qmaxTxRes <- liftIO $ alloca $ \pMax -> do r <- c_qmax_q slot txQ pMax; if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
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
                      setupRx <- liftIO $ c_qsetup_q slot rxQ (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) qsizeRx
                      if setupRx /= 0
                        then do freeQueue vqRx; freeQueue vqTx; Dmesg.dmesgLog ("con setupRx slot " ++ show slot ++ "=" ++ show setupRx); return (Left (ConIoError setupRx))
                        else do
                          setupTx <- liftIO $ c_qsetup_q slot txQ (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeTx
                          if setupTx /= 0
                            then do freeQueue vqRx; freeQueue vqTx; Dmesg.dmesgLog ("con setupTx slot " ++ show slot ++ "=" ++ show setupTx); return (Left (ConIoError setupTx))
                            else return (Right (vqRx, vqTx, qsizeRx, qsizeTx))
        _ -> return (Left (ConIoError 5))

-- | Attach a live device: IRQ, endpoint, registry, RX replenish. Shared by
-- the console and serial init paths.
attachDevice :: Int -> ConKind -> VirtQueue -> VirtQueue -> Maybe (VirtQueue, VirtQueue) -> H (Either ConError ConDevice)
attachDevice slot kind vqRx vqTx mCtrl = do
  DGIC.enableSpi (fromIntegral (16 + slot))
  ep <- IPC.newEndpoint
  _ <- DIRQ.registerIrqForwarding (spi (fromIntegral (16 + slot))) ep
  let intid = spi (fromIntegral (16 + slot))
  let dev = ConDevice slot intid ep vqRx vqTx mCtrl
  rReg <- DrvReg.registerDriver ("virtio-con" ++ show slot) ep (Just intid) VirtioMMIO
  case rReg of
    Left _ -> do freeQueue vqRx; freeQueue vqTx; freeCtrl mCtrl; return (Left (ConInvalidArg "register failed"))
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
      Dmesg.dmesgLog
        ( "con slot "
            ++ show slot
            ++ ": init ok"
            ++ " qsize0="
            ++ show (queueSize vqRx)
            ++ " qsize1="
            ++ show (queueSize vqTx)
            ++ serialNote kind
        )
      return (Right dev)
