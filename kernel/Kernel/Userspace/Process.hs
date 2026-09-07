{-# LANGUAGE ForeignFunctionInterface #-}

{- |
Module      : Kernel.Userspace.Process
Description : ELF loader -> PageMap -> EL0 entry with cleanup.
-}
module Kernel.Userspace.Process (
  runElf,
  forkProc,
  procInfo,
  listProcs,
  waitPid,
  killPid,
  procBrkGrow,
  stackTop,
  ParkRequest (..),
)
where

import Control.Concurrent (tryPutMVar, tryTakeMVar)
import Control.Monad (forM_, void, when)
import Data.Bits (complement, shiftR, (.&.))
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64, Word8)
import Foreign.C.String (withCString)
import Foreign.C.Types (CChar, CInt (..))
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import H.AdHocMem (allocaArray, peek, peekElemOff, poke, pokeElemOff)
import H.Concurrency (MVar, forkH, newEmptyMVar, putMVar, takeMVar, threadDelay, withQSem)
import H.Monad (H, liftIO, runH)
import H.Mutable (Ref, modifyRef, newRef, readRef, writeRef)
import qualified H.Pages as HPages
import H.PhysicalMemory (fromPhysPage, toPhysPage)
import H.Unsafe (unsafePerformH)
import H.Utils (ptrFromWord64)
import qualified H.VirtualMemory as VM
import qualified Kernel.FileSystem.Vfs as Vfs
import qualified Kernel.IPC.Endpoint as IPC
import Kernel.IPC.Types (IpcError (..), Message (..), mkMessage)
import Kernel.Userspace.Loader (Elf (..), LoadError (..), Segment (..))
import Kernel.Userspace.Types (Pid (..), Process (..), pidNext, procExitMap, procMap, processExitVar, userSem)
import qualified System.Timeout as T

foreign import ccall unsafe "house_enter_el0" c_enter_el0 :: Word64 -> Word64 -> Ptr Word64 -> Word64 -> IO ()

foreign import ccall unsafe "house_asid_for_pdir" c_asid_for :: Ptr Word64 -> IO Word64

foreign import ccall unsafe "house_get_exit_code" c_get_exit :: IO CInt

foreign import ccall unsafe "house_clear_exit" c_clear_exit :: IO ()

foreign import ccall unsafe "house_is_exited" c_is_exited :: IO CInt

foreign import ccall unsafe "house_el0_register" c_el0_register :: Ptr Word64 -> IO CInt

foreign import ccall unsafe "house_el0_unregister" c_el0_unregister :: Ptr Word64 -> IO ()

foreign import ccall unsafe "house_el0_exit_status" c_el0_status :: Ptr Word64 -> Ptr CInt -> IO CInt

foreign import ccall unsafe "house_el0_parked" c_el0_parked :: Ptr Word64 -> IO CInt

foreign import ccall unsafe "house_el0_take_request" c_el0_take :: Ptr Word64 -> Ptr Word32 -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "house_resume_el0" c_resume_el0 :: Ptr Word64 -> Word64 -> Word64 -> IO CInt

foreign import ccall unsafe "house_user_read" c_user_read :: Ptr Word64 -> Word64 -> Ptr Word64 -> Word64 -> IO CInt

foreign import ccall unsafe "house_user_write" c_user_write :: Ptr Word64 -> Word64 -> Ptr Word64 -> Word64 -> IO CInt

foreign import ccall unsafe "current_pdir" c_current_pdir :: IO (Ptr Word64)

foreign import ccall unsafe "house_set_recorded_pdir" c_set_pdir :: Ptr Word64 -> IO ()

foreign import ccall unsafe "uart_puts" c_uart_puts :: Ptr CChar -> IO ()

stackTop :: Word64
stackTop = 0x3FFFE000

