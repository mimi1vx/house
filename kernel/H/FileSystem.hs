{-# OPTIONS_GHC -Wno-unused-top-binds #-}

-- | Volatile RamFS over 'H.Pages' 512x4K pool.
-- Backed purely by 'H.Pages' ('P.Page Word8'); 2 MiB cap, no host I/O.
-- Single global root protected by one 'QSem' (matches 'H.Pages.pageSem' pattern).
module H.FileSystem
  ( FsError (..),
    FsStat (..),
    fsInit,
    fsCreate,
    fsMkdir,
    fsWrite,
    fsRead,
    fsLs,
    fsRm,
    fsStat,
    freePageCount,
  )
where

import Control.Monad (forM_)
import Data.Char (chr, ord)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64, Word8)
import H.AdHocMem (peek, plusPtr, poke)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import qualified H.Pages as P
import H.Unsafe (unsafePerformH)

-- | File-system errors, mapped to human strings in the shell.
data FsError
  = ENOENT
  | EEXIST
  | ENOTDIR
  | EISDIR
  | ENOSPC
  | EINVAL String
  deriving (Eq, Show)

-- | Stat result for 'fsStat'.
data FsStat = FsStat
  { fsIsDir :: Bool,
    fsSize :: Int,
    fsBlocks :: Int
  }
  deriving (Eq, Show)

-- | In-memory node. 'File' pages are 'P.validPage' and
-- length equals ceil(fileSize/4096).
data Node
  = File {filePages :: [P.Page Word8], fileSize :: Int, fileMtime :: Word64}
  | Dir {dirKids :: Map String Node}

-- Global root and semaphore. Matches 'H.Pages.freeList'/'pageSem' pattern.
{-# NOINLINE fsRoot #-}
fsRoot :: Ref Node
fsRoot = unsafePerformH $ newRef (Dir Map.empty)

{-# NOINLINE fsSem #-}
fsSem :: QSem
fsSem = unsafePerformH $ newQSem 1

-- | Re-export pool observability for IPC coexistence checks.
freePageCount :: H Int
freePageCount = P.freePageCount

-- Helpers --------------------------------------------------------------------

-- | Split and normalize a POSIX path. Drops leading '/', collapses '//',
-- resolves '.' and '..' without escaping root, rejects overlong names.
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

resolve :: [String] -> Node -> Maybe Node
resolve [] n = Just n
resolve (c : cs) (Dir kids) = case Map.lookup c kids of
  Nothing -> Nothing
  Just child -> resolve cs child
resolve _ (File _ _ _) = Nothing

updateAt :: [String] -> (Node -> Either FsError Node) -> Node -> Either FsError Node
updateAt [] f n = f n
updateAt (c : cs) f (Dir kids) = case Map.lookup c kids of
  Nothing -> Left ENOENT
  Just child -> case updateAt cs f child of
    Left e -> Left e
    Right child' -> Right (Dir (Map.insert c child' kids))
updateAt _ _ (File _ _ _) = Left ENOTDIR

freeNodePages :: Node -> H ()
freeNodePages (File ps _ _) = mapM_ P.freePage ps
freeNodePages (Dir kids) = mapM_ freeNodePages (Map.elems kids)

collectPages :: Node -> [P.Page Word8]
collectPages (File ps _ _) = ps
collectPages (Dir kids) = concatMap collectPages (Map.elems kids)

-- | Copy a String (treated as bytes via 'ord') into page list.
writeBytesToPages :: [P.Page Word8] -> String -> H ()
writeBytesToPages pages str = go pages bytes
  where
    bytes = map (fromIntegral . ord) str :: [Word8]
    go [] _ = return ()
    go (p : ps) bs = do
      P.zeroPage p
      let chunk = take 4096 bs
          rest = drop 4096 bs
      forM_ (zip [(0 :: Int) ..] chunk) $ \(i, b) ->
        poke (p `plusPtr` i) b
      go ps rest

readBytesFromPages :: [P.Page Word8] -> Int -> H String
readBytesFromPages pages sz = do
  bytes <- collect pages sz :: H [Word8]
  return (map (chr . fromIntegral) bytes)
  where
    collect [] _ = return []
    collect _ 0 = return []
    collect (p : ps) n = do
      let takeN = min n 4096
      chunk <- sequence [peek (p `plusPtr` i) :: H Word8 | i <- [0 .. takeN - 1]]
      rest <- collect ps (n - takeN)
      return (chunk ++ rest)

-- API ------------------------------------------------------------------------

-- | Reset root to empty, reclaiming any prior pages.
fsInit :: H ()
fsInit = do
  old <- withQSem fsSem $ do
    o <- readRef fsRoot
    writeRef fsRoot (Dir Map.empty)
    return o
  mapM_ P.freePage (collectPages old)

fsCreate :: FilePath -> H (Either FsError ())
fsCreate path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> case cs of
    [] -> return (Left (EINVAL "cannot create root"))
    _ -> withQSem fsSem $ do
      root <- readRef fsRoot
      let parentComps = init cs
          name = last cs
      case resolve parentComps root of
        Nothing -> return (Left ENOENT)
        Just (File _ _ _) -> return (Left ENOTDIR)
        Just (Dir kids) ->
          if Map.member name kids
            then return (Left EEXIST)
            else case updateAt
              parentComps
              ( \p -> case p of
                  Dir ks -> Right (Dir (Map.insert name (File [] 0 0) ks))
                  _ -> Left ENOTDIR
              )
              root of
              Left e -> return (Left e)
              Right nrt -> do writeRef fsRoot nrt; return (Right ())

