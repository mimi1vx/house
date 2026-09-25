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
import Control.Monad (foldM, forM, unless)
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString qualified as BS
import Data.Char (chr, ord)
import Data.Either (fromRight, isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Ix qualified as Ix
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Word (Word16, Word32, Word64, Word8)
import H.FileSystem qualified as FS
import H.Monad qualified as HM
import Kernel.Driver.Virtio.Net.Stack qualified as Stack
import Kernel.Driver.Virtio.Net.Types qualified as NT
import Kernel.FileSystem.BlkPersist qualified as BP
import Kernel.FileSystem.RamFs qualified as RamFs
import Kernel.FileSystem.Vfs qualified as Vfs
import Kernel.Initramfs.Cpio qualified as Cpio
import Kernel.Initramfs.Unpack qualified as Unpack
import Kernel.Userspace.Linker qualified as Linker
import Kernel.Userspace.Loader qualified as Ldr
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
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

-- | Assert pure link planning fails without throwing.
assertLinkLeft :: String -> Either Ldr.LoadError Linker.LinkPlan -> IO Bool
assertLinkLeft name result = do
  r <- try (evaluate result) :: IO (Either SomeException (Either Ldr.LoadError Linker.LinkPlan))
  case r of
    Left _ -> check name False
    Right (Left _) -> check name True
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
      , -- M1/M2.0 dynamic ELF: hostile vectors and landed eager-relocation metadata
        check "elf ET_EXEC min parses" (isDynRight elfExecMin False)
      , check "elf ET_DYN good parses" (isDynRight elfDynGood True)
      , check "elf ET_DYN low zero-entry parses" (isDynRight elfDynLow True)
      , assertLoadLeft "elf exec PT_TLS reject" elfExecTls Ldr.TlsUnsupported
      , assertLoadLeft "elf dyn PT_TLS reject" elfDynTls Ldr.TlsUnsupported
      , assertLoadLeft "elf overlapping LOAD pages reject" elfOverlapLoads (Ldr.BadSegment "overlapping LOAD pages")
      , assertLoadLeft "elf stack page collision reject" elfStackCollision (Ldr.BadSegment "stack page collision")
      , assertLoadLeft "elf bad EI_VERSION reject" elfBadVersion Ldr.BadMagic
      , assertLoadLeft "elf static BSS reject" elfStaticBss (Ldr.BadSegment "static BSS unsupported")
      , check "elf zero phentsize parses" (isDynRight elfPhentZero True)
      , check "elf 8K align parses" (isDynRight elfDynAlign8192 True)
      , check "elf unsorted dynamic loads parse" (isDynRight elfDynUnsorted True)
      , check "elf dyn interp pin" (dynInterpIs elfDynGood (Just "/lib/ld-house.so.0"))
      , check "elf dyn one rela" (dynRelaCountIs elfDynGood 1)
      , check "elf dyn relro pin" (dynRelroIs elfDynGood (Just (Ldr.RelroRange 0x01000000 0x01000010)))
      , check "elf dyn two needed" (dynNeededIs elfNeededTwo ["libc-house.so.0", "libm-house.so.0"])
      , -- M2.0 artifact compatibility: SysV symbols + eager relocations, never executed
        check "elf m2 zero-entry bss dso parses" (isDynRight elfM2Dso True)
      , check "elf m2 soname parsed" (dynSonameIs elfM2Dso (Just "libc-house.so.0"))
      , check "elf m2 sysv hash parsed" (isSysvHash elfJumpSlot)
      , check "elf m2 jump-slot parsed" (hasEagerType elfJumpSlot 1026)
      , check "elf m2 glob-dat parsed" (hasEagerType elfGlobDat 1025)
      , check "elf m2 dual relocation tables" (hasTableKind elfJumpSlot Ldr.DynamicRelocations && hasTableKind elfJumpSlot Ldr.PltRelocations)
      , check "elf m2 run guard rejects dyn" (validateElf elfJumpSlot == Left (Ldr.BadDyn "dynamic execution unsupported"))
      , check "elf run guard rejects exec interp" (validateElf elfExecInterp == Left (Ldr.BadDyn "dynamic execution unsupported"))
      , check "elf run guard accepts exec" (validateElf elfExecMin == Right ())
      , assertLoadLeft "elf m2 missing bind-now" elfM2NoBind (Ldr.BadDyn "eager relocation without bind-now")
      , assertLoadLeft "elf m2 bad symbol index" elfM2BadSymIndex (Ldr.BadDyn "eager relocation symbol index")
      , assertLoadLeft "elf m2 bad symbol offset" elfM2BadSymbolOffset (Ldr.BadDyn "symbol name offset")
      , assertLoadLeft "elf m2 bad symbol name" elfM2BadSymbolName (Ldr.BadDyn "symbol non-printable")
      , assertLoadLeft "elf m2 non-writable target" elfM2NonWritable (Ldr.BadDyn "rela target not writable")
      , assertLoadLeft "elf m2 hash bucket cap" elfM2HashBuckets (Ldr.BadDyn "hash buckets")
      , assertLoadLeft "elf m2 symbol count cap" elfM2SymbolCount (Ldr.BadDyn "symbol count")
      , assertLoadLeft "elf m2 GNU hash reject" elfM2GnuHash (Ldr.BadDyn "GNU hash unsupported")
      , assertLoadLeft "elf m2 versioning reject" elfM2Version (Ldr.BadDyn "symbol versioning unsupported")
      , assertLoadLeft "elf m2 init array reject" elfM2Init (Ldr.BadDyn "init/fini arrays unsupported")
      , assertLoadLeft "elf m2 TEXTREL reject" elfM2Textrel (Ldr.BadDyn "TEXTREL unsupported")
      , assertLoadLeft "elf m2 flags TEXTREL reject" elfM2FlagsTextrel (Ldr.BadDyn "TEXTREL unsupported")
      , assertLoadLeft "elf m2 strsz without strtab" elfM2StrszNoStrtab (Ldr.BadDyn "missing STRTAB")
      , assertLoadLeft "elf m2 RELACOUNT reject" elfM2RelaCount (Ldr.BadDyn "RELACOUNT unsupported")
      , assertLoadLeft "elf m2 RELR reject" elfM2Relr (Ldr.BadDyn "RELR unsupported")
      , assertLoadLeft "elf m2 IRELATIVE reject" elfM2Irelative (Ldr.BadDyn "IRELATIVE unsupported")
      , assertLoadLeft "elf bad type" elfBadType Ldr.BadType
      , assertLoadLeft "elf entry outside LOAD" elfEntryOutside (Ldr.BadSegment "entry not in LOAD")
      , assertLoadLeft "elf interp wrong path" elfInterpWrong (Ldr.BadDyn "interp path /lib/ld-linux.so.2")
      , assertLoadLeft "elf interp too long" elfInterpLong (Ldr.BadDyn "interp too long")
      , assertLoadLeft "elf interp double" elfDoubleInterp (Ldr.BadDyn "double-interp")
      , assertLoadLeft "elf dynamic truncated" elfDynTrunc Ldr.Truncated
      , assertLoadLeft "elf strsz overrun" elfStrszOverrun (Ldr.BadDyn "strsz overrun")
      , assertLoadLeft "elf rela outside LOAD" elfRelaOutside (Ldr.BadDyn "rela outside LOAD")
      , assertLoadLeft "elf rela count cap" elfRelaCount (Ldr.BadDyn "rela count")
      , check "elf jump-slot accepted" (isDynRight elfJumpSlot True)
      , check "elf tls reject" (Ldr.loadElf elfTls == Left Ldr.TlsUnsupported)
      , assertLoadLeft "elf relro outside LOAD" elfRelroOutside (Ldr.BadDyn "relro outside LOAD")
      , check "needed cycle a->b->a" (Ldr.findNeededCycle [("a", ["b"]), ("b", ["a"])] == Left Ldr.NeededCycle)
      , check "needed self cycle" (Ldr.findNeededCycle [("a", ["a"])] == Left Ldr.NeededCycle)
      , check "needed acyclic" (Ldr.findNeededCycle [("a", ["b"]), ("b", [])] == Right ())
      , check "needed diamond ok" (Ldr.findNeededCycle [("a", ["b", "c"]), ("b", ["d"]), ("c", ["d"]), ("d", [])] == Right ())
      , check "rela slide good" (Ldr.applyRelativeRelocs 0x01000000 [relativeRelocation 0x01000008 0x2000] (replicate 16 0) == Right (replicate 8 0 ++ put64le 0x01002000))
      , check "rela slide overflow" (Ldr.applyRelativeRelocs 0x01000000 [relativeRelocation 0x01000008 maxBound] (replicate 16 0) == Left Ldr.OverlapSize)
      , check "rela slide jump reject" (Ldr.applyRelativeRelocs 0x01000000 [eagerRelocation 0x01000008 1026 1 "strlen" 0] (replicate 16 0) == Left (Ldr.UnsupportedReloc 1026))
      , check "rela file slide good" (Ldr.applyRelocsToFile [Ldr.Segment 0x01000000 288 512 512 5] 0x01000000 [relativeRelocation 0x01000008 0x2000] (replicate 512 0) == Right (replicate 296 0 ++ put64le 0x01002000 ++ replicate 208 0))
      , -- M2.1 pure dependency, placement, symbol, and relocation planner
        check
          "link JUMP_SLOT resolves"
          ( linkPatchMatches
              Linker.LinkJumpSlot
              "libc-house.so.0"
              (Just "strlen")
              0x01000338
              0x01010100
              (defaultLink elfLinkMain)
          )
      , check
          "link GLOB_DAT resolves"
          ( linkPatchMatches
              Linker.LinkGlobDat
              "libc-house.so.0"
              (Just "strlen")
              0x01000338
              0x01010100
              (defaultLink elfLinkGlobMain)
          )
      , check
          "link RELATIVE resolves"
          ( linkPatchMatches
              Linker.LinkRelative
              "main"
              Nothing
              0x01000310
              0x01000020
              ( linkWith
                  elfLinkMain
                  (Right . setMainRelocations [relativeBinding 0x310 0x20] . setMainNeeded [])
                  []
              )
          )
      , check
          "link negative RELATIVE addend"
          ( linkPatchMatches
              Linker.LinkRelative
              "main"
              Nothing
              0x01000310
              0x00FFFFE0
              ( linkWith
                  elfLinkMain
                  (Right . setMainRelocations [relativeBinding 0x310 (fromIntegral (-0x20 :: Int64))] . setMainNeeded [])
                  []
              )
          )
      , check
          "link negative JUMP_SLOT addend"
          ( linkPatchMatches
              Linker.LinkJumpSlot
              "libc-house.so.0"
              (Just "strlen")
              0x01000338
              0x01010000
              ( linkWith
                  elfLinkMain
                  (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" (fromIntegral (-0x100 :: Int64))] . setMainNeeded ["libc-house.so.0"])
                  [("libc-house.so.0", elfLinkDep, validDependency "libc-house.so.0" [] [definedSymbol "strlen" 0x100 1])]
              )
          )
      , check
          "link DFS discovery order"
          ( linkNamesAre
              ["main", "liba.so.0", "libc.so.0", "libb.so.0"]
              ( linkWith
                  elfLinkMain
                  (Right . setMainRelocations [] . setMainNeeded ["liba.so.0", "libb.so.0"])
                  [ ("liba.so.0", elfLinkDep, validDependency "liba.so.0" ["libc.so.0"] [])
                  , ("libb.so.0", elfLinkDep, validDependency "libb.so.0" ["libc.so.0"] [])
                  , ("libc.so.0", elfLinkDep, validDependency "libc.so.0" [] [])
                  ]
              )
          )
      , check
          "link duplicate NEEDED dedup"
          ( linkNamesAre
              ["main", "liba.so.0"]
              ( linkWith
                  elfLinkMain
                  (Right . setMainRelocations [] . setMainNeeded ["liba.so.0", "liba.so.0"])
                  [("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [])]
              )
          )
      , check
          "link placement non-overlap"
          ( linkBasesAre
              [0x01000000, 0x01010000, 0x01020000]
              ( linkWith
                  elfLinkMain
                  (Right . setMainRelocations [] . setMainNeeded ["liba.so.0", "libb.so.0"])
                  [ ("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [])
                  , ("libb.so.0", elfLinkDep, validDependency "libb.so.0" [] [])
                  ]
              )
          )
      , check
          "link patch order deterministic"
          ( linkPatchTargetsAre
              [0x01000300, 0x01000308, 0x01000310]
              ( linkWith
                  elfLinkMain
                  ( Right
                      . setMainRelocations
                        [relativeBinding 0x300 1, relativeBinding 0x308 2, relativeBinding 0x310 3]
                      . setMainNeeded []
                  )
                  []
              )
          )
      , check
          "link relocation table order"
          (linkPatchTargetsAre [0x01000310, 0x01000338] (defaultLink elfLinkMain))
      , check
          "link does not unlock dynamic run"
          ( case defaultLink elfLinkMain of
              Left _ -> False
              Right _ -> validateElf elfLinkMain == Left (Ldr.BadDyn "dynamic execution unsupported")
          )
      , assertLinkLeft
          "link missing dependency"
          (linkWith elfLinkMain (Right . setMainRelocations [] . setMainNeeded ["missing.so.0"]) [])
      , assertLinkLeft
          "link incomplete transitive dependency"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, validDependency "liba.so.0" ["libmissing.so.0"] [])]
          )
      , assertLinkLeft
          "link dependency cycle"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [] . setMainNeeded ["liba.so.0"])
              [ ("liba.so.0", elfLinkDep, validDependency "liba.so.0" ["libb.so.0"] [])
              , ("libb.so.0", elfLinkDep, validDependency "libb.so.0" ["liba.so.0"] [])
              ]
          )
      , assertLinkLeft
          "link SONAME mismatch"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, validDependency "actual.so.0" [] [])]
          )
      , assertLinkLeft
          "link dependency INTERP rejected"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, setDependencyInterp (validDependency "liba.so.0" [] []))]
          )
      , assertLinkLeft
          "link dependency RELRO required"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, clearDependencyRelro (validDependency "liba.so.0" [] []))]
          )
      , assertLinkLeft
          "link dependency object cap"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [])
              [ ("lib" ++ show index ++ ".so.0", elfLinkDep, validDependency ("lib" ++ show index ++ ".so.0") [] [])
              | index <- ([0 .. 9] :: [Int])
              ]
          )
      , assertLinkLeft
          "link total page cap"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [] . setMainNeeded ["lib0.so.0", "lib1.so.0", "lib2.so.0", "lib3.so.0"])
              [ ("lib" ++ show index ++ ".so.0", elfLinkDepLarge, validDependency ("lib" ++ show index ++ ".so.0") [] [])
              | index <- ([0 .. 3] :: [Int])
              ]
          )
      , assertLinkLeft
          "link placed stack collision"
          (linkWith elfLinkMain setMainForStack [])
      , assertLinkLeft
          "link unresolved relocation"
          ( linkWith
              elfLinkMain
              ( Right
                  . setMainRelocations [eagerBinding 0x338 1026 1 "missing" 0]
                  . setMainSymbolTable [undefinedSymbol "missing"]
                  . setMainNeeded []
              )
              []
          )
      , assertLinkLeft
          "link duplicate export"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [] . setMainNeeded ["liba.so.0", "libb.so.0"])
              [ ("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [definedSymbol "dup" 0x100 1])
              , ("libb.so.0", elfLinkDep, validDependency "libb.so.0" [] [definedSymbol "dup" 0x100 1])
              ]
          )
      , assertLinkLeft
          "link provider outside LOAD"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [definedSymbol "strlen" 0x1000 1])]
          )
      , assertLinkLeft
          "link symbol size overflow"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [definedSymbol "strlen" 0x100 maxBound])]
          )
      , assertLinkLeft
          "link relocation target overflow"
          (linkWith elfLinkMain (Right . setMainRelocations [eagerBinding maxBound 1026 1 "strlen" 0] . setMainNeeded []) [])
      , assertLinkLeft
          "link relocation value overflow"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0x110000] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, setDependencyNearTop (validDependency "liba.so.0" [] [definedSymbol "strlen" 0x100 1]))]
          )
      , assertLinkLeft
          "link relocation addend underflow"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0x8000000000000000] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [definedSymbol "strlen" 0x100 1])]
          )
      , assertLinkLeft
          "link duplicate relocation target"
          ( linkWith
              elfLinkMain
              ( Right
                  . setMainRelocations
                    [eagerBinding 0x338 1026 1 "strlen" 0, eagerBinding 0x338 1026 1 "strlen" 0]
                  . setMainNeeded ["liba.so.0"]
              )
              [("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [definedSymbol "strlen" 0x100 1])]
          )
      , assertLinkLeft
          "link weak symbol rejected"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [weakSymbol "strlen"])]
          )
      , assertLinkLeft
          "link protected visibility rejected"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [protectedSymbol "strlen"])]
          )
      , assertLinkLeft
          "link IFUNC rejected"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0] . setMainNeeded ["liba.so.0"])
              [("liba.so.0", elfLinkDep, validDependency "liba.so.0" [] [ifuncSymbol "strlen"])]
          )
      , assertLinkLeft
          "link SHN_COMMON rejected"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0] . setMainNeeded ["libc-house.so.0"])
              [("libc-house.so.0", elfLinkDepCommon, Right)]
          )
      , assertLinkLeft
          "link SHN_ABS rejected"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0] . setMainNeeded ["libc-house.so.0"])
              [("libc-house.so.0", elfLinkDepAbsolute, Right)]
          )
      , assertLinkLeft
          "link SHN_XINDEX rejected"
          ( linkWith
              elfLinkMain
              (Right . setMainRelocations [eagerBinding 0x338 1026 1 "strlen" 0] . setMainNeeded ["libc-house.so.0"])
              [("libc-house.so.0", elfLinkDepXIndex, Right)]
          )
      , assertLinkLeft
          "link main bind-now required"
          (linkWith elfLinkMain (Right . setMainBindNow False . setMainRelocations []) [])
      , assertLinkLeft
          "link main RELRO required"
          (linkWith elfLinkMain (Right . clearMainRelro . setMainRelocations []) [])
      , assertLinkLeft
          "link main SysV required"
          (linkWith elfLinkMain (Right . setMainHash Ldr.NoHash . setMainRelocations []) [])
      , checkIO "loader vs repack parity" parityCheck
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

