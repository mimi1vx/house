{-# LANGUAGE GHC2024 #-}

{- | Pure regression suite for Track H (SOTA Haskell 02/03/07).

Covers the hostile-input decoders hardened in H1/H2 plus the Word12
contract errors documented in H2, without QEMU and without executing
any FFI (foreign symbols are stubbed at link time, never called):

* Net.Stack: QuickCheck @encode . decode = id@ round-trips plus golden
  truncated vectors that must return @Left@ (never @ErrorCall@).
* Loader: bad-ELF vectors return typed @Left@ (never throw); hex goldens.
* BlkPersist: QuickCheck @decode . encode = id@ plus golden truncations.
* H.FileSystem.splitPath: normalization goldens.
* Util.Word12: Enum/Ix contract errors fire (HasCallStack-annotated),
  guarded paths stay pure.
-}
module Main (main) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM, unless)
import Data.Either (isLeft)
import Data.Ix qualified as Ix
import Data.Word (Word16, Word32, Word8)
import H.FileSystem qualified as FS
import Kernel.Driver.Virtio.Net.Stack qualified as Stack
import Kernel.Driver.Virtio.Net.Types qualified as NT
import Kernel.FileSystem.BlkPersist qualified as BP
import Kernel.FileSystem.Vfs qualified as Vfs
import Kernel.Userspace.Loader qualified as Ldr
import System.Exit (exitFailure)
import Test.QuickCheck (Arbitrary (..), Property, choose, counterexample, property, quickCheckResult, vectorOf, (===))
import Test.QuickCheck qualified as QC
import Util.Word12 (Word12)

-- Framework ---------------------------------------------------------------

-- | Run one named unit check; prints PASS/FAIL, returns success.
check :: String -> Bool -> IO Bool
check name ok = do
  putStrLn ((if ok then "PASS " else "FAIL ") ++ name)
  return ok

-- | Run one named QuickCheck property with a fixed seed count.
checkQC :: (QC.Testable a) => String -> a -> IO Bool
checkQC name prop = do
  r <- quickCheckResult (QC.withMaxSuccess 200 prop)
  let ok = QC.isSuccess r
  putStrLn ((if ok then "PASS " else "FAIL ") ++ name)
  return ok

-- | Assert evaluating the thunk raises an exception (contract error fires).
assertThrows :: String -> a -> IO Bool
assertThrows name x = do
  r <- try @SomeException (evaluate x)
  check name (either (const True) (const False) r)

-- | Assert a pure Either is Left (typed failure, no ErrorCall).
assertLeft :: (Show b) => String -> Either e b -> IO Bool
assertLeft name = check name . isLeft

-- | Assert loadElf never throws and returns the expected Left.
assertLoadLeft :: String -> [Word8] -> Ldr.LoadError -> IO Bool
assertLoadLeft name bytes want = do
  r <- try (evaluate (Ldr.loadElf bytes)) :: IO (Either SomeException (Either Ldr.LoadError Ldr.Elf))
  case r of
    Left _ -> check name False
    Right (Left got) -> check name (got == want)
    Right (Right _) -> check name False

-- Generators ---------------------------------------------------------------

instance Arbitrary NT.Mac where
  arbitrary = NT.Mac <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary NT.Ipv4 where
  arbitrary = NT.Ipv4 <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

smallBytes :: QC.Gen [Word8]
smallBytes = choose (0, 48) >>= flip vectorOf arbitrary

instance Arbitrary Stack.ArpPacket where
  arbitrary = Stack.ArpPacket <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary Stack.Ipv4Packet where
  arbitrary = Stack.Ipv4Packet <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> smallBytes

instance Arbitrary Stack.UdpPacket where
  arbitrary = Stack.UdpPacket <$> arbitrary <*> arbitrary <*> smallBytes

newtype TestFiles = TestFiles [(FilePath, [Word8])]
  deriving (Show)

instance Arbitrary TestFiles where
  arbitrary = do
    n <- choose (0, 4) :: QC.Gen Int
    fmap TestFiles $ forM [0 .. n - 1] $ \i -> do
      nb <- choose (0, 16) :: QC.Gen Int
      bs <- vectorOf nb (arbitrary :: QC.Gen Word8)
      return ("/f" ++ show i, bs)

