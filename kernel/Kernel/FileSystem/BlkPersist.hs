{-# LANGUAGE GHC2024 #-}

-- | RamFS <-> virtio-blk persistence. Volatile by default; explicit save/restore only.
module Kernel.FileSystem.BlkPersist
  ( PersistError (..),
    persistErrorToString,
    persistSave,
    persistRestore,
    encodeImage,
    decodeImage,
  )
where

import Data.Bits (shiftL, shiftR)
import Data.Char (chr, ord)
import Data.Word (Word32, Word8)
import H.FileSystem qualified as FS
import H.Monad (H)
import Kernel.Driver.Virtio.Blk.Server qualified as Blk
import Kernel.Driver.Virtio.Blk.Types (BlkError)

data PersistError
  = PersistBlk BlkError
  | PersistFs FS.FsError
  | PersistFormat String
  deriving (Eq, Show)

persistErrorToString :: PersistError -> String
persistErrorToString (PersistBlk _) = "blk I/O error"
persistErrorToString (PersistFs e) = "fs error: " ++ show e
persistErrorToString (PersistFormat s) = "bad image: " ++ s

maxImageBytes :: Int
maxImageBytes = 2 * 1024 * 1024

maxFiles :: Int
maxFiles = 4096

maxPathLen :: Int
maxPathLen = 1024

magic :: [Word8]
magic = [0x48, 0x46, 0x53, 0x31]

version :: Word8
version = 0x01

word32LE :: Word32 -> [Word8]
word32LE w =
  [ fromIntegral w,
    fromIntegral (w `shiftR` 8),
    fromIntegral (w `shiftR` 16),
    fromIntegral (w `shiftR` 24)
  ]

word16LE :: Int -> [Word8]
word16LE n = [fromIntegral n, fromIntegral (n `shiftR` 8)]

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

-- | Pure encode. Total; caps enforced before allocation.
encodeImage :: [(FilePath, [Word8])] -> Either String [Word8]
encodeImage files
  | length files > maxFiles = Left "too many files"
  | any badPath files = Left "bad path"
  | any (\(_, b) -> length b > maxImageBytes) files = Left "file too large"
  | otherwise =
      let body = concatMap encodeOne files
          total = 4 + 1 + 4 + 4 + length body
       in if total > maxImageBytes
            then Left "image too large"
            else Right (magic ++ [version] ++ word32LE (fromIntegral total) ++ word32LE (fromIntegral (length files)) ++ body)
  where
    badPath (p, _) = null p || length p > maxPathLen || safeHead p /= Just '/'
    encodeOne (p, bs) =
      let pb = map (fromIntegral . ord) p
       in word16LE (length pb) ++ pb ++ word32LE (fromIntegral (length bs)) ++ bs

safeIndex :: [Word8] -> Int -> Maybe Word8
safeIndex xs i
  | i < 0 || i >= length xs = Nothing
  | otherwise = Just (xs !! i)

getU32 :: Int -> [Word8] -> Maybe Int
getU32 off bs
  | off < 0 || off + 4 > length bs = Nothing
  | otherwise = case (safeIndex bs off, safeIndex bs (off + 1), safeIndex bs (off + 2), safeIndex bs (off + 3)) of
      (Just b0, Just b1, Just b2, Just b3) ->
        Just (fromIntegral b0 + (fromIntegral b1 `shiftL` 8) + (fromIntegral b2 `shiftL` 16) + (fromIntegral b3 `shiftL` 24))
      _ -> Nothing

getU16 :: Int -> [Word8] -> Maybe Int
getU16 off bs
  | off < 0 || off + 2 > length bs = Nothing
  | otherwise = case (safeIndex bs off, safeIndex bs (off + 1)) of
      (Just b0, Just b1) -> Just (fromIntegral b0 + (fromIntegral b1 `shiftL` 8))
      _ -> Nothing

-- | Pure decode. Total; corrupt magic yields Left, never a crash.
decodeImage :: [Word8] -> Either String [(FilePath, [Word8])]
decodeImage bytes
  | length bytes < 13 = Left "truncated header"
  | take 4 bytes /= magic = Left "bad magic"
  | safeIndex bytes 4 /= Just version = Left "bad version"
  | otherwise = case (getU32 5 bytes, getU32 9 bytes) of
      (Just total, Just nFiles)
        | total < 13 || total > maxImageBytes -> Left "bad total"
        | nFiles < 0 || nFiles > maxFiles -> Left "bad count"
        | length bytes < total -> Left "truncated body"
        | otherwise -> parseFiles (take total bytes) 13 nFiles []
      _ -> Left "truncated header"
  where
    parseFiles _ _ 0 acc = Right (reverse acc)
    parseFiles img off n acc = case getU16 off img of
      Nothing -> Left "truncated entry"
      Just plen
        | plen <= 0 || plen > maxPathLen -> Left "bad path len"
        | off + 2 + plen + 4 > length img -> Left "truncated entry"
        | otherwise ->
            let pbs = take plen (drop (off + 2) img)
                path = map (chr . fromIntegral) pbs
             in if null path || safeHead path /= Just '/' || any (== 0) pbs
                  then Left "bad path"
                  else case getU32 (off + 2 + plen) img of
                    Nothing -> Left "truncated entry"
                    Just flen
                      | flen < 0 || flen > maxImageBytes -> Left "bad file len"
                      | off + 2 + plen + 4 + flen > length img -> Left "truncated body"
                      | otherwise ->
                          let bs = take flen (drop (off + 2 + plen + 4) img)
                           in parseFiles img (off + 2 + plen + 4 + flen) (n - 1) ((path, bs) : acc)

-- | Save ramfs to blk slot. Writes data blocks first, superblock last.
persistSave :: Int -> H (Either PersistError ())
persistSave slot = do
  eFiles <- collectAll
  case eFiles of
    Left e -> return (Left (PersistFs e))
    Right files -> case encodeImage files of
      Left s -> return (Left (PersistFormat s))
      Right img -> do
        eCap <- Blk.blkGetCapacity slot
        case eCap of
          Left e -> return (Left (PersistBlk e))
          Right capSectors -> do
            let blkBlocks = fromIntegral (capSectors `div` 8) :: Int
                need = (length img + 4095) `div` 4096
            if need > blkBlocks || need == 0
              then return (Left (PersistFormat "capacity"))
              else do
                let chunks = chunk4096 img
                r1 <- writeBlocks slot 1 (drop 1 chunks)
                case r1 of
                  Left e -> return (Left (PersistBlk e))
                  Right () -> case chunks of
                    [] -> return (Left (PersistFormat "empty"))
                    (b0 : _) -> do
                      r0 <- Blk.blkWriteBlockBytes slot 0 b0
                      case r0 of
                        Left e -> return (Left (PersistBlk e))
                        Right () -> return (Right ())
  where
    chunk4096 bs
      | null bs = []
      | otherwise = take 4096 (bs ++ repeat 0) : chunk4096 (drop 4096 bs)
    writeBlocks :: Int -> Int -> [[Word8]] -> H (Either BlkError ())
    writeBlocks _ _ [] = return (Right ())
    writeBlocks s lba (b : rest) = do
      r <- Blk.blkWriteBlockBytes s (fromIntegral lba) b
      case r of
        Left e -> return (Left e)
        Right () -> writeBlocks s (lba + 1) rest

collectAll :: H (Either FS.FsError [(FilePath, [Word8])])
collectAll = go ["/"] []
  where
    go [] acc = return (Right acc)
    go (dir : stack) acc = do
      eLs <- FS.fsLs dir
      case eLs of
        Left e -> return (Left e)
        Right names -> do
          r <- walkNames dir names
          case r of
            Left e -> return (Left e)
            Right (files, dirs) -> go (dirs ++ stack) (acc ++ files)
    walkNames _ [] = return (Right ([], []))
    walkNames dir (n : ns) = do
      let full = if dir == "/" then "/" ++ n else dir ++ "/" ++ n
      eSt <- FS.fsStat full
      case eSt of
        Left e -> return (Left e)
        Right st ->
          if FS.fsIsDir st
            then do
              r <- walkNames dir ns
              case r of
                Left e -> return (Left e)
                Right (fs, ds) -> return (Right (fs, full : ds))
            else do
              eR <- FS.fsRead full
              case eR of
                Left e -> return (Left e)
                Right s -> do
                  let bs = map (\c -> fromIntegral (ord c `mod` 256) :: Word8) s
                  r <- walkNames dir ns
                  case r of
                    Left e -> return (Left e)
                    Right (fs, ds) -> return (Right ((full, bs) : fs, ds))

-- | Restore blk slot into ramfs (clears current FS first).
persistRestore :: Int -> H (Either PersistError ())
persistRestore slot = do
  r0 <- Blk.blkReadBlockBytes slot 0
  case r0 of
    Left e -> return (Left (PersistBlk e))
    Right b0
      | length b0 < 13 -> return (Left (PersistFormat "truncated header"))
      | take 4 b0 /= magic -> return (Left (PersistFormat "bad magic"))
      | otherwise -> case getU32 5 b0 of
          Nothing -> return (Left (PersistFormat "truncated header"))
          Just t
            | t < 13 || t > maxImageBytes -> return (Left (PersistFormat "bad total"))
            | otherwise -> do
                let need = (t + 4095) `div` 4096
                eRest <- readBlocks slot 1 (need - 1)
                case eRest of
                  Left e -> return (Left (PersistBlk e))
                  Right rest ->
                    let img = take t (b0 ++ concat rest)
                     in case decodeImage img of
                          Left s -> return (Left (PersistFormat s))
                          Right files -> restoreFiles files
  where
    readBlocks :: Int -> Int -> Int -> H (Either BlkError [[Word8]])
    readBlocks _ _ 0 = return (Right [])
    readBlocks s lba n = do
      r <- Blk.blkReadBlockBytes s (fromIntegral lba)
      case r of
        Left e -> return (Left e)
        Right b -> do
          rest <- readBlocks s (lba + 1) (n - 1)
          case rest of
            Left e -> return (Left e)
            Right bs -> return (Right (b : bs))
    restoreFiles files = do
      FS.fsInit
      go files
    go [] = return (Right ())
    go ((p, bs) : rest) = do
      mapM_ ensureDir (parentDirs p)
      let s = map (chr . fromIntegral) bs
      r <- FS.fsWrite p s
      case r of
        Left e -> return (Left (PersistFs e))
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
      r <- FS.fsMkdir d
      case r of
        Left _ -> return ()
        Right () -> return ()
