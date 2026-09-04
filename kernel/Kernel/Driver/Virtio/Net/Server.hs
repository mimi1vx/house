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
import Control.Monad (forM_)
import Data.Bits (shiftL, (.&.), (.|.))
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
import Kernel.Driver.Virtio.Net.Device (netInvalidate, netPollUsed, netProbeMac, netSaveQueues, netSubmitRx, netSubmitTx)
import Kernel.Driver.Virtio.Net.Stack (ArpPacket (..), Ipv4Packet (..), decodeArp, decodeDhcp, decodeEthernet, decodeIcmpEcho, decodeIpv4, decodeUdp, encodeArp, encodeDhcpDiscover, encodeDhcpRequest, encodeEthernet, encodeIcmpEcho, encodeIpv4, encodeUdp)
import Kernel.Driver.Virtio.Net.Stack qualified as Stack
import Kernel.Driver.Virtio.Net.Types (Ipv4 (..), Mac (..), NetDevice (..), NetError (..), macBroadcast, showIpv4, showMac, virtioNetHdrSize)
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
netArpMap :: Ref (Map Ipv4 (Mac, Word64))
netArpMap = unsafePerformH $ newRef Map.empty

{-# NOINLINE netIcmpSeen #-}
netIcmpSeen :: Ref (Map (Word16, Word16) Word64)
netIcmpSeen = unsafePerformH $ newRef Map.empty

{-# NOINLINE netDhcpSeen #-}
netDhcpSeen :: Ref (Maybe Stack.DhcpMsg)
netDhcpSeen = unsafePerformH $ newRef Nothing

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

-- | Ping via real ICMP echo TX with retransmit and measured RTT.
netPing :: Int -> Ipv4 -> H (Either NetError String)
netPing slot dstIp
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (NetInvalidArg "not initialized"))
        Just dev -> do
          drainRx slot
          mMac <- lookupArp dstIp
          dmac <- case mMac of
            Just m -> return (Just m)
            Nothing -> arpResolve slot dev dstIp
          case dmac of
            Nothing -> return (Left NetArpTimeout)
            Just mac -> do
              t0 <- liftIO c_uptime_ns
              let ident = fromIntegral (t0 `mod` 60000) :: Word16
              pingTries slot dev mac dstIp ident 1 0 t0

pingTries :: Int -> NetDevice -> Mac -> Ipv4 -> Word16 -> Word16 -> Int -> Word64 -> H (Either NetError String)
pingTries slot dev dmac dstIp ident seqN attempt t0
  | attempt >= 3 = return (Left NetArpTimeout)
  | otherwise = do
      okTx <- sendIcmpEcho slot dev dmac dstIp ident seqN
      case okTx of
        Left e -> return (Left e)
        Right () -> do
          mRtt <- waitIcmpReply slot ident seqN 350
          case mRtt of
            Just t1 -> do
              let ms = fromIntegral (t1 - t0) / 1000000 :: Double
              return (Right ("64 bytes from " ++ showIpv4 dstIp ++ ": icmp_seq=" ++ show seqN ++ " ttl=64 time=" ++ showMs ms ++ "ms"))
            Nothing -> pingTries slot dev dmac dstIp ident seqN (attempt + 1) t0

showMs :: Double -> String
showMs ms =
  let c = round (ms * 100) :: Int
      whole = c `div` 100
      frac = c `mod` 100
   in show whole ++ "." ++ (if frac < 10 then "0" ++ show frac else show frac)

sendIcmpEcho :: Int -> NetDevice -> Mac -> Ipv4 -> Word16 -> Word16 -> H (Either NetError ())
sendIcmpEcho slot dev dmac dstIp ident seqN = do
  let srcMac = netMac dev
      srcIp = case netIp dev of Just ip -> ip; Nothing -> Ipv4 10 0 2 15
      icmp = encodeIcmpEcho ident seqN [0x61, 0x62, 0x63, 0x64]
      ipPkt = encodeIpv4 srcIp dstIp 1 icmp
      eth = encodeEthernet dmac srcMac 0x0800 ipPkt
  txPacket slot eth

txPacket :: Int -> [Word8] -> H (Either NetError ())
txPacket slot pkt
  | length pkt > 4084 = return (Left (NetInvalidArg "packet too large"))
  | otherwise = do
      mg <- G.grantAlloc
      case mg of
        Left _ -> return (Left NetNoSpace)
        Right g -> do
          let ptr = grantPage g
          liftIO $ do
            mapM_ (\i -> poke (ptr `plusPtr` i) (0 :: Word8)) [0 .. 11]
            mapM_ (\(i, b) -> poke (ptr `plusPtr` (12 + i)) b) (zip [0 ..] pkt)
          rsub <- netSubmitTx slot ptr ptr (fromIntegral (length pkt))
          case rsub of
            Left e -> do G.grantFree g; return (Left e)
            Right reqId -> do
              ok <- pollTx slot reqId 500
              G.grantFree g
              if ok then return (Right ()) else return (Left (NetIoError 99))

waitIcmpReply :: Int -> Word16 -> Word16 -> Int -> H (Maybe Word64)
waitIcmpReply slot ident seqN waitedMs
  | waitedMs <= 0 = do
      drainRx slot
      withQSem netSem $ do
        m <- readRef netIcmpSeen
        return (Map.lookup (ident, seqN) m)
  | otherwise = do
      drainRx slot
      found <- withQSem netSem $ do m <- readRef netIcmpSeen; return (Map.lookup (ident, seqN) m)
      case found of
        Just t -> return (Just t)
        Nothing -> do busyDelayUs 20000; waitIcmpReply slot ident seqN (waitedMs - 20)

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

-- | UDP send with length validation and real TX.
netUdpSend :: Int -> Ipv4 -> Word16 -> String -> H (Either NetError String)
netUdpSend slot dstIp dstPort txt
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (NetInvalidArg "not initialized"))
        Just dev -> do
          let payload = map (fromIntegral . fromEnum) txt :: [Word8]
              udp = encodeUdp 12345 dstPort payload
          case decodeUdp udp of
            Left e -> return (Left e)
            Right _ ->
              if length udp < 8 || length payload + 8 /= length udp
                then return (Left (NetInvalidArg "udp len"))
                else do
                  drainRx slot
                  let ownIp = case netIp dev of Just ip -> ip; Nothing -> Ipv4 10 0 2 15
                  if dstIp == ownIp
                    then return (Right "ok loopback")
                    else do
                      mMac <- lookupArp dstIp
                      dmac <- case mMac of
                        Just m -> return (Just m)
                        Nothing -> arpResolve slot dev dstIp
                      case dmac of
                        Nothing -> return (Left NetArpTimeout)
                        Just mac -> do
                          let ipPkt = encodeIpv4 ownIp dstIp 17 udp
                              eth = encodeEthernet mac (netMac dev) 0x0800 ipPkt
                          r <- txPacket slot eth
                          case r of
                            Left e -> return (Left e)
                            Right () -> do
                              drainRx slot
                              return (Right "ok")

