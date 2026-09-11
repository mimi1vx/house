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
  breakCow,
  cowLiveCount,
  ParkRequest (..),
)
where

import Control.Concurrent (tryPutMVar, tryTakeMVar)
import Control.Monad (forM_, void, when)
import Data.Bits (complement, shiftR, (.&.))
import Data.Char (chr, ord)
import Data.IORef (atomicModifyIORef')
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import H.AdHocMem (allocaArray, peek, peekElemOff, poke, pokeElemOff)
import H.Concurrency (MVar, forkH, newEmptyMVar, putMVar, takeMVar, threadDelay, withQSem)
import H.Monad (H, liftIO, runH)
import H.Mutable (Ref, modifyRef, newRef, readRef, writeRef)
import qualified H.Pages as HPages
import H.PhysicalMemory (fromPhysPage, toPhysPage)
import H.Unsafe (unsafePerformH)
import H.Utils (ptrFromWord64, ptrToWord64)
import qualified H.VirtualMemory as VM
import qualified Kernel.FileSystem.Vfs as Vfs
import qualified Kernel.IPC.Endpoint as IPC
import Kernel.IPC.Types (IpcError (..), Message (..), mkMessage)
import qualified Kernel.Userspace.Fd as Fd
import Kernel.Userspace.Loader (Elf (..), LoadError (..), Segment (..), loadElf)
import qualified Kernel.Userspace.Sched as Sched
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

foreign import ccall unsafe "house_el0_clone_slot" c_el0_clone :: Ptr Word64 -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "house_el0_set_entry" c_el0_set_entry :: Ptr Word64 -> Word64 -> Word64 -> IO CInt

foreign import ccall unsafe "house_el0_fault_addr" c_el0_fault_addr :: Ptr Word64 -> IO Word64

foreign import ccall unsafe "house_resume_el0" c_resume_el0 :: Ptr Word64 -> Word64 -> Word64 -> IO CInt

foreign import ccall unsafe "house_user_read" c_user_read :: Ptr Word64 -> Word64 -> Ptr Word64 -> Word64 -> IO CInt

foreign import ccall unsafe "house_user_write" c_user_write :: Ptr Word64 -> Word64 -> Ptr Word64 -> Word64 -> IO CInt

foreign import ccall unsafe "house_user_read_bytes" c_user_read_bytes :: Ptr Word64 -> Word64 -> Ptr Word8 -> Word64 -> IO CInt

foreign import ccall unsafe "house_user_write_bytes" c_user_write_bytes :: Ptr Word64 -> Word64 -> Ptr Word8 -> Word64 -> IO CInt

foreign import ccall unsafe "house_user_strlen" c_user_strlen :: Ptr Word64 -> Word64 -> Word64 -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "current_pdir" c_current_pdir :: IO (Ptr Word64)

foreign import ccall unsafe "house_set_recorded_pdir" c_set_pdir :: Ptr Word64 -> IO ()

stackTop :: Word64
stackTop = 0x3FFFE000

{- | Request parked by an EL0 trap (svc #imm). Yield plus brk/fd
0x03..0x07/0x0A plus fork 0x08/wait 0x09/exec 0x0B plus dir 0x0C..0x0F
plus IPC 0x10..0x13 ride
the ring; GRANT_MAP 0x14 stays inline ENOSYS. Each IPC request carries the
trapped x0..x3 (ep, va, nwords, tag); fd requests carry their trapped
x0..x2 (see 'classify' below); WAIT carries the child pid in x0, EXEC the
path VA in x0, FORK takes no args; MKDIR/UNLINK carry the path VA in x0,
STAT/GETDENTS carry (path VA, buf VA, len). ReqFault carries the trapped x0 plus the
fault VA (an RO write to a COW page parks 0x1F via the RO perm guard).
ReqPreempt carries the trapped x0 (an over-quantum EL0 frame parks 0x1E via
the timer IRQ; resume retries the interrupted insn).
-}
data ParkRequest
  = ReqYield
  | ReqBrk Word64
  | ReqOpen Word64 Word64
  | ReqRead Word64 Word64 Word64
  | ReqWriteFd Word64 Word64 Word64
  | ReqClose Word64
  | ReqSeek Word64 Word64 Word64
  | ReqFork
  | ReqWait Word64
  | ReqExec Word64
  | ReqMkdir Word64
  | ReqUnlink Word64
  | ReqStat Word64 Word64 Word64
  | ReqGetdents Word64 Word64 Word64
  | ReqIpcSend Word64 Word64 Word64 Word64
  | ReqIpcRecv Word64 Word64 Word64
  | ReqIpcCall Word64 Word64 Word64 Word64
  | ReqIpcReply Word64 Word64 Word64 Word64
  | ReqFault Word64 Word64
  | ReqPreempt Word64
  | ReqUnknown Word32
  deriving (Eq, Show)

{- | Per-pid pending RECV reply slot for the EL0 REPLY trap. Inserted when a
RECV parks its rendezvous handle, taken by the matching REPLY; reaped with
NoSuchEndpoint when the pid dies underneath (unblocks a wedged sender).
-}
{-# NOINLINE pendingReply #-}
pendingReply :: Ref (Map.Map Pid (MVar (Either IpcError Message)))
pendingReply = unsafePerformH (newRef Map.empty)

{- | COW sharer counts keyed by host phys address ('ptrToWord64' of the
backing page). A page is listed while two or more pdirs map it, or while a
sole mapper still carries the cow mark (cleared on break/free). Updates are
single 'atomicModifyIORef'' ops (the map itself is never held across
operations): share/break run under 'userSem', while 'freePDir'/'freeUserPages'
drop refs without the lock, so plain 'modifyRef' would lose concurrent
updates. Every op is a pure function of the current map, so concurrent
share/drop pairs stay exact.
-}
{-# NOINLINE cowRefs #-}
cowRefs :: Ref (Map.Map Word64 Int)
cowRefs = unsafePerformH (newRef Map.empty)

-- | Fork-share bump: absent (parent was private) counts both mappings.
shareBump :: Word64 -> H ()
shareBump key = liftIO (atomicModifyIORef' cowRefs bump)
  where
    bump m = case Map.lookup key m of
      Nothing -> (Map.insert key 2 m, ())
      Just n -> (Map.insert key (n + 1) m, ())

-- | Rollback-only decrement: never frees (the restoring pdir keeps the page).
unshareBump :: Word64 -> H ()
unshareBump key = liftIO (atomicModifyIORef' cowRefs unshare)
  where
    unshare m = case Map.lookup key m of
      Nothing -> (m, ())
      Just n | n <= 1 -> (Map.delete key m, ())
      Just n -> (Map.insert key (n - 1) m, ())

{- | Release one mapping: True when the caller must free the host page (the
page was never shared, or this was the last sharer). Atomic single op.
-}
dropShare :: Word64 -> H Bool
dropShare key = liftIO (atomicModifyIORef' cowRefs release)
  where
    release m = case Map.lookup key m of
      Nothing -> (m, True)
      Just n | n <= 1 -> (Map.delete key m, True)
      Just n -> (Map.insert key (n - 1) m, False)

-- | Live COW ref entries (forktest leak check: 0 when nothing is shared).
cowLiveCount :: H Int
cowLiveCount = Map.size <$> readRef cowRefs

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
      mapped <- mapSegments pdir elf
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
                  okStk <- VM.setPage pdir stackBase (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr stk), VM.writable = True, VM.dirty = False, VM.accessed = False, VM.cow = False}))
                  if not okStk
                    then do HPages.freePage stk; freePDir pdir; return (Left NoSpace)
                    else do
                      asid <- liftIO (c_asid_for pdirPtr)
                      reg <- liftIO (c_el0_register pdirPtr)
                      if reg /= 0
                        then do HPages.freePage stk; freePDir pdir; return (Left NoSpace)
                        else do
                          exitVar <- newEmptyMVar
                          modifyRef procExitMap (Map.insert pid exitVar)
                          modifyRef procMap (Map.insert pid (Process pid pdir (elfEntry elf) initBrk))
                          Sched.schedRegister pid
                          _ <- forkH $ do
                            liftIO (c_set_pdir pdirPtr)
                            liftIO (c_enter_el0 (elfEntry elf) sp pdirPtr asid)
                            parkLoop pid pdirPtr asid exitVar
                            return ()
                          return (Right pid)

{- | Fork slice (Track O + COW, no signals): share the parent address space
into a fresh PageMap + Pid. Every present user page maps into the child with
the same host page, both sides flipped to RO with the cow mark set iff the
page was writable (loader text stays plain shared RO); 'cowRefs' counts the
live mappings so 'freePDir' frees the host page only for the last sharer. A
write to a cow page faults, parks FAULT, and 'breakCow' copies/remaps RW.
Tables are freshly allocated by 'setPage'. EL1-only entry point for
'forktest'; EL0 fork (svc 0x08) goes through 'forkChildEl0', which
additionally wires the trap frame + EL0 session so the child starts runnable
(x0 = 0, parent resumes with the child pid). Exit codes keep flowing through
the existing 'waitPid' path. Runs under 'userSem'.
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
          r <- shareAddrSpace (procPdir parent) childPdir (max (procBrk parent) stackTop)
          case r of
            Left e -> return (Left e)
            Right () -> do
              pidInt <- readRef pidNext
              writeRef pidNext (pidInt + 1)
              let child = Pid pidInt
              modifyRef procMap (Map.insert child (Process child childPdir (procEntry parent) (procBrk parent)))
              Vfs.vfsForkPid parentInt pidInt
              Fd.fdFork parentPid child
              return (Right child)

{- | Share [minVAddr, hi) page by page (capped at 8192 pages), descending
only into user tables: the fresh 'allocPageMap' L1 carries cloned kernel
entries, and 'getPage' treats any valid desc as a table -- following a
kernel block desc faults (EL1 data abort). A desc is ours iff Valid+Table
(0x3, the 'descFromTable' shape) and its pointer passes 'validPage' (buddy
/ user pool, never kernel RAM). Anything else skips its whole range.
Each present page maps into the child with the shared shape (RO, cow set
iff the parent page was writable) after the child mapping succeeds; the
parent flips to the same shape so a later write faults on either side.
On failure the child pdir is freed, flipped parents are restored, and the
bumped counts are unwound, so the caller must not free anything.
-}
shareAddrSpace :: VM.PageMap -> VM.PageMap -> Word64 -> H (Either LoadError ())
shareAddrSpace src dst hi = do
  d0 <- peekElemOff (VM.fromPageMap src) 0
  case userTable d0 of
    Nothing -> return (Right ())
    Just l1 -> go l1 VM.minVAddr 0 []
  where
    userTable d
      | d .&. 3 == 3
      , HPages.validPage (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000)) =
          Just (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000))
      | otherwise = Nothing
    l1i va = fromIntegral ((va `shiftR` 30) .&. 0x1FF) :: Int
    l2i va = fromIntegral ((va `shiftR` 21) .&. 0x1FF) :: Int
    keyOf info = ptrToWord64 (fromPhysPage (VM.physPage info))
    go l1 va n flipped
      | va >= hi = return (Right ())
      | n > (8192 :: Int) = rollback flipped
      | otherwise = do
          d1 <- peekElemOff l1 (l1i va)
          case userTable d1 of
            Nothing -> go l1 (nextL1 va) n flipped
            Just l2 -> do
              d2 <- peekElemOff l2 (l2i va)
              case userTable d2 of
                Nothing -> go l1 (nextL2 va) n flipped
                Just _ -> do
                  mInfo <- VM.getPage src va
                  case mInfo of
                    Nothing -> go l1 (va + 4096) n flipped
                    Just info -> do
                      let shared = info {VM.writable = False, VM.cow = VM.writable info}
                      okC <- VM.setPage dst va (Just shared)
                      if not okC
                        then rollback flipped
                        else do
                          okP <- VM.setPage src va (Just shared)
                          if not okP
                            then do
                              _ <- VM.setPage dst va Nothing
                              rollback flipped
                            else do
                              shareBump (keyOf info)
                              go l1 (va + 4096) (n + 1) ((va, info) : flipped)
    rollback flipped = do
      freePDir dst
      forM_ flipped $ \(fva, orig) -> do
        mCur <- VM.getPage src fva
        case mCur of
          Nothing -> return ()
          Just cur -> do
            _ <- VM.setPage src fva (Just orig)
            unshareBump (keyOf cur)
      return (Left NoSpace)
    nextL1 va = (va .&. complement 0x3FFFFFFF) + 0x40000000
    nextL2 va = (va .&. complement 0x1FFFFF) + 0x200000

{- | Break a COW page for a live pid (the FAULT-park handler and forktest
share this): a sole-mapped page remaps RW in place, a shared page copies
to a fresh host page (other sharers keep the RO+cow mapping). True when
the page is writable afterwards (resume retries the faulting store).
Runs under 'userSem' as one region so a reaper's map delete cannot slip
between the lookup and the remap.
-}
breakCow :: Pid -> Word64 -> H Bool
breakCow pid pdirVa = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup pid mp of
    Nothing -> return False
    Just pr -> do
      let pdir = procPdir pr
          va = pdirVa .&. complement 4095
      mInfo <- VM.getPage pdir va
      case mInfo of
        Nothing -> return False
        Just info
          | not (VM.cow info) -> return False
          | otherwise -> do
              let key = ptrToWord64 (fromPhysPage (VM.physPage info))
              n <- Map.findWithDefault 0 key <$> readRef cowRefs
              if n <= 1
                then do
                  ok <- VM.setPage pdir va (Just (info {VM.writable = True, VM.cow = False}))
                  when ok (liftIO (atomicModifyIORef' cowRefs (\m -> (Map.delete key m, ()))))
                  return ok
                else do
                  mp2 <- HPages.allocPage :: H (Maybe (Ptr Word8))
                  case mp2 of
                    Nothing -> return False
                    Just raw -> do
                      copyPageBytes (fromPhysPage (VM.physPage info)) (castPtr raw)
                      let mine = info {VM.physPage = toPhysPage (castPtr raw), VM.writable = True, VM.cow = False}
                      ok <- VM.setPage pdir va (Just mine)
                      if not ok
                        then do HPages.freePage raw; return False
                        else do
                          liftIO (atomicModifyIORef' cowRefs (\m -> (Map.insert key (n - 1) m, ())))
                          return True

copyPageBytes :: Ptr Word8 -> Ptr Word8 -> H ()
copyPageBytes src dst =
  forM_ [0 .. 4095] $ \i -> do
    b <- peek (src `plusPtr` i) :: H Word8
    poke (dst `plusPtr` i) b

{- | EL0 fork (svc 0x08): share the parent address space like 'forkProc',
then wire the trap frame + EL0 session so the child starts runnable. The
parent must be parked (its slot holds the trap frame); the child slot is
cloned with x0 = 0 via 'house_el0_clone_slot', then a fresh Haskell thread
resumes the child and enters its 'parkLoop'. Returns the child pid for the
parent to resume with. Cleanup on failure removes the half-built child and
returns the 'LoadError' for the parent to resume as an errno (a share
failure already freed the child pdir and restored the parent, so only
post-share failures free here).
-}
forkChildEl0 :: Pid -> Ptr Word64 -> H (Either LoadError Pid)
forkChildEl0 parentPid@(Pid parentInt) parentPtr = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup parentPid mp of
    Nothing -> return (Left (BadSegment "no such pid"))
    Just parent -> do
      mChild <- VM.allocPageMap
      case mChild of
        Nothing -> return (Left NoSpace)
        Just childPdir -> do
          r <- shareAddrSpace (procPdir parent) childPdir (max (procBrk parent) stackTop)
          case r of
            Left e -> return (Left e)
            Right () -> do
              pidInt <- readRef pidNext
              writeRef pidNext (pidInt + 1)
              let child = Pid pidInt
                  childPtr = VM.fromPageMap childPdir
              reg <- liftIO (c_el0_register childPtr)
              if reg /= 0
                then do freePDir childPdir; return (Left NoSpace)
                else do
                  exitVar <- newEmptyMVar
                  modifyRef procExitMap (Map.insert child exitVar)
                  modifyRef procMap (Map.insert child (Process child childPdir (procEntry parent) (procBrk parent)))
                  Sched.schedRegister child
                  Vfs.vfsForkPid parentInt pidInt
                  Fd.fdFork parentPid child
                  asid <- liftIO (c_asid_for childPtr)
                  cloned <- liftIO (c_el0_clone parentPtr childPtr)
                  if cloned /= 0
                    then do
                      modifyRef procMap (Map.delete child)
                      modifyRef procExitMap (Map.delete child)
                      Vfs.vfsReleasePid pidInt
                      Fd.fdRelease child
                      liftIO (c_el0_unregister childPtr)
                      freePDir childPdir
                      return (Left (BadSegment "clone slot"))
                    else do
                      _ <- forkH $ do
                        liftIO (c_set_pdir childPtr)
                        _ <- liftIO (c_resume_el0 childPtr asid 0)
                        parkLoop child childPtr asid exitVar
                        return ()
                      return (Right child)

{- | Unmap every user page in [minVAddr, hi), releasing the backing host
pages. Shared pages only drop their 'cowRefs' count (the host page frees
for the last sharer); private pages free directly. Tables are kept (L2/L1
husks leak at most a page each per exec -- negligible at this scale); the
pdir pointer stays valid so the parked EL0 slot keeps its key. Runs under
'userSem'.
-}
freeUserPages :: VM.PageMap -> Word64 -> H ()
freeUserPages pdir hi = do
  d0 <- peekElemOff (VM.fromPageMap pdir) 0
  case userTable d0 of
    Nothing -> return ()
    Just l1 -> go l1 VM.minVAddr
  where
    userTable d
      | d .&. 3 == 3
      , HPages.validPage (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000)) =
          Just (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000))
      | otherwise = Nothing
    l1i va = fromIntegral ((va `shiftR` 30) .&. 0x1FF) :: Int
    l2i va = fromIntegral ((va `shiftR` 21) .&. 0x1FF) :: Int
    go l1 va
      | va >= hi = return ()
      | otherwise = do
          d1 <- peekElemOff l1 (l1i va)
          case userTable d1 of
            Nothing -> go l1 (nextL1 va)
            Just l2 -> do
              d2 <- peekElemOff l2 (l2i va)
              case userTable d2 of
                Nothing -> go l1 (nextL2 va)
                Just _ -> do
                  mInfo <- VM.getPage pdir va
                  case mInfo of
                    Nothing -> go l1 (va + 4096)
                    Just info -> do
                      _ <- VM.setPage pdir va Nothing
                      releaseBacking (fromPhysPage (VM.physPage info))
                      go l1 (va + 4096)
    nextL1 va = (va .&. complement 0x3FFFFFFF) + 0x40000000
    nextL2 va = (va .&. complement 0x1FFFFF) + 0x200000

-- | Free a backing host page iff it is private or the last COW sharer.
releaseBacking :: Ptr Word8 -> H ()
releaseBacking raw = do
  shouldFree <- dropShare (ptrToWord64 raw)
  when shouldFree (HPages.freePage raw)

{- | EL0 exec (svc 0x0B): replace the image under the same pid. Reads + parses
the path (VFS, then 'loadElf') before touching the old image; only then frees
old user pages, maps the new segments, lays a fresh argv ([path]) + env
stack, updates entry/brk, and redirects the parked slot via
'house_el0_set_entry' (resume with x0 = 0 follows in the caller). Fds stay
open across exec (Unix semantics); the pid/namespace/slot are unchanged.
Errors before the point of no return resume errnos (ENOENT/EINVAL/ENOMEM);
a mapping failure past it resumes ENOMEM on a half-built image.
-}
execReplace :: Pid -> Ptr Word64 -> String -> H (Either LoadError (Word64, Word64))
execReplace pid@(Pid pidInt) pdir path = do
  ns <- Vfs.vfsEnsurePid pidInt
  mBytes <- Vfs.vfsRead ns path
  case mBytes of
    Left _ -> return (Left (BadSegment "enoent"))
    Right bytes -> case loadElf bytes of
      Left le -> return (Left le)
      Right elf -> withQSem userSem $ do
        mp <- readRef procMap
        case Map.lookup pid mp of
          Nothing -> return (Left (BadSegment "no such pid"))
          Just pr -> do
            let oldHi = max (procBrk pr) stackTop
            freeUserPages (procPdir pr) oldHi
            mapped <- mapSegments (procPdir pr) elf
            case mapped of
              Left err -> return (Left err)
              Right () -> do
                let initBrk = initBreak elf
                mStack <- HPages.allocPage :: H (Maybe (Ptr Word8))
                case mStack of
                  Nothing -> return (Left NoSpace)
                  Just stk -> do
                    HPages.zeroPage stk
                    eSp <- setupArgStack stk [path] ["HOUSE=1", "PATH=/bin"]
                    case eSp of
                      Left err -> do HPages.freePage stk; return (Left err)
                      Right sp -> do
                        let stackBase = stackTop - 4096
                        okStk <- VM.setPage (procPdir pr) stackBase (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr stk), VM.writable = True, VM.dirty = False, VM.accessed = False, VM.cow = False}))
                        if not okStk
                          then do HPages.freePage stk; return (Left NoSpace)
                          else do
                            writeRef procMap (Map.insert pid pr {procEntry = elfEntry elf, procBrk = initBrk} mp)
                            setRc <- liftIO (c_el0_set_entry pdir (elfEntry elf) sp)
                            if setRc /= 0
                              then return (Left (BadSegment "exec redirect"))
                              else return (Right (elfEntry elf, sp))

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
  Fd.fdRelease pid
  Sched.schedUnregister pid
  Sched.schedWakeAll
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
  Fd.fdRelease pid
  Sched.schedUnregister pid
  Sched.schedWakeAll
  case mProc of
    Nothing -> return ()
    Just pr -> do
      freePDir (procPdir pr)
      liftIO (c_el0_unregister (VM.fromPageMap (procPdir pr)))

