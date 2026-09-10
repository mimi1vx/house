{-# LANGUAGE GHC2024 #-}

{- | Pure cpio newc (`070701`) parser for initramfs.

Bytes in, entries out; hostile input is rejected with typed errors,
never partial functions. Caps are checked before expensive work:
archive, file count, name length, and file size.
-}
module Kernel.Initramfs.Cpio (
  CpioEntry (..),
  CpioError (..),
  isDirEntry,
  isFileEntry,
  parseCpio,
  encodeCpio,
  mkCpioFile,
  mkCpioDir,
  maxArchiveBytes,
  maxFiles,
  maxNameLen,
  maxFileBytes,
)
where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.Char (chr, ord)
import Data.Word (Word32, Word8)

-- | One archive entry: path plus raw payload (empty for directories).
data CpioEntry = CpioEntry {
  entryName :: String
  , entryMode :: Word32
  , entryData :: [Word8]
  }
  deriving (Eq, Show)

-- | Typed parse failures.
data CpioError
  = BadMagic
  | Truncated String
  | BadHeader String
  | BadName String
  | TooBig String
  | TooManyFiles
  | MissingTrailer
  deriving (Eq, Show)

-- | Archive cap: 8 MiB total.
maxArchiveBytes :: Int
maxArchiveBytes = 8 * 1024 * 1024

-- | Entry count cap: 512 files.
maxFiles :: Int
maxFiles = 512

-- | Name length cap: 255 chars (excludes NUL).
maxNameLen :: Int
maxNameLen = 255

-- | Single file payload cap: 1 MiB.
maxFileBytes :: Int
maxFileBytes = 1024 * 1024

-- | Directory bit (`S_IFDIR`) in the mode field.
dirBit :: Word32
dirBit = 0o040000

-- | True when the mode marks a directory.
isDirEntry :: CpioEntry -> Bool
isDirEntry e = (entryMode e .&. 0o170000) == dirBit

-- | True when the entry is not a directory.
isFileEntry :: CpioEntry -> Bool
isFileEntry = not . isDirEntry

{- | Parse a newc archive. Accepts `070701` only; the `TRAILER!!!`
terminator is consumed, not returned.
-}
parseCpio :: [Word8] -> Either CpioError [CpioEntry]
parseCpio bs
  | length bs > maxArchiveBytes = Left (TooBig "archive over 8M")
  | otherwise = go bs 0 []
  where
    go rest n acc
      | n > maxFiles = Left TooManyFiles
      | otherwise = case parseOne rest of
          Left MissingTrailer -> Left MissingTrailer
          Left e -> Left e
          Right Nothing -> Right (reverse acc)
          Right (Just (e, rest')) ->
            if length acc + 1 > maxFiles
              then Left TooManyFiles
              else go rest' (n + 1) (e : acc)

-- | Parse one header; `Nothing` is the trailer terminator.
parseOne :: [Word8] -> Either CpioError (Maybe (CpioEntry, [Word8]))
parseOne bs = case splitAt 6 bs of
  (magic, rest)
    | length magic < 6 -> Left MissingTrailer
    | magic /= magicNewc -> Left BadMagic
    | otherwise -> case splitAt 104 rest of
        (fields, rest2)
          | length fields < 104 -> Left (Truncated "header")
          | otherwise -> case parseFields fields of
              Left e -> Left e
              Right (mode, filesize, namesize) ->
                if namesize <= 0
                  then Left (BadHeader "namesize is zero")
                  else
                    let nameLen = namesize - 1
                     in if nameLen > maxNameLen
                          then Left (TooBig "name over 255")
                          else
                            if filesize > maxFileBytes
                              then Left (TooBig "file over 1M")
                              else case splitAt namesize rest2 of
                                (nameBs, rest3)
                                  | length nameBs < namesize -> Left (Truncated "name")
                                  | lastByte nameBs /= Just 0 -> Left (BadHeader "name not NUL-terminated")
                                  | otherwise ->
                                      let raw = take nameLen nameBs
                                          namePad = padEntry (headerSize + namesize)
                                          afterName = drop namePad rest3
                                       in case decodeName raw of
                                            Left e -> Left e
                                            Right name ->
                                              if name == "TRAILER!!!"
                                                then
                                                  if filesize /= 0
                                                    then Left (BadHeader "trailer has payload")
                                                    else Right Nothing
                                                else case splitAt filesize afterName of
                                                  (payload, rest4)
                                                    | length payload < filesize -> Left (Truncated "payload")
                                                    | otherwise ->
                                                        let entry = CpioEntry name mode payload
                                                            dataPad = padEntry (headerSize + namesize + namePad + filesize)
                                                            rest5 = drop dataPad rest4
                                                         in Right (Just (entry, rest5))

lastByte :: [Word8] -> Maybe Word8
lastByte [] = Nothing
lastByte xs = Just (go xs)
  where
    go [b] = b
    go (_ : ys) = go ys
    go [] = 0

magicNewc :: [Word8]
magicNewc = [48, 55, 48, 55, 48, 49]

-- | Header fields: mode, filesize, namesize (all 8-hex-digit).
parseFields :: [Word8] -> Either CpioError (Word32, Int, Int)
parseFields f = do
  mode <- note badHex (parseHex8 (take 8 (drop 8 f)))
  filesize <- note badHex (parseHex8 (take 8 (drop 48 f)))
  namesize <- note badHex (parseHex8 (take 8 (drop 88 f)))
  return (mode, fromIntegral filesize, fromIntegral namesize)
  where
    badHex = BadHeader "bad hex field"

note :: e -> Maybe a -> Either e a
note e Nothing = Left e
note _ (Just a) = Right a

-- | Decode 8 ASCII hex bytes (big-endian).
parseHex8 :: [Word8] -> Maybe Word32
parseHex8 bs
  | length bs /= 8 = Nothing
  | otherwise = go bs 0
  where
    go [] acc = Just acc
    go (b : rest) acc = case hexVal b of
      Nothing -> Nothing
      Just v -> go rest ((acc `shiftL` 4) .|. v)

hexVal :: Word8 -> Maybe Word32
hexVal b
  | b >= 48 && b <= 57 = Just (fromIntegral b - 48)
  | b >= 97 && b <= 102 = Just (fromIntegral b - 87)
  | b >= 65 && b <= 70 = Just (fromIntegral b - 55)
  | otherwise = Nothing

-- | Reject traversal/absolute/empty/NUL names; allow `./` prefixes.
decodeName :: [Word8] -> Either CpioError String
decodeName bs
  | null bs = Left (BadName "empty name")
  | 0 `elem` bs = Left (BadName "NUL in name")
  | headIsSlash bs = Left (BadName "absolute path")
  | otherwise =
      let s = map (chr . fromIntegral) bs
          comps = splitOn '/' s
       in if ".." `elem` comps
            then Left (BadName "dotdot escape")
            else Right s
  where
    headIsSlash (b : _) = b == 47
    headIsSlash [] = False

splitOn :: Char -> String -> [String]
splitOn d s = case break (== d) s of
  (pre, []) -> [pre]
  (pre, _ : rest) -> pre : splitOn d rest

-- | Header size: entries start 4-aligned, so names begin at offset 2 mod 4.
headerSize :: Int
headerSize = 110

{- | Padding after a field ending at an entry-relative offset, restoring
4-alignment for what follows.
-}
padEntry :: Int -> Int
padEntry offInEntry = (4 - offInEntry `mod` 4) `mod` 4

-- Encoding (for tests + tooling goldens) ---------------------------------------

-- | Regular-file entry.
mkCpioFile :: String -> [Word8] -> CpioEntry
mkCpioFile name = CpioEntry name 0o100644

-- | Directory entry.
mkCpioDir :: String -> CpioEntry
mkCpioDir name = CpioEntry name 0o040755 []

-- | Encode entries plus the `TRAILER!!!` terminator.
encodeCpio :: [CpioEntry] -> [Word8]
encodeCpio es = concatMap encodeOne es ++ encodeOne (CpioEntry "TRAILER!!!" 0 [])
  where
    encodeOne e =
      let nameLen = length (entryName e) + 1
          dataLen = length (entryData e)
          namePad = padEntry (headerSize + nameLen)
          dataPad = padEntry (headerSize + nameLen + namePad + dataLen)
       in magicNewc
            ++ hex8 0
            ++ hex8 (entryMode e)
            ++ hex8 0
            ++ hex8 0
            ++ hex8 1
            ++ hex8 0
            ++ hex8 (fromIntegral dataLen)
            ++ hex8 0
            ++ hex8 0
            ++ hex8 0
            ++ hex8 0
            ++ hex8 (fromIntegral nameLen)
            ++ hex8 0
            ++ nameBytes (entryName e)
            ++ replicate namePad 0
            ++ entryData e
            ++ replicate dataPad 0
    nameBytes s = [fromIntegral (ord c `mod` 256) | c <- s] ++ [0]

hex8 :: Word32 -> [Word8]
hex8 w = [hexChar ((w `div` (16 ^ i)) `mod` 16) | i <- [7, 6 .. (0 :: Int)]]
  where
    hexChar n
      | n < 10 = fromIntegral n + 48
      | otherwise = fromIntegral n + 87