{- | Request parked by an EL0 trap (svc #imm). Yield plus IPC
0x10..0x13 ride the ring; GRANT_MAP 0x14 stays inline ENOSYS.
Each IPC request carries the trapped x0..x3 (ep, va, nwords, tag).
-}
data ParkRequest
  = ReqYield
  | ReqIpcSend Word64 Word64 Word64 Word64
  | ReqIpcRecv Word64 Word64 Word64
  | ReqIpcCall Word64 Word64 Word64 Word64
  | ReqIpcReply Word64 Word64 Word64 Word64
  | ReqUnknown Word32
  deriving (Eq, Show)

{- | Per-pid pending RECV reply slot for the EL0 REPLY trap. Inserted when a
RECV parks its rendezvous handle, taken by the matching REPLY; reaped with
NoSuchEndpoint when the pid dies underneath (unblocks a wedged sender).
-}
{-# NOINLINE pendingReply #-}
pendingReply :: Ref (Map.Map Pid (MVar (Either IpcError Message)))
pendingReply = unsafePerformH (newRef Map.empty)

pfW :: Word32
pfW = 2

runElf :: Elf -> [String] -> [String] -> H (Either LoadError Pid)
runElf elf argv envp = withQSem userSem $ do
  pidInt <- readRef pidNext
  writeRef pidNext (pidInt + 1)
  _ <- Vfs.vfsEnsurePid pidInt
  let pid = Pid pidInt
  _ <- liftIO c_clear_exit
  mPdir <- VM.allocPageMap
  case mPdir of
    Nothing -> return (Left NoSpace)
    Just pdir -> do
      let pdirPtr = VM.fromPageMap pdir
      _ <- liftIO (withCString "[run] mapSegments start\n" c_uart_puts)
      mapped <- mapSegments pdir elf
      _ <- liftIO (withCString "[run] mapSegments done\n" c_uart_puts)
      case mapped of
        Left err -> do
          freePDir pdir
          return (Left err)
        Right () -> do
          let initBrk = initBreak elf
          mStack <- HPages.allocPage :: H (Maybe (Ptr Word8))
          case mStack of
            Nothing -> do freePDir pdir; return (Left NoSpace)
            Just stk -> do
              HPages.zeroPage stk
              eSp <- setupArgStack stk argv envp
              case eSp of
                Left err -> do HPages.freePage stk; freePDir pdir; return (Left err)
                Right sp -> do
                  let stackBase = stackTop - 4096
                  okStk <- VM.setPage pdir stackBase (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr stk), VM.writable = True, VM.dirty = False, VM.accessed = False}))
                  if not okStk
                    then do HPages.freePage stk; freePDir pdir; return (Left NoSpace)
                    else do
                      asid <- liftIO (c_asid_for pdirPtr)
                      _ <- liftIO (withCString "[run] got asid\n" c_uart_puts)
                      reg <- liftIO (c_el0_register pdirPtr)
                      if reg /= 0
                        then do HPages.freePage stk; freePDir pdir; return (Left NoSpace)
                        else do
                          exitVar <- newEmptyMVar
                          modifyRef procExitMap (Map.insert pid exitVar)
                          modifyRef procMap (Map.insert pid (Process pid pdir (elfEntry elf) initBrk))
                          _ <- liftIO (withCString "[run] before fork\n" c_uart_puts)
                          _ <- forkH $ do
                            _ <- liftIO (withCString "[run] fork enter\n" c_uart_puts)
                            liftIO (c_set_pdir pdirPtr)
                            liftIO (c_enter_el0 (elfEntry elf) sp pdirPtr asid)
                            _ <- liftIO (withCString "[run] fork after enter\n" c_uart_puts)
                            parkLoop pid pdirPtr asid exitVar
                            return ()
                          _ <- liftIO (withCString "[run] after fork\n" c_uart_puts)
                          return (Right pid)