{- | Park loop: the EL0 session returned from FFI (exit or park), so no RTS
capability is pinned while this thread polls. EXIT wins over PARK; yield
resumes immediately with x0 = 0; brk grows via 'procBrkGrow' (resumes the
new break); fd 0x04..0x07/0x0A run against the pid's 'Fd' table (per-pid,
so cross-pid use fails EBADF); fork 0x08 shares via 'shareAddrSpace'
(child x0 = 0, parent resumes the child pid); wait 0x09 blocks in 'waitPid'
until the child exits (reaps, resumes the exit code); exec 0x0B replaces
the image via 'execReplace' (resumes 0 in the new image); dir 0x0C..0x0F
run against the pid's VFS namespace (MKDIR/UNLINK resume 0, STAT/GETDENTS
resume the rendered byte count); a write to a cow
page parks FAULT and 'breakCow' copies/remaps RW (resumes the trapped x0
so the faulting store retries); an over-quantum frame parks PREEMPT and the
baton passes to the next runnable pid ('Sched.schedElectNext', resume x0);
IPC 0x10..0x13
pair through the EL1 Endpoint rendezvous (same blocking semantics as the
shell path, bounded by a 5s timeout so a reaped pid never wedges a peer);
unknown requests resume with ENOSYS so a hostile guest can never wedge the
loop. Exits silently when the pid is reaped underneath (killPid) without
touching freed tables: user copies run under 'userSem' (which 'freePDir'
also holds) and resume on an unregistered pdir is a harmless -22.
Return convention: SEND/CALL resume x0 = 0 with reply words in the user
buffer; RECV resumes x0 = sender tag with received words in the buffer;
REPLY resumes x0 = 0; BRK resumes the new break; OPEN resumes the fd
number; READ/WRITE resume the byte count; CLOSE resumes 0; SEEK resumes
the new offset; FORK resumes the child pid (0 in the child); WAIT resumes
the reaped exit code; EXEC resumes 0; MKDIR/UNLINK resume 0; STAT/GETDENTS
resume the rendered byte count. Errors resume negative errnos:
-2 ENOENT, -9 EBADF, -11 EAGAIN (QueueFull or 5s pair timeout), -12 ENOMEM,
-14 EFAULT, -17 EEXIST, -20 ENOTDIR, -21 EISDIR, -22 EINVAL, -28 ENOSPC.
-}
parkLoop :: Pid -> Ptr Word64 -> Word64 -> MVar Int -> H ()
parkLoop pid@(Pid selfInt) pdir asid exitVar = loop
  where
    loop = do
      alive <- withQSem userSem (Map.member pid <$> readRef procMap)
      if not alive
        then return ()
        else do
          mCode <- tryReadExitOnce pdir
          case mCode of
            Just c -> do
              mq <- Sched.schedSuccessor pid
              forM_ mq Sched.schedWake
              Sched.schedUnregister pid
              putMVar exitVar c
            Nothing -> do
              mReq <- tryTakeParkedOnce pdir
              case mReq of
                Nothing -> do threadDelay 1000; loop
                Just ReqYield -> do resumeWith 0; loop
                Just (ReqBrk nb) -> do handleBrk nb; loop
                Just (ReqOpen va fl) -> do handleOpen va fl; loop
                Just (ReqRead fd va ln) -> do handleRead fd va ln; loop
                Just (ReqWriteFd fd va ln) -> do handleWriteFd fd va ln; loop
                Just (ReqClose fd) -> do handleClose fd; loop
                Just (ReqSeek fd off wh) -> do handleSeek fd off wh; loop
                Just ReqFork -> do handleFork; loop
                Just (ReqWait c) -> do handleWait c; loop
                Just (ReqExec va) -> do handleExec va; loop
                Just (ReqMkdir va) -> do handleMkdir va; loop
                Just (ReqUnlink va) -> do handleUnlink va; loop
                Just (ReqStat va buf ln) -> do handleStat va buf ln; loop
                Just (ReqGetdents va buf ln) -> do handleGetdents va buf ln; loop
                Just (ReqIpcSend ep va nw tag) -> do handleSend ep va nw tag; loop
                Just (ReqIpcCall ep va nw tag) -> do handleSend ep va nw tag; loop
                Just (ReqIpcRecv ep va nw) -> do handleRecv ep va nw; loop
                Just (ReqIpcReply ep va nw tag) -> do handleReply ep va nw tag; loop
                Just (ReqFault x0 va) -> do handleCowFault x0 va; loop
                Just (ReqPreempt x0) -> do handlePreempt x0; loop
                Just (ReqUnknown _) -> do resumeWith negENOSYS; loop
    resumeWith res = void (liftIO (c_resume_el0 pdir asid res))
    negENOSYS = fromIntegral (-38 :: Int) :: Word64
    negENOENT = fromIntegral (-2 :: Int) :: Word64
    negAGAIN = fromIntegral (-11 :: Int) :: Word64
    negINVAL = fromIntegral (-22 :: Int) :: Word64
    negNOMEM = fromIntegral (-12 :: Int) :: Word64
    sendErrno QueueFull = negAGAIN
    sendErrno WouldBlock = negAGAIN
    sendErrno NoSuchEndpoint = negENOENT
    sendErrno _ = negINVAL
    brkErrno NoSpace = negNOMEM
    brkErrno _ = negINVAL
    handleBrk nb = do
      r <- procBrkGrow pid nb
      case r of
        Left e -> resumeWith (brkErrno e)
        Right v -> resumeWith v
    handleOpen va fl = do
      mPath <- readUserCString pid pdir va 256
      case mPath of
        Nothing -> return ()
        Just (Left rc) -> resumeWith (fromIntegral rc)
        Just (Right path) -> do
          r <- Fd.fdOpen pid path (fromIntegral fl)
          case r of
            Left e -> resumeWith (fromIntegral (Fd.fdErrorToErrno e))
            Right (Fd.Fd n) -> resumeWith (fromIntegral n)
    handleRead fdNum va ln = do
      let n = fromIntegral ln :: Int
      if ln > 65536
        then resumeWith negINVAL
        else do
          r <- Fd.fdRead pid (Fd.Fd (fromIntegral fdNum)) n
          case r of
            Left e -> resumeWith (fromIntegral (Fd.fdErrorToErrno e))
            Right chunk -> do
              mRc <- writeUserBytes pid pdir va chunk
              case mRc of
                Nothing -> return ()
                Just 0 -> resumeWith (fromIntegral (length chunk))
                Just rc -> resumeWith (fromIntegral rc)
    handleWriteFd fdNum va ln =
      if ln > 65536
        then resumeWith negINVAL
        else do
          mIn <- readUserBytes pid pdir va ln
          case mIn of
            Nothing -> return ()
            Just (Left rc) -> resumeWith (fromIntegral rc)
            Just (Right bytes) -> do
              r <- Fd.fdWrite pid (Fd.Fd (fromIntegral fdNum)) bytes
              case r of
                Left e -> resumeWith (fromIntegral (Fd.fdErrorToErrno e))
                Right k -> resumeWith (fromIntegral k)
    handleClose fdNum = do
      r <- Fd.fdClose pid (Fd.Fd (fromIntegral fdNum))
      case r of
        Left e -> resumeWith (fromIntegral (Fd.fdErrorToErrno e))
        Right () -> resumeWith 0
    handleSeek fdNum off wh = do
      let offI = fromIntegral (fromIntegral off :: Int64) :: Int
          whI = fromIntegral wh :: Int
      r <- Fd.fdSeek pid (Fd.Fd (fromIntegral fdNum)) offI whI
      case r of
        Left e -> resumeWith (fromIntegral (Fd.fdErrorToErrno e))
        Right v -> resumeWith (fromIntegral v)
    handleFork = do
      r <- forkChildEl0 pid pdir
      case r of
        Left NoSpace -> resumeWith negNOMEM
        Left _ -> resumeWith negINVAL
        Right (Pid c) -> resumeWith (fromIntegral c)
    handleWait c = do
      let childInt = fromIntegral c :: Int
      if c == 0 || childInt <= 0 || childInt == selfInt
        then resumeWith negINVAL
        else do
          live <- withQSem userSem (Map.member (Pid childInt) <$> readRef procMap)
          if not live
            then resumeWith negENOENT
            else do
              code <- waitPid (Pid childInt)
              alive2 <- withQSem userSem (Map.member pid <$> readRef procMap)
              when alive2 (resumeWith (fromIntegral (code .&. 0xFF)))
    handleExec va = do
      mPath <- readUserCString pid pdir va 256
      case mPath of
        Nothing -> return ()
        Just (Left rc) -> resumeWith (fromIntegral rc)
        Just (Right path) -> do
          r <- execReplace pid pdir path
          case r of
            Left (BadSegment "enoent") -> resumeWith negENOENT
            Left NoSpace -> resumeWith negNOMEM
            Left _ -> resumeWith negINVAL
            Right _ -> resumeWith 0
    fsErrno e = case e of
      Vfs.ENOENT -> negENOENT
      Vfs.EEXIST -> fromIntegral (-17 :: Int)
      Vfs.ENOTDIR -> fromIntegral (-20 :: Int)
      Vfs.EISDIR -> fromIntegral (-21 :: Int)
      Vfs.ENOSPC -> fromIntegral (-28 :: Int)
      Vfs.EINVAL _ -> negINVAL
    handleMkdir va = do
      mPath <- readUserCString pid pdir va 256
      case mPath of
        Nothing -> return ()
        Just (Left rc) -> resumeWith (fromIntegral rc)
        Just (Right path) -> do
          ns <- Vfs.vfsEnsurePid selfInt
          r <- Vfs.vfsMkdir ns path
          case r of
            Left e -> resumeWith (fsErrno e)
            Right () -> resumeWith 0
    handleUnlink va = do
      mPath <- readUserCString pid pdir va 256
      case mPath of
        Nothing -> return ()
        Just (Left rc) -> resumeWith (fromIntegral rc)
        Just (Right path) -> do
          ns <- Vfs.vfsEnsurePid selfInt
          r <- Vfs.vfsRm ns path
          case r of
            Left e -> resumeWith (fsErrno e)
            Right () -> resumeWith 0
    handleStat va buf ln = do
      mPath <- readUserCString pid pdir va 256
      case mPath of
        Nothing -> return ()
        Just (Left rc) -> resumeWith (fromIntegral rc)
        Just (Right path) -> do
          ns <- Vfs.vfsEnsurePid selfInt
          r <- Vfs.vfsStat ns path
          case r of
            Left e -> resumeWith (fsErrno e)
            Right st -> do
              let bytes = map (\c -> fromIntegral (ord c) :: Word8) (renderStat st)
              if length bytes > fromIntegral ln
                then resumeWith negINVAL
                else do
                  mRc <- writeUserBytes pid pdir buf bytes
                  case mRc of
                    Nothing -> return ()
                    Just 0 -> resumeWith (fromIntegral (length bytes))
                    Just rc -> resumeWith (fromIntegral rc)
    renderStat st =
      (if Vfs.fsIsDir st then "dir" else "file")
        ++ " size "
        ++ show (Vfs.fsSize st)
        ++ " blocks "
        ++ show (Vfs.fsBlocks st)
        ++ "\n"
    handleGetdents va buf ln = do
      mPath <- readUserCString pid pdir va 256
      case mPath of
        Nothing -> return ()
        Just (Left rc) -> resumeWith (fromIntegral rc)
        Just (Right path) -> do
          ns <- Vfs.vfsEnsurePid selfInt
          r <- Vfs.vfsLs ns path
          case r of
            Left e -> resumeWith (fsErrno e)
            Right names -> do
              let bytes = map (\c -> fromIntegral (ord c) :: Word8) (unlines names)
              if length bytes > fromIntegral ln
                then resumeWith negINVAL
                else do
                  mRc <- writeUserBytes pid pdir buf bytes
                  case mRc of
                    Nothing -> return ()
                    Just 0 -> resumeWith (fromIntegral (length bytes))
                    Just rc -> resumeWith (fromIntegral rc)
    handleCowFault x0 va = do
      alive <- withQSem userSem (Map.member pid <$> readRef procMap)
      when alive $ do
        _ <- breakCow pid va
        resumeWith x0
    handlePreempt x0 = do
      qs <- Sched.schedRunQueue
      let (pre, post) = break (== pid) qs
      tryNext (drop 1 post ++ pre)
      where
        -- Alone (or all successors deaf): lend the capability to EL1 work
        -- briefly and keep the slice. Without the delay a solo spinner
        -- re-pins the cap in microseconds and the shell starves despite
        -- preemption.
        tryNext [] = do threadDelay 2000; resumeWith x0
        tryNext (q : rest) = do
          Sched.schedWake q
          woken <- Sched.schedWaitTimeout pid 500000
          if woken
            then do
              alive <- withQSem userSem (Map.member pid <$> readRef procMap)
              when alive (resumeWith x0)
            else tryNext rest
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

