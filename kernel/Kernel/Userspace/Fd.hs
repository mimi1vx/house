{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Fd
Description : Per-pid EL0 fd tables over the VFS namespaces.
Stability   : experimental

Per-pid offsets over 'Kernel.FileSystem.Vfs'. Fds 3..34 per pid (stdio
0-2 reserved: EL0 svc WRITE uses fd 1 for UART). DUP2 may additionally
install entries at 0/1 (the ONLY way fd 0/1 become real table entries;
without it @fdWrite (Fd 1)@ stays EBADF). Pipes are pairs of ends
sharing one 64 KiB buffer 'Ref' (per-end offsets unused: the buffer is
the offset); pipe reads drain, see EOF once all writers close, and poll
bounded (~5s, console-style) while writers live; pipe writes to a
readerless pipe fail broken-pipe and a full pipe short-writes after a
bounded poll. All paths go through
'Vfs.splitPath' in the opener's namespace on every call, except pipes
and the reserved '/dev/console' which binds to the virtio-console endpoint via
the IPC nameservice (no VFS node, no new svc); console reads poll bounded
(~5s) and writes chunk to the 4K grant page. All lengths are
capped at 64 KiB (matches the svc user-buffer bound); the RamFS page quota
(10% of RAM, 16 MiB floor) is inherited -- backend writes return ENOSPC
and no fd path grows it.

Isolation: tables are keyed by 'Pid', so a cross-pid fd use misses the
caller's map and fails EBADF. 'fdFork' copies entries+offsets on fork
(pipe ends share the buffer ref with bumped reader/writer counts);
'fdRelease' drops the table on wait/kill, closing pipe ends first (no leak
over fork/exit cycles).

Lock order: 'fdSem' is a leaf; it is never held across 'Vfs' calls
(which take @registrySem@ then backend sems) or pipe-block polling.
Entries are snapshotted under the lock, VFS I/O runs unlocked, then
offsets are committed under the lock. Pipe buffer reads/writes are short
critical sections under the lock; the bounded yield-poll loops drop the
lock across each 'threadDelay'. Each file entry remembers the opener's
namespace; 'fdOpen' resolves through the pid's namespace via 'vfsEnsurePid'.

EL0 trap wiring rides the delegation ring ('Syscall' 0x04..0x07 + 0x0A,
pipe 0x19/0x1A): Rust ('svc.rs' 'house_fd_should_park' /
'house_pipe_should_park') validates the path NUL-termination
(256B), buffer window (64K), and PIPE/DUP2 args trap-side and parks; Haskell
('Kernel.Userspace.Process.parkLoop') performs the table op and resumes
with the result in x0. The shell 'fdtest' verb exercises the file half of
this table from EL1 under pid 0.
-}
module Kernel.Userspace.Fd (
  Fd (..),
  FdError (..),
  consolePath,
  fdErrorToString,
  fdErrorToErrno,
  fdOpen,
  fdPipe,
  fdRead,
  fdWrite,
  fdClose,
  fdDup2,
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

import Control.Monad (forM_)
import Data.Bits (complement, (.&.))
import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word8)
import Foreign.C.Types (CInt (..))
import H.Concurrency (QSem, newQSem, threadDelay, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import Kernel.Driver.Virtio.Con.Server qualified as Con
import Kernel.FileSystem.Vfs (NamespaceId, vfsEnsurePid, vfsLookup)
import Kernel.FileSystem.Vfs qualified as Vfs
import Kernel.IPC.Nameservice qualified as NS
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

-- | Reserved console path bound to the virtio-console endpoint.
consolePath :: FilePath
consolePath = "/dev/console"

-- | First live virtio-console slot from the IPC nameservice, if any.
findConsoleSlot :: H (Maybe Int)
findConsoleSlot = do
  xs <- NS.nsList
  let cons = filter ("virtio-con" `isPrefixOf`) xs
  case cons of
    [] -> return Nothing
    (x : _) -> case reads (drop (length "virtio-con") x) of
      [(n, "")] -> return (Just n)
      _ -> return Nothing

{- | Bounded console read: one RX completion truncated to n, polling
with yield-friendly delay up to ~5s before reporting idle as empty.
-}
consoleRead :: Int -> H (Either FdError [Word8])
consoleRead n
  | n <= 0 = return (Right [])
  | otherwise = do
      mSlot <- findConsoleSlot
      case mSlot of
        Nothing -> return (Left (FdFs Vfs.ENOENT))
        Just slot -> go slot (500 :: Int)
  where
    go _ tries | tries <= 0 = return (Right [])
    go slot tries = do
      r <- Con.conReadBytes slot
      case r of
        Left _ -> return (Left (FdFs Vfs.ENOENT))
        Right [] -> threadDelay 10000 >> go slot (tries - 1)
        Right bytes -> return (Right (take n bytes))

-- | Console write chunked to the 4K grant page; no silent truncation.
consoleWrite :: [Word8] -> H (Either FdError Int)
consoleWrite content = do
  mSlot <- findConsoleSlot
  case mSlot of
    Nothing -> return (Left (FdFs Vfs.ENOENT))
    Just slot -> go slot content 0
  where
    go _ [] k = return (Right k)
    go slot rest k = do
      let (chunk, rest') = splitAt 4095 rest
      r <- Con.conWriteBytes slot chunk
      case r of
        Left _ -> return (Left (FdInval "con write"))
        Right () -> go slot rest' (k + length chunk)

{- | Table entry: a file (path + offset + access mode + opener
namespace) or one end of a pipe. Both ends of a pipe point at the same
'Ref'-held 'PipeState'; per-end offsets are unused for pipes.
-}
data Entry
  = FileEntry {
      entPath :: FilePath
      , entOff :: Int
      , entAcc :: Int
      , entNs :: NamespaceId
      }
  | PipeEntry
      -- Shared buffer 'Ref' and True for the read end.
      (Ref PipeState)
      Bool
  deriving (Eq)

instance Show Entry where
  show (FileEntry p o a _) = "FileEntry " ++ show p ++ " " ++ show o ++ " " ++ show a
  show (PipeEntry _ r) = "PipeEntry read=" ++ show r

{- | Shared pipe buffer: one FIFO capped at 'maxFdBytes' plus the live
reader/writer end counts. All ends (across pids after fork/dup2) point
at one 'Ref'; last-writer close surfaces EOF, last-reader close
surfaces broken-pipe.
-}
data PipeState = PipeState {
  pipeBuf :: [Word8]
  , pipeReaders :: Int
  , pipeWriters :: Int
  }
  deriving (Eq, Show)

{- | Bounded pipe read on a read end: nonempty drains up to n; empty with
live writers polls yield-friendly (~5s, like console) then idles empty;
empty with no writers is EOF. The lock is dropped across each poll.
-}
pipeReadWait :: Ref PipeState -> Int -> H (Either FdError [Word8])
pipeReadWait st n
  | n <= 0 = return (Right [])
  | otherwise = go (500 :: Int)
  where
    go tries
      | tries <= 0 = return (Right [])
      | otherwise = do
          r <- withQSem fdSem $ do
            ps <- readRef st
            if not (null (pipeBuf ps))
              then do
                let (out, rest) = splitAt n (pipeBuf ps)
                writeRef st ps {pipeBuf = rest}
                return (Just out)
              else return (if pipeWriters ps == 0 then Just [] else Nothing)
          case r of
            Just out -> return (Right out)
            Nothing -> threadDelay 10000 >> go (tries - 1)

{- | Bounded pipe write on a write end: readerless is broken-pipe; a full
buffer polls yield-friendly (~5s), then short-writes the stored count
(never silent truncation). The lock is dropped across each poll.
-}
pipeWriteWait :: Ref PipeState -> [Word8] -> H (Either FdError Int)
pipeWriteWait _ [] = return (Right 0)
pipeWriteWait st content = go (500 :: Int)
  where
    go tries = do
      r <- withQSem fdSem $ do
        ps <- readRef st
        if pipeReaders ps == 0
          then return (Left (FdInval "broken pipe"))
          else do
            let room = maxFdBytes - length (pipeBuf ps)
            if room > 0
              then do
                let k = min room (length content)
                writeRef st ps {pipeBuf = pipeBuf ps ++ take k content}
                return (Right (Just k))
              else
                if tries <= 0
                  then return (Right (Just 0))
                  else return (Right Nothing)
      case r of
        Left e -> return (Left e)
        Right (Just k) -> return (Right k)
        Right Nothing -> threadDelay 10000 >> go (tries - 1)

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
  | path == consolePath = do
      mSlot <- findConsoleSlot
      case mSlot of
        Nothing -> return (Left (FdFs Vfs.ENOENT))
        Just _ -> do
          ns <- vfsEnsurePid pidInt
          insertEntry ns
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
          writeRef fdTable (Map.insert pid (Map.insert fd (FileEntry path 0 acc ns) per) m)
          return (Right fd)

{- | Allocate a pipe read+write pair in the caller's pid (lowest two free
fds >= 3; the read end takes the lower). 'FdNoSpace' when fewer than two
slots are free, so a half-built pair never publishes. Both ends share one
buffer 'Ref' with one reader and one writer.
-}
fdPipe :: Pid -> H (Either FdError (Fd, Fd))
fdPipe pid = withQSem fdSem $ do
  m <- readRef fdTable
  let per = Map.findWithDefault Map.empty pid m
      free2 = take 2 [Fd n | n <- [3 .. 3 + maxFdCount - 1], Map.notMember (Fd n) per]
  case free2 of
    [rd, wr] -> do
      st <- newRef (PipeState [] 1 1)
      let per' = Map.insert rd (PipeEntry st True) (Map.insert wr (PipeEntry st False) per)
      writeRef fdTable (Map.insert pid per' m)
      return (Right (rd, wr))
    _ -> return (Left FdNoSpace)

{- | Reposition a file entry's offset; pipes carry no offset (Nothing),
so a commit racing a dup2-replacement fails EBADF instead of crashing
a record update.
-}
setFileOff :: Entry -> Int -> Maybe Entry
setFileOff (FileEntry p _ a ns) o = Just (FileEntry p o a ns)
setFileOff _ _ = Nothing

-- | Read up to n bytes from the pid's fd offset. Advances the offset.
fdRead :: Pid -> Fd -> Int -> H (Either FdError [Word8])
fdRead pid fd n
  | n < 0 || n > maxFdBytes = return (Left (FdInval "bad length"))
  | otherwise = do
      mEnt <- lookupEntry pid fd
      case mEnt of
        Nothing -> return (Left FdBadFd)
        Just (PipeEntry st True) -> pipeReadWait st n
        Just (PipeEntry _ False) -> return (Left (FdInval "not readable"))
        Just ent
          | entAcc ent == o_WRONLY -> return (Left (FdInval "not readable"))
          | entPath ent == consolePath -> consoleRead n
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
                        case Map.lookup pid m >>= Map.lookup fd >>= (`setFileOff` off') of
                          Nothing -> return (Left FdBadFd)
                          Just e2 -> do
                            let per = Map.findWithDefault Map.empty pid m
                            writeRef fdTable (Map.insert pid (Map.insert fd e2 per) m)
                            return (Right chunk)

-- | Write bytes at the pid's fd offset (read-modify-write). Advances the offset.
fdWrite :: Pid -> Fd -> [Word8] -> H (Either FdError Int)
fdWrite pid fd content
  | length content > maxFdBytes = return (Left (FdInval "bad length"))
  | otherwise = do
      mEnt <- lookupEntry pid fd
      case mEnt of
        Nothing -> return (Left FdBadFd)
        Just (PipeEntry st False)
          | null content -> return (Right 0)
          | otherwise -> pipeWriteWait st content
        Just (PipeEntry _ True) -> return (Left (FdInval "not writable"))
        Just ent
          | entAcc ent == o_RDONLY -> return (Left (FdInval "not writable"))
          | entPath ent == consolePath -> consoleWrite content
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
                                case Map.lookup pid m >>= Map.lookup fd >>= (`setFileOff` off') of
                                  Nothing -> return (Left FdBadFd)
                                  Just e2 -> do
                                    let per = Map.findWithDefault Map.empty pid m
                                    writeRef fdTable (Map.insert pid (Map.insert fd e2 per) m)
                                    return (Right (length content))

{- | Close a pid's fd (miss is EBADF). Closing a pipe end decrements its
shared count: last-writer close surfaces EOF to readers, last-reader
close surfaces broken-pipe to writers.
-}
fdClose :: Pid -> Fd -> H (Either FdError ())
fdClose pid fd = withQSem fdSem $ do
  m <- readRef fdTable
  case Map.lookup pid m >>= Map.lookup fd of
    Nothing -> return (Left FdBadFd)
    Just ent -> do
      dropEnd ent
      let per = Map.findWithDefault Map.empty pid m
          per' = Map.delete fd per
      writeRef fdTable (if Map.null per' then Map.delete pid m else Map.insert pid per' m)
      return (Right ())

{- | Alias @old@ onto @new@ (any 0..34; the ONLY way fd 0/1 become real
table entries) in the pid, closing the prior occupant of @new@ first
(POSIX-like; @old == new@ with a live @old@ is a no-op). Missing @old@
is EBADF; @new@ outside 0..34 is EINVAL-shaped 'FdInval'. A duped pipe
end shares the buffer 'Ref' (counts bumped, so the alias holds its end).
-}
fdDup2 :: Pid -> Int -> Int -> H (Either FdError ())
fdDup2 pid old new
  | new < 0 || new > 34 = return (Left (FdInval "bad fd"))
  | otherwise = withQSem fdSem $ do
      m <- readRef fdTable
      let per = Map.findWithDefault Map.empty pid m
      case Map.lookup (Fd old) per of
        Nothing -> return (Left FdBadFd)
        Just ent
          | old == new -> return (Right ())
          | otherwise -> do
              per1 <- closeLocked per (Fd new)
              shareEnd ent
              writeRef fdTable (Map.insert pid (Map.insert (Fd new) ent per1) m)
              return (Right ())
  where
    closeLocked per fd = case Map.lookup fd per of
      Nothing -> return per
      Just victim -> do
        dropEnd victim
        return (Map.delete fd per)

{- | One more live reference on a pipe end's shared buffer (fork/dup2
share); files have no shared state.
-}
shareEnd :: Entry -> H ()
shareEnd (PipeEntry st isRead) = do
  ps <- readRef st
  writeRef
    st
    ( if isRead
        then ps {pipeReaders = pipeReaders ps + 1}
        else ps {pipeWriters = pipeWriters ps + 1}
    )
shareEnd (FileEntry {}) = return ()

{- | Drop one pipe end reference (close/release/dup2-evict), clamped at 0
so a double-drop degrades to EOF/broken-pipe, never a negative count.
-}
dropEnd :: Entry -> H ()
dropEnd (PipeEntry st isRead) = do
  ps <- readRef st
  writeRef
    st
    ( if isRead
        then ps {pipeReaders = max 0 (pipeReaders ps - 1)}
        else ps {pipeWriters = max 0 (pipeWriters ps - 1)}
    )
dropEnd (FileEntry {}) = return ()

-- | Reposition the pid's fd offset.
fdSeek :: Pid -> Fd -> Int -> Int -> H (Either FdError Int)
fdSeek pid fd off whence = do
  mEnt <- lookupEntry pid fd
  case mEnt of
    Nothing -> return (Left FdBadFd)
    Just (PipeEntry _ _) -> return (Left (FdInval "not seekable"))
    Just ent
      | entPath ent == consolePath -> return (Left (FdInval "not seekable"))
      | otherwise -> do
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
                      case Map.lookup pid m >>= Map.lookup fd >>= (`setFileOff` newOff) of
                        Nothing -> return (Left FdBadFd)
                        Just e2 -> do
                          let per = Map.findWithDefault Map.empty pid m
                          writeRef fdTable (Map.insert pid (Map.insert fd e2 per) m)
                          return (Right newOff)

{- | Inherit entries+offsets on fork (fresh map). Pipe ends share the
buffer 'Ref' with bumped reader/writer counts, so the child holds its
own ends (offsets are the buffer itself, not per-fd).
-}
fdFork :: Pid -> Pid -> H ()
fdFork parent child = withQSem fdSem $ do
  m <- readRef fdTable
  case Map.lookup parent m of
    Nothing -> return ()
    Just per -> do
      forM_ (Map.elems per) shareEnd
      writeRef fdTable (Map.insert child per m)

{- | Drop the pid's table on wait/kill, closing pipe ends first (counts
decremented, so survivors see EOF/broken-pipe, not a wedge). No leak
over fork/exit cycles.
-}
fdRelease :: Pid -> H ()
fdRelease pid = withQSem fdSem $ do
  m <- readRef fdTable
  case Map.lookup pid m of
    Nothing -> return ()
    Just per -> do
      forM_ (Map.elems per) dropEnd
      writeRef fdTable (Map.delete pid m)