{- | Fork slice (Track O, no COW, no signals): dormant copy of the
parent address space into a fresh PageMap + Pid. Segments, brk-grown
pages and the stack page are deep-copied page by page (capped at 8192
pages); tables are freshly allocated by 'setPage'. The child shares
nothing writable with the parent. Spawning the child on EL0 (register
copy at the svc trap) waits on the delegation ring -- same pattern as
the fd slice -- so svc 0x08 returns ENOSYS until then; exit codes keep
flowing through the existing 'waitPid' path. Runs under 'userSem'.
-}
forkProc :: Pid -> H (Either LoadError Pid)
forkProc parentPid@(Pid parentInt) = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup parentPid mp of
    Nothing -> return (Left (BadSegment "no such pid"))
    Just parent -> do
      mChild <- VM.allocPageMap
      case mChild of
        Nothing -> return (Left NoSpace)
        Just childPdir -> do
          r <- copyAddrSpace (procPdir parent) childPdir (copyHi (procBrk parent))
          case r of
            Left e -> do
              freePDir childPdir
              return (Left e)
            Right () -> do
              pidInt <- readRef pidNext
              writeRef pidNext (pidInt + 1)
              let child = Pid pidInt
              modifyRef procMap (Map.insert child (Process child childPdir (procEntry parent) (procBrk parent)))
              Vfs.vfsForkPid parentInt pidInt
              return (Right child)
  where
    copyHi brk = max brk stackTop
    -- Walk [minVAddr, hi), descending only into user tables: the fresh
    -- 'allocPageMap' L1 carries cloned kernel entries, and 'getPage'
    -- treats any valid desc as a table -- following a kernel block desc
    -- faults (EL1 data abort). A desc is ours iff Valid+Table (0x3, the
    -- 'descFromTable' shape) and its pointer passes 'validPage' (buddy /
    -- user pool, never kernel RAM). Anything else skips its whole range.
    copyAddrSpace src dst hi = do
      d0 <- peekElemOff (VM.fromPageMap src) 0
      case userTable d0 of
        Nothing -> return (Right ())
        Just l1 -> go l1 VM.minVAddr 0
      where
        userTable d
          | d .&. 3 == 3
          , HPages.validPage (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000)) =
              Just (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000))
          | otherwise = Nothing
        l1i va = fromIntegral ((va `shiftR` 30) .&. 0x1FF) :: Int
        l2i va = fromIntegral ((va `shiftR` 21) .&. 0x1FF) :: Int
        go l1 va n
          | va >= hi = return (Right ())
          | n > (8192 :: Int) = return (Left NoSpace)
          | otherwise = do
              d1 <- peekElemOff l1 (l1i va)
              case userTable d1 of
                Nothing -> go l1 (nextL1 va) n
                Just l2 -> do
                  d2 <- peekElemOff l2 (l2i va)
                  case userTable d2 of
                    Nothing -> go l1 (nextL2 va) n
                    Just _ -> do
                      mInfo <- VM.getPage src va
                      case mInfo of
                        Nothing -> go l1 (va + 4096) n
                        Just info -> do
                          mp2 <- HPages.allocPage :: H (Maybe (Ptr Word8))
                          case mp2 of
                            Nothing -> return (Left NoSpace)
                            Just raw -> do
                              copyPageBytes (fromPhysPage (VM.physPage info)) (castPtr raw)
                              ok <- VM.setPage dst va (Just (info {VM.physPage = toPhysPage (castPtr raw)}))
                              if not ok
                                then do HPages.freePage raw; return (Left NoSpace)
                                else go l1 (va + 4096) (n + 1)
        nextL1 va = (va .&. complement 0x3FFFFFFF) + 0x40000000
        nextL2 va = (va .&. complement 0x1FFFFF) + 0x200000
    copyPageBytes src dst =
      forM_ [0 .. 4095] $ \i -> do
        b <- peek (src `plusPtr` i) :: H Word8
        poke (dst `plusPtr` i) b

-- | EL1 lookup for the forktest isolation check (caller holds no locks).
procInfo :: Pid -> H (Maybe Process)
procInfo pid = withQSem userSem $ do
  mp <- readRef procMap
  return (Map.lookup pid mp)

-- | Live pids for the shell `jobs` verb.
listProcs :: H [Pid]
listProcs = withQSem userSem (Map.keys <$> readRef procMap)

-- | Initial break: end of highest loaded segment, 16-byte aligned.
initBreak :: Elf -> Word64
initBreak elf = case elfSegs elf of
  [] -> VM.minVAddr
  segs -> align16 (maximum (map segEnd segs))
  where
    segEnd s = segVaddr s + fromIntegral (segMemSz s)
    align16 w = (w + 15) .&. complement 15

