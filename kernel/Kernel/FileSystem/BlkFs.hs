{-# LANGUAGE GHC2024 #-}

{- | Block-backed filesystem backend over virtio-blk HFS1 images.

Each 'blkfsOps slot' presents the image in that slot as an 'FsOps'
via load-modify-store: validate header + capacity before further
reads (hostile declared count\/total cannot drive unbounded reads),
decode fully before mutating anything (rejected images leave prior
contents intact), then write data blocks first and the superblock
last. Fresh (all-zero block 0) slots read as an empty filesystem;
any other corrupt header surfaces @EINVAL "bad image: ..."@.

Empty directories are session-local (HFS1 stores files only, same as
'BlkPersist' collect\/restore today): an in-memory per-slot dir
cache makes @mkdir \/a && mkdir \/a\/b@ work within a session, but
a sync\/mount round-trip with no files under @\/a@ drops it.
-}
module Kernel.FileSystem.BlkFs (
  blkfsCheck,
  blkfsOps,
  blkfsSave,
  blkfsRestore,
)
where

import Data.Either (fromRight)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Word (Word8)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import Kernel.FileSystem.BlkPersist qualified as BP
import Kernel.FileSystem.BlockDev (BlockDev (..))
import Kernel.FileSystem.Vfs (
  FsError (..),
  FsOps (..),
  FsStat (..),
  defaultNamespace,
  splitPath,
  vfsInit,
  vfsLs,
  vfsMkdir,
  vfsRead,
  vfsStat,
  vfsWrite,
 )

-- Session-local empty-dir cache per slot ---------------------------------------

{-# NOINLINE blkDirCache #-}
blkDirCache :: Ref (Map Int [[String]])
blkDirCache = unsafePerformH $ newRef Map.empty

{-# NOINLINE blkDirSem #-}
blkDirSem :: QSem
blkDirSem = unsafePerformH $ newQSem 1

rememberDir :: Int -> [String] -> H ()
rememberDir slot comps = withQSem blkDirSem $ do
  m <- readRef blkDirCache
  let cur = fromMaybe [] (Map.lookup slot m)
  if comps `elem` cur
    then return ()
    else writeRef blkDirCache (Map.insert slot (comps : cur) m)

cachedDirs :: Int -> H [[String]]
cachedDirs slot = withQSem blkDirSem $ do
  m <- readRef blkDirCache
  case Map.lookup slot m of
    Nothing -> return []
    Just ds -> return ds

-- Image I/O ---------------------------------------------------------------------

isZeroBlock :: [Word8] -> Bool
isZeroBlock = all (== 0)

{- | Load and decode the slot image. All-zero block 0 reads as empty.
Header (magic + version + caps + total) is validated from block 0
and total is checked against device capacity before any further
block is read, so hostile lengths cannot drive unbounded reads.
-}
loadFiles :: BlockDev -> Int -> H (Either FsError [(FilePath, [Word8])])
loadFiles bd slot = do
  r0 <- bdRead bd slot 0
  case r0 of
    Left e -> return (Left e)
    Right b0
      | isZeroBlock (take 4096 b0) -> return (Right [])
      | otherwise -> case BP.headerTotal b0 of
          Left s -> return (Left (EINVAL ("bad image: " ++ s)))
          Right total -> do
            eCap <- bdCapacity bd slot
            case eCap of
              Left e -> return (Left e)
              Right capSectors -> do
                let blkBlocks = fromIntegral (capSectors `div` 8) :: Int
                    need = (total + 4095) `div` 4096
                if need <= 0 || need > blkBlocks
                  then return (Left (EINVAL "bad image: capacity"))
                  else do
                    eRest <- readBlocks slot 1 (need - 1)
                    case eRest of
                      Left e -> return (Left e)
                      Right rest ->
                        let img = take total (b0 ++ concat rest)
                         in case BP.decodeImage img of
                              Left s -> return (Left (EINVAL ("bad image: " ++ s)))
                              Right files -> return (Right files)
  where
    readBlocks :: Int -> Int -> Int -> H (Either FsError [[Word8]])
    readBlocks _ _ 0 = return (Right [])
    readBlocks s lba n = do
      r <- bdRead bd s (fromIntegral lba)
      case r of
        Left e -> return (Left e)
        Right b -> do
          rest <- readBlocks s (lba + 1) (n - 1)
          case rest of
            Left e -> return (Left e)
            Right bs -> return (Right (b : bs))

-- | Encode and store, data blocks first and superblock last.
storeFiles :: BlockDev -> Int -> [(FilePath, [Word8])] -> H (Either FsError ())
storeFiles bd slot files = case BP.encodeImage files of
  Left s -> return (Left (EINVAL s))
  Right img -> do
    eCap <- bdCapacity bd slot
    case eCap of
      Left e -> return (Left e)
      Right capSectors -> do
        let blkBlocks = fromIntegral (capSectors `div` 8) :: Int
            need = (length img + 4095) `div` 4096
        if need > blkBlocks || need == 0
          then return (Left (EINVAL "capacity"))
          else do
            let chunks = chunk4096 img
            r1 <- writeBlocks slot 1 (drop 1 chunks)
            case r1 of
              Left e -> return (Left e)
              Right () -> case chunks of
                [] -> return (Left (EINVAL "empty"))
                (b0 : _) -> do
                  r0 <- bdWrite bd slot 0 b0
                  case r0 of
                    Left e -> return (Left e)
                    Right () -> return (Right ())
  where
    chunk4096 bs
      | null bs = []
      | otherwise = take 4096 (bs ++ repeat 0) : chunk4096 (drop 4096 bs)
    writeBlocks :: Int -> Int -> [[Word8]] -> H (Either FsError ())
    writeBlocks _ _ [] = return (Right ())
    writeBlocks s lba (b : rest) = do
      r <- bdWrite bd s (fromIntegral lba) b
      case r of
        Left e -> return (Left e)
        Right () -> writeBlocks s (lba + 1) rest

-- Pure file-list ops ---------------------------------------------------------------

type Image = [(FilePath, [Word8])]

pathComps :: FilePath -> Either FsError [String]
pathComps = splitPath

fileAt :: Image -> [String] -> Maybe [Word8]
fileAt files comps = lookup (render comps) files
  where
    render [] = "/"
    render cs = "/" ++ joinWith "/" cs
    joinWith _ [] = ""
    joinWith _ [x] = x
    joinWith s (x : xs) = x ++ s ++ joinWith s xs

dirExists :: Image -> [[String]] -> [String] -> Bool
dirExists files cached comps =
  null comps || comps `elem` cached || any ((comps `isPrefixOf`) . fst) fileComps
  where
    fileComps = [(pcs, bs) | (p, bs) <- files, let pcs = fromRight [] (splitPath p)]
    isPrefixOf [] _ = True
    isPrefixOf _ [] = False
    isPrefixOf (x : xs) (y : ys) = x == y && isPrefixOf xs ys

parentComps :: [String] -> [String]
parentComps [] = []
parentComps cs = init cs

-- VFS-aware persist (default namespace) --------------------------------------------

-- | Save the default-namespace RamFS into a blk slot (superblock last).
blkfsSave :: BlockDev -> Int -> H (Either FsError ())
blkfsSave bd slot = do
  eFiles <- collectVfs ["/"] []
  case eFiles of
    Left e -> return (Left e)
    Right files -> do
      r <- storeFiles bd slot files
      case r of
        Left (EINVAL "capacity") -> return (Left (EINVAL "capacity"))
        other -> return other
  where
    collectVfs [] acc = return (Right acc)
    collectVfs (dir : stack) acc = do
      eLs <- vfsLs defaultNamespace dir
      case eLs of
        Left e -> return (Left e)
        Right names -> do
          r <- walkNames dir names
          case r of
            Left e -> return (Left e)
            Right (files, dirs) -> collectVfs (dirs ++ stack) (acc ++ files)
    walkNames _ [] = return (Right ([], []))
    walkNames dir (n : ns) = do
      let full = if dir == "/" then "/" ++ n else dir ++ "/" ++ n
      eSt <- vfsStat defaultNamespace full
      case eSt of
        Left e -> return (Left e)
        Right st ->
          if fsIsDir st
            then do
              r <- walkNames dir ns
              case r of
                Left e -> return (Left e)
                Right (fs, ds) -> return (Right (fs, full : ds))
            else do
              eR <- vfsRead defaultNamespace full
              case eR of
                Left e -> return (Left e)
                Right bs -> do
                  r <- walkNames dir ns
                  case r of
                    Left e -> return (Left e)
                    Right (fs, ds) -> return (Right ((full, bs) : fs, ds))

{- | Restore a blk slot into the default namespace. Validates fully
before clearing, so rejected images leave ramfs intact.
-}
blkfsRestore :: BlockDev -> Int -> H (Either FsError ())
blkfsRestore bd slot = do
  eFiles <- loadFiles bd slot
  case eFiles of
    Left e -> return (Left e)
    Right files -> do
      _ <- vfsInit defaultNamespace
      go files
  where
    go [] = return (Right ())
    go ((p, bs) : rest) = do
      mapM_ ensureDir (parentDirs p)
      r <- vfsWrite defaultNamespace p bs
      case r of
        Left e -> return (Left e)
        Right () -> go rest
    parentDirs p =
      let parts = filter (not . null) (splitOn '/' p)
       in ["/" ++ joinWith "/" (take i parts) | i <- [1 .. length parts - 1]]
    splitOn _ [] = [""]
    splitOn c (x : xs)
      | x == c = "" : splitOn c xs
      | otherwise = case splitOn c xs of
          [] -> [[x]]
          (h : t) -> (x : h) : t
    joinWith _ [] = ""
    joinWith _ [x] = x
    joinWith s (x : xs) = x ++ s ++ joinWith s xs
    ensureDir d = do
      _ <- vfsMkdir defaultNamespace d
      return ()

-- Backend record --------------------------------------------------------------------

-- | Validate and decode a slot before publishing it as a mounted root.
blkfsCheck :: BlockDev -> Int -> H (Either FsError ())
blkfsCheck bd slot = either Left (const (Right ())) <$> loadFiles bd slot

-- | Block-backed 'FsOps' for one slot.
blkfsOps :: BlockDev -> Int -> FsOps
blkfsOps bd slot =
  FsOps {
    opsInit = return ()
    , opsCreate = blkCreate bd slot
    , opsMkdir = blkMkdir bd slot
    , opsWrite = blkWrite bd slot
    , opsRead = blkRead bd slot
    , opsLs = blkLs bd slot
    , opsRm = blkRm bd slot
    , opsStat = blkStat bd slot
    }

blkCreate :: BlockDev -> Int -> FilePath -> H (Either FsError ())
blkCreate bd slot path = case pathComps path of
  Left e -> return (Left e)
  Right [] -> return (Left (EINVAL "cannot create root"))
  Right cs -> do
    eFiles <- loadFiles bd slot
    case eFiles of
      Left e -> return (Left e)
      Right files -> do
        cached <- cachedDirs slot
        let parent = parentComps cs
        case fileAt files parent of
          Just _ -> return (Left ENOTDIR)
          Nothing
            | not (dirExists files cached parent) -> return (Left ENOENT)
            | isJust (fileAt files cs) || cs `elem` cached -> return (Left EEXIST)
            | otherwise -> storeFiles bd slot ((render cs, []) : files)
  where
    render [] = "/"
    render xs = "/" ++ joinWith "/" xs
    joinWith _ [] = ""
    joinWith _ [x] = x
    joinWith s (x : xs) = x ++ s ++ joinWith s xs

blkMkdir :: BlockDev -> Int -> FilePath -> H (Either FsError ())
blkMkdir bd slot path = case pathComps path of
  Left e -> return (Left e)
  Right [] -> return (Left EEXIST)
  Right cs -> do
    eFiles <- loadFiles bd slot
    case eFiles of
      Left e -> return (Left e)
      Right files -> do
        cached <- cachedDirs slot
        let parent = parentComps cs
        case fileAt files parent of
          Just _ -> return (Left ENOTDIR)
          Nothing
            | not (dirExists files cached parent) -> return (Left ENOENT)
            | isJust (fileAt files cs) || cs `elem` cached -> return (Left EEXIST)
            | otherwise -> do
                rememberDir slot cs
                return (Right ())

blkWrite :: BlockDev -> Int -> FilePath -> [Word8] -> H (Either FsError ())
blkWrite bd slot path content = case pathComps path of
  Left e -> return (Left e)
  Right [] -> return (Left EISDIR)
  Right cs -> do
    eFiles <- loadFiles bd slot
    case eFiles of
      Left e -> return (Left e)
      Right files -> do
        cached <- cachedDirs slot
        let parent = parentComps cs
        case fileAt files parent of
          Just _ -> return (Left ENOTDIR)
          Nothing
            | not (dirExists files cached parent) -> return (Left ENOENT)
            | otherwise -> case fileAt files cs of
                Just _ | cs `elem` cached -> return (Left EISDIR)
                _ ->
                  let without = filter (\(p, _) -> p /= render cs) files
                   in storeFiles bd slot ((render cs, content) : without)
  where
    render [] = "/"
    render xs = "/" ++ joinWith "/" xs
    joinWith _ [] = ""
    joinWith _ [x] = x
    joinWith s (x : xs) = x ++ s ++ joinWith s xs

blkRead :: BlockDev -> Int -> FilePath -> H (Either FsError [Word8])
blkRead bd slot path = case pathComps path of
  Left e -> return (Left e)
  Right cs -> do
    eFiles <- loadFiles bd slot
    case eFiles of
      Left e -> return (Left e)
      Right files -> do
        cached <- cachedDirs slot
        case fileAt files cs of
          Just bs -> return (Right bs)
          Nothing
            | null cs || cs `elem` cached || any ((cs `isPrefixOf`) . fst) (filesComps files) -> return (Left EISDIR)
            | otherwise -> return (Left ENOENT)
  where
    filesComps files = [(fromRight [] (splitPath p), bs) | (p, bs) <- files]
    isPrefixOf [] _ = True
    isPrefixOf _ [] = False
    isPrefixOf (x : xs) (y : ys) = x == y && isPrefixOf xs ys

blkLs :: BlockDev -> Int -> FilePath -> H (Either FsError [String])
blkLs bd slot path = case pathComps path of
  Left e -> return (Left e)
  Right cs -> do
    eFiles <- loadFiles bd slot
    case eFiles of
      Left e -> return (Left e)
      Right files -> do
        cached <- cachedDirs slot
        case fileAt files cs of
          Just _ -> return (Left ENOTDIR)
          Nothing
            | not (dirExists files cached cs) -> return (Left ENOENT)
            | otherwise -> return (Right (children files cached cs))
  where
    children files cached cs =
      let fcs = [fromRight [] (splitPath p) | (p, _) <- files]
          fromFiles = [x | pcs <- fcs, Just rest <- [stripPrefix cs pcs], (x : _) <- [rest]]
          fromCache = [x | ccs <- cached, Just rest <- [stripPrefix cs ccs], (x : _) <- [rest]]
       in dedup (fromFiles ++ fromCache)
    stripPrefix [] ys = Just ys
    stripPrefix _ [] = Nothing
    stripPrefix (x : xs) (y : ys)
      | x == y = stripPrefix xs ys
      | otherwise = Nothing
    dedup [] = []
    dedup (x : xs) = x : dedup (filter (/= x) xs)

blkRm :: BlockDev -> Int -> FilePath -> H (Either FsError ())
blkRm bd slot path = case pathComps path of
  Left e -> return (Left e)
  Right [] -> return (Left (EINVAL "cannot remove root"))
  Right cs -> do
    eFiles <- loadFiles bd slot
    case eFiles of
      Left e -> return (Left e)
      Right files -> do
        cached <- cachedDirs slot
        case fileAt files cs of
          Just _ ->
            let without = filter (\(p, _) -> p /= render cs) files
             in storeFiles bd slot without
          Nothing
            | cs `elem` cached || any ((cs `isStrictPrefixOf`) . fst) (filesComps files) ->
                let hasKids = any ((cs `isStrictPrefixOf`) . fst) (filesComps files)
                 in if hasKids
                      then return (Left (EINVAL "directory not empty"))
                      else do
                        withQSem blkDirSem $ do
                          m <- readRef blkDirCache
                          case Map.lookup slot m of
                            Nothing -> return ()
                            Just ds -> writeRef blkDirCache (Map.insert slot (filter (/= cs) ds) m)
                        return (Right ())
            | otherwise -> return (Left ENOENT)
  where
    render [] = "/"
    render xs = "/" ++ joinWith "/" xs
    joinWith _ [] = ""
    joinWith _ [x] = x
    joinWith s (x : xs) = x ++ s ++ joinWith s xs
    filesComps files = [(fromRight [] (splitPath p), ()) | (p, _) <- files]
    isStrictPrefixOf [] (_ : _) = True
    isStrictPrefixOf _ _ = False

blkStat :: BlockDev -> Int -> FilePath -> H (Either FsError FsStat)
blkStat bd slot path = case pathComps path of
  Left e -> return (Left e)
  Right cs -> do
    eFiles <- loadFiles bd slot
    case eFiles of
      Left e -> return (Left e)
      Right files -> do
        cached <- cachedDirs slot
        case fileAt files cs of
          Just bs -> return (Right (FsStat False (length bs) ((length bs + 4095) `div` 4096)))
          Nothing
            | dirExists files cached cs ->
                return (Right (FsStat True 0 (length (children files cached cs))))
            | otherwise -> return (Left ENOENT)
  where
    children files cached cs =
      let fcs = [fromRight [] (splitPath p) | (p, _) <- files]
          fromFiles = [x | pcs <- fcs, Just rest <- [stripPrefix cs pcs], (x : _) <- [rest]]
          fromCache = [x | ccs <- cached, Just rest <- [stripPrefix cs ccs], (x : _) <- [rest]]
       in dedup (fromFiles ++ fromCache)
    stripPrefix [] ys = Just ys
    stripPrefix _ [] = Nothing
    stripPrefix (x : xs) (y : ys)
      | x == y = stripPrefix xs ys
      | otherwise = Nothing
    dedup [] = []
    dedup (x : xs) = x : dedup (filter (/= x) xs)
