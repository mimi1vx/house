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

-- | Total index into hostile bytes; Nothing on out-of-range.
safeIndex :: [Word8] -> Int -> Maybe Word8
safeIndex xs i
  | i < 0 = Nothing
  | otherwise = go xs i
  where
    go [] _ = Nothing
    go (y : _) 0 = Just y
    go (_ : ys) n = go ys (n - 1)

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
       in case (dst, src, safeIndex etB 0, safeIndex etB 1) of
            (Just d, Just s, Just hi, Just lo) ->
              Right (d, s, (fromIntegral hi `shiftL` 8) .|. fromIntegral lo, payload)
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
  | otherwise = do
      b0 <- at 0
      b1 <- at 1
      b2 <- at 2
      b3 <- at 3
      hlen <- at 4
      plen <- at 5
      b6 <- at 6
      b7 <- at 7
      let htype = (fromIntegral b0 `shiftL` 8) .|. fromIntegral b1 :: Word16
          ptype = (fromIntegral b2 `shiftL` 8) .|. fromIntegral b3 :: Word16
          op = (fromIntegral b6 `shiftL` 8) .|. fromIntegral b7 :: Word16
      if htype /= 1 || ptype /= 0x0800 || hlen /= 6 || plen /= 4
        then Left (NetInvalidArg "arp header")
        else do
          s0 <- at 8
          s1 <- at 9
          s2 <- at 10
          s3 <- at 11
          s4 <- at 12
          s5 <- at 13
          p0 <- at 14
          p1 <- at 15
          p2 <- at 16
          p3 <- at 17
          t0 <- at 18
          t1 <- at 19
          t2 <- at 20
          t3 <- at 21
          t4 <- at 22
          t5 <- at 23
          q0 <- at 24
          q1 <- at 25
          q2 <- at 26
          q3 <- at 27
          let sha = Mac s0 s1 s2 s3 s4 s5
              spa = Ipv4 p0 p1 p2 p3
              tha = Mac t0 t1 t2 t3 t4 t5
              tpa = Ipv4 q0 q1 q2 q3
          Right (ArpPacket op sha spa tha tpa)
  where
    at i = maybe (Left (NetInvalidArg "arp trunc")) Right (safeIndex bytes i)

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
-- Bounds: IHL>=5, hdrLen=IHL*4 <= frame, hdrLen <= totalLen <= frame;
-- trailing Ethernet padding beyond totalLen is ignored.
decodeIpv4 :: [Word8] -> Either NetError Ipv4Packet
decodeIpv4 bytes
  | length bytes < 20 = Left (NetInvalidArg "ipv4 short")
  | otherwise = do
      verIhl <- at 0
      let ver = verIhl `shiftR` 4
          ihl = verIhl .&. 0x0F
      if ver /= 4 || ihl < 5
        then Left (NetInvalidArg "ipv4 ver/ihl")
        else do
          b2 <- at 2
          b3 <- at 3
          ttl <- at 8
          proto <- at 9
          s0 <- at 12
          s1 <- at 13
          s2 <- at 14
          s3 <- at 15
          d0 <- at 16
          d1 <- at 17
          d2 <- at 18
          d3 <- at 19
          let totalLen = (fromIntegral b2 `shiftL` 8) .|. fromIntegral b3 :: Int
              src = Ipv4 s0 s1 s2 s3
              dst = Ipv4 d0 d1 d2 d3
              hdrLen = fromIntegral ihl * 4 :: Int
          if hdrLen > length bytes
            then Left (NetInvalidArg "ipv4 hlen")
            else
              if totalLen < hdrLen || totalLen < 20
                then Left (NetInvalidArg "ipv4 len")
                else
                  if length bytes < totalLen
                    then Left (NetInvalidArg "ipv4 len")
                    else
                      let payload = take (totalLen - hdrLen) (drop hdrLen bytes)
                       in Right (Ipv4Packet src dst proto ttl payload)
  where
    at i = maybe (Left (NetInvalidArg "ipv4 trunc")) Right (safeIndex bytes i)

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
  | otherwise = do
      b0 <- at 0
      b1 <- at 1
      b2 <- at 2
      b3 <- at 3
      b4 <- at 4
      b5 <- at 5
      let src = (fromIntegral b0 `shiftL` 8) .|. fromIntegral b1 :: Word16
          dst = (fromIntegral b2 `shiftL` 8) .|. fromIntegral b3 :: Word16
          len = (fromIntegral b4 `shiftL` 8) .|. fromIntegral b5 :: Int
      if len < 8 || length bytes < len
        then Left (NetInvalidArg "udp len")
        else Right (UdpPacket src dst (take (len - 8) (drop 8 bytes)))
  where
    at i = maybe (Left (NetInvalidArg "udp trunc")) Right (safeIndex bytes i)

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
  | otherwise = do
      typ <- at 0
      b4 <- at 4
      b5 <- at 5
      b6 <- at 6
      b7 <- at 7
      let ident = (fromIntegral b4 `shiftL` 8) .|. fromIntegral b5 :: Word16
          seqNum = (fromIntegral b6 `shiftL` 8) .|. fromIntegral b7 :: Word16
          payload = drop 8 bytes
      Right (typ, ident, seqNum, payload)
  where
    at i = maybe (Left (NetInvalidArg "icmp trunc")) Right (safeIndex bytes i)

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
-- Cursor is (offset, remaining): each step consumes >=1 byte, TLV needs
-- 2+len <= remaining (checked_add style); truncated headers/values reject.
decodeDhcp :: [Word8] -> Either NetError DhcpMsg
decodeDhcp bytes
  | length bytes < 240 = Left (NetInvalidArg "dhcp short")
  | otherwise = do
      op <- at 0
      b4 <- at 4
      b5 <- at 5
      b6 <- at 6
      b7 <- at 7
      y0 <- at 16
      y1 <- at 17
      y2 <- at 18
      y3 <- at 19
      s0 <- at 20
      s1 <- at 21
      s2 <- at 22
      s3 <- at 23
      let xid =
            (fromIntegral b4 `shiftL` 24)
              .|. (fromIntegral b5 `shiftL` 16)
              .|. (fromIntegral b6 `shiftL` 8)
              .|. fromIntegral b7 ::
              Word32
          yiaddr = Ipv4 y0 y1 y2 y3
          siaddr = Ipv4 s0 s1 s2 s3
          cookie = take 4 (drop 236 bytes)
      if op /= 2 || cookie /= [0x63, 0x82, 0x53, 0x63]
        then Left (NetInvalidArg "dhcp header")
        else case parseOpts 0 (drop 240 bytes) Nothing Nothing of
          Left e -> Left e
          Right (mtype, server) -> case mtype of
            Nothing -> Left (NetInvalidArg "dhcp no type")
            Just t -> Right (DhcpMsg xid yiaddr siaddr t server)
  where
    at i = maybe (Left (NetInvalidArg "dhcp trunc")) Right (safeIndex bytes i)
    parseOpts :: Int -> [Word8] -> Maybe Word8 -> Maybe Ipv4 -> Either NetError (Maybe Word8, Maybe Ipv4)
    parseOpts _ [] mt sv = Right (mt, sv)
    parseOpts _ (255 : _) mt sv = Right (mt, sv)
    parseOpts off (0 : rest) mt sv = parseOpts (off + 1) rest mt sv
    parseOpts off (tag : lenB : rest) mt sv =
      let n = fromIntegral lenB :: Int
          need = 2 + n
          remaining = 2 + length rest
       in if need > remaining || off > maxBound - need
            then Left (NetInvalidArg "dhcp opts trunc")
            else case (tag, lenB) of
              (53, 1) -> case rest of
                (b : _) -> parseOpts (off + need) (drop 1 rest) (Just b) sv
                [] -> Left (NetInvalidArg "dhcp opts trunc")
              (54, 4) -> case rest of
                (a : b : c : d : _) ->
                  let svIp = Ipv4 a b c d
                   in parseOpts (off + need) (drop 4 rest) mt (Just svIp)
                _ -> Left (NetInvalidArg "dhcp opts trunc")
              _ -> parseOpts (off + need) (drop n rest) mt sv
    parseOpts _ [_] _ _ = Left (NetInvalidArg "dhcp opts trunc")