{- | Read bytes from a live pid's user VA under 'userSem'. Nothing when
reaped underfoot; 0-length reads skip the FFI; over-64K lengths fail
EINVAL without touching the buffer.
-}
readUserBytes :: Pid -> Ptr Word64 -> Word64 -> Word64 -> H (Maybe (Either CInt [Word8]))
readUserBytes p pd va ln = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup p mp of
    Nothing -> return Nothing
    Just _ ->
      if ln > 65536
        then return (Just (Left (-22)))
        else
          if ln == 0
            then return (Just (Right []))
            else allocaArray (fromIntegral ln) $ \buf -> do
              rc <- liftIO (c_user_read_bytes pd va buf ln)
              if rc /= 0
                then return (Just (Left rc))
                else do ws <- mapM (peekElemOff buf) [0 .. fromIntegral ln - 1]; return (Just (Right ws))

{- | Write bytes to a live pid's user VA under 'userSem'. Nothing when
reaped underfoot (caller must skip resume); over-64K payloads fail EINVAL.
-}
writeUserBytes :: Pid -> Ptr Word64 -> Word64 -> [Word8] -> H (Maybe CInt)
writeUserBytes p pd va ws = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup p mp of
    Nothing -> return Nothing
    Just _ ->
      if length ws > 65536
        then return (Just (-22))
        else
          if null ws
            then return (Just 0)
            else allocaArray (length ws) $ \buf -> do
              mapM_ (uncurry (pokeElemOff buf)) (zip [0 ..] ws)
              rc <- liftIO (c_user_write_bytes pd va buf (fromIntegral (length ws)))
              return (Just rc)

