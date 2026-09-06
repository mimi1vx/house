-- | Well-known name registry (String -> Endpoint) + delegatable caps.
-- Names ≤255, no empty or '/' per H.FileSystem.splitPath style.
-- Lock order: nsSem -> epSem (never hold epSem across nsRegister).
-- Capability slice (Track S, log-only): 'nsLookupChecked' runs 'checkCap'
-- (dmesg on mismatch, still allows) so violations are visible pre-deny.
module Kernel.IPC.Nameservice
  ( nsRegister,
    nsLookup,
    nsLookupChecked,
    nsUnregister,
    nsList,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import qualified Kernel.Driver.Dmesg as Dmesg
import Kernel.IPC.Endpoint (CapToken, checkCap)
import Kernel.IPC.Types (Endpoint, IpcError (..))

{-# NOINLINE nsMap #-}
nsMap :: Ref (Map String Endpoint)
nsMap = unsafePerformH $ newRef Map.empty

{-# NOINLINE nsSem #-}
nsSem :: QSem
nsSem = unsafePerformH $ newQSem 1

-- | Validate name: non-empty, ≤255, no '/' .
validName :: String -> Either IpcError ()
validName s
  | null s = Left (InvalidName "empty name")
  | length s > 255 = Left (InvalidName "name too long")
  | '/' `elem` s = Left (InvalidName "name contains '/'")
  | otherwise = Right ()

-- | Register well-known name. Returns Left NameExists if occupied.
nsRegister :: String -> Endpoint -> H (Either IpcError ())
nsRegister name ep = case validName name of
  Left e -> return (Left e)
  Right () -> withQSem nsSem $ do
    m <- readRef nsMap
    if Map.member name m
      then return (Left NameExists)
      else do
        writeRef nsMap (Map.insert name ep m)
        return (Right ())

-- | Lookup endpoint by name.
nsLookup :: String -> H (Maybe Endpoint)
nsLookup name = withQSem nsSem $ do
  m <- readRef nsMap
  return (Map.lookup name m)

-- | Checked lookup: miss logs to dmesg (maps to NoSuchEndpoint at the trap
-- boundary); hit runs 'checkCap' (log-only, still allows on mismatch).
nsLookupChecked :: String -> Maybe CapToken -> H (Either IpcError Endpoint)
nsLookupChecked name mtok = do
  mep <- nsLookup name
  case mep of
    Nothing -> do Dmesg.dmesgLog ("ns miss: " ++ take 64 name); return (Left NameNotFound)
    Just ep -> do _ <- checkCap ep mtok; return (Right ep)

-- | Unregister name.
nsUnregister :: String -> H (Either IpcError ())
nsUnregister name = withQSem nsSem $ do
  m <- readRef nsMap
  if Map.member name m
    then do writeRef nsMap (Map.delete name m); return (Right ())
    else return (Left NameNotFound)

-- | List all registered names.
nsList :: H [String]
nsList = withQSem nsSem $ do
  m <- readRef nsMap
  return (Map.keys m)
