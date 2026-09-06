{-# LANGUAGE GHC2024 #-}

{-|
Module      : Kernel.Userspace.Fd
Description : EL0 fd table over the volatile ramfs.
Stability   : experimental

Per-fd offsets over 'H.FileSystem' for the Track O FS slice. Fds 3..34
(stdio 0-2 reserved: EL0 svc WRITE uses fd 1 for UART). All paths go
through 'FS.splitPath'; all lengths are capped at 64 KiB (matches the
svc user-buffer bound); the 2 MiB ramfs cap is inherited -- 'fsWrite'
returns ENOSPC and no fd path grows it.

Lock order: 'fdSem' is a leaf; it is never held across 'FS' calls
(which take 'fsSem'). Entries are snapshotted under the lock, FS I/O
runs unlocked, then offsets are committed under the lock.

EL0 trap wiring waits on the delegation ring (same pattern as the IPC
slice): 'Syscall' reserves 0x04..0x07 + 0x0A and svc returns ENOSYS
until then. The shell 'fdtest' verb exercises this table from EL1.
-}
module Kernel.Userspace.Fd
  ( Fd (..),
    FdError (..),
    fdErrorToString,
    fdOpen,
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
import qualified Data.Map.Strict as Map
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import qualified H.FileSystem as FS

-- | File descriptor (3..34; 0-2 reserved for stdio convention).
newtype Fd = Fd Int
  deriving (Eq, Ord, Show)

-- | Fd errors; FsError embedded for pass-through.
data FdError
  = FdBadFd
  | FdInval String
  | FdNoSpace
  | FdFs FS.FsError
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

-- | Table entry: absolute path + offset + access mode.
data Entry = Entry
  { entPath :: FilePath,
    entOff :: Int,
    entAcc :: Int
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

-- | Open a ramfs path. Creates (empty) on O_CREAT when missing;
-- truncates on O_TRUNC. Directories reject with EISDIR via fsStat.
fdOpen :: FilePath -> Int -> H (Either FdError Fd)
fdOpen path flags
  | not (validFlags flags) = return (Left (FdInval "bad flags"))
  | otherwise = case FS.splitPath path of
      Left e -> return (Left (FdFs e))
      Right _ -> do
        st <- FS.fsStat path
        case st of
          Right s
            | FS.fsIsDir s -> return (Left (FdFs FS.EISDIR))
            | otherwise -> openExisting
          Left FS.ENOENT
            | flags .&. o_CREAT /= 0 -> do
                r <- FS.fsCreate path
                case r of
                  Left e -> return (Left (FdFs e))
                  Right () -> insertEntry
            | otherwise -> return (Left (FdFs FS.ENOENT))
          Left e -> return (Left (FdFs e))
  where
    acc = flags .&. 3
    openExisting
      | flags .&. o_TRUNC /= 0 && acc /= o_RDONLY = do
          r <- FS.fsWrite path ""
          case r of
            Left FS.ENOSPC -> return (Left FdNoSpace)
            Left e -> return (Left (FdFs e))
            Right () -> insertEntry
      | otherwise = insertEntry
    insertEntry = withQSem fdSem $ do
      m <- readRef fdTable
      case allocFd m of
        Nothing -> return (Left (FdInval "fd table full"))
        Just fd -> do
          writeRef fdTable (Map.insert fd (Entry path 0 acc) m)
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
              r <- FS.fsRead (entPath ent)
              case r of
                Left FS.ENOSPC -> return (Left FdNoSpace)
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
              r <- FS.fsRead (entPath ent)
              cur <- case r of
                Right s -> return (Right s)
                Left FS.ENOENT -> return (Right "")
                Left FS.ENOSPC -> return (Left FdNoSpace)
                Left e -> return (Left (FdFs e))
              case cur of
                Left e -> return (Left e)
                Right old ->
                  if entOff ent > length old
                    then return (Left (FdInval "offset past EOF"))
                    else do
                      let newContent = take (entOff ent) old ++ content ++ drop (entOff ent + length content) old
                      w <- FS.fsWrite (entPath ent) newContent
                      case w of
                        Left FS.ENOSPC -> return (Left FdNoSpace)
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
          r <- FS.fsRead (entPath ent)
          case r of
            Right s -> return (Right (length s))
            Left FS.ENOENT -> return (Right 0)
            Left FS.ENOSPC -> return (Left FdNoSpace)
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