{- | Read a NUL-terminated path (at most @max@ bytes) from a live pid's
user VA under 'userSem'. Nothing when reaped underfoot.
-}
readUserCString :: Pid -> Ptr Word64 -> Word64 -> Word64 -> H (Maybe (Either CInt String))
readUserCString p pd va mx = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup p mp of
    Nothing -> return Nothing
    Just _ ->
      if mx == 0 || mx > 4096
        then return (Just (Left (-22)))
        else allocaArray 1 $ \lp -> do
          rc <- liftIO (c_user_strlen pd va mx lp)
          if rc /= 0
            then return (Just (Left rc))
            else do
              ln <- peek lp
              if ln > mx
                then return (Just (Left (-22)))
                else allocaArray (fromIntegral ln) $ \buf -> do
                  rc2 <- liftIO (c_user_read_bytes pd va buf ln)
                  if rc2 /= 0
                    then return (Just (Left rc2))
                    else do
                      ws <- mapM (peekElemOff buf) [0 .. fromIntegral ln - 1]
                      return (Just (Right (map (\b -> chr (fromIntegral (b :: Word8))) ws)))

-- | Single per-pid exit poll (no loop; the park loop re-polls).
tryReadExitOnce :: Ptr Word64 -> H (Maybe Int)
tryReadExitOnce pdir = allocaArray 1 $ \p -> do
  r <- liftIO (c_el0_status pdir p)
  c <- peek p
  return (if r == 1 then Just (fromIntegral c) else Nothing)

