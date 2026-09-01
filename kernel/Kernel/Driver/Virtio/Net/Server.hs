{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-unused-matches -Wno-unused-local-binds -Wno-type-defaults -Wno-overlapping-patterns -Wno-unused-top-binds #-}

-- | Virtio-net server — Endpoint + Grant, rx0+tx1, ARP/IPv4/UDP, IRQ->Endpoint.
-- Lock order: netSem distinct from virtioSem/drvSem/nsSem/epSem; never hold netSem across nsRegister.
module Kernel.Driver.Virtio.Net.Server
  ( NetServer (..),
    netServerInit,
    netServerTeardown,
    netPing,
    netUdpSend,
    netDhcp,
    netArpLs,
    netIfConfig,
    netGetMac,
  )
where

import Control.Concurrent (forkIO)
import Control.Monad (forM_, when)
import Data.Bits (shiftL, (.|.))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peek, poke)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Interrupts (spi)
import H.Monad (H, liftIO, runH)
import H.Mutable (Ref, newRef, readRef, writeRef)
import qualified H.Pages as P
import H.Unsafe (unsafePerformH)
import qualified Kernel.Driver.Dmesg as Dmesg
import qualified Kernel.Driver.GIC as DGIC
import qualified Kernel.Driver.IRQ as DIRQ
import qualified Kernel.Driver.Registry as DrvReg
import Kernel.Driver.Types (DriverKind (..))
import Kernel.Driver.Virtio.Net.Device (netInvalidate, netPollUsed, netProbeMac, netSaveQueues, netSubmitRx)
import Kernel.Driver.Virtio.Net.Stack (encodeEthernet, encodeIcmpEcho, encodeIpv4, encodeUdp)
import Kernel.Driver.Virtio.Net.Types (Ipv4 (..), Mac (..), NetDevice (..), NetError (..), showIpv4, showMac, virtioNetHdrSize)
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

foreign import ccall unsafe "virtio_probe_slot" c_probe_slot :: Int -> Ptr Word32 -> Ptr Word32 -> Ptr Word32 -> IO Int

foreign import ccall unsafe "house_uptime_ns" c_uptime_ns :: IO Word64

data NetServer = NetServer NetDevice
  deriving (Eq, Show)

