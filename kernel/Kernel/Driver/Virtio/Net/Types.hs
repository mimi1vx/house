{-# LANGUAGE ForeignFunctionInterface #-}

-- | Virtio-net types — MAC, IPv4, errors, device record.
-- Strictness: MAC/IPv4 are strict Word8 tuples; NetDevice fields strict.
-- Exceptions: all validation returns Either, no partial head/fromJust/!!.
-- Bounds: slot 0..7, MTU 1500, maxPacketBytes 2048 fits Grant page.
module Kernel.Driver.Virtio.Net.Types
  ( NetError (..),
    netErrorToString,
    Mac (..),
    showMac,
    macBroadcast,
    macToWords,
    Ipv4 (..),
    showIpv4,
    ipv4ToWord32,
    word32ToIpv4,
    validateIpv4,
    isBroadcast,
    NetDevice (..),
    virtioNetHdrSize,
    ethHeaderLen,
    ipv4HeaderLen,
    udpHeaderLen,
    mtu,
    maxPacketBytes,
    arpEntryValid,
  )
where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Word (Word32, Word8)
import H.Interrupts (IntId)
import Kernel.Driver.Virtio.Queue (VirtQueue)
import Kernel.IPC.Types (Endpoint)

-- | Net subsystem errors (total decoder).
data NetError
  = NetBadSlot
  | NetNotNet
  | NetNotReady
  | NetNoSpace
  | NetIoError Int
  | NetInvalidArg String
  | NetArpTimeout
  | NetDhcpFailed
  deriving (Eq, Show)

-- | Human string for error (shell).
netErrorToString :: NetError -> String
netErrorToString NetBadSlot = "NetBadSlot"
netErrorToString NetNotNet = "NetNotNet"
netErrorToString NetNotReady = "NetNotReady"
netErrorToString NetNoSpace = "NetNoSpace"
netErrorToString (NetIoError n) = "NetIoError " ++ show n
netErrorToString (NetInvalidArg s) = "NetInvalidArg: " ++ s
netErrorToString NetArpTimeout = "NetArpTimeout"
netErrorToString NetDhcpFailed = "NetDhcpFailed"

-- | MAC address (6 bytes).
data Mac = Mac Word8 Word8 Word8 Word8 Word8 Word8
  deriving (Eq, Ord, Show)

-- | Show MAC as hex colon separated.
showMac :: Mac -> String
showMac (Mac a b c d e f) = hex2 a ++ ":" ++ hex2 b ++ ":" ++ hex2 c ++ ":" ++ hex2 d ++ ":" ++ hex2 e ++ ":" ++ hex2 f
  where
    hex2 w = [h !! fromIntegral (w `shiftR` 4), h !! fromIntegral (w .&. 0xF)]
    h = "0123456789abcdef"

-- | Broadcast MAC ff:ff:ff:ff:ff:ff
macBroadcast :: Mac
macBroadcast = Mac 0xff 0xff 0xff 0xff 0xff 0xff

-- | MAC to list.
macToWords :: Mac -> [Word8]
macToWords (Mac a b c d e f) = [a, b, c, d, e, f]

-- | IPv4 address.
data Ipv4 = Ipv4 Word8 Word8 Word8 Word8
  deriving (Eq, Ord, Show)

-- | Show IPv4 dotted.
showIpv4 :: Ipv4 -> String
showIpv4 (Ipv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

-- | IPv4 to Word32 (big endian).
ipv4ToWord32 :: Ipv4 -> Word32
ipv4ToWord32 (Ipv4 a b c d) =
  (fromIntegral a `shiftL` 24) .|. (fromIntegral b `shiftL` 16) .|. (fromIntegral c `shiftL` 8) .|. fromIntegral d

-- | Word32 to IPv4 (big endian).
word32ToIpv4 :: Word32 -> Ipv4
word32ToIpv4 w = Ipv4 (fromIntegral (w `shiftR` 24)) (fromIntegral (w `shiftR` 16)) (fromIntegral (w `shiftR` 8)) (fromIntegral w)

-- | Validate IPv4 (reject 0.0.0.0 and 255.255.255.255 as host, allow others).
validateIpv4 :: Ipv4 -> Either NetError ()
validateIpv4 ip
  | ip == Ipv4 0 0 0 0 = Left (NetInvalidArg "0.0.0.0")
  | otherwise = Right ()

-- | Is broadcast 255.255.255.255.
isBroadcast :: Ipv4 -> Bool
isBroadcast (Ipv4 255 255 255 255) = True
isBroadcast _ = False

-- | Virtio-net device record.
data NetDevice = NetDevice
  { netSlot :: Int,
    netMac :: Mac,
    netIp :: Maybe Ipv4,
    netGw :: Ipv4,
    netMask :: Ipv4,
    netIntId :: IntId,
    netEndpoint :: Endpoint,
    netRxQueue :: VirtQueue,
    netTxQueue :: VirtQueue
  }
  deriving (Eq, Show)

-- | Constants.
virtioNetHdrSize :: Int
virtioNetHdrSize = 12

ethHeaderLen :: Int
ethHeaderLen = 14

ipv4HeaderLen :: Int
ipv4HeaderLen = 20

udpHeaderLen :: Int
udpHeaderLen = 8

mtu :: Int
mtu = 1500

maxPacketBytes :: Int
maxPacketBytes = 2048

-- | Check ARP entry valid (non-zero IP and MAC not broadcast).
arpEntryValid :: Ipv4 -> Mac -> Bool
arpEntryValid ip mac = ip /= Ipv4 0 0 0 0 && mac /= macBroadcast
