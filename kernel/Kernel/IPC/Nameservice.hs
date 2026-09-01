-- | Well-known name registry (String -> Endpoint) + delegatable caps.
-- Names ≤255, no empty or '/' per H.FileSystem.splitPath style.
-- Lock order: nsSem -> epSem (never hold epSem across nsRegister).
module Kernel.IPC.Nameservice
  ( nsRegister,
    nsLookup,
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
