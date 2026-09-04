{-# OPTIONS_GHC -Wno-unused-imports #-}

-- | Pure packet encode/decode — ARP, IPv4, UDP, DHCP, ICMP checksum.
-- No FFI, total parsers returning Either NetError. Tested via ghci round-trip.
module Kernel.Driver.Virtio.Net.Stack
  ( ArpPacket (..),
    Ipv4Packet (..),
    UdpPacket (..),
    DhcpMsg (..),
    encodeEthernet,
    decodeEthernet,
    encodeArp,
    decodeArp,
    encodeIpv4,
    decodeIpv4,
    encodeUdp,
    decodeUdp,
    encodeIcmpEcho,
    decodeIcmpEcho,
    encodeDhcpDiscover,
    encodeDhcpRequest,
    decodeDhcp,
    ipv4Checksum,
    udpChecksum,
    macBroadcast,
    arpTableLookup,
  )
where

import Data.Bits (shiftL, shiftR, xor, (.&.), (.|.))
import Data.List (foldl')
import Data.Word (Word16, Word32, Word8)
import Kernel.Driver.Virtio.Net.Types (Ipv4 (..), Mac (..), NetError (..), macBroadcast, showIpv4, showMac)

-- | ARP packet.
data ArpPacket = ArpPacket
  { arpOp :: Word16,
    arpSenderMac :: Mac,
    arpSenderIp :: Ipv4,
    arpTargetMac :: Mac,
    arpTargetIp :: Ipv4
  }
  deriving (Eq, Show)

-- | IPv4 packet (without ethernet).
data Ipv4Packet = Ipv4Packet
  { ipv4Src :: Ipv4,
    ipv4Dst :: Ipv4,
    ipv4Proto :: Word8,
    ipv4Ttl :: Word8,
    ipv4Payload :: [Word8]
  }
  deriving (Eq, Show)

-- | UDP packet.
data UdpPacket = UdpPacket
  { udpSrcPort :: Word16,
    udpDstPort :: Word16,
    udpPayload :: [Word8]
  }
  deriving (Eq, Show)

-- | DHCP message (minimal).
data DhcpMsg = DhcpMsg
  { dhcpXid :: Word32,
    dhcpYiaddr :: Ipv4,
    dhcpSiaddr :: Ipv4,
    dhcpMsgType :: Word8,
    dhcpServerId :: Maybe Ipv4
  }
  deriving (Eq, Show)

-- | Encode ethernet header: dst(6) src(6) ethertype(2) ++ payload.
encodeEthernet :: Mac -> Mac -> Word16 -> [Word8] -> [Word8]
encodeEthernet dst src ethertype payload =
  macToList dst ++ macToList src ++ [fromIntegral (ethertype `shiftR` 8), fromIntegral ethertype] ++ payload
  where
    macToList (Mac a b c d e f) = [a, b, c, d, e, f]

-- | Decode ethernet: returns (dst,src,ethertype,payload) or error.
decodeEthernet :: [Word8] -> Either NetError (Mac, Mac, Word16, [Word8])
decodeEthernet bytes
  | length bytes < 14 = Left (NetInvalidArg "eth short")
  | otherwise =
      let (dstB, rest1) = splitAt 6 bytes
          (srcB, rest2) = splitAt 6 rest1
          (etB, payload) = splitAt 2 rest2
          dst = listToMac dstB
          src = listToMac srcB
          et = (fromIntegral (etB !! 0) `shiftL` 8) .|. fromIntegral (etB !! 1)
       in case (dst, src) of
            (Just d, Just s) -> Right (d, s, et, payload)
            _ -> Left (NetInvalidArg "eth mac")
  where
    listToMac [a, b, c, d, e, f] = Just (Mac a b c d e f)
    listToMac _ = Nothing

-- | Encode ARP: htype=1, ptype=0x0800, hlen=6, plen=4, op, sha, spa, tha, tpa.
encodeArp :: ArpPacket -> [Word8]
encodeArp p =
  [0x00, 0x01, 0x08, 0x00, 0x06, 0x04]
    ++ word16be (arpOp p)
    ++ macToList (arpSenderMac p)
    ++ ipv4ToList (arpSenderIp p)
    ++ macToList (arpTargetMac p)
    ++ ipv4ToList (arpTargetIp p)
  where
    macToList (Mac a b c d e f) = [a, b, c, d, e, f]
    ipv4ToList (Ipv4 a b c d) = [a, b, c, d]
    word16be w = [fromIntegral (w `shiftR` 8), fromIntegral w]

-- | Decode ARP packet (28 bytes after ethernet).
decodeArp :: [Word8] -> Either NetError ArpPacket
decodeArp bytes
  | length bytes < 28 = Left (NetInvalidArg "arp short")
  | otherwise =
      let htype = (fromIntegral (bytes !! 0) `shiftL` 8) .|. fromIntegral (bytes !! 1) :: Word16
          ptype = (fromIntegral (bytes !! 2) `shiftL` 8) .|. fromIntegral (bytes !! 3) :: Word16
          hlen = bytes !! 4
          plen = bytes !! 5
          op = (fromIntegral (bytes !! 6) `shiftL` 8) .|. fromIntegral (bytes !! 7) :: Word16
       in if htype /= 1 || ptype /= 0x0800 || hlen /= 6 || plen /= 4
            then Left (NetInvalidArg "arp header")
            else
              let sha = Mac (bytes !! 8) (bytes !! 9) (bytes !! 10) (bytes !! 11) (bytes !! 12) (bytes !! 13)
                  spa = Ipv4 (bytes !! 14) (bytes !! 15) (bytes !! 16) (bytes !! 17)
                  tha = Mac (bytes !! 18) (bytes !! 19) (bytes !! 20) (bytes !! 21) (bytes !! 22) (bytes !! 23)
                  tpa = Ipv4 (bytes !! 24) (bytes !! 25) (bytes !! 26) (bytes !! 27)
               in Right (ArpPacket op sha spa tha tpa)

-- | Compute IPv4 header checksum (ones complement).
ipv4Checksum :: [Word8] -> Word16
ipv4Checksum bytes = complement16 (foldl' add16 0 (chunks bytes))
  where
    chunks [] = []
    chunks [_] = [] -- odd pad ignored (should not happen for header)
    chunks (hi : lo : rest) = ((fromIntegral hi `shiftL` 8) .|. fromIntegral lo :: Word32) : chunks rest
    add16 acc w =
      let s = acc + w
       in (s .&. 0xFFFF) + (s `shiftR` 16)
    complement16 w = fromIntegral (xor (w .&. 0xFFFF) 0xFFFF)

-- | Encode IPv4 header + payload. Header 20 bytes: ver/ihl, tos, totalLen, id, flags/frag, ttl, proto, csum, src, dst.
encodeIpv4 :: Ipv4 -> Ipv4 -> Word8 -> [Word8] -> [Word8]
encodeIpv4 src dst proto payload =
  let totalLen = 20 + length payload
      headerNoCsum =
        [0x45, 0x00]
          ++ word16be (fromIntegral totalLen :: Word16)
          ++ [0x00, 0x00, 0x40, 0x00, 0x40, proto]
          ++ [0x00, 0x00]
          ++ ipv4ToList src
          ++ ipv4ToList dst
      csum = ipv4Checksum headerNoCsum
      header = take 10 headerNoCsum ++ word16be csum ++ drop 12 headerNoCsum
   in header ++ payload
  where
    word16be w = [fromIntegral (w `shiftR` 8), fromIntegral w]
    ipv4ToList (Ipv4 a b c d) = [a, b, c, d]

-- | Decode IPv4. Returns packet or error.
decodeIpv4 :: [Word8] -> Either NetError Ipv4Packet
decodeIpv4 bytes
  | length bytes < 20 = Left (NetInvalidArg "ipv4 short")
  | otherwise =
      let verIhl = bytes !! 0
          ver = verIhl `shiftR` 4
          ihl = verIhl .&. 0x0F
       in if ver /= 4 || ihl < 5
            then Left (NetInvalidArg "ipv4 ver/ihl")
            else
              let totalLen = (fromIntegral (bytes !! 2) `shiftL` 8) .|. fromIntegral (bytes !! 3) :: Int
                  ttl = bytes !! 8
                  proto = bytes !! 9
                  src = Ipv4 (bytes !! 12) (bytes !! 13) (bytes !! 14) (bytes !! 15)
                  dst = Ipv4 (bytes !! 16) (bytes !! 17) (bytes !! 18) (bytes !! 19)
                  hdrLen = fromIntegral ihl * 4
               in if length bytes < totalLen
                    then Left (NetInvalidArg "ipv4 len")
                    else
                      let payload = take (totalLen - hdrLen) (drop hdrLen bytes)
                       in Right (Ipv4Packet src dst proto ttl payload)

-- | Encode UDP: srcPort 2, dstPort 2, len 2, csum 2 (zero) + payload.
encodeUdp :: Word16 -> Word16 -> [Word8] -> [Word8]
encodeUdp src dst payload =
  let len = 8 + length payload
   in word16be src ++ word16be dst ++ word16be (fromIntegral len :: Word16) ++ [0x00, 0x00] ++ payload
  where
    word16be w = [fromIntegral (w `shiftR` 8), fromIntegral w]

-- | Decode UDP.
decodeUdp :: [Word8] -> Either NetError UdpPacket
decodeUdp bytes
  | length bytes < 8 = Left (NetInvalidArg "udp short")
  | otherwise =
      let src = (fromIntegral (bytes !! 0) `shiftL` 8) .|. fromIntegral (bytes !! 1) :: Word16
          dst = (fromIntegral (bytes !! 2) `shiftL` 8) .|. fromIntegral (bytes !! 3) :: Word16
          len = (fromIntegral (bytes !! 4) `shiftL` 8) .|. fromIntegral (bytes !! 5) :: Int
       in if len < 8 || length bytes < len
            then Left (NetInvalidArg "udp len")
            else Right (UdpPacket src dst (take (len - 8) (drop 8 bytes)))

-- | UDP checksum (pseudo header) — if we send 0, receiver accepts 0. Compute optionally.
udpChecksum :: Ipv4 -> Ipv4 -> [Word8] -> Word16
udpChecksum src dst udpBytes = ipv4Checksum (pseudo ++ udpBytes)
  where
    pseudo = ipv4ToList src ++ ipv4ToList dst ++ [0x00, 17] ++ word16be (fromIntegral (length udpBytes) :: Word16)
    word16be w = [fromIntegral (w `shiftR` 8), fromIntegral w]
    ipv4ToList (Ipv4 a b c d) = [a, b, c, d]

-- | Encode ICMP echo request: type 8 code 0 csum id seq payload.
encodeIcmpEcho :: Word16 -> Word16 -> [Word8] -> [Word8]
encodeIcmpEcho ident seqNum payload =
  let headerNoCsum = [0x08, 0x00, 0x00, 0x00] ++ word16be ident ++ word16be seqNum ++ payload
      csum = ipv4Checksum headerNoCsum
   in [0x08, 0x00] ++ word16be csum ++ word16be ident ++ word16be seqNum ++ payload
  where
    word16be w = [fromIntegral (w `shiftR` 8), fromIntegral w]

-- | Decode ICMP echo (check type 0 or 8). Returns (type,ident,seq,payload)
decodeIcmpEcho :: [Word8] -> Either NetError (Word8, Word16, Word16, [Word8])
decodeIcmpEcho bytes
  | length bytes < 8 = Left (NetInvalidArg "icmp short")
  | otherwise =
      let typ = bytes !! 0
          ident = (fromIntegral (bytes !! 4) `shiftL` 8) .|. fromIntegral (bytes !! 5) :: Word16
          seqNum = (fromIntegral (bytes !! 6) `shiftL` 8) .|. fromIntegral (bytes !! 7) :: Word16
          payload = drop 8 bytes
       in Right (typ, ident, seqNum, payload)

-- | Encode DHCP Discover (BOOTREQUEST). xid random.
encodeDhcpDiscover :: Word32 -> Mac -> [Word8]
encodeDhcpDiscover xid mac = encodeDhcp 1 xid mac Nothing Nothing

-- | Encode DHCP Request.
encodeDhcpRequest :: Word32 -> Mac -> Ipv4 -> Ipv4 -> [Word8]
encodeDhcpRequest xid mac reqIp serverId = encodeDhcp 3 xid mac (Just reqIp) (Just serverId)

encodeDhcp :: Word8 -> Word32 -> Mac -> Maybe Ipv4 -> Maybe Ipv4 -> [Word8]
encodeDhcp msgType xid mac mReq mServer =
  let op = 1 -- BOOTREQUEST
      htype = 1
      hlen = 6
      hops = 0
      secs = 0 :: Word16
      flags = 0x8000 :: Word16
      ciaddr = [0, 0, 0, 0]
      yiaddr = [0, 0, 0, 0]
      siaddr = [0, 0, 0, 0]
      giaddr = [0, 0, 0, 0]
      chaddr = macToList mac ++ replicate 10 0
      sname = replicate 64 0
      file = replicate 128 0
      cookie = [0x63, 0x82, 0x53, 0x63]
      opts =
        [53, 1, msgType]
          ++ maybe [] (\ip -> [50, 4] ++ ipv4ToList ip) mReq
          ++ maybe [] (\ip -> [54, 4] ++ ipv4ToList ip) mServer
          ++ [12, 4, 0x48, 0x4f, 0x55, 0x53] -- hostname "HOUS"
          ++ [55, 4, 1, 3, 6, 28]
          ++ [255]
   in [op, htype, hlen, hops]
        ++ word32be xid
        ++ word16be secs
        ++ word16be flags
        ++ ciaddr
        ++ yiaddr
        ++ siaddr
        ++ giaddr
        ++ chaddr
        ++ sname
        ++ file
        ++ cookie
        ++ opts
  where
    macToList (Mac a b c d e f) = [a, b, c, d, e, f]
    ipv4ToList (Ipv4 a b c d) = [a, b, c, d]
    word16be w = [fromIntegral (w `shiftR` 8), fromIntegral w]
    word32be w = [fromIntegral (w `shiftR` 24), fromIntegral (w `shiftR` 16), fromIntegral (w `shiftR` 8), fromIntegral w]

-- | ARP table lookup capped 32.
arpTableLookup :: Ipv4 -> [(Ipv4, Mac)] -> Maybe Mac
arpTableLookup ip tbl = lookup ip (take 32 tbl)

-- | Decode minimal DHCP BOOTREPLY. Total; options TLV walk bounded by packet length.
decodeDhcp :: [Word8] -> Either NetError DhcpMsg
decodeDhcp bytes
  | length bytes < 240 = Left (NetInvalidArg "dhcp short")
  | otherwise =
      let op = bytes !! 0
          xid =
            (fromIntegral (bytes !! 4) `shiftL` 24)
              .|. (fromIntegral (bytes !! 5) `shiftL` 16)
              .|. (fromIntegral (bytes !! 6) `shiftL` 8)
              .|. fromIntegral (bytes !! 7) ::
              Word32
          yiaddr = Ipv4 (bytes !! 16) (bytes !! 17) (bytes !! 18) (bytes !! 19)
          siaddr = Ipv4 (bytes !! 20) (bytes !! 21) (bytes !! 22) (bytes !! 23)
          cookie = take 4 (drop 236 bytes)
       in if op /= 2 || cookie /= [0x63, 0x82, 0x53, 0x63]
            then Left (NetInvalidArg "dhcp header")
            else case parseOpts (drop 240 bytes) Nothing Nothing of
              Nothing -> Left (NetInvalidArg "dhcp opts")
              Just (mtype, server) -> case mtype of
                Nothing -> Left (NetInvalidArg "dhcp no type")
                Just t -> Right (DhcpMsg xid yiaddr siaddr t server)
  where
    parseOpts [] mt sv = Just (mt, sv)
    parseOpts (255 : _) mt sv = Just (mt, sv)
    parseOpts (0 : rest) mt sv = parseOpts rest mt sv
    parseOpts (tag : len : rest) mt sv
      | tag == 53 && len == 1 && not (null rest) = parseOpts (drop 1 rest) (Just (rest !! 0)) sv
      | tag == 54 && len == 4 && length rest >= 4 =
          let svIp = Ipv4 (rest !! 0) (rest !! 1) (rest !! 2) (rest !! 3)
           in parseOpts (drop 4 rest) mt (Just svIp)
      | otherwise =
          let n = fromIntegral len
           in if n < 0 || length rest < n
                then Nothing
                else parseOpts (drop n rest) mt sv
    parseOpts [_] mt sv = Just (mt, sv)
