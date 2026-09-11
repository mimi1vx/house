{-# LANGUAGE GHC2024 #-}

{- | Pure regression suite for Track H (SOTA Haskell 02/03/07).

Covers the hostile-input decoders hardened in H1/H2 plus the Word12
contract errors documented in H2, without QEMU and without executing
any FFI (foreign symbols are stubbed at link time, never called):

* Net.Stack: QuickCheck @encode . decode = id@ round-trips plus golden
  truncated vectors that must return @Left@ (never @ErrorCall@).
* Loader: bad-ELF vectors return typed @Left@ (never throw); hex goldens.
* BlkPersist: QuickCheck @decode . encode = id@ plus golden truncations.
* VFS routing: longest-prefix dispatch, @..@-confinement per backend,
  @nsFork@ invisibility, and bytes round-trips (NUL + 0x80-0xFF) through
  fake in-memory backends via @runH@ (RamFS pages need real FFI, so the
  routing contract is exercised without them).
* Initramfs: cpio newc round-trip (all-256 binary payloads) plus
  bad-magic/truncation/traversal/oversize rejects, unpack via the fake
  backends, manifest line validation, RamFS quota math + over-quota
  refusal.
* H.FileSystem.splitPath: normalization goldens.
* Util.Word12: Enum/Ix contract errors fire (HasCallStack-annotated),
  guarded paths stay pure.
-}
module Main (main) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM, unless)
import Data.Char (chr, ord)
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Ix qualified as Ix
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Word (Word16, Word32, Word8)
import H.FileSystem qualified as FS
import H.Monad qualified as HM
import Kernel.Driver.Virtio.Net.Stack qualified as Stack
import Kernel.Driver.Virtio.Net.Types qualified as NT
import Kernel.FileSystem.BlkPersist qualified as BP
import Kernel.FileSystem.RamFs qualified as RamFs
import Kernel.FileSystem.Vfs qualified as Vfs
import Kernel.Initramfs.Cpio qualified as Cpio
import Kernel.Initramfs.Unpack qualified as Unpack
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

-- | Run one named IO check (H actions via runH); prints PASS/FAIL.
checkIO :: String -> IO Bool -> IO Bool
checkIO name act = do
  ok <- act
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

-- VFS routing goldens (fake backends, no pages/QEMU) ---------------------------