-- Properties ----------------------------------------------------------------

propEthernetRoundTrip :: NT.Mac -> NT.Mac -> Word16 -> Property
propEthernetRoundTrip dst src et =
  let payload = [1, 2, 3] :: [Word8]
   in Stack.decodeEthernet (Stack.encodeEthernet dst src et payload) === Right (dst, src, et, payload)

propArpRoundTrip :: Stack.ArpPacket -> Property
propArpRoundTrip p = Stack.decodeArp (Stack.encodeArp p) === Right p

propIpv4RoundTrip :: NT.Ipv4 -> NT.Ipv4 -> Word8 -> Property
propIpv4RoundTrip src dst proto =
  let payload = [9, 8, 7, 6] :: [Word8]
   in Stack.decodeIpv4 (Stack.encodeIpv4 src dst proto payload)
        === Right (Stack.Ipv4Packet src dst proto 64 payload)

propUdpRoundTrip :: Word16 -> Word16 -> Property
propUdpRoundTrip s d =
  let payload = [5, 5, 5] :: [Word8]
   in Stack.decodeUdp (Stack.encodeUdp s d payload) === Right (Stack.UdpPacket s d payload)

propIcmpRoundTrip :: Word16 -> Word16 -> Property
propIcmpRoundTrip ident seqNum =
  let payload = [1] :: [Word8]
   in Stack.decodeIcmpEcho (Stack.encodeIcmpEcho ident seqNum payload) === Right (8, ident, seqNum, payload)

propDnsRoundTrip :: Word16 -> Property
propDnsRoundTrip xid =
  case Stack.encodeDnsQuery xid "example.com" of
    Left _ -> property False
    Right q -> case dnsFakeResponse xid q of
      Nothing -> property False
      Just resp -> Stack.decodeDnsResponse resp === Right (Stack.DnsResponse xid (NT.Ipv4 93 184 216 34))

propBlkRoundTrip :: TestFiles -> Property
propBlkRoundTrip (TestFiles files) =
  counterexample "encode failed" $ case BP.encodeImage files of
    Left _ -> property False
    Right img -> BP.decodeImage img === Right files

-- Goldens -------------------------------------------------------------------

{- | BOOTREPLY golden built from the BOOTREQUEST encoder with the op byte
patched (encoder only emits BOOTREQUEST; decoder only accepts BOOTREPLY).
-}
dhcpReplyGolden :: [Word8]
dhcpReplyGolden =
  let xid = 0x12345678 :: Word32
      req = Stack.encodeDhcpDiscover xid (NT.Mac 1 2 3 4 5 6)
   in 2 : drop 1 req

trunc :: [a] -> [a]
trunc xs = take (length xs - 1) xs

