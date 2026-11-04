{- | Driver registry wrapping 'Kernel.IPC.Nameservice'.
Lock order: @drvSem@ outermost, @nsSem@ inner — never invert.
Endpoint table's @endpointSem@ only around queue splice, never across registry calls:
teardown snapshots the endpoint and thread lists under @drvSem@, releases, then
clears IRQ forwarding, then frees (each @freeEndpoint@ takes @endpointSem@ on its
own), then stops the service threads. A thread blocked in @recv@ on a freed endpoint
observes @NoSuchEndpoint@ and exits, so freeing before stopping keeps the stop
bounded however many threads the driver owns.
-}
module Kernel.Driver.Registry (
  registerDriver,
  unregisterDriver,
  lookupDriver,
  listDrivers,
  registerDriverRoot,
  lookupDriverRoot,
  lookupDriverByPdir,
  addDriverService,
  installDriverRoot,
  reapAndRestartDriver,
  superviseDriverEndpoint,
)
where

import Control.Concurrent (ThreadId)
import Control.Exception (AsyncException, SomeException, fromException, onException, throwIO, try)
import Control.Monad (unless, when)
import Data.Bits (complement, (.&.))
import Data.Foldable (forM_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word32, Word64)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr)
import H.AdHocMem (allocaArray, peek, peekElemOff)
import H.Concurrency (QSem, killH, newQSem, threadDelay, withQSem)
import H.Concurrency qualified as HC
import H.Interrupts (IntId)
import H.Monad (H, liftIO, runH)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Pages qualified as HPages
import H.Unsafe (unsafePerformH)
import H.VirtualMemory qualified as VM
import Kernel.Driver.IRQ qualified as DIRQ
import Kernel.Driver.Types (DriverError (..), DriverInfo (..), DriverKind)
import Kernel.IPC.Endpoint qualified as IPC
import Kernel.IPC.Nameservice qualified as NS
import Kernel.IPC.Types (Endpoint, IpcError, Message)
import Kernel.IPC.Types qualified as IPCType
import Kernel.Log.Dmesg qualified as Dmesg
import Numeric (showHex)

