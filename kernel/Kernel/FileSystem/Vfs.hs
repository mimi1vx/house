{-# LANGUAGE GHC2024 #-}

{- | Virtual filesystem switch with per-process mount namespaces.

Backends are 'FsOps' records of 'H' (hybrid model: Haskell ops now,
IPC Endpoint servers later). Mount tables live per namespace; longest
prefix wins inside the caller's namespace. Paths are total
('splitPath' confines @..@ to root, rejects overlong names), so a
backend never sees an escaping path.

A prefix may carry several layers: 'vfsMount' replaces the prefix,
'vfsMountLayer' appends below it. 'vfsReadOverlay' walks the layers of
the longest matching prefix in order and stops at the first hit, while
ordinary ops use only the topmost layer.

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
  resolveLayers,
  joinRel,
  nsCreate,
  nsFork,
  vfsMount,
  vfsMountLayer,
  vfsLayerCount,
  vfsLookup,
  vfsEnsurePid,
  vfsBindPid,
  vfsForkPid,
  vfsReleasePid,
  vfsLookupPid,
  vfsInit,
  vfsCreate,
  vfsMkdir,
  vfsWrite,
  vfsRead,
  vfsReadOverlay,
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

{- | Backend interface. Paths are backend-relative absolute paths.
File content is bytes end-to-end; text encode/decode lives at the
shell edge only.
-}
data FsOps = FsOps {
  opsInit :: H ()
  , opsCreate :: FilePath -> H (Either FsError ())
  , opsMkdir :: FilePath -> H (Either FsError ())
  , opsWrite :: FilePath -> [Word8] -> H (Either FsError ())
  , opsRead :: FilePath -> H (Either FsError [Word8])
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
      | compIsPrefixOf pre comps = Just (v, drop (length pre) comps)
      | otherwise = go rest

-- | Segment-wise prefix test over normalized comp lists.
compIsPrefixOf :: [String] -> [String] -> Bool
compIsPrefixOf [] _ = True
compIsPrefixOf _ [] = False
compIsPrefixOf (x : xs) (y : ys) = x == y && compIsPrefixOf xs ys

{- | Ordered read candidates for a path: every layer at the longest
matching prefix, topmost first. The table is longest-prefix sorted, so
the first match fixes the routing boundary; a shorter prefix is never a
candidate, which keeps a miss under a nested mount from leaking into a
root layer.
-}
resolveLayers :: MountTable -> [String] -> [(FsOps, FilePath)]
resolveLayers table comps = case filter covers table of
  [] -> []
  top : rest -> map layer (top : takeWhile (samePrefix top) rest)
  where
    covers m = compIsPrefixOf (mountPrefixComps m) comps
    samePrefix a b = mountPrefixComps a == mountPrefixComps b
    layer m = (mountOps m, joinRel (drop (length (mountPrefixComps m)) comps))

{- | Insert a layer below the layers already mounted at the same prefix,
keeping the table longest-prefix sorted.
-}
insertLayer :: Mount -> MountTable -> MountTable
insertLayer entry = go
  where
    go [] = [entry]
    go (m : ms)
      | mountPrefixComps m == mountPrefixComps entry = m : insertBelow ms
      | length (mountPrefixComps m) < length (mountPrefixComps entry) = entry : m : ms
      | otherwise = m : go ms
    insertBelow [] = [entry]
    insertBelow (m : ms)
      | mountPrefixComps m == mountPrefixComps entry = m : insertBelow ms
      | otherwise = entry : m : ms

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
Replaces every layer at the same normalized prefix.
-}
vfsMount :: NamespaceId -> FilePath -> FsOps -> H (Either FsError ())
vfsMount ns prefix ops = case normalizeMount prefix of
  Left e -> return (Left e)
  Right comps -> withQSem registrySem $ do
    m <- readRef nsTable
    let table = fromMaybe [] (Map.lookup ns m)
        entry = Mount (joinRel comps) comps ops
        without = filter ((/= comps) . mountPrefixComps) table
    writeRef nsTable (Map.insert ns (insertLayer entry without) m)
    return (Right ())

{- | Append a layer below the ones already mounted at an absolute
prefix. Ordinary ops keep using the topmost layer; only
'vfsReadOverlay' walks the stack.
-}
vfsMountLayer :: NamespaceId -> FilePath -> FsOps -> H (Either FsError ())
vfsMountLayer ns prefix ops = case normalizeMount prefix of
  Left e -> return (Left e)
  Right comps -> withQSem registrySem $ do
    m <- readRef nsTable
    let table = fromMaybe [] (Map.lookup ns m)
        entry = Mount (joinRel comps) comps ops
    writeRef nsTable (Map.insert ns (insertLayer entry table) m)
    return (Right ())

-- | Number of layers stacked at an exact normalized prefix.
vfsLayerCount :: NamespaceId -> FilePath -> H Int
vfsLayerCount ns prefix = case normalizeMount prefix of
  Left _ -> return 0
  Right comps -> withQSem registrySem $ do
    m <- readRef nsTable
    let table = fromMaybe [] (Map.lookup ns m)
    return (length (filter ((== comps) . mountPrefixComps) table))

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

-- | Bind a newly allocated pid to an existing namespace.
vfsBindPid :: Int -> NamespaceId -> H Bool
vfsBindPid pid ns = withQSem registrySem $ do
  namespaces <- readRef nsTable
  bindings <- readRef pidNs
  if Map.notMember ns namespaces
    then return False
    else case Map.lookup pid bindings of
      Just existing | existing /= ns -> return False
      _ -> do
        writeRef pidNs (Map.insert pid ns bindings)
        return True

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

vfsWrite :: NamespaceId -> FilePath -> [Word8] -> H (Either FsError ())
vfsWrite ns path content = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsWrite ops rel content

vfsRead :: NamespaceId -> FilePath -> H (Either FsError [Word8])
vfsRead ns path = do
  r <- vfsLookup ns path
  case r of
    Left e -> return (Left e)
    Right (ops, rel) -> opsRead ops rel

{- | Read through every layer of the longest matching prefix, topmost
first. A layer is skipped only on 'ENOENT'; any other failure is
authoritative and stops the walk, so the caller fails closed.
-}
vfsReadOverlay :: NamespaceId -> FilePath -> H (Either FsError [Word8])
vfsReadOverlay ns path = case splitPath path of
  Left e -> return (Left e)
  Right comps -> do
    layers <- withQSem registrySem $ do
      m <- readRef nsTable
      return (resolveLayers (fromMaybe [] (Map.lookup ns m)) comps)
    readLayers layers

readLayers :: [(FsOps, FilePath)] -> H (Either FsError [Word8])
readLayers [] = return (Left ENOENT)
readLayers ((ops, rel) : rest) = do
  r <- opsRead ops rel
  case r of
    Left ENOENT -> readLayers rest
    other -> return other

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