{- | Lay argc/argv+envp on the stack page. Returns adjusted sp (16-byte aligned).
Layout: argc, argv[argc+1] (NULL-terminated), envp[envc+1] (NULL-terminated),
then NUL-terminated strings. Bounds: 64 entries and 1024 bytes per string.
-}
setupArgStack :: Ptr Word8 -> [String] -> [String] -> H (Either LoadError Word64)
setupArgStack stk argv envp
  | length argv > 64 = return (Left NoSpace)
  | length envp > 64 = return (Left NoSpace)
  | any (\a -> length a > 1024) argv = return (Left NoSpace)
  | any (\e -> length e > 1024) envp = return (Left NoSpace)
  | otherwise = do
      let toBlob s = map (\c -> fromIntegral (ord c `mod` 256) :: Word8) s ++ [0]
          argBlobs = map toBlob argv
          envBlobs = map toBlob envp
          stringsLen = sum (map length argBlobs) + sum (map length envBlobs)
          argc = length argv
          envc = length envp
          ptrsLen = (argc + 1) * 8 + (envc + 1) * 8
          total = 8 + ptrsLen + stringsLen
          aligned = ((total + 15) `div` 16) * 16
      if aligned > 4000
        then return (Left NoSpace)
        else do
          let sp = stackTop - fromIntegral aligned
              base = stackTop - 4096
              off = fromIntegral (sp - base) :: Int
              argvOff = off + 8
              envOff = argvOff + (argc + 1) * 8
              strBase = sp + 8 + fromIntegral ptrsLen
          pokeWord64LE stk off (fromIntegral argc)
          let go _ [] _ = return ()
              go o (b : rest) va = do
                pokeWord64LE stk o va
                mapM_ (\(i, byte) -> poke (stk `plusPtr` (fromIntegral (va - base) + i)) byte) (zip [0 ..] b)
                go (o + 8) rest (va + fromIntegral (length b))
          go argvOff argBlobs strBase
          pokeWord64LE stk (argvOff + argc * 8) 0
          let envStrBase = strBase + fromIntegral (sum (map length argBlobs))
          go envOff envBlobs envStrBase
          pokeWord64LE stk (envOff + envc * 8) 0
          return (Right sp)

pokeWord64LE :: Ptr Word8 -> Int -> Word64 -> H ()
pokeWord64LE p o w = do
  poke (p `plusPtr` o) (fromIntegral w :: Word8)
  poke (p `plusPtr` (o + 1)) (fromIntegral (w `shiftR` 8) :: Word8)
  poke (p `plusPtr` (o + 2)) (fromIntegral (w `shiftR` 16) :: Word8)
  poke (p `plusPtr` (o + 3)) (fromIntegral (w `shiftR` 24) :: Word8)
  poke (p `plusPtr` (o + 4)) (fromIntegral (w `shiftR` 32) :: Word8)
  poke (p `plusPtr` (o + 5)) (fromIntegral (w `shiftR` 40) :: Word8)
  poke (p `plusPtr` (o + 6)) (fromIntegral (w `shiftR` 48) :: Word8)
  poke (p `plusPtr` (o + 7)) (fromIntegral (w `shiftR` 56) :: Word8)

waitPid :: Pid -> H Int
waitPid pid@(Pid pidInt) = do
  mVar <- withQSem userSem (Map.lookup pid <$> readRef procExitMap)
  code <- maybe pollExit takeMVar mVar
  (mProc, mStash) <- withQSem userSem $ do
    mp <- readRef procMap
    case Map.lookup pid mp of
      Nothing -> return (Nothing, Nothing)
      Just pr -> do
        writeRef procMap (Map.delete pid mp)
        modifyRef procExitMap (Map.delete pid)
        m <- readRef pendingReply
        writeRef pendingReply (Map.delete pid m)
        return (Just pr, Map.lookup pid m)
  case mStash of
    Just h -> do _ <- liftIO (tryPutMVar h (Left NoSuchEndpoint)); return ()
    Nothing -> return ()
  Vfs.vfsReleasePid pidInt
  case mProc of
    Nothing -> return code
    Just pr -> do
      freePDir (procPdir pr)
      liftIO (c_el0_unregister (VM.fromPageMap (procPdir pr)))
      return code