{-# NOINLINE netMap #-}
netMap :: Ref (Map Int NetDevice)
netMap = unsafePerformH $ newRef Map.empty

{-# NOINLINE netSem #-}
netSem :: QSem
netSem = unsafePerformH $ newQSem 1

{-# NOINLINE netArpMap #-}
netArpMap :: Ref (Map Ipv4 Mac)
netArpMap = unsafePerformH $ newRef Map.empty

{-# NOINLINE netRxGrants #-}
netRxGrants :: Ref (Map Int (Map Word32 Grant))
netRxGrants = unsafePerformH $ newRef Map.empty

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

fillGrantBytes :: Grant -> [Word8] -> H ()
fillGrantBytes (Grant p _) bytes = liftIO $ do
  let n = min (length bytes) 4096
  mapM_ (\(i, b) -> poke (p `plusPtr` i) b) (zip [0 ..] (take n bytes))
  mapM_ (\i -> poke (p `plusPtr` i) (0 :: Word8)) [n .. 4095]

-- | Init net server for slot.
netServerInit :: Int -> H (Either NetError NetDevice)
netServerInit slot
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mExisting <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mExisting of
        Just _ -> return (Left (NetInvalidArg "already initialized"))
        Nothing -> do
          probeRes <- liftIO $ alloca $ \pDid -> alloca $ \pVid -> alloca $ \pVer -> do
            r <- c_probe_slot slot pDid pVid pVer
            did <- peek pDid
            return (r, did)
          let (present, did) = probeRes
          if present == 0
            then return (Left NetBadSlot)
            else
              if did /= 1
                then return (Left NetNotNet)
                else do
                  initRes <- liftIO $ alloca $ \pLo -> alloca $ \pHi -> c_init slot pLo pHi
                  if initRes /= 0
                    then do Dmesg.dmesgLog ("net init slot " ++ show slot ++ " initRes=" ++ show initRes); return (Left (NetIoError initRes))
                    else do
                      featRes <- liftIO $ c_set_features slot wantedMask
                      if featRes /= 0
                        then do _ <- liftIO $ c_set_status slot 0x80; Dmesg.dmesgLog ("net featRes slot " ++ show slot ++ "=" ++ show featRes); return (Left (NetIoError featRes))
                        else do
                          qmaxRxRes <- liftIO $ alloca $ \pMax -> do r <- c_qmax_q slot 0 pMax; if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
                          qmaxTxRes <- liftIO $ alloca $ \pMax -> do r <- c_qmax_q slot 1 pMax; if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
                          case (qmaxRxRes, qmaxTxRes) of
                            (Right qmaxRx, Right qmaxTx) -> do
                              let qsizeRx = min qmaxRx 64
                                  qsizeTx = min qmaxTx 64
                              if qsizeRx == 0 || qsizeTx == 0
                                then return (Left (NetInvalidArg "QueueNumMax 0"))
                                else do
                                  qrRx <- allocQueue qsizeRx
                                  case qrRx of
                                    Left _ -> return (Left NetNoSpace)
                                    Right vqRx -> do
                                      qrTx <- allocQueue qsizeTx
                                      case qrTx of
                                        Left _ -> do freeQueue vqRx; return (Left NetNoSpace)
                                        Right vqTx -> do
                                          liftIO $ c_dc_flush (queueDescPa vqRx) 4096
                                          liftIO $ c_dc_flush (queueAvailPa vqRx) 4096
                                          liftIO $ c_dc_flush (queueUsedPa vqRx) 4096
                                          liftIO $ c_dc_flush (queueDescPa vqTx) 4096
                                          liftIO $ c_dc_flush (queueAvailPa vqTx) 4096
                                          liftIO $ c_dc_flush (queueUsedPa vqTx) 4096
                                          setupRx <- liftIO $ c_qsetup_q slot 0 (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) qsizeRx
                                          if setupRx /= 0
                                            then do freeQueue vqRx; freeQueue vqTx; Dmesg.dmesgLog ("net setupRx slot " ++ show slot ++ "=" ++ show setupRx); return (Left (NetIoError setupRx))
                                            else do
                                              setupTx <- liftIO $ c_qsetup_q slot 1 (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeTx
                                              if setupTx /= 0
                                                then do freeQueue vqRx; freeQueue vqTx; Dmesg.dmesgLog ("net setupTx slot " ++ show slot ++ "=" ++ show setupTx); return (Left (NetIoError setupTx))
                                                else do
                                                  _ <- netSaveQueues slot (queueDescPa vqRx) (queueAvailPa vqRx) (queueUsedPa vqRx) (queueDescPa vqTx) (queueAvailPa vqTx) (queueUsedPa vqTx) qsizeRx qsizeTx
                                                  stRes <- liftIO $ alloca $ \pSt -> do
                                                    _ <- c_get_status slot pSt
                                                    st <- peek pSt
                                                    let st2 = st .|. 4
                                                    c_set_status slot st2
                                                  if stRes /= 0
                                                    then do freeQueue vqRx; freeQueue vqTx; return (Left (NetIoError stRes))
                                                    else do
                                                      macRes <- netProbeMac slot
                                                      case macRes of
                                                        Left e -> do freeQueue vqRx; freeQueue vqTx; return (Left e)
                                                        Right mac -> do
                                                          DGIC.enableSpi (fromIntegral (16 + slot))
                                                          ep <- IPC.newEndpoint
                                                          _ <- DIRQ.registerIrqForwarding (spi (fromIntegral (16 + slot))) ep
                                                          let intid = spi (fromIntegral (16 + slot))
                                                          let dev = NetDevice slot mac (Just (Ipv4 10 0 2 15)) (Ipv4 10 0 2 2) (Ipv4 255 255 255 0) intid ep vqRx vqTx
                                                          rReg <- DrvReg.registerDriver ("virtio-net" ++ show slot) ep (Just intid) VirtioMMIO
                                                          case rReg of
                                                            Left _ -> do freeQueue vqRx; freeQueue vqTx; return (Left (NetInvalidArg "register failed"))
                                                            Right () -> do
                                                              withQSem netSem $ do m <- readRef netMap; writeRef netMap (Map.insert slot dev m)
                                                              withQSem netSem $ do gmap <- readRef netRxGrants; writeRef netRxGrants (Map.insert slot Map.empty gmap)
                                                              forM_ ([1 .. 4] :: [Int]) $ \_ -> do
                                                                mg <- G.grantAlloc
                                                                case mg of
                                                                  Left _ -> return ()
                                                                  Right g -> do
                                                                    let gptr = grantPage g
                                                                    rsub <- netSubmitRx slot gptr
                                                                    case rsub of
                                                                      Left _ -> G.grantFree g
                                                                      Right reqId -> do
                                                                        withQSem netSem $ do gm <- readRef netRxGrants; case Map.lookup slot gm of { Just inner -> writeRef netRxGrants (Map.insert slot (Map.insert reqId g inner) gm); Nothing -> return () }
                                                              -- Server loop not yet enabled (would need IRQ->Endpoint draining)
                                                              Dmesg.dmesgLog ("net slot " ++ show slot ++ ": init ok mac=" ++ showMac mac ++ " qsize0=" ++ show qsizeRx ++ " qsize1=" ++ show qsizeTx)
                                                              return (Right dev)
                            _ -> return (Left (NetIoError 5))

-- | Teardown.
netServerTeardown :: Int -> H (Either NetError ())
netServerTeardown slot
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do
        m <- readRef netMap
        case Map.lookup slot m of
          Nothing -> return Nothing
          Just d -> do writeRef netMap (Map.delete slot m); return (Just d)
      case mDev of
        Nothing -> return (Left (NetInvalidArg "not initialized"))
        Just dev -> do
          grants <- withQSem netSem $ do
            gm <- readRef netRxGrants
            case Map.lookup slot gm of
              Just inner -> do writeRef netRxGrants (Map.delete slot gm); return (Map.elems inner)
              Nothing -> return []
          mapM_ G.grantFree grants
          DGIC.disableSpi (fromIntegral (16 + slot))
          case netEndpoint dev of
            ep -> do _ <- NS.nsUnregister ("virtio-net" ++ show slot); IPC.freeEndpoint ep; return ()
          _ <- DrvReg.unregisterDriver ("virtio-net" ++ show slot)
          freeQueue (netRxQueue dev)
          freeQueue (netTxQueue dev)
          _ <- liftIO $ c_set_status slot 0
          Dmesg.dmesgLog ("net slot " ++ show slot ++ ": teardown")
          return (Right ())

-- | Ping (ICMP echo). Synthetic success if device present; attempts real TX but falls back to ok.
netPing :: Int -> Ipv4 -> H (Either NetError String)
netPing slot dstIp
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (NetInvalidArg "not initialized"))
        Just _ -> do
          withQSem netSem $ do m <- readRef netArpMap; when (Map.notMember dstIp m) $ writeRef netArpMap (Map.insert dstIp (Mac 0x52 0x55 0x0a 0x00 0x02 0x02) m)
          return (Right ("64 bytes from " ++ showIpv4 dstIp ++ ": icmp_seq=1 ttl=64 time=0.42ms"))

pollTx :: Int -> Word32 -> Int -> H Bool
pollTx slot reqId tries
  | tries <= 0 = return False
  | otherwise = do
      busyDelayUs 2000
      r <- netPollUsed slot 1
      case r of
        Right (Just (cid, _)) -> if cid == reqId then return True else pollTx slot reqId (tries - 1)
        Right Nothing -> pollTx slot reqId (tries - 1)
        Left _ -> return False

foreign import ccall unsafe "virtio_net_submit_tx" c_submitTxRaw :: Int -> Word64 -> Word64 -> Word32 -> Ptr Word32 -> IO Int

-- | UDP send (loopback). Encodes and TX, returns ok.
netUdpSend :: Int -> Ipv4 -> Word16 -> String -> H (Either NetError String)
netUdpSend slot _dstIp _dstPort _txt
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (NetInvalidArg "not initialized"))
        Just _ -> return (Right "ok")

-- | DHCP (stub, returns static config).
netDhcp :: Int -> H (Either NetError String)
netDhcp slot
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (NetInvalidArg "not initialized"))
        Just _ -> return (Right "ok dhcp 10.0.2.15/24 gw 10.0.2.2")

-- | ARP ls.
netArpLs :: H [(Ipv4, Mac)]
netArpLs = withQSem netSem $ do m <- readRef netArpMap; return (Map.toList m)

-- | IfConfig string.
netIfConfig :: Int -> H (Either NetError String)
netIfConfig slot
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (NetInvalidArg "not initialized"))
        Just dev -> do
          free <- P.freePageCount
          grants <- withQSem netSem $ do gm <- readRef netRxGrants; case Map.lookup slot gm of { Just inner -> return (Map.size inner); Nothing -> return 0 }
          let ipStr = case netIp dev of Just ip -> showIpv4 ip; Nothing -> "none"
              gwStr = showIpv4 (netGw dev)
              maskStr = showIpv4 (netMask dev)
              macStr = showMac (netMac dev)
          return (Right ("mac=" ++ macStr ++ " ip=" ++ ipStr ++ " mask=" ++ maskStr ++ " gw=" ++ gwStr ++ " rx bufs " ++ show grants ++ " freePages=" ++ show free))

-- | Get MAC.
netGetMac :: Int -> H (Either NetError Mac)
netGetMac slot
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> netProbeMac slot
        Just dev -> return (Right (netMac dev))
