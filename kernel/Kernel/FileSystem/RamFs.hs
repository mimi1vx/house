{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}

{- | Volatile RamFS backend over 'H.Pages' 512x4K pool.

Pure 'H.Pages' backing, no host I/O. Single global root protected by
one 'QSem' (matches 'H.Pages.pageSem' pattern). Exposed as 'ramfsOps'
for the VFS switch; 'H.FileSystem' is a thin shim over the default
namespace.

Quota (defense-in-depth against hostile initrd starving the pager):
used pages are capped at 'quotaBytes' (10% of RAM, 16 MiB floor);
over-quota writes fail 'ENOSPC' without mutating the FS.
-}
module Kernel.FileSystem.RamFs (
  ramfsOps,
  ramfsInit,
  ramfsCreate,
  ramfsMkdir,
  ramfsWrite,
  ramfsRead,
  ramfsLs,
  ramfsRm,
  ramfsStat,
  ramfsFreePages,
  ramfsUsedPages,
  ramfsQuotaPages,
  ramfsSetQuotaPages,
  quotaPagesFor,
)
where

import Control.Monad (forM_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word64, Word8)
import Foreign.Ptr (Ptr)
import H.AdHocMem (peek, plusPtr, poke)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Pages qualified as P
import H.Unsafe (unsafePerformH)
import Kernel.Driver.Dmesg qualified as Dmesg
import Kernel.FileSystem.Vfs (FsError (..), FsOps (..), FsStat (..), splitPath)

-- Store ------------------------------------------------------------------------

{- | In-memory node. 'File' pages are 'P.validPage' and length equals
ceil(fileSize/4096).
-}
data Node
  = File [P.Page Word8] Int Word64
  | Dir (Map String Node)