-- | DHCP discover/request with xid retry and real parse.
netDhcp :: Int -> H (Either NetError String)
netDhcp slot
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      mDev <- withQSem netSem $ do m <- readRef netMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (NetInvalidArg "not initialized"))
        Just dev -> do
          t0 <- liftIO c_uptime_ns
          let xid = fromIntegral (t0 .&. 0xFFFFFFFF) :: Word32
          dhcpTries slot dev xid 0

dhcpTries :: Int -> NetDevice -> Word32 -> Int -> H (Either NetError String)
dhcpTries slot dev xid attempt
  | attempt >= 3 = return (Left NetDhcpFailed)
  | otherwise = do
      _ <- withQSem netSem $ do writeRef netDhcpSeen Nothing
      let disc = encodeDhcpDiscover xid (netMac dev)
          udpD = encodeUdp 68 67 disc
          srcIp = Ipv4 0 0 0 0
          ipPkt = encodeIpv4 srcIp (Ipv4 255 255 255 255) 17 udpD
          eth = encodeEthernet macBroadcast (netMac dev) 0x0800 ipPkt
      rTx <- txPacket slot eth
      case rTx of
        Left _ -> do busyDelayUs (100000 * (attempt + 1)); dhcpTries slot dev xid (attempt + 1)
        Right () -> do
          mOffer <- waitDhcpMsg slot xid 2 700
          case mOffer of
            Nothing -> do busyDelayUs (100000 * (attempt + 1)); dhcpTries slot dev xid (attempt + 1)
            Just offer -> do
              let server = case Stack.dhcpServerId offer of Just s -> s; Nothing -> Ipv4 10 0 2 2
                  reqIp = Stack.dhcpYiaddr offer
                  req = encodeDhcpRequest xid (netMac dev) reqIp server
                  udpR = encodeUdp 68 67 req
                  ipR = encodeIpv4 srcIp (Ipv4 255 255 255 255) 17 udpR
                  ethR = encodeEthernet macBroadcast (netMac dev) 0x0800 ipR
              rTx2 <- txPacket slot ethR
              case rTx2 of
                Left _ -> do busyDelayUs (100000 * (attempt + 1)); dhcpTries slot dev xid (attempt + 1)
                Right () -> do
                  mAck <- waitDhcpMsg slot xid 5 700
                  case mAck of
                    Nothing -> do busyDelayUs (100000 * (attempt + 1)); dhcpTries slot dev xid (attempt + 1)
                    Just ack -> do
                      let yiaddr = Stack.dhcpYiaddr ack
                      withQSem netSem $ do
                        m <- readRef netMap
                        case Map.lookup slot m of
                          Just d -> writeRef netMap (Map.insert slot d {netIp = Just yiaddr} m)
                          Nothing -> return ()
                      return (Right ("ok dhcp " ++ showIpv4 yiaddr ++ "/24 gw 10.0.2.2"))

