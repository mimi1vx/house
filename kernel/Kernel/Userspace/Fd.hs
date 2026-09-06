{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Fd
Description : EL0 fd table over the VFS default namespace.
Stability   : experimental

Per-fd offsets over 'Kernel.FileSystem.Vfs' for the Track O FS slice.
Fds 3..34 (stdio 0-2 reserved: EL0 svc WRITE uses fd 1 for UART). All
paths go through 'Vfs.splitPath' in the fd's namespace on every call;
all lengths are capped at 64 KiB (matches the svc user-buffer bound);
the 2 MiB ramfs cap is inherited -- backend writes return ENOSPC and
no fd path grows it.

Lock order: 'fdSem' is a leaf; it is never held across 'Vfs' calls
(which take @registrySem@ then backend sems). Entries are snapshotted
under the lock, VFS I/O runs unlocked, then offsets are committed
under the lock. Each entry remembers the opener's namespace; 'fdOpen'
uses the default namespace (boot\/shell\/fdtest), 'fdOpenIn' resolves
through a pid's namespace for future EL0 trap wiring.

EL0 trap wiring waits on the delegation ring (same pattern as the IPC
slice): 'Syscall' reserves 0x04..0x07 + 0x0A and svc returns ENOSYS
until then. The shell 'fdtest' verb exercises this table from EL1.
-}
module Kernel.Userspace.Fd (
  Fd (..),
  FdError (..),
  fdErrorToString,
  fdOpen,
  fdOpenIn,
  fdRead,
  fdWrite,
  fdClose,
  fdSeek,
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
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import Kernel.FileSystem.Vfs (NamespaceId, defaultNamespace, vfsEnsurePid, vfsLookup)
import Kernel.FileSystem.Vfs qualified as Vfs

-- | File descriptor (3..34; 0-2 reserved for stdio convention).
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

-- | Bounds: 32 fds, 64 KiB per read/write (svc buffer cap).
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
fdTable :: Ref (Map Fd Entry)
fdTable = unsafePerformH $ newRef Map.empty

{-# NOINLINE fdSem #-}
fdSem :: QSem
fdSem = unsafePerformH $ newQSem 1

-- | Lowest free fd >=3, or Nothing when full.
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

lookupEntry :: Fd -> H (Maybe Entry)
lookupEntry fd = withQSem fdSem $ do
  m <- readRef fdTable
  return (Map.lookup fd m)

{- | Open a path in the default namespace. Creates (empty) on O_CREAT
when missing; truncates on O_TRUNC. Directories reject with EISDIR.
-}
fdOpen :: FilePath -> Int -> H (Either FdError Fd)
fdOpen = fdOpenInNs defaultNamespace

{- | Open a path through a pid's mount namespace (EL0 trap path).
Resolves via 'vfsLookupPid' so a child mount is visible here.
-}
fdOpenIn :: Int -> FilePath -> Int -> H (Either FdError Fd)
fdOpenIn pid path flags = do
  ns <- vfsEnsurePid pid
  fdOpenInNs ns path flags

fdOpenInNs :: NamespaceId -> FilePath -> Int -> H (Either FdError Fd)
fdOpenInNs ns path flags
  | not (validFlags flags) = return (Left (FdInval "bad flags"))
  | otherwise = case Vfs.splitPath path of
      Left e -> return (Left (FdFs e))
      Right _ -> do
        rStat <- vfsLookup ns path
        case rStat of
          Left e -> return (Left (FdFs e))
          Right (ops, rel) -> do
            st <- Vfs.opsStat ops rel
            case st of
              Right s
                | Vfs.fsIsDir s -> return (Left (FdFs Vfs.EISDIR))
                | otherwise -> openExisting ops rel
              Left Vfs.ENOENT
                | flags .&. o_CREAT /= 0 -> do
                    r <- vfsLookup ns path
                    case r of
                      Left e -> return (Left (FdFs e))
                      Right (ops2, rel2) -> do
                        cr <- Vfs.opsCreate ops2 rel2
                        case cr of
                          Left e -> return (Left (FdFs e))
                          Right () -> insertEntry
                | otherwise -> return (Left (FdFs Vfs.ENOENT))
              Left e -> return (Left (FdFs e))
  where
    acc = flags .&. 3
    openExisting ops rel
      | flags .&. o_TRUNC /= 0 && acc /= o_RDONLY = do
          r <- Vfs.opsWrite ops rel ""
          case r of
            Left Vfs.ENOSPC -> return (Left FdNoSpace)
            Left e -> return (Left (FdFs e))
            Right () -> insertEntry
      | otherwise = insertEntry
    insertEntry = withQSem fdSem $ do
      m <- readRef fdTable
      case allocFd m of
        Nothing -> return (Left (FdInval "fd table full"))
        Just fd -> do
          writeRef fdTable (Map.insert fd (Entry path 0 acc ns) m)
          return (Right fd)

-- | Read up to n bytes from the fd offset. Advances the offset.
fdRead :: Fd -> Int -> H (Either FdError String)
fdRead fd n
  | n < 0 || n > maxFdBytes = return (Left (FdInval "bad length"))
  | otherwise = do
      mEnt <- lookupEntry fd
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
                        case Map.lookup fd m of
                          Nothing -> return (Left FdBadFd)
                          Just e2 -> do
                            writeRef fdTable (Map.insert fd e2 {entOff = off'} m)
                            return (Right chunk)

-- | Write bytes at the fd offset (read-modify-write). Advances the offset.
fdWrite :: Fd -> String -> H (Either FdError Int)
fdWrite fd content
  | length content > maxFdBytes = return (Left (FdInval "bad length"))
  | otherwise = do
      mEnt <- lookupEntry fd
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
                    Left Vfs.ENOENT -> return (Right "")
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
                                case Map.lookup fd m of
                                  Nothing -> return (Left FdBadFd)
                                  Just e2 -> do
                                    writeRef fdTable (Map.insert fd e2 {entOff = off'} m)
                                    return (Right (length content))

-- | Close an fd (idempotent miss is EBADF).
fdClose :: Fd -> H (Either FdError ())
fdClose fd = withQSem fdSem $ do
  m <- readRef fdTable
  case Map.lookup fd m of
    Nothing -> return (Left FdBadFd)
    Just _ -> do
      writeRef fdTable (Map.delete fd m)
      return (Right ())

-- | Reposition the fd offset.
fdSeek :: Fd -> Int -> Int -> H (Either FdError Int)
fdSeek fd off whence = do
  mEnt <- lookupEntry fd
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
                  case Map.lookup fd m of
                    Nothing -> return (Left FdBadFd)
                    Just e2 -> do
                      writeRef fdTable (Map.insert fd e2 {entOff = newOff} m)
                      return (Right newOff)
