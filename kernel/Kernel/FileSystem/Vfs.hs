{-# LANGUAGE GHC2024 #-}

{- | Virtual filesystem switch with per-process mount namespaces.

Backends are 'FsOps' records of 'H' (hybrid model: Haskell ops now,
IPC Endpoint servers later). Mount tables live per namespace; longest
prefix wins inside the caller's namespace. Paths are total
('splitPath' confines @..@ to root, rejects overlong names), so a
backend never sees an escaping path.

Lock order: 'registrySem' is a leaf; it is never held across backend
ops (which take their own @fsSem@\/@blkSem@). Lookup snapshots
@(ops, relPath)@ under the lock, then invokes the backend unlocked.
Namespace copy copies descriptors only (the 'Mount' list), never a
walk of the user window.
-}
module Kernel.FileSystem.Vfs (
  FsError (..),
  FsStat (..),
  FsOps (..),
  Mount (..),
  MountTable,
  NamespaceId,
  defaultNamespace,
  splitPath,
  normalizeMount,
  resolvePrefix,
  joinRel,
  nsCreate,
  nsFork,
  vfsMount,
  vfsLookup,
  vfsEnsurePid,
  vfsForkPid,
  vfsReleasePid,
  vfsLookupPid,
  vfsInit,
  vfsCreate,
  vfsMkdir,
  vfsWrite,
  vfsRead,
  vfsReadBytes,
  vfsLs,
  vfsRm,
  vfsStat,
)
where

import Data.List (sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Word (Word8)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)

-- Types -----------------------------------------------------------------------

-- | File-system errors, mapped to human strings in the shell.
data FsError
  = ENOENT
  | EEXIST
  | ENOTDIR
  | EISDIR
  | ENOSPC
  | EINVAL String
  deriving (Eq, Show)

-- | Stat result.
data FsStat = FsStat {
  fsIsDir :: Bool
  , fsSize :: Int
  , fsBlocks :: Int
  }
  deriving (Eq, Show)

-- | Backend interface. Paths are backend-relative absolute paths.
data FsOps = FsOps {
  opsInit :: H ()
  , opsCreate :: FilePath -> H (Either FsError ())
  , opsMkdir :: FilePath -> H (Either FsError ())
  , opsWrite :: FilePath -> String -> H (Either FsError ())
  , opsRead :: FilePath -> H (Either FsError String)
  , opsReadBytes :: FilePath -> H (Either FsError [Word8])
  , opsLs :: FilePath -> H (Either FsError [String])
  , opsRm :: FilePath -> H (Either FsError ())
  , opsStat :: FilePath -> H (Either FsError FsStat)
  }

-- | One mount: normalized prefix plus backend ops.
data Mount = Mount {
  mountPrefix :: FilePath
  , mountPrefixComps :: [String]
  , mountOps :: FsOps
  }

-- | Longest-prefix-first mount list.
type MountTable = [Mount]

-- | Namespace identifier. 0 is the default (boot/shell) namespace.
type NamespaceId = Int

-- | Default namespace id.
defaultNamespace :: NamespaceId
defaultNamespace = 0

-- Pure path helpers ------------------------------------------------------------

{- | Split and normalize a POSIX path. Drops leading shamrock, collapses
@//@, resolves @.@ and @..@ without escaping root, rejects overlong names.
-}
splitPath :: String -> Either FsError [String]
splitPath s
  | null s = Left (EINVAL "empty path")
  | otherwise = go (splitOn '/' s) []
  where
    go [] acc = Right (reverse acc)
    go (c : cs) acc
      | null c = go cs acc
      | c == "." = go cs acc
      | c == ".." = case acc of
          [] -> go cs []
          (_ : xs) -> go cs xs
      | length c > 255 = Left (EINVAL "name too long")
      | otherwise = go cs (c : acc)

splitOn :: Char -> String -> [String]
splitOn d s = case break (== d) s of
  (pre, []) -> [pre]
  (pre, _ : rest) -> pre : splitOn d rest

-- | Validate a mount prefix. Must be absolute; normalized via 'splitPath'.
normalizeMount :: FilePath -> Either FsError [String]
normalizeMount p = case p of
  ('/' : _) -> splitPath p
  _ -> Left (EINVAL "mount prefix must be absolute")

-- | Render backend-relative comps as an absolute path.
joinRel :: [String] -> FilePath
joinRel [] = "/"
joinRel cs = "/" ++ joinWith "/" cs
  where
    joinWith _ [] = ""
    joinWith _ [x] = x
    joinWith s (x : xs) = x ++ s ++ joinWith s xs

-- | Longest-prefix match on comps. Prefixes are comp lists paired with a value.
resolvePrefix :: [([String], a)] -> [String] -> Maybe (a, [String])
resolvePrefix mounts comps = go sorted
  where
    sorted = sortBy (comparing (negate . length . fst)) mounts
    go [] = Nothing
    go ((pre, v) : rest)
      | pre `isPrefixOf` comps = Just (v, drop (length pre) comps)
      | otherwise = go rest
    isPrefixOf [] _ = True
    isPrefixOf _ [] = False
    isPrefixOf (x : xs) (y : ys) = x == y && isPrefixOf xs ys

-- Registry ---------------------------------------------------------------------

{-# NOINLINE nsTable #-}
nsTable :: Ref (Map NamespaceId MountTable)
nsTable = unsafePerformH $ newRef Map.empty

{-# NOINLINE nsNext #-}
nsNext :: Ref NamespaceId
nsNext = unsafePerformH $ newRef 1

{-# NOINLINE pidNs #-}
pidNs :: Ref (Map Int NamespaceId)
pidNs = unsafePerformH $ newRef Map.empty

{-# NOINLINE registrySem #-}
registrySem :: QSem
registrySem = unsafePerformH $ newQSem 1

-- | Create an empty namespace.
nsCreate :: H NamespaceId
nsCreate = withQSem registrySem $ do
  n <- readRef nsNext
  writeRef nsNext (n + 1)
  m <- readRef nsTable
  writeRef nsTable (Map.insert n [] m)
  return n

-- | Fork a namespace: copy the mount descriptor list (shallow; backends shared).
nsFork :: NamespaceId -> H NamespaceId
nsFork parent = withQSem registrySem $ do
  m <- readRef nsTable
  let table = fromMaybe [] (Map.lookup parent m)
  n <- readRef nsNext
  writeRef nsNext (n + 1)
  m2 <- readRef nsTable
  writeRef nsTable (Map.insert n table m2)
  return n

{- | Mount backend ops at an absolute prefix inside a namespace.
Replaces an existing mount at the same normalized prefix.
-}
vfsMount :: NamespaceId -> FilePath -> FsOps -> H (Either FsError ())
vfsMount ns prefix ops = case normalizeMount prefix of
  Left e -> return (Left e)
  Right comps -> withQSem registrySem $ do
    m <- readRef nsTable
    let table = fromMaybe [] (Map.lookup ns m)
        norm = joinRel comps
        without = filter (\mt -> mountPrefix mt /= norm) table
        entry = Mount norm comps ops
        sorted = sortBy (comparing (negate . length . mountPrefixComps)) (entry : without)
    writeRef nsTable (Map.insert ns sorted m)
    return (Right ())

-- | Resolve a full path inside a namespace to backend ops + relative path.
vfsLookup :: NamespaceId -> FilePath -> H (Either FsError (FsOps, FilePath))
vfsLookup ns path = case splitPath path of
  Left e -> return (Left e)
  Right comps -> withQSem registrySem $ do
    m <- readRef nsTable
    case Map.lookup ns m of
      Nothing -> return (Left ENOENT)
      Just table ->
        let pairs = map (\mt -> (mountPrefixComps mt, mountOps mt)) table
         in case resolvePrefix pairs comps of
              Nothing -> return (Left ENOENT)
              Just (ops, rel) -> return (Right (ops, joinRel rel))

-- | Ensure a pid has a namespace (defaults to sharing 'defaultNamespace').
vfsEnsurePid :: Int -> H NamespaceId
vfsEnsurePid pid = withQSem registrySem $ do
  m <- readRef pidNs
  case Map.lookup pid m of
    Just ns -> return ns
    Nothing -> do
      writeRef pidNs (Map.insert pid defaultNamespace m)
      return defaultNamespace

-- | Fork a pid's namespace for a child pid (copies descriptors only).
vfsForkPid :: Int -> Int -> H ()
vfsForkPid parentPid childPid = do
  parentNs <- vfsEnsurePid parentPid
  childNs <- nsFork parentNs
  withQSem registrySem $ do
    m <- readRef pidNs
    writeRef pidNs (Map.insert childPid childNs m)

-- | Release a pid's namespace binding (no backend teardown).
vfsReleasePid :: Int -> H ()
vfsReleasePid pid = withQSem registrySem $ do
  m <- readRef pidNs
  writeRef pidNs (Map.delete pid m)

-- | Resolve a path through a pid's namespace.
vfsLookupPid :: Int -> FilePath -> H (Either FsError (FsOps, FilePath))
vfsLookupPid pid path = do
  ns <- vfsEnsurePid pid
  vfsLookup ns path

-- VFS ops (default-namespace routing; lock never held across backend) ----------

-- | Init every backend mounted in the namespace.
vfsInit :: NamespaceId -> H ()
vfsInit ns = do
  ops <- withQSem registrySem $ do
    m <- readRef nsTable
    case Map.lookup ns m of
      Nothing -> return []
      Just table -> return (map mountOps table)
  mapM_ opsInit ops

vfsCreate :: NamespaceId -> FilePath -> H (Either FsError ())
vfsCreate ns path = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsCreate ops rel

vfsMkdir :: NamespaceId -> FilePath -> H (Either FsError ())
vfsMkdir ns path = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsMkdir ops rel

vfsWrite :: NamespaceId -> FilePath -> String -> H (Either FsError ())
vfsWrite ns path content = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsWrite ops rel content

vfsRead :: NamespaceId -> FilePath -> H (Either FsError String)
vfsRead ns path = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsRead ops rel

vfsReadBytes :: NamespaceId -> FilePath -> H (Either FsError [Word8])
vfsReadBytes ns path = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsReadBytes ops rel

vfsLs :: NamespaceId -> FilePath -> H (Either FsError [String])
vfsLs ns path = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsLs ops rel

vfsRm :: NamespaceId -> FilePath -> H (Either FsError ())
vfsRm ns path = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsRm ops rel

vfsStat :: NamespaceId -> FilePath -> H (Either FsError FsStat)
vfsStat ns path = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsStat ops rel
