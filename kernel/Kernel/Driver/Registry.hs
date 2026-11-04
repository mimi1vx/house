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
  installDriverRoot,
)
where

import Control.Concurrent (ThreadId)
import Control.Exception (onException)
import Data.Bits (complement, (.&.))
import Data.Foldable (forM_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word64)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr)
import H.Concurrency (QSem, killH, newQSem, withQSem)
import H.Interrupts (IntId)
import H.Monad (H, liftIO, runH)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import H.VirtualMemory qualified as VM
import Kernel.Driver.IRQ qualified as DIRQ
import Kernel.Driver.Types (DriverError (..), DriverInfo (..), DriverKind)
import Kernel.IPC.Endpoint qualified as IPC
import Kernel.IPC.Nameservice qualified as NS
import Kernel.IPC.Types (Endpoint)
import Kernel.IPC.Types qualified as IPCType
import Kernel.Log.Dmesg qualified as Dmesg

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
@NoSuchEndpoint@ and exit on their own, so the stop is bounded.
-}
unregisterDriver :: String -> H (Either DriverError ())
unregisterDriver name = do
  mInfo <- withQSem drvSem $ do
    m <- readRef drvMap
    case Map.lookup name m of
      Nothing -> return Nothing
      Just info -> do
        writeRef drvMap (Map.delete name m)
        _ <- NS.nsUnregister name
        -- S1 (house-oz9.11): drop the root entry with the driver. The root's
        -- pages are NOT freed here (S2 teardown wires house_release_pdir +
        -- freePDir, which skips Device leaves); a reload cycle leaks three
        -- pages until then.
        r <- readRef drvRoots
        writeRef drvRoots (Map.delete name r)
        return (Just info)
  case mInfo of
    Nothing -> return (Left NotFound)
    Just info -> do
      -- Before the free, not after: a handler still installed would trySend
      -- into the endpoint this call is about to drop.
      forM_ (diIntId info) DIRQ.unregisterIrqForwarding
      mapM_ IPC.freeEndpoint (diEndpoints info)
      mapM_ killH (diService info)
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

-- S1 (house-oz9.11): per-driver TTBR0 roots (slot -> root + ASID). The root
-- is mapping-only at S1 (never installed; access still from EL1) and becomes
-- the fault boundary in S2. Separate map so registering a root never changes
-- the driver insert/remove shape above; same lock ('drvSem' outermost).
{-# NOINLINE drvRoots #-}
drvRoots :: Ref (Map String (VM.PageMap, Word64))
drvRoots = unsafePerformH $ newRef Map.empty

{- | Record a driver root: the name must be registered, and at most one root
per name (a duplicate is a caller bug and fails closed).
-}
registerDriverRoot :: String -> VM.PageMap -> Word64 -> H (Either DriverError ())
registerDriverRoot name pm asid = withQSem drvSem $ do
  m <- readRef drvMap
  case Map.lookup name m of
    Nothing -> return (Left NotFound)
    Just _ -> do
      r <- readRef drvRoots
      if Map.member name r
        then return (Left AlreadyRegistered)
        else do
          writeRef drvRoots (Map.insert name (pm, asid) r)
          return (Right ())

-- | Look up a driver root.
lookupDriverRoot :: String -> H (Maybe (VM.PageMap, Word64))
lookupDriverRoot name = withQSem drvSem $ do
  r <- readRef drvRoots
  return (Map.lookup name r)

foreign import ccall unsafe "house_vm_map_mmio" c_map_mmio :: Ptr Word64 -> CInt -> IO CInt
foreign import ccall unsafe "house_asid_for_pdir" c_asid_for_pdir :: Ptr Word64 -> IO Word64

{- | S1 (house-oz9.11): build a driver's own TTBR0 root and map its
virtio-MMIO window into it (mapping only — the root is never installed here,
access still runs from EL1). Steps: validate the slot (the range check makes
the window arithmetic total), fresh root via 'VM.allocPageMap', Haskell-side
overlap check in the 'mapOneSegment' pattern (the Rust helper re-checks under
'VM_LOCK' and is the backstop), map via FFI, wire the ASID every EL0 root
shares, record (slot -> pdir/ASID).

Failure is fail-open and logged: the driver keeps running rootless (the root
is not load-bearing until S2) and no entry is recorded. A refused map leaks
the fresh root's three pages — S2 teardown frees driver roots.
-}
installDriverRoot :: String -> Int -> H Bool
installDriverRoot name slot
  | slot < 0 || slot > 31 = do
      Dmesg.dmesgLog ("driver root: bad slot " ++ show slot ++ " for " ++ name)
      return False
  | otherwise = do
      mpm <- VM.allocPageMap
      case mpm of
        Nothing -> do
          Dmesg.dmesgLog ("driver root: no pages for " ++ name)
          return False
        Just pm -> do
          let page = 0x0a000000 + fromIntegral slot * 0x200
              pageBase = page .&. complement 4095
          occupied <- VM.getPage pm pageBase
          case occupied of
            Just _ -> do
              Dmesg.dmesgLog ("driver root: window occupied for " ++ name)
              return False
            Nothing -> do
              rc <- liftIO (c_map_mmio (VM.fromPageMap pm) (fromIntegral slot))
              if rc /= 1
                then do
                  Dmesg.dmesgLog ("driver root: map refused slot " ++ show slot ++ " for " ++ name)
                  return False
                else do
                  asid <- liftIO (c_asid_for_pdir (VM.fromPageMap pm))
                  r <- registerDriverRoot name pm asid
                  case r of
                    Left _ -> do
                      Dmesg.dmesgLog ("driver root: duplicate for " ++ name)
                      return False
                    Right () -> do
                      Dmesg.dmesgLog ("driver root: " ++ name ++ " slot " ++ show slot ++ " asid " ++ show asid)
                      return True