{-# NOINLINE drvMap #-}
drvMap :: Ref (Map String DriverInfo)
drvMap = unsafePerformH $ newRef Map.empty

{-# NOINLINE drvSem #-}
drvSem :: QSem
drvSem = unsafePerformH $ newQSem 1

-- | Validate driver name (same rule as nsRegister: non-empty, <=255, no '/').
validDriverName :: String -> Either DriverError ()
validDriverName s
  | null s = Left (InvalidName "empty name")
  | length s > 255 = Left (InvalidName "name too long")
  | '/' `elem` s = Left (InvalidName "name contains '/'")
  | otherwise = Right ()

{- | Register a driver: insert into 'drvMap' then 'nsRegister'. On 'NameExists'
roll back the 'drvMap' insert. Lock order @drvSem@ outermost, @nsSem@ inner:
validation runs outside sems, then @drvSem@ is held across 'nsRegister'
(which takes @nsSem@) to keep @drvMap@ and @nsMap@ consistent.
Note: 'NS.nsRegister' handles the global uniqueness check under @nsSem@;
we hold @drvSem@ across the call to keep @drvMap@ and @nsMap@ consistent
without inverting lock order — caller never holds @epSem@ here.
The service thread list and endpoint list ride along so teardown can drop
endpoints then stop every thread the driver started.
-}
registerDriver :: String -> Endpoint -> Maybe IntId -> DriverKind -> [ThreadId] -> [Endpoint] -> H (Either DriverError ())
registerDriver name ep mIntId kind service endpoints = case validDriverName name of
  Left e -> return (Left e)
  Right () -> withQSem drvSem $ do
    m <- readRef drvMap
    if Map.member name m
      then return (Left AlreadyRegistered)
      else do
        let info = DriverInfo name ep kind mIntId Nothing service endpoints
        writeRef drvMap (Map.insert name info m)
        let rollback = do
              m2 <- readRef drvMap
              writeRef drvMap (Map.delete name m2)
        r <- liftIO (runH (NS.nsRegister name ep) `onException` runH rollback)
        case r of
          Right () -> return (Right ())
          Left IPCType.NameExists -> do
            -- rollback drvMap
            m2 <- readRef drvMap
            writeRef drvMap (Map.delete name m2)
            return (Left AlreadyRegistered)
          Left (IPCType.InvalidName s) -> do
            m2 <- readRef drvMap
            writeRef drvMap (Map.delete name m2)
            return (Left (InvalidName s))
          Left _ -> do
            m2 <- readRef drvMap
            writeRef drvMap (Map.delete name m2)
            return (Left (InvalidName "nsRegister failed"))

{- | Unregister driver: stop accepting new work, clear IRQ forwarding, drop
endpoints outside @drvSem@ (each @freeEndpoint@ takes @endpointSem@ on its
own), then stop the service threads. Join last: the threads observe
@NoSuchEndpoint@ and exit on their own, so the stop is bounded. The recorded
fault-domain root (if any) is claimed and freed after the service threads
(including the fault watch) are stopped, so no poller touches freed tables;
the S1 reload leak (three table pages per cycle) ends here.
-}
unregisterDriver :: String -> H (Either DriverError ())
unregisterDriver name = do
  (mInfo, mRoot) <- withQSem drvSem $ do
    m <- readRef drvMap
    case Map.lookup name m of
      Nothing -> return (Nothing, Nothing)
      Just info -> do
        writeRef drvMap (Map.delete name m)
        _ <- NS.nsUnregister name
        r <- readRef drvRoots
        case Map.lookup name r of
          Nothing -> return (Just info, Nothing)
          Just root -> do
            writeRef drvRoots (Map.delete name r)
            return (Just info, Just root)
  case mInfo of
    Nothing -> return (Left NotFound)
    Just info -> do
      -- Before the free, not after: a handler still installed would trySend
      -- into the endpoint this call is about to drop.
      forM_ (diIntId info) DIRQ.unregisterIrqForwarding
      mapM_ IPC.freeEndpoint (diEndpoints info)
      mapM_ killH (diService info)
      case mRoot of
        Nothing -> return ()
        Just (pm, _asid, _slot) -> do
          -- Retract the EL0 slot first so a concurrent trap cannot route to
          -- the freed root (an already-parked request is consumed by the
          -- dying watch, which finds no entry and exits).
          liftIO (c_el0_unregister (VM.fromPageMap pm))
          live <- liftIO (c_release_pdir (VM.fromPageMap pm))
          unless (live /= 0) (VM.freeUserTables HPages.freePage pm)
          Dmesg.dmesgLog ("driver root teardown: " ++ name ++ " (fault domain freed)")
      return (Right ())

-- | Lookup driver metadata.
lookupDriver :: String -> H (Maybe DriverInfo)
lookupDriver name = withQSem drvSem $ do
  m <- readRef drvMap
  return (Map.lookup name m)

-- | Sorted driver names.
listDrivers :: H [DriverInfo]
listDrivers = withQSem drvSem $ do
  m <- readRef drvMap
  return (Map.elems m)

-- S2 (house-oz9.11): per-driver TTBR0 fault domains (slot -> root + ASID +
-- slot). S1 built mapping-only roots (never installed, EL1-accessed, RAM
-- clone intact); S2 narrows each root before use (the clone and the UART/GIC
-- blocks are stripped, so a narrowed root names exactly its own window) and
-- enrolls it as an EL0 fault domain: the pager refuses it, an EL0 sync fault
-- under its TTBR0 context parks 0x1D FAULT_KILL attributed to the driver pid,
-- and the per-pid preempt path covers a spinning driver (the global quantum
-- from `quantum` bounds the slice; the fault watch below resumes). The
-- supervisor half is the restarting endpoint servers plus the fault watch
-- that reaps only the faulting driver and re-arms its domain.
--
-- IRQ decision (recorded, S2): GIC + 'registerIrqForwarding' dispatch stays
-- EL1 and delivery to the EL0 driver rides the endpoint (already the
-- 'Transport.virtioInit' pattern) — no EL0 GIC mapping, which would violate
-- the allowlist layer. Narrowing strips the cloned GIC block, and no mapping
-- call ever adds one back.
--
-- Separate map so registering a root never changes the driver insert/remove
-- shape above; same lock ('drvSem' outermost).
{-# NOINLINE drvRoots #-}
drvRoots :: Ref (Map String (VM.PageMap, Word64, Int))
drvRoots = unsafePerformH $ newRef Map.empty

{- | Record a driver root: the name must be registered, and at most one root
per name (a duplicate is a caller bug and fails closed).
-}
registerDriverRoot :: String -> VM.PageMap -> Word64 -> Int -> H (Either DriverError ())
registerDriverRoot name pm asid slot = withQSem drvSem $ do
  m <- readRef drvMap
  case Map.lookup name m of
    Nothing -> return (Left NotFound)
    Just _ -> do
      r <- readRef drvRoots
      if Map.member name r
        then return (Left AlreadyRegistered)
        else do
          writeRef drvRoots (Map.insert name (pm, asid, slot) r)
          return (Right ())

-- | Look up a driver root.
lookupDriverRoot :: String -> H (Maybe (VM.PageMap, Word64, Int))
lookupDriverRoot name = withQSem drvSem $ do
  r <- readRef drvRoots
  return (Map.lookup name r)

{- | Fault attribution: which driver owns the faulting TTBR0 root, if any.
The trap side keys every park (FAULT_KILL, PREEMPT) on the faulting pdir, so
the watch attributes a parked request to its driver pid by pointer equality —
a fault under a driver context reaps only that driver, never a neighbour.
-}
lookupDriverByPdir :: Ptr Word64 -> H (Maybe String)
lookupDriverByPdir ptr = withQSem drvSem $ do
  r <- readRef drvRoots
  return (Map.foldrWithKey (\k (pm, _, _) acc -> if VM.fromPageMap pm == ptr then Just k else acc) Nothing r)

{- | Append a service thread to a registered driver (the fault watch joins
the endpoint servers in 'diService', so teardown stops it with the rest).
-}
addDriverService :: String -> ThreadId -> H (Either DriverError ())
addDriverService name tid = withQSem drvSem $ do
  m <- readRef drvMap
  case Map.lookup name m of
    Nothing -> return (Left NotFound)
    Just info -> do
      writeRef drvMap (Map.insert name info {diService = diService info ++ [tid]} m)
      return (Right ())

foreign import ccall unsafe "house_vm_map_mmio" c_map_mmio :: Ptr Word64 -> CInt -> IO CInt
foreign import ccall unsafe "house_vm_narrow_driver_root" c_narrow_driver_root :: Ptr Word64 -> IO CInt
foreign import ccall unsafe "house_asid_for_pdir" c_asid_for_pdir :: Ptr Word64 -> IO Word64
foreign import ccall unsafe "house_el0_register" c_el0_register :: Ptr Word64 -> IO CInt
foreign import ccall unsafe "house_el0_unregister" c_el0_unregister :: Ptr Word64 -> IO ()
foreign import ccall unsafe "house_release_pdir" c_release_pdir :: Ptr Word64 -> IO CInt
foreign import ccall unsafe "house_el0_parked" c_el0_parked :: Ptr Word64 -> IO CInt
foreign import ccall unsafe "house_el0_take_request" c_el0_take :: Ptr Word64 -> Ptr Word32 -> Ptr Word64 -> IO CInt
foreign import ccall unsafe "house_el0_fault_addr" c_el0_fault_addr :: Ptr Word64 -> IO Word64
foreign import ccall unsafe "house_resume_el0" c_resume_el0 :: Ptr Word64 -> Word64 -> Word64 -> IO CInt

{- | Drop a fresh root that was never recorded: retract the EL0 slot, release,
free tables. Every 'buildDriverRoot' failure path funnels here, so the S1
refused-map leak ends at the source (nothing registered, never installed,
nothing to shoot down — the Device leaf is skipped by the shared walker).
-}
dropFreshRoot :: VM.PageMap -> H ()
dropFreshRoot pm = do
  liftIO (c_el0_unregister (VM.fromPageMap pm))
  _ <- liftIO (c_release_pdir (VM.fromPageMap pm))
  VM.freeUserTables HPages.freePage pm

{- | S2 (house-oz9.11): build a driver's own TTBR0 fault domain. Steps:
validate the slot (the range check makes the window arithmetic total), fresh
root via 'VM.allocPageMap', Haskell-side overlap check in the 'mapOneSegment'
pattern (the Rust helper re-checks under 'VM_LOCK' and is the backstop), map
via FFI, narrow via FFI (strips the RAM-identity clone + UART/GIC blocks and
enrolls the fault domain — the pager refuses it from here on), wire the ASID
every EL0 root shares, register the EL0_TABLE slot (fault-kill + preempt
attribution). Any failure after allocation frees the fresh root at once, so a
refused domain leaks nothing.
-}
buildDriverRoot :: String -> Int -> H (Maybe (VM.PageMap, Word64))
buildDriverRoot name slot = do
  mpm <- VM.allocPageMap
  case mpm of
    Nothing -> do
      Dmesg.dmesgLog ("driver root: no pages for " ++ name)
      return Nothing
    Just pm -> do
      let page = 0x0a000000 + fromIntegral slot * 0x200
          pageBase = page .&. complement 4095
      occupied <- VM.getPage pm pageBase
      case occupied of
        Just _ -> do
          Dmesg.dmesgLog ("driver root: window occupied for " ++ name)
          dropFreshRoot pm
          return Nothing
        Nothing -> do
          rc <- liftIO (c_map_mmio (VM.fromPageMap pm) (fromIntegral slot))
          if rc /= 1
            then do
              Dmesg.dmesgLog ("driver root: map refused slot " ++ show slot ++ " for " ++ name)
              dropFreshRoot pm
              return Nothing
            else do
              nr <- liftIO (c_narrow_driver_root (VM.fromPageMap pm))
              if nr /= 1
                then do
                  Dmesg.dmesgLog ("driver root: narrow refused slot " ++ show slot ++ " for " ++ name)
                  dropFreshRoot pm
                  return Nothing
                else do
                  asid <- liftIO (c_asid_for_pdir (VM.fromPageMap pm))
                  reg <- liftIO (c_el0_register (VM.fromPageMap pm))
                  if reg /= 0
                    then do
                      Dmesg.dmesgLog ("driver root: EL0 slot refused for " ++ name)
                      dropFreshRoot pm
                      return Nothing
                    else return (Just (pm, asid))

{- | S2 (house-oz9.11): install a driver's fault domain and supervise it.
Fail-open like S1: the driver keeps running rootless (no entry recorded) when
any step refuses — the domain is not load-bearing for EL1 execution. Success
records (slot -> pdir/ASID), enrolls the preempt watchdog (EL0_TABLE slot),
and spawns the fault watch as a driver service thread.
-}
installDriverRoot :: String -> Int -> H Bool
installDriverRoot name slot
  | slot < 0 || slot > 31 = do
      Dmesg.dmesgLog ("driver root: bad slot " ++ show slot ++ " for " ++ name)
      return False
  | otherwise = do
      mBuilt <- buildDriverRoot name slot
      case mBuilt of
        Nothing -> return False
        Just (pm, asid) -> do
          r <- registerDriverRoot name pm asid slot
          case r of
            Left _ -> do
              Dmesg.dmesgLog ("driver root: duplicate for " ++ name)
              dropFreshRoot pm
              return False
            Right () -> do
              tid <- liftIO $ HC.forkSupervisedIO $ runH (driverFaultWatch name slot)
              rAdd <- addDriverService name tid
              case rAdd of
                Left _ -> do
                  -- The driver vanished mid-install: stop the watch and drop
                  -- the root only if it is still ours (teardown may have
                  -- claimed it first — exactly one owner frees).
                  killH tid
                  owned <- withQSem drvSem $ do
                    r2 <- readRef drvRoots
                    case Map.lookup name r2 of
                      Just (pm', _, _) | pm' == pm -> do
                        writeRef drvRoots (Map.delete name r2)
                        return True
                      _ -> return False
                  when owned (dropFreshRoot pm)
                  return False
                Right () -> do
                  Dmesg.dmesgLog ("driver root: " ++ name ++ " slot " ++ show slot ++ " asid " ++ show asid ++ " narrowed+supervised")
                  return True

{- | A parked request from a driver TTBR0 context. Only KILL (reap + re-arm)
and PREEMPT (resume: the timer already bounded the slice) are expected —
a driver root holds no COW/demand pages and issues no svcs, so anything
else is a fault-domain breach and is contained the same way.
-}
data DriverPark
  = DriverKill Word64
  | DriverPreempt Word64
  | DriverUnexpected Word32 Word64
  deriving (Eq, Show)

{- | Take one parked request from a driver pdir, if any. Mirrors
'Kernel.Userspace.Process.tryTakeParkedOnce' for 0x1D/0x1E only (no new park
predicates: the trap side already parks generically keyed on the pdir).
-}
takeParkedDriver :: Ptr Word64 -> H (Maybe DriverPark)
takeParkedDriver pdir = do
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
          if w == 0x1D
            then do
              va <- liftIO (c_el0_fault_addr pdir)
              return (Just (DriverKill va))
            else
              if w == 0x1E
                then return (Just (DriverPreempt a0))
                else return (Just (DriverUnexpected w a0))

{- | Reap a faulted driver domain and re-arm it: claim the root entry (exactly
one owner frees — a concurrent teardown that claimed first wins and this path
does nothing), reap only this driver (free its root; every other domain is
untouched), then rebuild + re-register a fresh narrowed root under the same
slot. The endpoint servers (EL1) survive the fault; the fault domain
restarts. Fail-open on rebuild refusal: the driver runs rootless until
re-init, like S1.
-}
reapAndRestartDriver :: String -> Int -> VM.PageMap -> Word64 -> H ()
reapAndRestartDriver name slot pm va = do
  owned <- withQSem drvSem $ do
    r <- readRef drvRoots
    case Map.lookup name r of
      Just (pm', _, _) | pm' == pm -> do
        writeRef drvRoots (Map.delete name r)
        return True
      _ -> return False
  -- Lost the race with teardown (entry gone): the watch loop exits on its
  -- next lookup. Only the claim winner frees + re-arms, so a fault-restart
  -- cycle can never double-free the root.
  when owned $ do
    Dmesg.dmesgLog ("driver fault kill " ++ name ++ " va=0x" ++ showHex va "" ++ " (reaped only driver)")
    liftIO (c_el0_unregister (VM.fromPageMap pm))
    live <- liftIO (c_release_pdir (VM.fromPageMap pm))
    unless (live /= 0) (VM.freeUserTables HPages.freePage pm)
    mBuilt <- buildDriverRoot name slot
    case mBuilt of
      Nothing -> Dmesg.dmesgLog ("driver root rearm failed for " ++ name ++ " (running rootless until re-init)")
      Just (pm2, asid2) -> do
        r2 <- registerDriverRoot name pm2 asid2 slot
        case r2 of
          Left _ -> do
            Dmesg.dmesgLog ("driver root rearm conflict for " ++ name)
            dropFreshRoot pm2
          Right () -> Dmesg.dmesgLog ("driver root reinstalled: " ++ name ++ " slot " ++ show slot ++ " asid " ++ show asid2)

{- | Per-driver fault watch (watchdog): polls the recorded root for parked
trap-side requests. FAULT_KILL reaps only this driver and re-arms its domain;
PREEMPT resumes at once (the scheduler run queue holds no driver pids, and
the global quantum still bounds the slice — this is the preempt/watchdog
budget for driver pids: EL0_TABLE enrollment plus this bounded poll). An
unexpected park is contained the same way (fail closed). No root entry means
the driver went away: exit, teardown owns the join.
-}
driverFaultWatch :: String -> Int -> H ()
driverFaultWatch name slot = loop
  where
    loop = do
      mRoot <- lookupDriverRoot name
      case mRoot of
        Nothing -> return ()
        Just (pm, asid, _) -> do
          mReq <- takeParkedDriver (VM.fromPageMap pm)
          case mReq of
            Nothing -> do threadDelay 5000; loop
            Just (DriverPreempt x0) -> do
              _ <- liftIO (c_resume_el0 (VM.fromPageMap pm) asid x0)
              loop
            Just (DriverKill va) -> do reapAndRestartDriver name slot pm va; loop
            Just (DriverUnexpected req x0) -> do
              Dmesg.dmesgLog ("driver unexpected park " ++ name ++ " req=" ++ show req ++ " (contained)")
              reapAndRestartDriver name slot pm x0
              loop

{- | Supervised endpoint server: serve until the endpoint is freed (clean
exit, teardown owns this), restarting the serve loop on handler death with a
dmesg line and a 50ms backoff (a hot-failing server yields the capability
instead of pinning it). Async exceptions (teardown's 'killH') are rethrown, so
the stop stays bounded. Replaces bare 'forkSupervisedIO' at the driver
endpoint sites: a wedged server heals instead of wedging its endpoint.
-}
superviseDriverEndpoint :: String -> Endpoint -> (Message -> H (Either IpcError Message)) -> IO ThreadId
superviseDriverEndpoint name ep handler = HC.forkSupervisedIO (loop 0)
  where
    loop :: Int -> IO ()
    loop n = do
      r <- try (runH (IPC.serveEndpoint ep handler)) :: IO (Either SomeException ())
      case r of
        Left e -> case fromException e of
          Just (_ :: AsyncException) -> throwIO e
          Nothing -> do
            runH (Dmesg.dmesgLog ("driver endpoint restart " ++ name ++ " #" ++ show n ++ ": " ++ show e))
            runH (threadDelay 50000)
            loop (n + 1)
        Right () -> return ()
