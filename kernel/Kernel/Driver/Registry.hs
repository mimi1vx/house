{- | Driver registry wrapping 'Kernel.IPC.Nameservice'.
Lock order: @drvSem@ outermost, @nsSem@ inner — never invert.
Endpoint table's @endpointSem@ only around queue splice, never across registry calls:
teardown snapshots the endpoint list under @drvSem@, releases, then clears IRQ
forwarding, then frees (each @freeEndpoint@ takes @endpointSem@ on its own), then
stops the service threads. A thread blocked in @recv@ on a freed endpoint observes
@NoSuchEndpoint@ and exits, so freeing before stopping keeps the stop bounded.
-}
module Kernel.Driver.Registry (
  registerDriver,
  unregisterDriver,
  lookupDriver,
  listDrivers,
)
where

import Control.Concurrent (ThreadId)
import Control.Exception (onException)
import Data.Foldable (forM_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import H.Concurrency (QSem, killH, newQSem, withQSem)
import H.Interrupts (IntId)
import H.Monad (H, liftIO, runH)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import Kernel.Driver.IRQ qualified as DIRQ
import Kernel.Driver.Types (DriverError (..), DriverInfo (..), DriverKind)
import Kernel.IPC.Endpoint qualified as IPC
import Kernel.IPC.Nameservice qualified as NS
import Kernel.IPC.Types (Endpoint)
import Kernel.IPC.Types qualified as IPCType

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
The service thread id and endpoint list ride along so teardown can drop
endpoints then stop the thread.
-}
registerDriver :: String -> Endpoint -> Maybe IntId -> DriverKind -> Maybe ThreadId -> [Endpoint] -> H (Either DriverError ())
registerDriver name ep mIntId kind mService endpoints = case validDriverName name of
  Left e -> return (Left e)
  Right () -> withQSem drvSem $ do
    m <- readRef drvMap
    if Map.member name m
      then return (Left AlreadyRegistered)
      else do
        let info = DriverInfo name ep kind mIntId Nothing mService endpoints
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
        return (Just info)
  case mInfo of
    Nothing -> return (Left NotFound)
    Just info -> do
      -- Before the free, not after: a handler still installed would trySend
      -- into the endpoint this call is about to drop.
      forM_ (diIntId info) DIRQ.unregisterIrqForwarding
      mapM_ IPC.freeEndpoint (diEndpoints info)
      forM_ (diService info) killH
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