{-# NOINLINE ramfsRoot #-}
ramfsRoot :: Ref Node
ramfsRoot = unsafePerformH $ newRef (Dir Map.empty)

{-# NOINLINE ramfsSem #-}
ramfsSem :: QSem
ramfsSem = unsafePerformH $ newQSem 1

-- Quota ------------------------------------------------------------------------

foreign import ccall unsafe "&house_ram_bytes" c_ram_ref :: Ptr Word64

-- | Pages currently consumed by RamFS files.
{-# NOINLINE ramfsUsedRef #-}
ramfsUsedRef :: Ref Int
ramfsUsedRef = unsafePerformH $ newRef 0

-- | Page quota from 'quotaPagesFor' at last 'ramfsInit'.
{-# NOINLINE ramfsQuotaRef #-}
ramfsQuotaRef :: Ref Int
ramfsQuotaRef = unsafePerformH $ newRef floorQuotaPages

-- | 16 MiB floor in pages.
floorQuotaPages :: Int
floorQuotaPages = (16 * 1024 * 1024) `div` 4096

{- | Page quota for a RAM size: 10% of RAM with a 16 MiB floor, no
ceiling. Pure for cabal tests (stub RAM 0 hits the floor).
-}
quotaPagesFor :: Word64 -> Int
quotaPagesFor ram = max floorQuotaPages (fromIntegral (ram `div` 10 `div` 4096))

-- | Snapshot of consumed pages.
ramfsUsedPages :: H Int
ramfsUsedPages = withQSem ramfsSem (readRef ramfsUsedRef)

-- | Snapshot of the page quota.
ramfsQuotaPages :: H Int
ramfsQuotaPages = withQSem ramfsSem (readRef ramfsQuotaRef)

-- | Override the page quota (tests; boot uses 'ramfsInit').
ramfsSetQuotaPages :: Int -> H ()
ramfsSetQuotaPages q = withQSem ramfsSem (writeRef ramfsQuotaRef (max 0 q))

countNodePages :: Node -> Int
countNodePages (File ps _ _) = length ps
countNodePages (Dir kids) = sum (map countNodePages (Map.elems kids))

-- | Re-export pool observability for IPC coexistence checks.
ramfsFreePages :: H Int
ramfsFreePages = P.freePageCount

resolve :: [String] -> Node -> Maybe Node
resolve [] n = Just n
resolve (c : cs) (Dir kids) = case Map.lookup c kids of
  Nothing -> Nothing
  Just child -> resolve cs child
resolve _ (File {}) = Nothing

updateAt :: [String] -> (Node -> Either FsError Node) -> Node -> Either FsError Node
updateAt [] f n = f n
updateAt (c : cs) f (Dir kids) = case Map.lookup c kids of
  Nothing -> Left ENOENT
  Just child -> case updateAt cs f child of
    Left e -> Left e
    Right child' -> Right (Dir (Map.insert c child' kids))
updateAt _ _ (File {}) = Left ENOTDIR

freeNodePages :: Node -> H ()
freeNodePages (File ps _ _) = mapM_ P.freePage ps
freeNodePages (Dir kids) = mapM_ freeNodePages (Map.elems kids)

collectPages :: Node -> [P.Page Word8]
collectPages (File ps _ _) = ps
collectPages (Dir kids) = concatMap collectPages (Map.elems kids)

-- | Copy bytes into the page list (zero-fill each page first).
writeBytesToPages :: [P.Page Word8] -> [Word8] -> H ()
writeBytesToPages = go
  where
    go [] _ = return ()
    go (p : ps) bs = do
      P.zeroPage p
      let chunk = take 4096 bs
          rest = drop 4096 bs
      forM_ (zip [(0 :: Int) ..] chunk) $ \(i, b) ->
        poke (p `plusPtr` i) b
      go ps rest

readBytesFromPages :: [P.Page Word8] -> Int -> H [Word8]
readBytesFromPages = collect
  where
    collect [] _ = return []
    collect _ 0 = return []
    collect (p : ps) n = do
      let takeN = min n 4096
      chunk <- sequence [peek (p `plusPtr` i) :: H Word8 | i <- [0 .. takeN - 1]]
      rest <- collect ps (n - takeN)
      return (chunk ++ rest)

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

-- Backend ops -------------------------------------------------------------------

-- | Reset root to empty, reclaiming any prior pages; recompute quota.
ramfsInit :: H ()
ramfsInit = do
  ram <- peek c_ram_ref
  old <- withQSem ramfsSem $ do
    o <- readRef ramfsRoot
    writeRef ramfsRoot (Dir Map.empty)
    writeRef ramfsUsedRef 0
    writeRef ramfsQuotaRef (quotaPagesFor ram)
    return o
  mapM_ P.freePage (collectPages old)

ramfsCreate :: FilePath -> H (Either FsError ())
ramfsCreate path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> case cs of
    [] -> return (Left (EINVAL "cannot create root"))
    _ -> withQSem ramfsSem $ do
      root <- readRef ramfsRoot
      let parentComps = init cs
          name = last cs
      case resolve parentComps root of
        Nothing -> return (Left ENOENT)
        Just (File {}) -> return (Left ENOTDIR)
        Just (Dir kids) ->
          if Map.member name kids
            then return (Left EEXIST)
            else case updateAt
              parentComps
              ( \case
                  Dir ks -> Right (Dir (Map.insert name (File [] 0 0) ks))
                  _ -> Left ENOTDIR
              )
              root of
              Left e -> return (Left e)
              Right nrt -> do writeRef ramfsRoot nrt; return (Right ())

ramfsMkdir :: FilePath -> H (Either FsError ())
ramfsMkdir path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> case cs of
    [] -> return (Left EEXIST)
    _ -> withQSem ramfsSem $ do
      root <- readRef ramfsRoot
      let parentComps = init cs
          name = last cs
      case resolve parentComps root of
        Nothing -> return (Left ENOENT)
        Just (File {}) -> return (Left ENOTDIR)
        Just (Dir kids) ->
          if Map.member name kids
            then return (Left EEXIST)
            else case updateAt
              parentComps
              ( \case
                  Dir ks -> Right (Dir (Map.insert name (Dir Map.empty) ks))
                  _ -> Left ENOTDIR
              )
              root of
              Left e -> return (Left e)
              Right nrt -> do writeRef ramfsRoot nrt; return (Right ())

{- | Truncate+overwrite. Creates file if missing. Returns 'ENOSPC' without
mutating FS if pool exhausted or the RamFS page quota is exceeded
(refusals are logged); frees excess pages on shrink.
-}
ramfsWrite :: FilePath -> [Word8] -> H (Either FsError ())
ramfsWrite path content = case splitPath path of
  Left e -> return (Left e)
  Right cs -> case cs of
    [] -> return (Left EISDIR)
    _ -> do
      let n = length content
          needed = (n + 4095) `div` 4096
      early <- withQSem ramfsSem $ do
        root <- readRef ramfsRoot
        used <- readRef ramfsUsedRef
        quota <- readRef ramfsQuotaRef
        return (used + needed - replacedPages cs root > quota)
      if early
        then do
          Dmesg.dmesgLog ("ramfs quota refuse: " ++ show n ++ " bytes")
          return (Left ENOSPC)
        else do
          mPages <- allocatePages needed
          case mPages of
            Nothing -> return (Left ENOSPC)
            Just newPages -> do
              writeBytesToPages newPages content
              result <- withQSem ramfsSem $ do
                root <- readRef ramfsRoot
                used <- readRef ramfsUsedRef
                quota <- readRef ramfsQuotaRef
                let parentComps = init cs
                    name = last cs
                case resolve parentComps root of
                  Nothing -> return (Left ENOENT)
                  Just (File {}) -> return (Left ENOTDIR)
                  Just (Dir kids) -> case Map.lookup name kids of
                    Just (Dir _) -> return (Left EISDIR)
                    Just (File oldPages _ _) ->
                      if used + needed - length oldPages > quota
                        then return (Left ENOSPC)
                        else case updateAt
                          parentComps
                          ( \case
                              Dir ks -> Right (Dir (Map.insert name (File newPages n 0) ks))
                              _ -> Left ENOTDIR
                          )
                          root of
                          Left e -> return (Left e)
                          Right nrt -> do
                            writeRef ramfsRoot nrt
                            writeRef ramfsUsedRef (used + needed - length oldPages)
                            return (Right (Just oldPages))
                    Nothing ->
                      if used + needed > quota
                        then return (Left ENOSPC)
                        else case updateAt
                          parentComps
                          ( \case
                              Dir ks -> Right (Dir (Map.insert name (File newPages n 0) ks))
                              _ -> Left ENOTDIR
                          )
                          root of
                          Left e -> return (Left e)
                          Right nrt -> do
                            writeRef ramfsRoot nrt
                            writeRef ramfsUsedRef (used + needed)
                            return (Right Nothing)
              case result of
                Left ENOSPC -> do
                  mapM_ P.freePage newPages
                  Dmesg.dmesgLog ("ramfs quota refuse: " ++ show n ++ " bytes")
                  return (Left ENOSPC)
                Left e -> do
                  mapM_ P.freePage newPages
                  return (Left e)
                Right Nothing -> return (Right ())
                Right (Just oldPages) -> do
                  mapM_ P.freePage oldPages
                  return (Right ())

-- | Page count of the file an overwrite would replace (0 for new paths).
replacedPages :: [String] -> Node -> Int
replacedPages cs root = case resolve (init cs) root of
  Nothing -> 0
  Just (File {}) -> 0
  Just (Dir kids) -> case Map.lookup (last cs) kids of
    Just (File ps _ _) -> length ps
    _ -> 0

ramfsRead :: FilePath -> H (Either FsError [Word8])
ramfsRead path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> withQSem ramfsSem $ do
    root <- readRef ramfsRoot
    case resolve cs root of
      Nothing -> return (Left ENOENT)
      Just (Dir _) -> return (Left EISDIR)
      Just (File ps sz _) -> do
        bs <- readBytesFromPages ps sz
        return (Right bs)

ramfsLs :: FilePath -> H (Either FsError [String])
ramfsLs path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> withQSem ramfsSem $ do
    root <- readRef ramfsRoot
    case resolve cs root of
      Nothing -> return (Left ENOENT)
      Just (File {}) -> return (Left ENOTDIR)
      Just (Dir kids) -> return (Right (Map.keys kids))

ramfsRm :: FilePath -> H (Either FsError ())
ramfsRm path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> case cs of
    [] -> return (Left (EINVAL "cannot remove root"))
    _ -> do
      res <- withQSem ramfsSem $ do
        root <- readRef ramfsRoot
        let parentComps = init cs
            name = last cs
        case resolve parentComps root of
          Nothing -> return (Left ENOENT :: Either FsError (Either FsError Node))
          Just (File {}) -> return (Left ENOTDIR)
          Just (Dir kids) -> case Map.lookup name kids of
            Nothing -> return (Left ENOENT)
            Just (Dir dkids) ->
              if not (Map.null dkids)
                then return (Left (EINVAL "directory not empty"))
                else case updateAt
                  parentComps
                  ( \case
                      Dir ks -> Right (Dir (Map.delete name ks))
                      _ -> Left ENOTDIR
                  )
                  root of
                  Left e -> return (Left e)
                  Right nrt -> do writeRef ramfsRoot nrt; return (Right (Right (Dir dkids)))
            Just f@(File {}) ->
              case updateAt
                parentComps
                ( \case
                    Dir ks -> Right (Dir (Map.delete name ks))
                    _ -> Left ENOTDIR
                )
                root of
                Left e -> return (Left e)
                Right nrt -> do
                  writeRef ramfsRoot nrt
                  used <- readRef ramfsUsedRef
                  writeRef ramfsUsedRef (max 0 (used - countNodePages f))
                  return (Right (Right f))
      case res of
        Left e -> return (Left e)
        Right (Left e) -> return (Left e)
        Right (Right node) -> do
          freeNodePages node
          return (Right ())

ramfsStat :: FilePath -> H (Either FsError FsStat)
ramfsStat path = case splitPath path of
  Left e -> return (Left e)
  Right cs -> withQSem ramfsSem $ do
    root <- readRef ramfsRoot
    case resolve cs root of
      Nothing -> return (Left ENOENT)
      Just (Dir kids) -> return (Right (FsStat True 0 (Map.size kids)))
      Just (File _ sz _) -> return (Right (FsStat False sz ((sz + 4095) `div` 4096)))

-- | Backend record for the VFS switch.
ramfsOps :: FsOps
ramfsOps =
  FsOps {
    opsInit = ramfsInit
    , opsCreate = ramfsCreate
    , opsMkdir = ramfsMkdir
    , opsWrite = ramfsWrite
    , opsRead = ramfsRead
    , opsLs = ramfsLs
    , opsRm = ramfsRm
    , opsStat = ramfsStat
    }