killPid :: Pid -> H ()
killPid pid@(Pid pidInt) = do
  (mProc, mStash) <- withQSem userSem $ do
    mp <- readRef procMap
    case Map.lookup pid mp of
      Nothing -> return (Nothing, Nothing)
      Just pr -> do
        writeRef procMap (Map.delete pid mp)
        modifyRef procExitMap (Map.delete pid)
        m <- readRef pendingReply
        writeRef pendingReply (Map.delete pid m)
        return (Just pr, Map.lookup pid m)
  case mStash of
    Just h -> do _ <- liftIO (tryPutMVar h (Left NoSuchEndpoint)); return ()
    Nothing -> return ()
  Vfs.vfsReleasePid pidInt
  case mProc of
    Nothing -> return ()
    Just pr -> do
      freePDir (procPdir pr)
      liftIO (c_el0_unregister (VM.fromPageMap (procPdir pr)))

{- | Park loop: the EL0 session returned from FFI (exit or park), so no RTS
capability is pinned while this thread polls. EXIT wins over PARK; yield
resumes immediately with x0 = 0; IPC 0x10..0x13 pair through the EL1
Endpoint rendezvous (same blocking semantics as the shell path, bounded by
a 5s timeout so a reaped pid never wedges a peer); unknown requests resume
with ENOSYS so a hostile guest can never wedge the loop. Exits silently
when the pid is reaped underneath (killPid) without touching freed tables:
user copies run under 'userSem' (which 'freePDir' also holds) and resume on
an unregistered pdir is a harmless -22.
Return convention: SEND/CALL resume x0 = 0 with reply words in the user
buffer; RECV resumes x0 = sender tag with received words in the buffer;
REPLY resumes x0 = 0. Errors resume negative errnos: -2 NoSuchEndpoint,
-11 EAGAIN (QueueFull or 5s pair timeout), -14 EFAULT, -22 EINVAL.
-}
parkLoop :: Pid -> Ptr Word64 -> Word64 -> MVar Int -> H ()
parkLoop pid pdir asid exitVar = loop
  where
    loop = do
      alive <- withQSem userSem (Map.member pid <$> readRef procMap)
      if not alive
        then return ()
        else do
          mCode <- tryReadExitOnce pdir
          case mCode of
            Just c -> putMVar exitVar c
            Nothing -> do
              mReq <- tryTakeParkedOnce pdir
              case mReq of
                Nothing -> do threadDelay 1000; loop
                Just ReqYield -> do resumeWith 0; loop
                Just (ReqIpcSend ep va nw tag) -> do handleSend ep va nw tag; loop
                Just (ReqIpcCall ep va nw tag) -> do handleSend ep va nw tag; loop
                Just (ReqIpcRecv ep va nw) -> do handleRecv ep va nw; loop
                Just (ReqIpcReply ep va nw tag) -> do handleReply ep va nw tag; loop
                Just (ReqUnknown _) -> do resumeWith negENOSYS; loop
    resumeWith res = void (liftIO (c_resume_el0 pdir asid res))
    negENOSYS = fromIntegral (-38 :: Int) :: Word64
    negENOENT = fromIntegral (-2 :: Int) :: Word64
    negAGAIN = fromIntegral (-11 :: Int) :: Word64
    negINVAL = fromIntegral (-22 :: Int) :: Word64
    sendErrno QueueFull = negAGAIN
    sendErrno WouldBlock = negAGAIN
    sendErrno NoSuchEndpoint = negENOENT
    sendErrno _ = negINVAL
    handleSend ep va nw tag = do
      mIn <- readUser pid pdir va nw
      case mIn of
        Nothing -> return ()
        Just (Left rc) -> resumeWith (fromIntegral rc)
        Just (Right ws) -> do
          mep <- IPC.lookupEndpoint ep
          case mep of
            Nothing -> resumeWith negENOENT
            Just h -> case mkMessage tag ws Nothing of
              Left _ -> resumeWith negINVAL
              Right msg -> do
                res <- IPC.callTimeout 5000000 h msg
                case res of
                  Left e -> resumeWith (sendErrno e)
                  Right reply -> do
                    mRc <- writeUser pid pdir va (take (fromIntegral nw) (msgWords reply))
                    case mRc of
                      Just 0 -> resumeWith 0
                      Just rc -> resumeWith (fromIntegral rc)
                      Nothing -> return ()
    handleRecv ep va nw = do
      mep <- IPC.lookupEndpoint ep
      case mep of
        Nothing -> resumeWith negENOENT
        Just h -> do
          mRv <- liftIO (T.timeout 5000000 (runH (IPC.recv h)))
          case mRv of
            Nothing -> resumeWith negAGAIN
            Just (msg, hReply) -> do
              mRc <- withQSem userSem $ do
                mp <- readRef procMap
                case Map.lookup pid mp of
                  Nothing -> return Nothing
                  Just _ -> do
                    modifyRef pendingReply (Map.insert pid hReply)
                    let ws = take (min 8 (fromIntegral nw)) (msgWords msg)
                    if null ws
                      then return (Just 0)
                      else allocaArray 8 $ \buf -> do
                        mapM_ (uncurry (pokeElemOff buf)) (zip [0 ..] ws)
                        rc <- liftIO (c_user_write pdir va buf (fromIntegral (length ws)))
                        if rc /= 0
                          then do modifyRef pendingReply (Map.delete pid); return (Just rc)
                          else return (Just 0)
              case mRc of
                Nothing -> do
                  _ <- liftIO (tryPutMVar hReply (Left NoSuchEndpoint))
                  return ()
                Just 0 -> resumeWith (msgTag msg)
                Just rc -> resumeWith (fromIntegral rc)
    handleReply _ep va nw tag = do
      mIn <- readUser pid pdir va nw
      case mIn of
        Nothing -> do
          mh <- withQSem userSem (takeStash pid)
          case mh of
            Nothing -> return ()
            Just h -> do _ <- liftIO (tryPutMVar h (Left NoSuchEndpoint)); return ()
        Just (Left rc) -> resumeWith (fromIntegral rc)
        Just (Right ws) -> do
          mh <- withQSem userSem (takeStash pid)
          case mh of
            Nothing -> resumeWith negINVAL
            Just h -> case mkMessage tag ws Nothing of
              Left _ -> do withQSem userSem (modifyRef pendingReply (Map.insert pid h)); resumeWith negINVAL
              Right msg -> do IPC.reply h (Right msg); resumeWith 0
    takeStash p = do
      m <- readRef pendingReply
      case Map.lookup p m of
        Nothing -> return Nothing
        Just h -> do writeRef pendingReply (Map.delete p m); return (Just h)