{- | In-memory 'FsOps' backend over IORefs (files + dir set, normalized
paths). Exercises the VFS routing contract without RamFS pages, which
need real FFI-backed page allocation.
-}
newMemBackend :: IO Vfs.FsOps
newMemBackend = do
  files <- newIORef (Map.empty :: Map.Map FilePath [Word8])
  dirs <- newIORef (Set.singleton "/" :: Set.Set FilePath)
  return
    Vfs.FsOps {
      Vfs.opsInit = HM.liftIO (writeIORef files Map.empty >> writeIORef dirs (Set.singleton "/"))
      , Vfs.opsCreate = \p -> HM.liftIO $ case norm p of
          Left e -> return (Left e)
          Right (np, cs)
            | null cs -> return (Left (Vfs.EINVAL "cannot create root"))
            | otherwise -> do
                fs <- readIORef files
                ds <- readIORef dirs
                if Map.member np fs || Set.member np ds
                  then return (Left Vfs.EEXIST)
                  else do
                    let par = parentOf cs
                    if Map.member par fs
                      then return (Left Vfs.ENOTDIR)
                      else
                        if Set.member par ds
                          then writeIORef files (Map.insert np [] fs) >> return (Right ())
                          else return (Left Vfs.ENOENT)
      , Vfs.opsMkdir = \p -> HM.liftIO $ case norm p of
          Left e -> return (Left e)
          Right (np, cs)
            | null cs -> return (Left Vfs.EEXIST)
            | otherwise -> do
                fs <- readIORef files
                ds <- readIORef dirs
                if Map.member np fs || Set.member np ds
                  then return (Left Vfs.EEXIST)
                  else do
                    let par = parentOf cs
                    if Map.member par fs
                      then return (Left Vfs.ENOTDIR)
                      else
                        if Set.member par ds
                          then writeIORef dirs (Set.insert np ds) >> return (Right ())
                          else return (Left Vfs.ENOENT)
      , Vfs.opsWrite = \p bs -> HM.liftIO $ case norm p of
          Left e -> return (Left e)
          Right (np, cs)
            | null cs -> return (Left Vfs.EISDIR)
            | otherwise -> do
                fs <- readIORef files
                ds <- readIORef dirs
                if Set.member np ds
                  then return (Left Vfs.EISDIR)
                  else do
                    let par = parentOf cs
                    if Map.member par fs
                      then return (Left Vfs.ENOTDIR)
                      else
                        if Set.member par ds
                          then writeIORef files (Map.insert np bs fs) >> return (Right ())
                          else return (Left Vfs.ENOENT)
      , Vfs.opsRead = \p -> HM.liftIO $ case norm p of
          Left e -> return (Left e)
          Right (np, _) -> do
            fs <- readIORef files
            ds <- readIORef dirs
            case Map.lookup np fs of
              Just bs -> return (Right bs)
              Nothing
                | Set.member np ds -> return (Left Vfs.EISDIR)
                | otherwise -> return (Left Vfs.ENOENT)
      , Vfs.opsLs = \p -> HM.liftIO $ case norm p of
          Left e -> return (Left e)
          Right (np, _) -> do
            fs <- readIORef files
            ds <- readIORef dirs
            if Map.member np fs
              then return (Left Vfs.ENOTDIR)
              else
                if Set.member np ds
                  then return (Right (childrenOf np fs ds))
                  else return (Left Vfs.ENOENT)
      , Vfs.opsRm = \p -> HM.liftIO $ case norm p of
          Left e -> return (Left e)
          Right (np, cs)
            | null cs -> return (Left (Vfs.EINVAL "cannot remove root"))
            | otherwise -> do
                fs <- readIORef files
                ds <- readIORef dirs
                if Map.member np fs
                  then writeIORef files (Map.delete np fs) >> return (Right ())
                  else
                    if Set.member np ds
                      then
                        if null (childrenOf np fs ds)
                          then writeIORef dirs (Set.delete np ds) >> return (Right ())
                          else return (Left (Vfs.EINVAL "directory not empty"))
                      else return (Left Vfs.ENOENT)
      , Vfs.opsStat = \p -> HM.liftIO $ case norm p of
          Left e -> return (Left e)
          Right (np, _) -> do
            fs <- readIORef files
            ds <- readIORef dirs
            case Map.lookup np fs of
              Just bs -> return (Right (Vfs.FsStat False (length bs) ((length bs + 4095) `div` 4096)))
              Nothing
                | Set.member np ds -> return (Right (Vfs.FsStat True 0 (length (childrenOf np fs ds))))
                | otherwise -> return (Left Vfs.ENOENT)
      }
  where
    norm p = case Vfs.splitPath p of
      Left e -> Left e
      Right cs -> Right (Vfs.joinRel cs, cs)
    parentOf cs = Vfs.joinRel (if null cs then [] else init cs)
    childrenOf np fs ds =
      Set.toList
        ( Set.fromList [last pcs | (fp, _) <- Map.toList fs, let pcs = compsOf fp, not (null pcs), parentOf pcs == np]
            `Set.union` Set.fromList [last dcs | d <- Set.toList ds, d /= np, let dcs = compsOf d, not (null dcs), parentOf dcs == np]
        )
    compsOf fp = case Vfs.splitPath fp of
      Right cs -> cs
      Left _ -> []