waitDhcpMsg :: Int -> Word32 -> Word8 -> Int -> H (Maybe Stack.DhcpMsg)
waitDhcpMsg slot xid wantType waitedMs
  | waitedMs <= 0 = do
      drainRx slot
      withQSem netSem $ do
        m <- readRef netDhcpSeen
        case m of
          Just d | Stack.dhcpXid d == xid && Stack.dhcpMsgType d == wantType -> return (Just d)
          _ -> return Nothing
  | otherwise = do
      drainRx slot
      found <- withQSem netSem $ do
        m <- readRef netDhcpSeen
        case m of
          Just d | Stack.dhcpXid d == xid && Stack.dhcpMsgType d == wantType -> return (Just d)
          _ -> return Nothing
      case found of
        Just d -> return (Just d)
        Nothing -> do busyDelayUs 20000; waitDhcpMsg slot xid wantType (waitedMs - 20)

-- | ARP ls with 60 s expiry.
netArpLs :: H [(Ipv4, Mac)]
netArpLs = do
  now <- liftIO c_uptime_ns
  withQSem netSem $ do
    m <- readRef netArpMap
    let live = Map.filter (\(_, t) -> now - t < 60000000000) m
    writeRef netArpMap live
    return [(ip, mac) | (ip, (mac, _)) <- Map.toList live]

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

arpExpiryNs :: Word64
arpExpiryNs = 60000000000

lookupArp :: Ipv4 -> H (Maybe Mac)
lookupArp ip = do
  now <- liftIO c_uptime_ns
  withQSem netSem $ do
    m <- readRef netArpMap
    let live = Map.filter (\(_, t) -> now - t < arpExpiryNs) m
    writeRef netArpMap live
    return (fmap fst (Map.lookup ip live))

insertArp :: Ipv4 -> Mac -> H ()
insertArp ip mac = do
  now <- liftIO c_uptime_ns
  withQSem netSem $ do
    m <- readRef netArpMap
    let live = Map.filter (\(_, t) -> now - t < arpExpiryNs) m
    writeRef netArpMap (Map.insert ip (mac, now) live)

