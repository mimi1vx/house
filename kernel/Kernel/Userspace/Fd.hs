{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Fd
Description : Per-pid EL0 fd tables over the VFS namespaces.
Stability   : experimental

Per-pid offsets over 'Kernel.FileSystem.Vfs'. Fds 3..34 per pid (stdio
0-2 reserved: EL0 svc WRITE uses fd 1 for UART). All paths go through
'Vfs.splitPath' in the opener's namespace on every call; all lengths are
capped at 64 KiB (matches the svc user-buffer bound); the RamFS page quota
(10% of RAM, 16 MiB floor) is inherited -- backend writes return ENOSPC
and no fd path grows it.

Isolation: tables are keyed by 'Pid', so a cross-pid fd use misses the
caller's map and fails EBADF. 'fdFork' copies entries+offsets on fork;
'fdRelease' drops the table on wait/kill (no leak over fork/exit cycles).

Lock order: 'fdSem' is a leaf; it is never held across 'Vfs' calls
(which take @registrySem@ then backend sems). Entries are snapshotted
under the lock, VFS I/O runs unlocked, then offsets are committed
under the lock. Each entry remembers the opener's namespace; 'fdOpen'
resolves through the pid's namespace via 'vfsEnsurePid'.

EL0 trap wiring rides the delegation ring ('Syscall' 0x04..0x07 + 0x0A):
Rust ('svc.rs' 'house_fd_should_park') validates the path NUL-termination
(256B) and buffer window (64K) trap-side and parks; Haskell
('Kernel.Userspace.Process.parkLoop') performs the table op and resumes
with the result in x0. The shell 'fdtest' verb exercises this table from
EL1 under pid 0.
-}
module Kernel.Userspace.Fd (
  Fd (..),
  FdError (..),
  fdErrorToString,
  fdErrorToErrno,
  fdOpen,
  fdRead,
  fdWrite,
  fdClose,
  fdSeek,
  fdFork,
  fdRelease,
  maxFdCount,
  maxFdBytes,
  o_RDONLY,
  o_WRONLY,
  o_RDWR,
  o_CREAT,
  o_TRUNC,
  seek_SET,
  seek_CUR,
  seek_END,
)
where

import Data.Bits (complement, (.&.))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word8)
import Foreign.C.Types (CInt (..))
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import Kernel.FileSystem.Vfs (NamespaceId, vfsEnsurePid, vfsLookup)
import Kernel.FileSystem.Vfs qualified as Vfs
import Kernel.Userspace.Types (Pid (..))

-- | File descriptor (3..34 per pid; 0-2 reserved for stdio convention).
newtype Fd = Fd Int
  deriving (Eq, Ord, Show)

-- | Fd errors; FsError embedded for pass-through.
data FdError
  = FdBadFd
  | FdInval String
  | FdNoSpace
  | FdFs Vfs.FsError
  deriving (Eq, Show)

-- | Human string for error (shell).
fdErrorToString :: FdError -> String
fdErrorToString FdBadFd = "EBADF"
fdErrorToString (FdInval s) = "EINVAL: " ++ s
fdErrorToString FdNoSpace = "ENOSPC"
fdErrorToString (FdFs e) = show e

-- | Negative errno for the EL0 resume path (x0).
fdErrorToErrno :: FdError -> CInt
fdErrorToErrno FdBadFd = -9
fdErrorToErrno (FdInval _) = -22
fdErrorToErrno FdNoSpace = -28
fdErrorToErrno (FdFs Vfs.ENOENT) = -2
fdErrorToErrno (FdFs Vfs.EEXIST) = -17
fdErrorToErrno (FdFs Vfs.ENOTDIR) = -20
fdErrorToErrno (FdFs Vfs.EISDIR) = -21
fdErrorToErrno (FdFs Vfs.ENOSPC) = -28
fdErrorToErrno (FdFs (Vfs.EINVAL _)) = -22

-- | Open flags (POSIX subset).
o_RDONLY, o_WRONLY, o_RDWR, o_CREAT, o_TRUNC :: Int
o_RDONLY = 0
o_WRONLY = 1
o_RDWR = 2
o_CREAT = 0x40
o_TRUNC = 0x200

-- | Seek whence.
seek_SET, seek_CUR, seek_END :: Int
seek_SET = 0
seek_CUR = 1
seek_END = 2

-- | Bounds: 32 fds per pid, 64 KiB per read/write (svc buffer cap).
maxFdCount :: Int
maxFdCount = 32

maxFdBytes :: Int
maxFdBytes = 65536

-- | Table entry: absolute path + offset + access mode + opener namespace.
data Entry = Entry {
  entPath :: FilePath
  , entOff :: Int
  , entAcc :: Int
  , entNs :: NamespaceId
  }
  deriving (Eq, Show)