-- | Longest-prefix dispatch: /blk writes land in backend B, invisible in A.
vfsPrefixGolden :: IO Bool
vfsPrefixGolden = do
  a <- newMemBackend
  b <- newMemBackend
  HM.runH $ do
    ns <- Vfs.nsCreate
    _ <- Vfs.vfsMount ns "/" a
    _ <- Vfs.vfsMount ns "/blk" b
    _ <- Vfs.vfsWrite ns "/a" [1, 2, 3]
    _ <- Vfs.vfsWrite ns "/blk/b" [4, 5]
    ra <- Vfs.vfsRead ns "/a"
    rb <- Vfs.vfsRead ns "/blk/b"
    da <- Vfs.opsRead a "/blk/b"
    db <- Vfs.opsRead b "/b"
    return (ra == Right [1, 2, 3] && rb == Right [4, 5] && isLeft da && db == Right [4, 5])

-- | @..@ never escapes the mount: /blk/../who resolves in the root backend.
vfsDotDotGolden :: IO Bool
vfsDotDotGolden = do
  a <- newMemBackend
  b <- newMemBackend
  HM.runH $ do
    ns <- Vfs.nsCreate
    _ <- Vfs.vfsMount ns "/" a
    _ <- Vfs.vfsMount ns "/blk" b
    _ <- Vfs.vfsWrite ns "/who" [65]
    _ <- Vfs.vfsWrite ns "/blk/who" [66]
    r <- Vfs.vfsRead ns "/blk/../who"
    return (r == Right [65])

{- | A mount in a forked namespace is invisible in the parent: the same
path reads through the parent's root backend (ENOENT) and the child's
mount (bytes). With @/@ mounted every path resolves, so invisibility
is asserted at read level, not lookup level.
-}
vfsForkGolden :: IO Bool
vfsForkGolden = do
  a <- newMemBackend
  b <- newMemBackend
  HM.runH $ do
    nsP <- Vfs.nsCreate
    _ <- Vfs.vfsMount nsP "/" a
    child <- Vfs.nsFork nsP
    _ <- Vfs.vfsMount child "/extra" b
    _ <- Vfs.vfsWrite child "/extra/secret" [7]
    rp <- Vfs.vfsRead nsP "/extra/secret"
    rc <- Vfs.vfsRead child "/extra/secret"
    return (isLeft rp && rc == Right [7])

-- | Byte fidelity through routing: all 256 values + NUL + empty.
vfsBytesGolden :: IO Bool
vfsBytesGolden = do
  a <- newMemBackend
  let allBs = [0 .. 255] :: [Word8]
  HM.runH $ do
    ns <- Vfs.nsCreate
    _ <- Vfs.vfsMount ns "/" a
    _ <- Vfs.vfsWrite ns "/all" allBs
    _ <- Vfs.vfsWrite ns "/empty" []
    ra <- Vfs.vfsRead ns "/all"
    re <- Vfs.vfsRead ns "/empty"
    return (ra == Right allBs && re == Right [])

-- Dir-op goldens for the pid1 VFS slice (0x0C..0x0F): mkdir/rm/stat/ls
-- over the fake backends, incl. bad-path/over-cap/namespace vectors.

-- | mkdir/rm/stat/ls round-trip plus bad-path errnos.
vfsDirGolden :: IO Bool
vfsDirGolden = do
  a <- newMemBackend
  HM.runH $ do
    ns <- Vfs.nsCreate
    _ <- Vfs.vfsMount ns "/" a
    okMkdir <- Vfs.vfsMkdir ns "/d"
    dupMkdir <- Vfs.vfsMkdir ns "/d"
    _ <- Vfs.vfsWrite ns "/d/f" [1, 2, 3]
    lsD <- Vfs.vfsLs ns "/d"
    stF <- Vfs.vfsStat ns "/d/f"
    stD <- Vfs.vfsStat ns "/d"
    lsF <- Vfs.vfsLs ns "/d/f"
    rmMissing <- Vfs.vfsRm ns "/nope"
    _ <- Vfs.vfsRm ns "/d/f"
    rmDir <- Vfs.vfsRm ns "/d"
    stGone <- Vfs.vfsStat ns "/d/f"
    return
      ( okMkdir == Right ()
          && dupMkdir == Left Vfs.EEXIST
          && lsD == Right ["f"]
          && stF == Right (Vfs.FsStat False 3 1)
          && stD == Right (Vfs.FsStat True 0 1)
          && lsF == Left Vfs.ENOTDIR
          && rmMissing == Left Vfs.ENOENT
          && rmDir == Right ()
          && stGone == Left Vfs.ENOENT
      )

