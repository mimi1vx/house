-- | Driver registry wrapping 'Kernel.IPC.Nameservice'.
-- Lock order: @drvSem@ outermost, @nsSem@ inner — never invert.
-- Endpoint table's @endpointSem@ only around queue splice, never across registry calls.
module Kernel.Driver.Registry
  ( registerDriver,
    unregisterDriver,
    lookupDriver,
    listDrivers,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import H.Concurrency (QSem, newQSem, withQSem)
import H.Interrupts (IntId)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import Kernel.Driver.Types (DriverError (..), DriverInfo (..), DriverKind)
import qualified Kernel.IPC.Nameservice as NS
import Kernel.IPC.Types (Endpoint)
import qualified Kernel.IPC.Types as IPC

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

-- | Register a driver: insert into 'drvMap' then 'nsRegister'. On 'NameExists'
-- roll back the 'drvMap' insert. Lock order @drvSem@ outermost, @nsSem@ inner:
-- validation runs outside sems, then @drvSem@ is held across 'nsRegister'
-- (which takes @nsSem@) to keep @drvMap@ and @nsMap@ consistent.
-- Note: 'NS.nsRegister' handles the global uniqueness check under @nsSem@;
-- we hold @drvSem@ across the call to keep @drvMap@ and @nsMap@ consistent
-- without inverting lock order — caller never holds @epSem@ here.
registerDriver :: String -> Endpoint -> Maybe IntId -> DriverKind -> H (Either DriverError ())
registerDriver name ep mIntId kind = case validDriverName name of
  Left e -> return (Left e)
  Right () -> withQSem drvSem $ do
    m <- readRef drvMap
    if Map.member name m
      then return (Left AlreadyRegistered)
      else do
        let info = DriverInfo name ep kind mIntId Nothing
        writeRef drvMap (Map.insert name info m)
        r <- NS.nsRegister name ep
        case r of
          Right () -> return (Right ())
          Left IPC.NameExists -> do
            -- rollback drvMap
            m2 <- readRef drvMap
            writeRef drvMap (Map.delete name m2)
            return (Left AlreadyRegistered)
          Left (IPC.InvalidName s) -> do
            m2 <- readRef drvMap
            writeRef drvMap (Map.delete name m2)
            return (Left (InvalidName s))
          Left _ -> do
            m2 <- readRef drvMap
            writeRef drvMap (Map.delete name m2)
            return (Left (InvalidName "nsRegister failed"))

-- | Unregister driver from both maps.
unregisterDriver :: String -> H (Either DriverError ())
unregisterDriver name = withQSem drvSem $ do
  m <- readRef drvMap
  case Map.lookup name m of
    Nothing -> return (Left NotFound)
    Just _ -> do
      writeRef drvMap (Map.delete name m)
      r <- NS.nsUnregister name
      case r of
        Right () -> return (Right ())
        Left IPC.NameNotFound -> return (Right ()) -- drvMap already cleared
        Left _ -> return (Right ())

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