-- M1 dynamic-linking fixtures -------------------------------------------------

-- | Little-endian encoders for synthetic ELF fixtures.
put16le :: Word16 -> [Word8]
put16le w = [fromIntegral w, fromIntegral (w `shiftR` 8)]

put32le :: Word32 -> [Word8]
put32le w = [fromIntegral (w `shiftR` s) | s <- [0, 8, 16, 24]]

put64le :: Word64 -> [Word8]
put64le w = [fromIntegral (w `shiftR` s) | s <- [0, 8, 16, 24, 32, 40, 48, 56]]

-- | Splice bytes into a fixture at a file offset (total).
patchAt :: [Word8] -> Int -> [Word8] -> [Word8]
patchAt bs off new = take off bs ++ new ++ drop (off + length new) bs

-- | Minimal 64-byte EHDR (phoff 64, phentsize 56).
mkEhdr :: Word16 -> Word64 -> Int -> [Word8]
mkEhdr etype entry phnum =
  [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    ++ put16le etype
    ++ put16le 183
    ++ put32le 1
    ++ put64le entry
    ++ put64le 64
    ++ put64le 0
    ++ put32le 0
    ++ put16le 64
    ++ put16le 56
    ++ put16le (fromIntegral phnum)
    ++ put16le 0
    ++ put16le 0
    ++ put16le 0

-- | One 56-byte program header.
mkPhdr :: Word32 -> Word32 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> [Word8]
mkPhdr ptype flags off vaddr filesz memsz align =
  put32le ptype
    ++ put32le flags
    ++ put64le off
    ++ put64le vaddr
    ++ put64le vaddr
    ++ put64le filesz
    ++ put64le memsz
    ++ put64le align

-- | 16-byte EL0 stub (movz x0 + ret) standing in for real code.
dynCode16 :: [Word8]
dynCode16 = [0x20, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6, 0, 0, 0, 0, 0, 0, 0, 0]

interpGoodBs :: [Word8]
interpGoodBs = map (fromIntegral . ord) "/lib/ld-house.so.0" ++ [0]

interpBadBs :: [Word8]
interpBadBs = map (fromIntegral . ord) "/lib/ld-linux.so.2" ++ [0]

-- | Dynamic array with DT_NULL terminator appended.
mkDynArr :: [(Word64, Word64)] -> [Word8]
mkDynArr ents = concatMap (\(t, v) -> put64le t ++ put64le v) (ents ++ [(0, 0)])

-- | One 24-byte RELA entry (symbol field 0).
mkRelaEnt :: Word64 -> Word32 -> Word64 -> [Word8]
mkRelaEnt off typ add = put64le off ++ put64le (fromIntegral typ) ++ put64le add

-- | One RELA entry with an explicit symbol-table index.
mkRelaEntSym :: Word64 -> Word32 -> Word32 -> Word64 -> [Word8]
mkRelaEntSym off typ sym add =
  put64le off
    ++ put64le ((fromIntegral sym `shiftL` 32) .|. fromIntegral typ)
    ++ put64le add

mkSymEnt :: Word32 -> Word8 -> Word64 -> Word64 -> [Word8]
mkSymEnt nameOff info value size =
  put32le nameOff
    ++ [info, 0]
    ++ put16le 1
    ++ put64le value
    ++ put64le size

mkSysvHash :: Word32 -> Word32 -> Word32 -> [Word32] -> [Word8]
mkSysvHash buckets symbols firstBucket chains =
  put32le buckets
    ++ put32le symbols
    ++ concatMap put32le (firstBucket : chains)

patchMany :: [(Int, [Word8])] -> [Word8] -> [Word8]
patchMany patches bytes = foldl (\current (off, replacement) -> patchAt current off replacement) bytes patches

m2Strings :: [Word8]
m2Strings = map (fromIntegral . ord) "\0libc-house.so.0\0strlen\0"

m2StrlenOffset :: Int
m2StrlenOffset = 1 + length "libc-house.so.0" + 1

m2JumpEnts :: [(Word64, Word64)]
m2JumpEnts =
  [ (1, 1)
  , (14, 1)
  , (2, 24)
  , (3, 0x338)
  , (20, 7)
  , (23, 0x280)
  , (24, 0)
  , (30, 8)
  , (4, 0x1C0)
  , (5, 0x200)
  , (6, 0x180)
  , (7, 0x240)
  , (8, 24)
  , (9, 24)
  , (10, fromIntegral (length m2Strings))
  , (11, 24)
  , (0x6FFFFFFB, 1)
  ]

m2DsoEnts :: [(Word64, Word64)]
m2DsoEnts =
  [ (14, 1)
  , (24, 0)
  , (30, 8)
  , (4, 0x1C0)
  , (5, 0x200)
  , (6, 0x180)
  , (10, fromIntegral (length m2Strings))
  , (11, 24)
  , (0x6FFFFFFB, 1)
  ]

m2Blob :: [(Word64, Word64)] -> Word32 -> Word32 -> [Word8]
m2Blob ents relType relSym =
  patchMany
    [ (0x40, mkDynArr ents)
    , (0x180, mkSymEnt 0 0 0 0 ++ mkSymEnt (fromIntegral m2StrlenOffset) 0x12 0x100 1)
    , (0x1C0, mkSysvHash 1 2 1 [0, 0])
    , (0x200, m2Strings)
    , (0x240, mkRelaEntSym 0x310 1027 0 0)
    , (0x280, mkRelaEntSym 0x338 relType relSym 0)
    , (0x340, interpGoodBs)
    ]
    (replicate 0x400 0)

mkM2ElfFromBlob :: Word64 -> Word32 -> Word64 -> Bool -> Bool -> Int -> [Word8] -> [Word8]
mkM2ElfFromBlob entry flags memSize withInterp withRelro dynSize blob =
  let n = 2 + (if withInterp then 1 else 0) + (if withRelro then 1 else 0)
      fileBase = 64 + 56 * n
      pLoad = mkPhdr 1 flags (fromIntegral fileBase) 0 0x400 memSize 0
      pDyn = mkPhdr 2 6 (fromIntegral (fileBase + 0x40)) 0x40 (fromIntegral dynSize) (fromIntegral dynSize) 8
      pInterp = [mkPhdr 3 4 (fromIntegral (fileBase + 0x340)) 0x340 (fromIntegral (length interpGoodBs)) (fromIntegral (length interpGoodBs)) 1 | withInterp]
      pRelro = [mkPhdr 0x6474E552 4 0 0x40 0x300 0x300 1 | withRelro]
   in mkEhdr 3 entry n ++ pLoad ++ pDyn ++ concat pInterp ++ concat pRelro ++ blob

mkM2Elf :: [(Word64, Word64)] -> Word32 -> Word32 -> Word32 -> Word64 -> Bool -> Bool -> [Word8]
mkM2Elf ents relType relSym flags memSize withInterp withRelro =
  mkM2ElfFromBlob 0x80 flags memSize withInterp withRelro (length (mkDynArr ents)) (m2Blob ents relType relSym)

{- | 512-byte LOAD blob: code at 0, interp at 0x10, dynamic at 0x100,
RELA at 0x180 (VAs 0x01000000 + offset).
-}
mkDynBlob :: [Word8] -> [(Word64, Word64)] -> (Word32, Word64, Word64) -> [Word8]
mkDynBlob interp dynEnts (rtype, roff, radd) =
  patchAt
    (patchAt (patchAt (patchAt (replicate 512 0) 0 dynCode16) 0x10 interp) 0x100 (mkDynArr dynEnts))
    0x180
    (mkRelaEnt roff rtype radd)

goodDynEnts :: [(Word64, Word64)]
goodDynEnts = [(7, 0x01000180), (8, 24), (9, 24)]

goodBlob :: [Word8]
goodBlob = mkDynBlob interpGoodBs goodDynEnts (1027, 0x01000008, 0x2000)

{- | Dynamic ELF: LOAD + INTERP + DYNAMIC + RELRO, blobs packed after the
headers. Interp/dyn specs are (blob off, size); dyn also carries its VA.
The LOAD file offset is computed from the phdr count, never hardcoded.
-}
mkDynElf :: Word16 -> Word64 -> [Word8] -> [(Int, Int)] -> [(Int, Word64, Int)] -> [(Word64, Word64)] -> [[Word8]] -> [Word8]
mkDynElf etype entry blob interps dyns relros extras =
  let n = 1 + length interps + length dyns + length relros + length extras
      base = 64 + 56 * n
      h = mkEhdr etype entry n
      pLoad = mkPhdr 1 5 (fromIntegral base) 0x01000000 0x200 0x200 0
      pIs = [mkPhdr 3 0 (fromIntegral (base + o)) 0 (fromIntegral s) (fromIntegral s) 1 | (o, s) <- interps]
      pDs = [mkPhdr 2 0 (fromIntegral (base + o)) v (fromIntegral s) (fromIntegral s) 8 | (o, v, s) <- dyns]
      pRs = [mkPhdr 0x6474E552 0 0 v m m 1 | (v, m) <- relros]
   in h ++ pLoad ++ concat pIs ++ concat pDs ++ concat pRs ++ concat extras ++ blob

elfExecMin :: [Word8]
elfExecMin = mkEhdr 2 0x01000000 1 ++ mkPhdr 1 5 120 0x01000000 16 16 0 ++ dynCode16

elfDynGood :: [Word8]
elfDynGood = mkDynElf 3 0x01000000 goodBlob [(0x10, 19)] [(0x100, 0x01000100, 64)] [(0x01000000, 0x10)] []

elfExecInterp :: [Word8]
elfExecInterp = mkDynElf 2 0x01000000 (mkDynBlob interpGoodBs [] (0, 0, 0)) [(0x10, 19)] [] [] []

elfExecTls :: [Word8]
elfExecTls = mkDynElf 2 0x01000000 (mkDynBlob interpGoodBs [] (0, 0, 0)) [] [] [] [mkPhdr 7 4 0 0x01000000 0 16 1]

elfDynTls :: [Word8]
elfDynTls = mkDynElf 3 0x01000000 (mkDynBlob interpGoodBs [] (0, 0, 0)) [] [] [] [mkPhdr 7 4 0 0x01000000 0 16 1]

elfOverlapLoads :: [Word8]
elfOverlapLoads =
  let base = 64 + 56 * 2
      p1 = mkPhdr 1 5 (fromIntegral base) 0x01000000 0x100 0x100 0
      p2 = mkPhdr 1 6 (fromIntegral (base + 0x100)) 0x01000800 0x100 0x100 0
   in mkEhdr 2 0x01000000 2 ++ p1 ++ p2 ++ replicate (base + 0x200) 0

elfStackCollision :: [Word8]
elfStackCollision = mkEhdr 2 0x3FFFD000 1 ++ mkPhdr 1 5 120 0x3FFFD000 0x1000 0x1000 0 ++ replicate 0x1000 0

elfBadVersion :: [Word8]
elfBadVersion = patchAt elfExecMin 6 [2]

elfPhentZero :: [Word8]
elfPhentZero = patchAt elfDynGood 54 [0, 0]

elfDynAlign8192 :: [Word8]
elfDynAlign8192 = patchMany [(72, put64le 0), (112, put64le 8192)] elfDynGood

elfStaticBss :: [Word8]
elfStaticBss = patchMany [(104, put64le 0x1000)] elfExecMin

elfDynUnsorted :: [Word8]
elfDynUnsorted =
  let blob = patchAt goodBlob 0x100 (mkDynArr [(5, 0x00200000), (7, 0x00200180), (8, 24), (9, 24)])
      extraLoad = mkPhdr 1 6 288 0x00200000 0x200 0x200 0
   in mkDynElf 3 0x01000000 blob [(0x10, 19)] [(0x100, 0x00200100, 80)] [] [extraLoad]

elfDynLow :: [Word8]
elfDynLow = mkEhdr 3 0 1 ++ mkPhdr 1 6 120 0 16 16 0 ++ dynCode16

elfBadType :: [Word8]
elfBadType = mkDynElf 7 0x01000000 goodBlob [(0x10, 19)] [(0x100, 0x01000100, 64)] [(0x01000000, 0x10)] []

elfEntryOutside :: [Word8]
elfEntryOutside = mkDynElf 3 0x02000000 goodBlob [(0x10, 19)] [(0x100, 0x01000100, 64)] [(0x01000000, 0x10)] []

elfInterpWrong :: [Word8]
elfInterpWrong =
  mkDynElf 3 0x01000000 (mkDynBlob interpBadBs goodDynEnts (1027, 0x01000008, 0x2000)) [(0x10, 19)] [(0x100, 0x01000100, 64)] [(0x01000000, 0x10)] []

elfInterpLong :: [Word8]
elfInterpLong = mkDynElf 3 0x01000000 goodBlob [(0x10, 300)] [(0x100, 0x01000100, 64)] [(0x01000000, 0x10)] []

elfDoubleInterp :: [Word8]
elfDoubleInterp = mkDynElf 3 0x01000000 goodBlob [(0x10, 19), (0x10, 19)] [(0x100, 0x01000100, 64)] [] []

elfDynTrunc :: [Word8]
elfDynTrunc = mkDynElf 3 0x01000000 goodBlob [(0x10, 19)] [(0x100, 0x01000100, 10000)] [] []

elfStrszOverrun :: [Word8]
elfStrszOverrun =
  mkDynElf 3 0x01000000 (mkDynBlob interpGoodBs [(5, 0x01000000), (10, 70000)] (1027, 0x01000008, 0x2000)) [(0x10, 19)] [(0x100, 0x01000100, 48)] [] []

elfRelaOutside :: [Word8]
elfRelaOutside =
  mkDynElf 3 0x01000000 (mkDynBlob interpGoodBs goodDynEnts (1027, 0x02000000, 0x2000)) [(0x10, 19)] [(0x100, 0x01000100, 64)] [] []

elfRelaCount :: [Word8]
elfRelaCount =
  mkDynElf 3 0x01000000 (mkDynBlob interpGoodBs [(7, 0x01000180), (8, 120000), (9, 24)] (1027, 0x01000008, 0x2000)) [(0x10, 19)] [(0x100, 0x01000100, 64)] [] []

elfJumpSlot :: [Word8]
elfJumpSlot = mkM2Elf m2JumpEnts 1026 1 6 0x500 True True

elfM2Dso :: [Word8]
elfM2Dso = mkM2ElfFromBlob 0 6 0x500 False False (length (mkDynArr m2DsoEnts)) (m2Blob m2DsoEnts 1026 1)

elfGlobDat :: [Word8]
elfGlobDat = mkM2Elf m2JumpEnts 1025 1 6 0x500 True True

elfM2NoBind :: [Word8]
elfM2NoBind = mkM2Elf [(tag, val) | (tag, val) <- m2JumpEnts, tag /= 24, tag /= 30, tag /= 0x6FFFFFFB] 1026 1 6 0x500 True True

elfM2BadSymIndex :: [Word8]
elfM2BadSymIndex = mkM2Elf m2JumpEnts 1026 2 6 0x500 True True

elfM2NonWritable :: [Word8]
elfM2NonWritable = mkM2Elf m2JumpEnts 1026 1 4 0x500 True True

elfM2GnuHash :: [Word8]
elfM2GnuHash = mkM2Elf ((0x6FFFFEF5, 0) : filter ((/= 4) . fst) m2JumpEnts) 1026 1 6 0x500 True True

elfM2Version :: [Word8]
elfM2Version = mkM2Elf ((0x6FFFFFF0, 0) : m2JumpEnts) 1026 1 6 0x500 True True

elfM2Init :: [Word8]
elfM2Init = mkM2Elf ((25, 0x240) : m2JumpEnts) 1026 1 6 0x500 True True

elfM2Textrel :: [Word8]
elfM2Textrel = mkM2Elf ((22, 0) : m2JumpEnts) 1026 1 6 0x500 True True

elfM2FlagsTextrel :: [Word8]
elfM2FlagsTextrel = mkM2Elf ((30, 4) : [(tag, value) | (tag, value) <- m2JumpEnts, tag /= 30]) 1026 1 6 0x500 True True

elfM2StrszNoStrtab :: [Word8]
elfM2StrszNoStrtab = mkM2Elf [(10, 24)] 1027 0 6 0x500 True True

elfM2RelaCount :: [Word8]
elfM2RelaCount = mkM2Elf ((0x6FFFFFF9, 1) : m2JumpEnts) 1026 1 6 0x500 True True

elfM2Irelative :: [Word8]
elfM2Irelative = mkM2Elf m2JumpEnts 1037 1 6 0x500 True True

elfM2Relr :: [Word8]
elfM2Relr = mkM2Elf ((36, 0) : m2JumpEnts) 1026 1 6 0x500 True True

elfM2HashBuckets :: [Word8]
elfM2HashBuckets =
  mkM2ElfFromBlob
    0x80
    6
    0x500
    True
    True
    (length (mkDynArr m2JumpEnts))
    (patchAt (m2Blob m2JumpEnts 1026 1) 0x1C0 (put32le (fromIntegral (Ldr.maxDynHashBuckets + 1)) ++ put32le 2))

elfM2SymbolCount :: [Word8]
elfM2SymbolCount =
  mkM2ElfFromBlob
    0x80
    6
    0x500
    True
    True
    (length (mkDynArr m2JumpEnts))
    (patchAt (m2Blob m2JumpEnts 1026 1) 0x1C0 (put32le 1 ++ put32le (fromIntegral (Ldr.maxDynSymbols + 1))))

elfM2BadSymbolName :: [Word8]
elfM2BadSymbolName =
  mkM2ElfFromBlob
    0x80
    6
    0x500
    True
    True
    (length (mkDynArr m2JumpEnts))
    (patchAt (m2Blob m2JumpEnts 1026 1) (0x200 + m2StrlenOffset) [1])

elfM2BadSymbolOffset :: [Word8]
elfM2BadSymbolOffset =
  mkM2ElfFromBlob
    0x80
    6
    0x500
    True
    True
    (length (mkDynArr m2JumpEnts))
    (patchAt (m2Blob m2JumpEnts 1026 1) (0x180 + 24) (put32le (fromIntegral (length m2Strings + 1))))

elfTls :: [Word8]
elfTls =
  mkDynElf 3 0x01000000 (mkDynBlob interpGoodBs goodDynEnts (1051, 0x01000008, 0x2000)) [(0x10, 19)] [(0x100, 0x01000100, 64)] [] []

elfRelroOutside :: [Word8]
elfRelroOutside = mkDynElf 3 0x01000000 goodBlob [(0x10, 19)] [(0x100, 0x01000100, 64)] [(0x02000000, 0x10)] []

elfNeededTwo :: [Word8]
elfNeededTwo =
  let strtab = map (fromIntegral . ord) "libc-house.so.0\0libm-house.so.0\0" :: [Word8]
      blob = patchAt (mkDynBlob interpGoodBs [(1, 0), (1, 16), (5, 0x010001A0), (10, 32)] (1027, 0x01000008, 0x2000)) 0x1A0 strtab
   in mkDynElf 3 0x01000000 blob [(0x10, 19)] [(0x100, 0x01000100, 80)] [] []

-- M2.1 linker fixtures ------------------------------------------------------

elfLinkDepCommon :: [Word8]
elfLinkDepCommon = patchAt elfLinkDep 0x286 (put16le 0xFFF2)

elfLinkDepAbsolute :: [Word8]
elfLinkDepAbsolute = patchAt elfLinkDep 0x286 (put16le 0xFFF1)

elfLinkDepXIndex :: [Word8]
elfLinkDepXIndex = patchAt elfLinkDep 0x286 (put16le 0xFFFF)

elfLinkMain :: [Word8]
elfLinkMain = patchAt elfJumpSlot 0x2BE (put16le 0)

elfLinkGlobMain :: [Word8]
elfLinkGlobMain = patchAt elfGlobDat 0x2BE (put16le 0)

elfLinkDep :: [Word8]
elfLinkDep =
  mkM2ElfFromBlob
    0
    6
    0x500
    False
    True
    (length (mkDynArr m2DsoEnts))
    (m2Blob m2DsoEnts 1026 1)

elfLinkDepLarge :: [Word8]
elfLinkDepLarge =
  mkM2ElfFromBlob
    0
    6
    0x40000
    False
    True
    (length (mkDynArr m2DsoEnts))
    (m2Blob m2DsoEnts 1026 1)

type ElfEdit = Ldr.Elf -> Either Ldr.LoadError Ldr.Elf

linkWith :: [Word8] -> ElfEdit -> [(String, [Word8], ElfEdit)] -> Either Ldr.LoadError Linker.LinkPlan
linkWith mainBytes editMain dependencyEdits = do
  mainElf <- Ldr.loadElf mainBytes >>= editMain
  dependencies <- foldM addDependency Map.empty dependencyEdits
  Linker.linkDynamic mainElf dependencies
  where
    addDependency dependencies (name, bytes, edit) = do
      elf <- Ldr.loadElf bytes
      edited <- edit elf
      pure (Map.insert name edited dependencies)

defaultLink :: [Word8] -> Either Ldr.LoadError Linker.LinkPlan
defaultLink mainBytes =
  linkWith
    mainBytes
    Right
    [("libc-house.so.0", elfLinkDep, validDependency "libc-house.so.0" [] [definedSymbol "strlen" 0x100 1])]

validDependency :: String -> [String] -> [Ldr.DynamicSymbol] -> ElfEdit
validDependency name needed exports elf = do
  withSymbols <- setSymbols exports elf
  let dynInfo = Ldr.elfDyn withSymbols
  pure
    withSymbols {
      Ldr.elfDyn =
        dynInfo {
          Ldr.dynSoname = Just name
          , Ldr.dynNeeded = needed
          , Ldr.dynRelocations = []
          }
      }

setSymbols :: [Ldr.DynamicSymbol] -> ElfEdit
setSymbols named elf = case (Ldr.dynSymbols dynInfo, Ldr.dynHashStyle dynInfo) of
  (Just symbols, Ldr.SysVHash hash) ->
    let entries = nullDynamicSymbol : named
        newSymbols = symbols {Ldr.dynamicSymbolEntries = entries}
        newHash = hash {Ldr.sysvHashSymbols = length entries}
     in Right
          elf {
            Ldr.elfDyn =
              dynInfo {
                Ldr.dynSymbols = Just newSymbols
                , Ldr.dynHashStyle = Ldr.SysVHash newHash
                }
            }
  _ -> Left (Ldr.BadDyn "link fixture has no SysV symbols")
  where
    dynInfo = Ldr.elfDyn elf

setMainNeeded :: [String] -> Ldr.Elf -> Ldr.Elf
setMainNeeded needed = updateDyn (\dynInfo -> dynInfo {Ldr.dynNeeded = needed})

setMainRelocations :: [Ldr.Relocation] -> Ldr.Elf -> Ldr.Elf
setMainRelocations relocations =
  updateDyn
    ( \dynInfo ->
        dynInfo {
          Ldr.dynRelocations =
            [ Ldr.RelocationTable Ldr.DynamicRelocations 0 (24 * length relocations) 24 relocations
            | not (null relocations)
            ]
          }
    )

setMainSymbolTable :: [Ldr.DynamicSymbol] -> Ldr.Elf -> Ldr.Elf
setMainSymbolTable names elf = fromRight elf (setSymbols names elf)

setMainBindNow :: Bool -> Ldr.Elf -> Ldr.Elf
setMainBindNow bindNow = updateDyn (\dynInfo -> dynInfo {Ldr.dynBindNow = bindNow})

setMainHash :: Ldr.HashStyle -> Ldr.Elf -> Ldr.Elf
setMainHash style = updateDyn (\dynInfo -> dynInfo {Ldr.dynHashStyle = style})

clearMainRelro :: Ldr.Elf -> Ldr.Elf
clearMainRelro elf = elf {Ldr.elfRelro = Nothing}

setMainForStack :: ElfEdit
setMainForStack elf =
  let vaddr = Ldr.stackPageStart - 0x01000000
      segments = [segment {Ldr.segVaddr = vaddr} | segment <- Ldr.elfSegs elf]
      relro = fmap (\range -> range {Ldr.relroStart = vaddr + Ldr.relroStart range, Ldr.relroEnd = vaddr + Ldr.relroEnd range}) (Ldr.elfRelro elf)
      cleaned = elf {Ldr.elfSegs = segments, Ldr.elfRelro = relro, Ldr.elfEntry = vaddr + Ldr.elfEntry elf}
   in Right (setMainNeeded [] (setMainRelocations [] cleaned))

setDependencyNearTop :: ElfEdit -> ElfEdit
setDependencyNearTop edit elf = do
  edited <- edit elf
  case Ldr.elfSegs edited of
    [] -> Left (Ldr.BadDyn "link fixture has no LOAD")
    first : _ ->
      let target = 0xFEEE0000
          delta = target - Ldr.segVaddr first
          segments = [segment {Ldr.segVaddr = Ldr.segVaddr segment + delta} | segment <- Ldr.elfSegs edited]
          relro = fmap (\range -> range {Ldr.relroStart = Ldr.relroStart range + delta, Ldr.relroEnd = Ldr.relroEnd range + delta}) (Ldr.elfRelro edited)
          symbols = fmap (\table -> table {Ldr.dynamicSymbolEntries = [symbol {Ldr.dynamicSymbolValue = Ldr.dynamicSymbolValue symbol + delta} | symbol <- Ldr.dynamicSymbolEntries table]}) (Ldr.dynSymbols (Ldr.elfDyn edited))
          dynInfo = (Ldr.elfDyn edited) {Ldr.dynSymbols = symbols}
       in Right edited {Ldr.elfSegs = segments, Ldr.elfRelro = relro, Ldr.elfEntry = Ldr.elfEntry edited + delta, Ldr.elfDyn = dynInfo}

setDependencyInterp :: ElfEdit -> ElfEdit
setDependencyInterp edit elf = do
  edited <- edit elf
  pure edited {Ldr.elfInterp = Just Ldr.ldHousePath}

clearDependencyRelro :: ElfEdit -> ElfEdit
clearDependencyRelro edit elf = do
  edited <- edit elf
  pure edited {Ldr.elfRelro = Nothing}

updateDyn :: (Ldr.DynInfo -> Ldr.DynInfo) -> Ldr.Elf -> Ldr.Elf
updateDyn update elf = elf {Ldr.elfDyn = update (Ldr.elfDyn elf)}

nullDynamicSymbol :: Ldr.DynamicSymbol
nullDynamicSymbol = Ldr.DynamicSymbol "" 0 0 0 0 0

undefinedSymbol :: String -> Ldr.DynamicSymbol
undefinedSymbol name = Ldr.DynamicSymbol name 0x12 0 0 0 0

definedSymbol :: String -> Word64 -> Word64 -> Ldr.DynamicSymbol
definedSymbol name = Ldr.DynamicSymbol name 0x12 0 1

weakSymbol :: String -> Ldr.DynamicSymbol
weakSymbol name = (definedSymbol name 0x100 1) {Ldr.dynamicSymbolInfo = 0x22}

protectedSymbol :: String -> Ldr.DynamicSymbol
protectedSymbol name = (definedSymbol name 0x100 1) {Ldr.dynamicSymbolOther = 2}

ifuncSymbol :: String -> Ldr.DynamicSymbol
ifuncSymbol name = (definedSymbol name 0x100 1) {Ldr.dynamicSymbolInfo = 0x1A}

relativeBinding :: Word64 -> Word64 -> Ldr.Relocation
relativeBinding offset addend = Ldr.RelativeBinding (Ldr.RelativeRelocation offset addend)

eagerBinding :: Word64 -> Word32 -> Word32 -> String -> Word64 -> Ldr.Relocation
eagerBinding offset relocationType symbolIndex name addend =
  Ldr.EagerSymbolBinding (Ldr.EagerSymbolRelocation offset relocationType symbolIndex name addend)

linkPatchMatches :: Linker.LinkRelocation -> String -> Maybe String -> Word64 -> Word64 -> Either Ldr.LoadError Linker.LinkPlan -> Bool
linkPatchMatches relocation provider symbol target value result = case result of
  Left _ -> False
  Right plan ->
    [patch | patch <- Linker.linkPatches plan, Linker.patchRelocation patch == relocation]
      == [Linker.RelocationPatch "main" provider symbol relocation target value]

linkNamesAre :: [String] -> Either Ldr.LoadError Linker.LinkPlan -> Bool
linkNamesAre expected result = case result of
  Left _ -> False
  Right plan -> map Linker.placedObjectName (Linker.linkObjects plan) == expected

linkBasesAre :: [Word64] -> Either Ldr.LoadError Linker.LinkPlan -> Bool
linkBasesAre expected result = case result of
  Left _ -> False
  Right plan -> map Linker.placedObjectBase (Linker.linkObjects plan) == expected

linkPatchTargetsAre :: [Word64] -> Either Ldr.LoadError Linker.LinkPlan -> Bool
linkPatchTargetsAre expected result = case result of
  Left _ -> False
  Right plan -> map Linker.patchTarget (Linker.linkPatches plan) == expected

relativeRelocation :: Word64 -> Word64 -> Ldr.Relocation
relativeRelocation off add = Ldr.RelativeBinding (Ldr.RelativeRelocation off add)

eagerRelocation :: Word64 -> Word32 -> Word32 -> String -> Word64 -> Ldr.Relocation
eagerRelocation off typ sym name add = Ldr.EagerSymbolBinding (Ldr.EagerSymbolRelocation off typ sym name add)

-- | Total field probes over a parsed fixture (Left counts as mismatch).
isDynRight :: [Word8] -> Bool -> Bool
isDynRight bytes wantDyn = case Ldr.loadElf bytes of
  Right e -> Ldr.elfIsDyn e == wantDyn
  Left _ -> False

validateElf :: [Word8] -> Either Ldr.LoadError ()
validateElf bytes = case Ldr.loadElf bytes of
  Left err -> Left err
  Right elf -> Ldr.validateRunElf elf

dynInterpIs :: [Word8] -> Maybe String -> Bool
dynInterpIs bytes want = case Ldr.loadElf bytes of
  Right e -> Ldr.elfInterp e == want
  Left _ -> False

dynRelaCountIs :: [Word8] -> Int -> Bool
dynRelaCountIs bytes n = case Ldr.loadElf bytes of
  Right e -> sum (map (length . Ldr.relocationTableEntries) (Ldr.dynRelocations (Ldr.elfDyn e))) == n
  Left _ -> False

dynRelroIs :: [Word8] -> Maybe Ldr.RelroRange -> Bool
dynRelroIs bytes want = case Ldr.loadElf bytes of
  Right e -> Ldr.elfRelro e == want
  Left _ -> False

dynNeededIs :: [Word8] -> [String] -> Bool
dynNeededIs bytes want = case Ldr.loadElf bytes of
  Right e -> Ldr.dynNeeded (Ldr.elfDyn e) == want
  Left _ -> False

dynSonameIs :: [Word8] -> Maybe String -> Bool
dynSonameIs bytes want = case Ldr.loadElf bytes of
  Right e -> Ldr.dynSoname (Ldr.elfDyn e) == want
  Left _ -> False

isSysvHash :: [Word8] -> Bool
isSysvHash bytes = case Ldr.loadElf bytes of
  Right e -> case Ldr.dynHashStyle (Ldr.elfDyn e) of
    Ldr.SysVHash _ -> True
    Ldr.NoHash -> False
  Left _ -> False

hasEagerType :: [Word8] -> Word32 -> Bool
hasEagerType bytes want = case Ldr.loadElf bytes of
  Right e -> any (any (isEager want) . Ldr.relocationTableEntries) (Ldr.dynRelocations (Ldr.elfDyn e))
  Left _ -> False
  where
    isEager typ relocation = case relocation of
      Ldr.EagerSymbolBinding eager -> Ldr.eagerType eager == typ
      Ldr.RelativeBinding _ -> False

hasTableKind :: [Word8] -> Ldr.RelocationTableKind -> Bool
hasTableKind bytes want = case Ldr.loadElf bytes of
  Right e -> any ((== want) . Ldr.relocationTableKind) (Ldr.dynRelocations (Ldr.elfDyn e))
  Left _ -> False

-- Differential parity: every vector must agree accept/reject ------------------

parityVectors :: [(String, [Word8])]
parityVectors =
  [ ("static-min", elfExecMin)
  , ("static-bss", elfStaticBss)
  , ("overlap-loads", elfOverlapLoads)
  , ("stack-collision", elfStackCollision)
  , ("bad-version", elfBadVersion)
  , ("zero-phentsize", elfPhentZero)
  , ("align-8k", elfDynAlign8192)
  , ("unsorted-dynamic", elfDynUnsorted)
  , ("exec-pt-tls", elfExecTls)
  , ("dyn-pt-tls", elfDynTls)
  , ("dyn-good", elfDynGood)
  , ("dyn-needed-two", elfNeededTwo)
  , ("bad-type", elfBadType)
  , ("entry-outside", elfEntryOutside)
  , ("interp-wrong", elfInterpWrong)
  , ("interp-long", elfInterpLong)
  , ("interp-double", elfDoubleInterp)
  , ("dyn-trunc", elfDynTrunc)
  , ("strsz-overrun", elfStrszOverrun)
  , ("rela-outside", elfRelaOutside)
  , ("rela-count", elfRelaCount)
  , ("jump-slot", elfJumpSlot)
  , ("m2-dso", elfM2Dso)
  , ("glob-dat", elfGlobDat)
  , ("m2-no-bind", elfM2NoBind)
  , ("m2-bad-symbol-index", elfM2BadSymIndex)
  , ("m2-bad-symbol-name", elfM2BadSymbolName)
  , ("m2-bad-symbol-offset", elfM2BadSymbolOffset)
  , ("m2-non-writable", elfM2NonWritable)
  , ("m2-hash-buckets", elfM2HashBuckets)
  , ("m2-symbol-count", elfM2SymbolCount)
  , ("m2-gnu-hash", elfM2GnuHash)
  , ("m2-version", elfM2Version)
  , ("m2-init", elfM2Init)
  , ("m2-textrel", elfM2Textrel)
  , ("m2-flags-textrel", elfM2FlagsTextrel)
  , ("m2-strsz-no-strtab", elfM2StrszNoStrtab)
  , ("m2-relacount", elfM2RelaCount)
  , ("m2-relr", elfM2Relr)
  , ("m2-irelative", elfM2Irelative)
  , ("tls", elfTls)
  , ("relro-outside", elfRelroOutside)
  ]

findRepack :: IO (Maybe FilePath)
findRepack = go ["../../build-probe/repack.py", "../build-probe/repack.py", "build-probe/repack.py"]
  where
    go [] = return Nothing
    go (p : rest) = do
      ok <- doesFileExist p
      if ok then return (Just p) else go rest

{- | Feed every vector to both Loader.hs and repack.py; any accept/reject
divergence fails. Fixture bytes are pure ASCII-range values, but they are
still written as raw bytes so the harness never depends on the locale.
-}
parityCheck :: IO Bool
parityCheck = do
  tmp <- getTemporaryDirectory
  let dir = tmp </> "house-parity"
  createDirectoryIfMissing True dir
  mRepack <- findRepack
  case mRepack of
    Nothing -> hPutStrLn stderr "parity: repack.py not found" >> return False
    Just repack -> do
      results <- forM parityVectors $ \(name, bytes) -> do
        let src = dir </> (name ++ ".bin")
            dst = dir </> (name ++ ".out")
        BS.writeFile src (BS.pack bytes)
        r <- try (readProcessWithExitCode "python3" [repack, src, dst] "") :: IO (Either SomeException (ExitCode, String, String))
        case r of
          Left e -> hPutStrLn stderr ("parity spawn failed: " ++ show e) >> return False
          Right (code, _, _) -> do
            let repackAccept = code == ExitSuccess
                loaderAccept = case Ldr.loadElf bytes of
                  Right _ -> True
                  Left _ -> False
            if repackAccept == loaderAccept
              then return True
              else hPutStrLn stderr ("parity mismatch: " ++ name) >> return False
      return (and results)