{- | Read nwords from a live pid's user VA under 'userSem' (so 'freePDir'
cannot run concurrently). Nothing when reaped underfoot; 0-length reads
skip the FFI; over-8 lengths fail EINVAL without touching the buffer.
-}
readUser :: Pid -> Ptr Word64 -> Word64 -> Word64 -> H (Maybe (Either CInt [Word64]))
readUser p pd va nw = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup p mp of
    Nothing -> return Nothing
    Just _ ->
      if nw > 8
        then return (Just (Left (-22)))
        else
          if nw == 0
            then return (Just (Right []))
            else allocaArray 8 $ \buf -> do
              rc <- liftIO (c_user_read pd va buf nw)
              if rc /= 0
                then return (Just (Left rc))
                else do ws <- mapM (peekElemOff buf) [0 .. fromIntegral nw - 1]; return (Just (Right ws))

{- | Write words to a live pid's user VA under 'userSem'. Nothing when reaped
underfoot (caller must skip resume); over-8 payloads fail EINVAL.
-}
writeUser :: Pid -> Ptr Word64 -> Word64 -> [Word64] -> H (Maybe CInt)
writeUser p pd va ws = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup p mp of
    Nothing -> return Nothing
    Just _ ->
      if length ws > 8
        then return (Just (-22))
        else
          if null ws
            then return (Just 0)
            else allocaArray 8 $ \buf -> do
              mapM_ (uncurry (pokeElemOff buf)) (zip [0 ..] ws)
              rc <- liftIO (c_user_write pd va buf (fromIntegral (length ws)))
              return (Just rc)