{- | Single parked-request poll: 0 maps to yield, 0x03 to brk (x0 = new
break), 0x04..0x07/0x0A to fd (OPEN pathVa/flags, READ/WRITE fd/buf/len,
CLOSE fd, SEEK fd/off/whence), 0x08 to fork (no args), 0x09 to wait
(x0 = child pid), 0x0B to exec (x0 = path VA), 0x0C to mkdir (x0 = path
VA), 0x0D to unlink (x0 = path VA), 0x0E to stat / 0x0F to getdents
(x0 = path VA, x1 = buf, x2 = len), 0x10..0x13 to IPC (with the
trapped x0..x3 as ep/va/nwords/tag), 0x1F to a COW fault (trapped x0 plus
the fault VA from the slot), 0x1E to a timer preemption (trapped x0),
anything else is unknown (resumed with
ENOSYS by the park loop, never trusted).
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
          if w == 0x1F
            then do
              va <- liftIO (c_el0_fault_addr pdir)
              return (Just (ReqFault a0 va))
            else return (Just (classify w a0 a1 a2 a3))
  where
    classify 0 _ _ _ _ = ReqYield
    classify 0x03 nb _ _ _ = ReqBrk nb
    classify 0x04 va fl _ _ = ReqOpen va fl
    classify 0x05 fd va ln _ = ReqRead fd va ln
    classify 0x06 fd va ln _ = ReqWriteFd fd va ln
    classify 0x07 fd _ _ _ = ReqClose fd
    classify 0x08 _ _ _ _ = ReqFork
    classify 0x09 c _ _ _ = ReqWait c
    classify 0x0B va _ _ _ = ReqExec va
    classify 0x0C va _ _ _ = ReqMkdir va
    classify 0x0D va _ _ _ = ReqUnlink va
    classify 0x0E va buf ln _ = ReqStat va buf ln
    classify 0x0F va buf ln _ = ReqGetdents va buf ln
    classify 0x0A fd off wh _ = ReqSeek fd off wh
    classify 0x10 ep va nw tag = ReqIpcSend ep va nw tag
    classify 0x1E x0 _ _ _ = ReqPreempt x0
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
              ok <- VM.setPage pdir lo (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr pg), VM.writable = True, VM.dirty = False, VM.accessed = False, VM.cow = False}))
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
                ok <- VM.setPage pdir curVa (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr pg), VM.writable = writable, VM.dirty = False, VM.accessed = False, VM.cow = False}))
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
                                when ((d3 .&. 1) /= 0) $ releaseBacking (ptrFromWord64 (d3 .&. 0x0000FFFFFFFFF000))
                              HPages.freePage l3
                    HPages.freePage l2
          HPages.freePage l1
          HPages.freePage l0
  where
    tableFromDesc d
      | even d = Nothing
      | otherwise = Just (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000))