fsMkdir :: FilePath -> H (Either FsError ())
fsMkdir path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> case cs of
    [] -> return (Left EEXIST)
    _ -> withQSem fsSem $ do
      root <- readRef fsRoot
      let parentComps = init cs
          name = last cs
      case resolve parentComps root of
        Nothing -> return (Left ENOENT)
        Just (File _ _ _) -> return (Left ENOTDIR)
        Just (Dir kids) ->
          if Map.member name kids
            then return (Left EEXIST)
            else case updateAt
              parentComps
              ( \p -> case p of
                  Dir ks -> Right (Dir (Map.insert name (Dir Map.empty) ks))
                  _ -> Left ENOTDIR
              )
              root of
              Left e -> return (Left e)
              Right nrt -> do writeRef fsRoot nrt; return (Right ())

-- | Truncate+overwrite. Creates file if missing. Returns 'ENOSPC' without
-- mutating FS if pool exhausted; frees excess pages on shrink.
fsWrite :: FilePath -> String -> H (Either FsError ())
fsWrite path content = case splitPath path of
  Left e -> return (Left e)
  Right cs -> case cs of
    [] -> return (Left EISDIR)
    _ -> do
      let n = length content
          needed = (n + 4095) `div` 4096
      mPages <- allocatePages needed
      case mPages of
        Nothing -> return (Left ENOSPC)
        Just newPages -> do
          writeBytesToPages newPages content
          result <- withQSem fsSem $ do
            root <- readRef fsRoot
            let parentComps = init cs
                name = last cs
            case resolve parentComps root of
              Nothing -> return (Left ENOENT)
              Just (File _ _ _) -> return (Left ENOTDIR)
              Just (Dir kids) -> case Map.lookup name kids of
                Just (Dir _) -> return (Left EISDIR)
                Just (File oldPages _ _) ->
                  case updateAt
                    parentComps
                    ( \p -> case p of
                        Dir ks -> Right (Dir (Map.insert name (File newPages n 0) ks))
                        _ -> Left ENOTDIR
                    )
                    root of
                    Left e -> return (Left e)
                    Right nrt -> do writeRef fsRoot nrt; return (Right (Just oldPages))
                Nothing ->
                  case updateAt
                    parentComps
                    ( \p -> case p of
                        Dir ks -> Right (Dir (Map.insert name (File newPages n 0) ks))
                        _ -> Left ENOTDIR
                    )
                    root of
                    Left e -> return (Left e)
                    Right nrt -> do writeRef fsRoot nrt; return (Right Nothing)
          case result of
            Left e -> do
              mapM_ P.freePage newPages
              return (Left e)
            Right Nothing -> return (Right ())
            Right (Just oldPages) -> do
              mapM_ P.freePage oldPages
              return (Right ())

allocatePages :: Int -> H (Maybe [P.Page Word8])
allocatePages 0 = return (Just [])
allocatePages k = go k []
  where
    go 0 acc = return (Just (reverse acc))
    go n acc = do
      mp <- P.allocPage
      case mp of
        Nothing -> do mapM_ P.freePage acc; return Nothing
        Just p -> go (n - 1) (p : acc)

fsRead :: FilePath -> H (Either FsError String)
fsRead path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> withQSem fsSem $ do
    root <- readRef fsRoot
    case resolve cs root of
      Nothing -> return (Left ENOENT)
      Just (Dir _) -> return (Left EISDIR)
      Just (File ps sz _) -> do
        s <- readBytesFromPages ps sz
        return (Right s)

fsLs :: FilePath -> H (Either FsError [String])
fsLs path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> withQSem fsSem $ do
    root <- readRef fsRoot
    case resolve cs root of
      Nothing -> return (Left ENOENT)
      Just (File _ _ _) -> return (Left ENOTDIR)
      Just (Dir kids) -> return (Right (Map.keys kids))

fsRm :: FilePath -> H (Either FsError ())
fsRm path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> case cs of
    [] -> return (Left (EINVAL "cannot remove root"))
    _ -> do
      res <- withQSem fsSem $ do
        root <- readRef fsRoot
        let parentComps = init cs
            name = last cs
        case resolve parentComps root of
          Nothing -> return (Left ENOENT :: Either FsError (Either FsError Node))
          Just (File _ _ _) -> return (Left ENOTDIR)
          Just (Dir kids) -> case Map.lookup name kids of
            Nothing -> return (Left ENOENT)
            Just (Dir dkids) ->
              if not (Map.null dkids)
                then return (Left (EINVAL "directory not empty"))
                else case updateAt
                  parentComps
                  ( \p -> case p of
                      Dir ks -> Right (Dir (Map.delete name ks))
                      _ -> Left ENOTDIR
                  )
                  root of
                  Left e -> return (Left e)
                  Right nrt -> do writeRef fsRoot nrt; return (Right (Right (Dir dkids)))
            Just f@(File _ _ _) ->
              case updateAt
                parentComps
                ( \p -> case p of
                    Dir ks -> Right (Dir (Map.delete name ks))
                    _ -> Left ENOTDIR
                )
                root of
                Left e -> return (Left e)
                Right nrt -> do writeRef fsRoot nrt; return (Right (Right f))
      case res of
        Left e -> return (Left e)
        Right (Left e) -> return (Left e)
        Right (Right node) -> do
          freeNodePages node
          return (Right ())

fsStat :: FilePath -> H (Either FsError FsStat)
fsStat path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> withQSem fsSem $ do
    root <- readRef fsRoot
    case resolve cs root of
      Nothing -> return (Left ENOENT)
      Just (Dir kids) -> return (Right (FsStat True 0 (Map.size kids)))
      Just (File _ sz _) -> return (Right (FsStat False sz ((sz + 4095) `div` 4096)))