{-# NOINLINE fdTable #-}
fdTable :: Ref (Map Pid (Map Fd Entry))
fdTable = unsafePerformH $ newRef Map.empty

{-# NOINLINE fdSem #-}
fdSem :: QSem
fdSem = unsafePerformH $ newQSem 1

-- | Lowest free fd >=3 in the pid's map, or Nothing when full.
allocFd :: Map Fd Entry -> Maybe Fd
allocFd m = go 3
  where
    go n
      | n >= 3 + maxFdCount = Nothing
      | Map.member (Fd n) m = go (n + 1)
      | otherwise = Just (Fd n)

-- | Known flag bits: acc(2) + CREAT + TRUNC.
validFlags :: Int -> Bool
validFlags f =
  let acc = f .&. 3
      rest = f .&. complement 0x243
   in acc <= 2 && rest == 0

lookupEntry :: Pid -> Fd -> H (Maybe Entry)
lookupEntry pid fd = withQSem fdSem $ do
  m <- readRef fdTable
  return (Map.lookup pid m >>= Map.lookup fd)

{- | Open a path through a pid's mount namespace (EL0 trap path and EL1
shell under pid 0). Resolves via 'vfsEnsurePid' so a child mount is
visible here. Creates (empty) on O_CREAT when missing; truncates on
O_TRUNC. Directories reject with EISDIR.
-}
fdOpen :: Pid -> FilePath -> Int -> H (Either FdError Fd)
fdOpen pid@(Pid pidInt) path flags
  | not (validFlags flags) = return (Left (FdInval "bad flags"))
  | otherwise = case Vfs.splitPath path of
      Left e -> return (Left (FdFs e))
      Right _ -> do
        ns <- vfsEnsurePid pidInt
        rStat <- vfsLookup ns path
        case rStat of
          Left e -> return (Left (FdFs e))
          Right (ops, rel) -> do
            st <- Vfs.opsStat ops rel
            case st of
              Right s
                | Vfs.fsIsDir s -> return (Left (FdFs Vfs.EISDIR))
                | otherwise -> openExisting ns ops rel
              Left Vfs.ENOENT
                | flags .&. o_CREAT /= 0 -> do
                    r <- vfsLookup ns path
                    case r of
                      Left e -> return (Left (FdFs e))
                      Right (ops2, rel2) -> do
                        cr <- Vfs.opsCreate ops2 rel2
                        case cr of
                          Left e -> return (Left (FdFs e))
                          Right () -> insertEntry ns
                | otherwise -> return (Left (FdFs Vfs.ENOENT))
              Left e -> return (Left (FdFs e))
  where
    acc = flags .&. 3
    openExisting ns ops rel
      | flags .&. o_TRUNC /= 0 && acc /= o_RDONLY = do
          r <- Vfs.opsWrite ops rel []
          case r of
            Left Vfs.ENOSPC -> return (Left FdNoSpace)
            Left e -> return (Left (FdFs e))
            Right () -> insertEntry ns
      | otherwise = insertEntry ns
    insertEntry ns = withQSem fdSem $ do
      m <- readRef fdTable
      let per = Map.findWithDefault Map.empty pid m
      case allocFd per of
        Nothing -> return (Left (FdInval "fd table full"))
        Just fd -> do
          writeRef fdTable (Map.insert pid (Map.insert fd (Entry path 0 acc ns) per) m)
          return (Right fd)

-- | Read up to n bytes from the pid's fd offset. Advances the offset.
fdRead :: Pid -> Fd -> Int -> H (Either FdError [Word8])
fdRead pid fd n
  | n < 0 || n > maxFdBytes = return (Left (FdInval "bad length"))
  | otherwise = do
      mEnt <- lookupEntry pid fd
      case mEnt of
        Nothing -> return (Left FdBadFd)
        Just ent
          | entAcc ent == o_WRONLY -> return (Left (FdInval "not readable"))
          | otherwise -> do
              r <- vfsLookup (entNs ent) (entPath ent)
              case r of
                Left e -> return (Left (FdFs e))
                Right (ops, rel) -> do
                  cr <- Vfs.opsRead ops rel
                  case cr of
                    Left Vfs.ENOSPC -> return (Left FdNoSpace)
                    Left e -> return (Left (FdFs e))
                    Right content -> do
                      let avail = drop (entOff ent) content
                          chunk = take n avail
                          off' = entOff ent + length chunk
                      withQSem fdSem $ do
                        m <- readRef fdTable
                        case Map.lookup pid m >>= Map.lookup fd of
                          Nothing -> return (Left FdBadFd)
                          Just e2 -> do
                            let per = Map.findWithDefault Map.empty pid m
                            writeRef fdTable (Map.insert pid (Map.insert fd e2 {entOff = off'} per) m)
                            return (Right chunk)

-- | Write bytes at the pid's fd offset (read-modify-write). Advances the offset.
fdWrite :: Pid -> Fd -> [Word8] -> H (Either FdError Int)
fdWrite pid fd content
  | length content > maxFdBytes = return (Left (FdInval "bad length"))
  | otherwise = do
      mEnt <- lookupEntry pid fd
      case mEnt of
        Nothing -> return (Left FdBadFd)
        Just ent
          | entAcc ent == o_RDONLY -> return (Left (FdInval "not writable"))
          | otherwise -> do
              r <- vfsLookup (entNs ent) (entPath ent)
              case r of
                Left e -> return (Left (FdFs e))
                Right (ops, rel) -> do
                  cr <- Vfs.opsRead ops rel
                  cur <- case cr of
                    Right s -> return (Right s)
                    Left Vfs.ENOENT -> return (Right [])
                    Left Vfs.ENOSPC -> return (Left FdNoSpace)
                    Left e -> return (Left (FdFs e))
                  case cur of
                    Left e -> return (Left e)
                    Right old ->
                      if entOff ent > length old
                        then return (Left (FdInval "offset past EOF"))
                        else do
                          let newContent = take (entOff ent) old ++ content ++ drop (entOff ent + length content) old
                          w <- Vfs.opsWrite ops rel newContent
                          case w of
                            Left Vfs.ENOSPC -> return (Left FdNoSpace)
                            Left e -> return (Left (FdFs e))
                            Right () -> do
                              let off' = entOff ent + length content
                              withQSem fdSem $ do
                                m <- readRef fdTable
                                case Map.lookup pid m >>= Map.lookup fd of
                                  Nothing -> return (Left FdBadFd)
                                  Just e2 -> do
                                    let per = Map.findWithDefault Map.empty pid m
                                    writeRef fdTable (Map.insert pid (Map.insert fd e2 {entOff = off'} per) m)
                                    return (Right (length content))

-- | Close a pid's fd (miss is EBADF).
fdClose :: Pid -> Fd -> H (Either FdError ())
fdClose pid fd = withQSem fdSem $ do
  m <- readRef fdTable
  case Map.lookup pid m >>= Map.lookup fd of
    Nothing -> return (Left FdBadFd)
    Just _ -> do
      let per = Map.findWithDefault Map.empty pid m
          per' = Map.delete fd per
      writeRef fdTable (if Map.null per' then Map.delete pid m else Map.insert pid per' m)
      return (Right ())

-- | Reposition the pid's fd offset.
fdSeek :: Pid -> Fd -> Int -> Int -> H (Either FdError Int)
fdSeek pid fd off whence = do
  mEnt <- lookupEntry pid fd
  case mEnt of
    Nothing -> return (Left FdBadFd)
    Just ent -> do
      base <- case whence of
        0 -> return (Right 0)
        1 -> return (Right (entOff ent))
        2 -> do
          r <- vfsLookup (entNs ent) (entPath ent)
          case r of
            Left e -> return (Left (FdFs e))
            Right (ops, rel) -> do
              sr <- Vfs.opsStat ops rel
              case sr of
                Right s -> return (Right (Vfs.fsSize s))
                Left Vfs.ENOENT -> return (Right 0)
                Left Vfs.ENOSPC -> return (Left FdNoSpace)
                Left e -> return (Left (FdFs e))
        _ -> return (Left (FdInval "bad whence"))
      case base of
        Left e -> return (Left e)
        Right b ->
          let newOff = b + off
           in if newOff < 0
                then return (Left (FdInval "negative offset"))
                else withQSem fdSem $ do
                  m <- readRef fdTable
                  case Map.lookup pid m >>= Map.lookup fd of
                    Nothing -> return (Left FdBadFd)
                    Just e2 -> do
                      let per = Map.findWithDefault Map.empty pid m
                      writeRef fdTable (Map.insert pid (Map.insert fd e2 {entOff = newOff} per) m)
                      return (Right newOff)

-- | Inherit entries+offsets on fork (fresh map, shared nothing mutable).
fdFork :: Pid -> Pid -> H ()
fdFork parent child = withQSem fdSem $ do
  m <- readRef fdTable
  case Map.lookup parent m of
    Nothing -> return ()
    Just per -> writeRef fdTable (Map.insert child per m)

-- | Drop the pid's table on wait/kill (no leak over fork/exit cycles).
fdRelease :: Pid -> H ()
fdRelease pid = withQSem fdSem $ do
  m <- readRef fdTable
  writeRef fdTable (Map.delete pid m)