{- | Dir ops resolve through the caller's pid namespace (the EL0
0x0C..0x0F path): a mount+mkdir under a forked pid is invisible in the
parent pid's namespace.
-}
vfsDirPidNsGolden :: IO Bool
vfsDirPidNsGolden = do
  a <- newMemBackend
  b <- newMemBackend
  HM.runH $ do
    _ <- Vfs.vfsEnsurePid 100
    _ <- Vfs.vfsMount Vfs.defaultNamespace "/" a
    Vfs.vfsForkPid 100 101
    childNs <- Vfs.vfsEnsurePid 101
    _ <- Vfs.vfsMount childNs "/extra" b
    _ <- Vfs.vfsMkdir childNs "/extra/kid"
    rp <- Vfs.vfsStat Vfs.defaultNamespace "/extra/kid"
    rc <- Vfs.vfsStat childNs "/extra/kid"
    Vfs.vfsReleasePid 100
    Vfs.vfsReleasePid 101
    return (rp == Left Vfs.ENOENT && rc == Right (Vfs.FsStat True 0 0))

-- Initramfs goldens (cpio newc + unpack + manifest + quota) ---------------------

-- | Fixture: dir, text file, all-256 binary, empty file, skipped symlink.
cpioGood :: [Cpio.CpioEntry]
cpioGood =
  [ Cpio.mkCpioDir "etc"
  , Cpio.mkCpioFile "etc/house-servers" [104, 105]
  , Cpio.mkCpioFile "all" [0 .. 255]
  , Cpio.mkCpioFile "empty" []
  , Cpio.CpioEntry "link" 0o120777 [120]
  ]

{- | Exact newc bytes for one tiny file (pins the 110-byte-header
alignment: names end at offset 2 mod 4, pads restore 4-alignment).
-}
cpioTinyGolden :: [Word8]
cpioTinyGolden =
  [48, 55, 48, 55, 48, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 56, 49, 97, 52, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 48, 48, 48, 48, 48, 48, 48, 48, 102, 0, 9, 0, 0, 0, 48, 55, 48, 55, 48, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 98, 48, 48, 48, 48, 48, 48, 48, 48, 84, 82, 65, 73, 76, 69, 82, 33, 33, 33, 0, 0, 0, 0]

-- | Encode/parse round-trip preserves every entry byte-for-byte.
cpioRoundTrip :: Bool
cpioRoundTrip = Cpio.parseCpio (Cpio.encodeCpio cpioGood) == Right cpioGood

{- | Unpack through VFS routing: dirs before files, `./` confined,
symlink skipped, payloads byte-exact.
-}
unpackGolden :: IO Bool
unpackGolden = do
  a <- newMemBackend
  HM.runH $ do
    ns <- Vfs.nsCreate
    _ <- Vfs.vfsMount ns "/" a
    r <- Unpack.unpackEntries ns cpioGood
    back <- Vfs.vfsRead ns "/etc/house-servers"
    allB <- Vfs.vfsRead ns "/all"
    return (r == Right 3 && back == Right [104, 105] && allB == Right [0 .. 255])