-- | Single per-pid exit poll (no loop; the park loop re-polls).
tryReadExitOnce :: Ptr Word64 -> H (Maybe Int)
tryReadExitOnce pdir = allocaArray 1 $ \p -> do
  r <- liftIO (c_el0_status pdir p)
  c <- peek p
  return (if r == 1 then Just (fromIntegral c) else Nothing)

{- | Single parked-request poll: 0 maps to yield, 0x10..0x13 to IPC (with
the trapped x0..x3 as ep/va/nwords/tag), anything else is unknown
(resumed with ENOSYS by the park loop, never trusted).
-}
tryTakeParkedOnce :: Ptr Word64 -> H (Maybe ParkRequest)
tryTakeParkedOnce pdir = do
  parked <- liftIO (c_el0_parked pdir)
  if parked /= 1
    then return Nothing
    else allocaArray 1 $ \pr -> allocaArray 4 $ \pa -> do
      r <- liftIO (c_el0_take pdir pr pa)
      if r /= 1
        then return Nothing
        else do
          w <- peek pr
          a0 <- peekElemOff pa 0
          a1 <- peekElemOff pa 1
          a2 <- peekElemOff pa 2
          a3 <- peekElemOff pa 3
          return (Just (classify w a0 a1 a2 a3))
  where
    classify 0 _ _ _ _ = ReqYield
    classify 0x10 ep va nw tag = ReqIpcSend ep va nw tag
    classify 0x11 ep va nw _ = ReqIpcRecv ep va nw
    classify 0x12 ep va nw tag = ReqIpcCall ep va nw tag
    classify 0x13 ep va nw tag = ReqIpcReply ep va nw tag
    classify w _ _ _ _ = ReqUnknown w

pollExit :: H Int
pollExit = loop
  where
    loop = do
      exited <- liftIO c_is_exited
      if exited /= 0
        then do
          c <- liftIO c_get_exit
          _ <- liftIO (void (tryTakeMVar processExitVar))
          return (fromIntegral c)
        else do
          m <- liftIO (tryTakeMVar processExitVar)
          case m of
            Just v -> return v
            Nothing -> do
              threadDelay 1000
              loop

{- | Grow a process break within the user window. Maps zero pages for
[oldBrk, newBrk); over-window yields OutOfWindow, OOM yields NoSpace.
-}
procBrkGrow :: Pid -> Word64 -> H (Either LoadError Word64)
procBrkGrow pid newBrk = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup pid mp of
    Nothing -> return (Left (BadSegment "no such pid"))
    Just pr -> do
      let oldBrk = procBrk pr
      if newBrk <= oldBrk
        then return (Right oldBrk)
        else
          if newBrk > VM.maxVAddr || oldBrk < VM.minVAddr
            then return (Left (OutOfWindow newBrk))
            else do
              let lo = (oldBrk + 4095) `div` 4096 * 4096
                  hi = (newBrk + 4095) `div` 4096 * 4096
              r <- growPages (procPdir pr) lo hi
              case r of
                Left e -> return (Left e)
                Right () -> do
                  writeRef procMap (Map.insert pid pr {procBrk = newBrk} mp)
                  return (Right newBrk)
  where
    growPages pdir lo hi
      | lo >= hi = return (Right ())
      | otherwise = do
          mp <- HPages.allocPage :: H (Maybe (Ptr Word8))
          case mp of
            Nothing -> return (Left NoSpace)
            Just pg -> do
              HPages.zeroPage pg
              ok <- VM.setPage pdir lo (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr pg), VM.writable = True, VM.dirty = False, VM.accessed = False}))
              if not ok
                then do HPages.freePage pg; return (Left NoSpace)
                else growPages pdir (lo + 4096) hi