{- | Build a synthetic DNS response for a query: header xid/0x8180/qd1/an1
+ echoed question + one A answer (pointer to qname, 93.184.216.34).
-}
dnsFakeResponse :: Word16 -> [Word8] -> Maybe [Word8]
dnsFakeResponse xid q
  | length q < 12 = Nothing
  | otherwise =
      let hi = fromIntegral (xid `div` 256) :: Word8
          lo = fromIntegral (xid `mod` 256) :: Word8
          hdr = [hi, lo, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
          question = drop 12 q
          answer = [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04, 93, 184, 216, 34]
       in Just (hdr ++ question ++ answer)

-- Main ----------------------------------------------------------------------

main :: IO ()
main = do
  results <-
    sequence
      [ checkQC "ethernet round-trip" (propEthernetRoundTrip :: NT.Mac -> NT.Mac -> Word16 -> Property)
      , checkQC "arp round-trip" (propArpRoundTrip :: Stack.ArpPacket -> Property)
      , checkQC "ipv4 round-trip" (propIpv4RoundTrip :: NT.Ipv4 -> NT.Ipv4 -> Word8 -> Property)
      , checkQC "udp round-trip" (propUdpRoundTrip :: Word16 -> Word16 -> Property)
      , checkQC "icmp round-trip" (propIcmpRoundTrip :: Word16 -> Word16 -> Property)
      , checkQC "dns query/response round-trip" (propDnsRoundTrip :: Word16 -> Property)
      , checkQC "blkpersist round-trip" (propBlkRoundTrip :: TestFiles -> Property)
      , -- Stack truncated goldens: Left, never ErrorCall
        assertLeft "eth empty" (Stack.decodeEthernet [])
      , assertLeft "eth truncated" (Stack.decodeEthernet (replicate 13 0))
      , assertLeft "arp empty" (Stack.decodeArp [])
      , assertLeft "arp truncated" (Stack.decodeArp (trunc (Stack.encodeArp (Stack.ArpPacket 1 (NT.Mac 1 2 3 4 5 6) (NT.Ipv4 10 0 0 1) (NT.Mac 0 0 0 0 0 0) (NT.Ipv4 10 0 0 2)))))
      , assertLeft "ipv4 empty" (Stack.decodeIpv4 [])
      , assertLeft "ipv4 truncated" (Stack.decodeIpv4 (trunc (Stack.encodeIpv4 (NT.Ipv4 10 0 0 1) (NT.Ipv4 10 0 0 2) 17 [1, 2, 3])))
      , assertLeft "udp empty" (Stack.decodeUdp [])
      , assertLeft "udp truncated" (Stack.decodeUdp (trunc (Stack.encodeUdp 68 67 [1, 2])))
      , assertLeft "icmp empty" (Stack.decodeIcmpEcho [])
      , assertLeft "icmp truncated" (Stack.decodeIcmpEcho (trunc (Stack.encodeIcmpEcho 1 2 [])))
      , assertLeft "dhcp empty" (Stack.decodeDhcp [])
      , assertLeft "dhcp short" (Stack.decodeDhcp (take 239 dhcpReplyGolden))
      , assertLeft "dhcp truncated" (Stack.decodeDhcp (take 250 dhcpReplyGolden))
      , check "dhcp bootreply golden" (Stack.decodeDhcp dhcpReplyGolden == Right (Stack.DhcpMsg 0x12345678 (NT.Ipv4 0 0 0 0) (NT.Ipv4 0 0 0 0) 1 Nothing))
      , -- DNS goldens (total decoder, never ErrorCall)
        assertLeft "dns empty" (Stack.decodeDnsResponse [])
      , assertLeft "dns short" (Stack.decodeDnsResponse (replicate 11 0))
      , assertLeft "dns bad name" (Stack.encodeDnsQuery 1 "")
      , assertLeft "dns bad char" (Stack.encodeDnsQuery 1 "bad_name")
      , check "dns query golden" (Stack.encodeDnsQuery 0x1234 "example.com" == Right [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0x00, 0x01, 0x00, 0x01])
      , check "dns response golden" (case Stack.encodeDnsQuery 0x1234 "example.com" of Left _ -> False; Right q -> case dnsFakeResponse 0x1234 q of Nothing -> False; Just r -> Stack.decodeDnsResponse r == Right (Stack.DnsResponse 0x1234 (NT.Ipv4 93 184 216 34)))
      , -- Types display goldens (total nibble render)
        check "showMac golden" (NT.showMac (NT.Mac 0 1 2 3 4 5) == "00:01:02:03:04:05")
      , check "showMac broadcast" (NT.showMac NT.macBroadcast == "ff:ff:ff:ff:ff:ff")
      , -- Loader bad-ELF goldens (typed Left, never throw)
        assertLoadLeft "elf empty" [] Ldr.Truncated
      , assertLoadLeft "elf short" (replicate 63 0) Ldr.Truncated
      , assertLoadLeft "elf bad magic" (replicate 64 0) Ldr.BadMagic
      , assertLoadLeft "elf bad arch" elfBadArch Ldr.BadArch
      , assertLoadLeft "elf phoff trunc" elfPhoffTrunc Ldr.Truncated
      , check "showHex64 via OutOfWindow" (Ldr.loadErrorToString (Ldr.OutOfWindow 0x01000000) == "OutOfWindow: 0x1000000")
      , -- BlkPersist golden truncations
        assertLeft "blk empty" (BP.decodeImage [])
      , assertLeft "blk short header" (BP.decodeImage [0, 1, 2])
      , assertLeft "blk bad magic" (BP.decodeImage (replicate 20 0))
      , assertLeft "blk bad path" (BP.encodeImage [("noSlash", [1])])
      , assertLeft "blk empty path" (BP.encodeImage [("", [1])])
      , blkTruncGolden
      , check "vfs longest-prefix" (Vfs.resolvePrefix [([], "root"), (["a"], "a"), (["a", "b"], "blk")] ["a", "b", "c"] == Just ("blk", ["c"]))
      , check "vfs root-fallback" (Vfs.resolvePrefix [([], "root"), (["a"], "a")] ["z"] == Just ("root", ["z"]))
      , check "vfs dotdot confined" (Vfs.splitPath "/a/../../b" == Right ["b"])
      , check "vfs joinRel root" (Vfs.joinRel [] == "/")
      , check "vfs joinRel nested" (Vfs.joinRel ["a", "b"] == "/a/b")
      , check "vfs ns isolation" (Vfs.resolvePrefix [([], "ram")] ["mnt", "x"] == Just ("ram", ["mnt", "x"]) && Vfs.resolvePrefix [(["mnt"], "blk"), ([], "ram")] ["mnt", "x"] == Just ("blk", ["x"]))
      , assertLeft "vfs mount relative" (Vfs.normalizeMount "ram")
      , check "vfs headerTotal" (case BP.encodeImage [("/a", [1, 2, 3])] of Left _ -> False; Right img -> BP.headerTotal img == Right (length img))
      , -- splitPath goldens
        check "splitPath a/b" (FS.splitPath "/a/b" == Right ["a", "b"])
      , check "splitPath collapse" (FS.splitPath "/a//b" == Right ["a", "b"])
      , check "splitPath dot" (FS.splitPath "/a/./b" == Right ["a", "b"])
      , check "splitPath dotdot" (FS.splitPath "/a/../b" == Right ["b"])
      , check "splitPath root" (FS.splitPath "/" == Right [])
      , check "splitPath confined" (FS.splitPath "/.." == Right [])
      , assertLeft "splitPath empty" (FS.splitPath "")
      , -- Word12 guarded paths stay pure
        check "word12 wrap" ((4096 :: Word12) == (0 :: Word12))
      , check "word12 maxBound" (fromEnum (maxBound :: Word12) == 4095)
      , check "word12 succ" ((succ 5 :: Word12) == 6)
      , check "word12 pred" ((pred 5 :: Word12) == 4)
      , check "word12 toEnum" ((toEnum 7 :: Word12) == 7)
      , check "word12 ix" (Ix.index (0, 10 :: Word12) 3 == 3 && not (Ix.inRange (0, 3 :: Word12) 4))
      , -- Word12 contract errors fire (HasCallStack-annotated, Enum/Ix law)
        assertThrows "word12 toEnum OOB" (toEnum 4096 :: Word12)
      , assertThrows "word12 succ maxBound" (succ (maxBound :: Word12))
      , assertThrows "word12 pred minBound" (pred (minBound :: Word12))
      , assertThrows "word12 ix OOB" (Ix.index (0, 3 :: Word12) 4)
      ]
  unless (and results) exitFailure
  putStrLn "all pure tests passed"

elfBadArch :: [Word8]
elfBadArch =
  [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    ++ [2, 0, 0, 0]
    ++ replicate 44 0

elfPhoffTrunc :: [Word8]
elfPhoffTrunc =
  [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    ++ [2, 0, 183, 0]
    ++ replicate 12 0
    ++ [232, 3, 0, 0, 0, 0, 0, 0]
    ++ replicate 24 0

blkTruncGolden :: IO Bool
blkTruncGolden = case BP.encodeImage [("/a", [1, 2, 3])] of
  Left _ -> check "blk trunc body" False
  Right img -> assertLeft "blk trunc body" (BP.decodeImage (trunc img))