-- | Over-quota write is refused without mutating the FS.
ramfsQuotaGolden :: IO Bool
ramfsQuotaGolden = HM.runH $ do
  RamFs.ramfsInit
  RamFs.ramfsSetQuotaPages 1
  r <- RamFs.ramfsWrite "/big" (replicate 5000 0)
  used <- RamFs.ramfsUsedPages
  RamFs.ramfsInit
  return (r == Left Vfs.ENOSPC && used == 0)

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
      , checkIO "vfs prefix routing" vfsPrefixGolden
      , checkIO "vfs dotdot per-backend" vfsDotDotGolden
      , checkIO "vfs nsFork invisibility" vfsForkGolden
      , checkIO "vfs bytes all-256" vfsBytesGolden
      , checkIO "vfs dir mkdir/rm/stat/ls" vfsDirGolden
      , checkIO "vfs dir pid-namespace isolation" vfsDirPidNsGolden
      , assertLeft "vfs empty path" (Vfs.splitPath "")
      , assertLeft "vfs long name" (Vfs.splitPath ("/" ++ replicate 256 'a'))
      , check "cpio round-trip all-256" cpioRoundTrip
      , check "cpio tiny exact bytes" (Cpio.encodeCpio [Cpio.mkCpioFile "f" [9]] == cpioTinyGolden)
      , check "cpio tiny parses back" (Cpio.parseCpio cpioTinyGolden == Right [Cpio.mkCpioFile "f" [9]])
      , assertLeft "cpio bad magic" (Cpio.parseCpio [0, 1, 2, 3, 4, 5, 6])
      , assertLeft "cpio truncated header" (Cpio.parseCpio ([48, 55, 48, 55, 48, 49] ++ replicate 10 0))
      , assertLeft "cpio empty missing trailer" (Cpio.parseCpio [])
      , assertLeft "cpio traversal" (Cpio.parseCpio (Cpio.encodeCpio [Cpio.mkCpioFile "../evil" [1]]))
      , assertLeft "cpio absolute" (Cpio.parseCpio (Cpio.encodeCpio [Cpio.mkCpioFile "/abs" [1]]))
      , assertLeft "cpio NUL name" (Cpio.parseCpio (Cpio.encodeCpio [Cpio.mkCpioFile "a\0b" [1]]))
      , assertLeft "cpio long name" (Cpio.parseCpio (Cpio.encodeCpio [Cpio.mkCpioFile (replicate 256 'a') [1]]))
      , assertLeft "cpio big file" (Cpio.parseCpio (Cpio.encodeCpio [Cpio.mkCpioFile "big" (replicate (1024 * 1024 + 1) 0)]))
      , checkIO "cpio unpack via VFS" unpackGolden
      , check "manifest good" (Unpack.parseManifest "# c\nhello /sbin/init init\n" == Right [("hello", "/sbin/init", "init")])
      , assertLeft "manifest bad line" (Unpack.parseManifest "oops\n")
      , assertLeft "manifest traversal" (Unpack.parseManifest "x /a/../b y\n")
      , assertLeft "manifest relative" (Unpack.parseManifest "x sbin/init y\n")
      , assertLeft "manifest too many" (Unpack.parseManifest (unlines (replicate 65 "a /b c")))
      , check "quota floor 16M" (RamFs.quotaPagesFor 0 == (16 * 1024 * 1024) `div` 4096)
      , check "quota 512M" (RamFs.quotaPagesFor (512 * 1024 * 1024) == 13107)
      , check "quota 4G" (RamFs.quotaPagesFor (4 * 1024 * 1024 * 1024) == 104857)
      , checkIO "ramfs over-quota refused" ramfsQuotaGolden
      , check "blk bytes all-256 round-trip" (case BP.encodeImage [("/all", [0 .. 255])] of Left _ -> False; Right img -> BP.decodeImage img == Right [("/all", [0 .. 255])])
      , check "blk bytes NUL+high round-trip" (case BP.encodeImage [("/b", [0, 128, 255, 0, 1])] of Left _ -> False; Right img -> BP.decodeImage img == Right [("/b", [0, 128, 255, 0, 1])])
      , check "latin1 edge round-trip" (let enc s = [fromIntegral (ord c `mod` 256) :: Word8 | c <- s]; dec bs = [chr (fromIntegral b) | b <- bs]; s = dec [0 .. 255] in dec (enc s) == s)
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