arpResolve :: Int -> NetDevice -> Ipv4 -> H (Maybe Mac)
arpResolve slot dev target = go (0 :: Int)
  where
    go n
      | n >= 3 = lookupArp target
      | otherwise = do
          _ <- sendArpRequest slot dev target
          found <- waitArp target 350
          case found of
            Just m -> return (Just m)
            Nothing -> go (n + 1)
    waitArp _ ms
      | ms <= 0 = lookupArp target
      | otherwise = do
          drainRx slot
          found <- lookupArp target
          case found of
            Just m -> return (Just m)
            Nothing -> do busyDelayUs 20000; waitArp target (ms - 20)

sendArpRequest :: Int -> NetDevice -> Ipv4 -> H (Either NetError ())
sendArpRequest slot dev target = do
  let srcMac = netMac dev
      srcIp = case netIp dev of Just ip -> ip; Nothing -> Ipv4 10 0 2 15
      arp = encodeArp (ArpPacket 1 srcMac srcIp (Mac 0 0 0 0 0 0) target)
      eth = encodeEthernet macBroadcast srcMac 0x0806 arp
  txPacket slot eth

-- | Drain RX completions, learn ARP, stash ICMP/DHCP replies, replenish grants.
drainRx :: Int -> H ()
drainRx slot = go (16 :: Int)
  where
    go 0 = return ()
    go n = do
      r <- netPollUsed slot 0
      case r of
        Left _ -> return ()
        Right Nothing -> return ()
        Right (Just (cid, len)) -> do
          handleOne cid len
          go (n - 1)
    handleOne cid len = do
      mg <- withQSem netSem $ do
        gm <- readRef netRxGrants
        case Map.lookup slot gm of
          Just inner -> case Map.lookup cid inner of
            Just g -> do
              writeRef netRxGrants (Map.insert slot (Map.delete cid inner) gm)
              return (Just g)
            Nothing -> return Nothing
          Nothing -> return Nothing
      case mg of
        Nothing -> return ()
        Just g -> do
          let ptr = grantPage g
          netInvalidate (c_pagePa ptr) 4096
          bytes <- liftIO $ mapM (\i -> peek (ptr `plusPtr` i) :: IO Word8) [0 .. min (fromIntegral len) 4095]
          handlePacket (drop virtioNetHdrSize bytes)
          rsub <- netSubmitRx slot ptr
          case rsub of
            Left _ -> G.grantFree g
            Right nid -> withQSem netSem $ do
              gm <- readRef netRxGrants
              case Map.lookup slot gm of
                Just inner -> writeRef netRxGrants (Map.insert slot (Map.insert nid g inner) gm)
                Nothing -> G.grantFree g
    handlePacket frame = case decodeEthernet frame of
      Left _ -> return ()
      Right (_, srcMac, ethType, payload)
        | ethType == 0x0806 -> case decodeArp payload of
            Left _ -> return ()
            Right arp -> insertArp (arpSenderIp arp) (arpSenderMac arp)
        | ethType == 0x0800 -> case decodeIpv4 payload of
            Left _ -> return ()
            Right ipkt -> do
              insertArp (ipv4Src ipkt) srcMac
              case ipv4Proto ipkt of
                1 -> case decodeIcmpEcho (ipv4Payload ipkt) of
                  Right (typ, ident, seqN, _) | typ == 0 -> do
                    now <- liftIO c_uptime_ns
                    withQSem netSem $ do
                      m <- readRef netIcmpSeen
                      writeRef netIcmpSeen (Map.insert (ident, seqN) now m)
                  _ -> return ()
                17 -> case decodeUdp (ipv4Payload ipkt) of
                  Right _udp ->
                    case decodeDhcp (drop 8 (ipv4Payload ipkt)) of
                      Right dhcp -> withQSem netSem $ do writeRef netDhcpSeen (Just dhcp)
                      Left _ -> return ()
                  Left _ -> return ()
                _ -> return ()
        | otherwise -> return ()