mapSegments :: VM.PageMap -> Elf -> H (Either LoadError ())
mapSegments pdir elf = go (elfSegs elf) []
  where
    bytes = elfBytes elf
    go [] _ = return (Right ())
    go (seg : rest) allocated = do
      r <- mapOneSegment pdir bytes seg
      case r of
        Left err -> do
          cleanup allocated
          return (Left err)
        Right addrs -> go rest (addrs ++ allocated)
    cleanup =
      mapM_
        ( \va -> do
            mInfo <- VM.getPage pdir va
            case mInfo of
              Nothing -> return ()
              Just info -> do
                _ <- VM.setPage pdir va Nothing
                HPages.freePage (fromPhysPage (VM.physPage info))
        )

mapOneSegment :: VM.PageMap -> [Word8] -> Segment -> H (Either LoadError [VM.VAddr])
mapOneSegment pdir bytes seg =
  let vaddr = segVaddr seg
      foff = segFileOff seg
      fsz = segFileSz seg
      msz = segMemSz seg
      flags = segFlags seg
      writable = (flags .&. pfW) /= 0
      pages = (msz + 4095) `div` 4096
      loop idx acc
        | idx >= pages = return (Right (reverse acc))
        | otherwise = do
            let curVa = vaddr + fromIntegral (idx * 4096)
            mp <- HPages.allocPage :: H (Maybe (Ptr Word8))
            case mp of
              Nothing -> return (Left NoSpace)
              Just pg -> do
                HPages.zeroPage pg
                let pageFileStart = idx * 4096
                let remainingFile = fsz - pageFileStart
                let copyLen = if remainingFile <= 0 then 0 else min 4096 remainingFile
                mapM_ (\i -> let srcIdx = foff + pageFileStart + i; b = indexBytes bytes srcIdx in poke (pg `plusPtr` i) b) [0 .. copyLen - 1]
                ok <- VM.setPage pdir curVa (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr pg), VM.writable = writable, VM.dirty = False, VM.accessed = False}))
                if not ok
                  then do
                    HPages.freePage pg
                    return (Left NoSpace)
                  else loop (idx + 1) (curVa : acc)
   in if pages == 0
        then return (Right [])
        else loop 0 []

indexBytes :: [Word8] -> Int -> Word8
indexBytes = go
  where
    go [] _ = 0
    go (y : _) 0 = y
    go (_ : ys) n = go ys (n - 1)

freePDir :: VM.PageMap -> H ()
freePDir pdir = do
  curPtr <- liftIO c_current_pdir
  let l0 = VM.fromPageMap pdir
      curL0 = curPtr
  if l0 == curL0
    then return ()
    else do
      let pageEntries = 512
      let l0Idx = fromIntegral ((VM.minVAddr `div` (2 ^ (39 :: Int))) `mod` 512) :: Int
      -- Instead of recomputing, directly walk all L1 entries for the user window
      -- Simpler: iterate whole L1 table (512) and free reachable L2/L3
      d0 <- peekElemOff l0 l0Idx
      case tableFromDesc d0 of
        Nothing -> HPages.freePage l0
        Just l1 -> do
          forM_ [0 .. pageEntries - 1] $ \i1 -> do
            d1 <- peekElemOff l1 i1
            case tableFromDesc d1 of
              Nothing -> return ()
              Just l2 -> do
                if not (HPages.validPage l2)
                  then return ()
                  else do
                    forM_ [0 .. pageEntries - 1] $ \i2 -> do
                      d2 <- peekElemOff l2 i2
                      case tableFromDesc d2 of
                        Nothing -> return ()
                        Just l3 -> do
                          if not (HPages.validPage l3)
                            then return ()
                            else do
                              forM_ [0 .. 511] $ \i3 -> do
                                d3 <- peekElemOff l3 i3
                                when ((d3 .&. 1) /= 0) $ HPages.freePage (ptrFromWord64 (d3 .&. 0x0000FFFFFFFFF000) :: Ptr Word8)
                              HPages.freePage l3
                    HPages.freePage l2
          HPages.freePage l1
          HPages.freePage l0
  where
    tableFromDesc d
      | even d = Nothing
      | otherwise = Just (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000))
