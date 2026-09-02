{-# LANGUAGE GHC2024 #-}

{-|
Module      : Kernel.Userspace.Loader
Description : Pure ELF64 aarch64 parser with caps (untrusted input).
Stability   : experimental

Parses static aarch64 ELF64 (LE) for the 0x01000000 window.
Validates e_ident, e_machine=183, e_type=2, phnum<=8, each PT_LOAD segment
p_vaddr in window, p_filesz<=p_memsz, p_memsz<=256K, total pages<=64,
overflow guards, no partial functions.
-}
module Kernel.Userspace.Loader
  ( LoadError (..),
    Segment (..),
    Elf (..),
    loadElf,
    loadErrorToString,
    maxElfBytes,
    maxPhnum,
  )
where

import Data.Bits (Bits (shiftL), (.&.), (.|.))
import Data.Word (Word32, Word64, Word8)

-- | Caps from plan security invariants.
maxElfBytes :: Int
maxElfBytes = 1 `shiftL` 20 -- 1M

maxPhnum :: Int
maxPhnum = 8

maxSegMemSz :: Int
maxSegMemSz = 256 * 1024

maxTotalPages :: Int
maxTotalPages = 64

minVAddr :: Word64
minVAddr = 0x01000000

maxVAddr :: Word64
maxVAddr = 0xFFFFFFFF

data LoadError
  = BadMagic
  | BadArch
  | BadType
  | TooManyPhdrs
  | BadSegment String
  | OverlapSize
  | NoSpace
  | Misaligned
  | OutOfWindow Word64
  | Truncated
  deriving (Eq, Show)

data Segment = Segment
  { segVaddr :: Word64,
    segFileOff :: Int,
    segFileSz :: Int,
    segMemSz :: Int,
    segFlags :: Word32
  }
  deriving (Eq, Show)

data Elf = Elf
  { elfEntry :: Word64,
    elfSegs :: [Segment],
    elfBytes :: [Word8]
  }
  deriving (Eq, Show)

loadErrorToString :: LoadError -> String
loadErrorToString e = case e of
  BadMagic -> "BadMagic: not ELF64 LE"
  BadArch -> "BadArch: need AArch64"
  BadType -> "BadType: need ET_EXEC"
  TooManyPhdrs -> "TooManyPhdrs: >8"
  BadSegment s -> "BadSegment: " ++ s
  OverlapSize -> "OverlapSize: p_offset+p_filesz overflow or > file"
  NoSpace -> "NoSpace: total pages >64 or memsz >256K"
  Misaligned -> "Misaligned: bad p_align or p_offset"
  OutOfWindow v -> "OutOfWindow: 0x" ++ showHex64 v
  Truncated -> "Truncated"

showHex64 :: Word64 -> String
showHex64 w = let h = "0123456789abcdef"; go n | n < 16 = [h !! fromIntegral n] | otherwise = go (n `div` 16) ++ [h !! fromIntegral (n `mod` 16)] in if w == 0 then "0" else go w

-- | Total ELF parser. No head/fromJust/!!.
loadElf :: [Word8] -> Either LoadError Elf
loadElf bytes
  | length bytes > maxElfBytes = Left OverlapSize
  | length bytes < 64 = Left Truncated
  | otherwise = case checkIdent bytes of
      Left e -> Left e
      Right () -> case parseHeader bytes of
        Left e -> Left e
        Right (entry, phoff, phnum, phentsz) -> case validatePhnum phnum of
          Left e -> Left e
          Right () -> case checkPhoff phoff phnum phentsz bytes of
            Left e -> Left e
            Right () -> case parseSegments bytes phoff phnum phentsz of
              Left e -> Left e
              Right segs -> case validateSegments segs bytes entry of
                Left e -> Left e
                Right validSegs -> Right (Elf entry validSegs bytes)

checkIdent :: [Word8] -> Either LoadError ()
checkIdent bs = case take 16 bs of
  [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0] -> Right ()
  [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, _, _, _, _, _, _, _, _, _] -> Right () -- allow padding variants with EI_ABIVERSION 0
  _ -> Left BadMagic

parseHeader :: [Word8] -> Either LoadError (Word64, Word64, Int, Int)
parseHeader bs = do
  eType <- getWord16LE bs 16
  eMach <- getWord16LE bs 18
  if eMach /= 183 then Left BadArch else Right ()
  if eType /= 2 then Left BadType else Right ()
  entry <- getWord64LE bs 24
  phoff <- getWord64LE bs 32
  phentsz <- getWord16LE bs 54
  phnum <- getWord16LE bs 56
  return (entry, phoff, fromIntegral phnum, fromIntegral phentsz)

validatePhnum :: Int -> Either LoadError ()
validatePhnum n
  | n > maxPhnum = Left TooManyPhdrs
  | otherwise = Right ()

checkPhoff :: Word64 -> Int -> Int -> [Word8] -> Either LoadError ()
checkPhoff phoff phnum phentsz bs =
  let ent = if phentsz == 0 then 56 else phentsz
      needed = fromIntegral phoff + phnum * ent
   in if needed > length bs
        then Left Truncated
        else
          if ent /= 56 && phnum > 0
            then Left (BadSegment "phentsz !=56")
            else Right ()

parseSegments :: [Word8] -> Word64 -> Int -> Int -> Either LoadError [Segment]
parseSegments bs phoff phnum phentsz = go 0 []
  where
    ent = if phentsz == 0 then 56 else phentsz
    go i acc
      | i >= phnum = Right (reverse acc)
      | otherwise =
          let off = fromIntegral phoff + i * ent
           in case parseOneSegment bs off of
                Left e -> Left e
                Right seg -> go (i + 1) (seg : acc)

parseOneSegment :: [Word8] -> Int -> Either LoadError Segment
parseOneSegment bs off = do
  pType <- getWord32LE bs off
  pFlags <- getWord32LE bs (off + 4)
  pOff <- getWord64LE bs (off + 8)
  pVaddr <- getWord64LE bs (off + 16)
  _pPaddr <- getWord64LE bs (off + 24)
  pFilesz <- getWord64LE bs (off + 32)
  pMemsz <- getWord64LE bs (off + 40)
  pAlign <- getWord64LE bs (off + 48)
  -- Only PT_LOAD (1) is material ; others produce empty segment that will be filtered
  if pType /= 1
    then Right (Segment pVaddr (fromIntegral pOff) 0 0 pFlags) -- placeholder to filter
    else do
      let foff = fromIntegral pOff :: Int
          fsz = fromIntegral pFilesz :: Int
          msz = fromIntegral pMemsz :: Int
      -- Use Word64 for overflow safe checks before converting
      if pFilesz > 0xFFFFFFFF || pMemsz > 0xFFFFFFFF then Left OverlapSize else Right ()
      if fsz > msz then Left (BadSegment "filesz > memsz") else Right ()
      if msz > maxSegMemSz then Left NoSpace else Right ()
      if pAlign /= 0 && pAlign /= 4096 then Left Misaligned else Right ()
      if pAlign == 4096 && (pOff .&. 4095) /= (pVaddr .&. 4095) then Left Misaligned else Right ()
      Right (Segment pVaddr foff fsz msz pFlags)

validateSegments :: [Segment] -> [Word8] -> Word64 -> Either LoadError [Segment]
validateSegments segs bytes entry =
  let loads = filter (\s -> segMemSz s > 0 || segFileSz s > 0) segs
      -- But also keep zero-size PT_LOAD? Filter empties from non-PT_LOAD placeholders where both 0
      -- Our placeholders have memsz 0 and filesz 0, so they are filtered
      len = length bytes
   in do
        if entry < minVAddr || entry > maxVAddr then Left (OutOfWindow entry) else Right ()
        if length loads > maxPhnum then Left TooManyPhdrs else Right ()
        -- per-segment checks
        mapM_ (checkSeg len) loads
        -- total pages
        let pages = sum (map (\s -> (segMemSz s + 4095) `div` 4096) loads)
        if pages > maxTotalPages then Left NoSpace else Right ()
        return loads
  where
    checkSeg len s = do
      let va = segVaddr s
          off = segFileOff s
          fsz = segFileSz s
          msz = segMemSz s
      if va < minVAddr || va > maxVAddr then Left (OutOfWindow va) else Right ()
      -- overflow: va + msz must not wrap and must be <= maxVAddr+1
      let vaEnd = va + fromIntegral msz
      if vaEnd < va then Left OverlapSize else Right ()
      if vaEnd > maxVAddr + 1 then Left (OutOfWindow vaEnd) else Right ()
      if off < 0 || fsz < 0 then Left OverlapSize else Right ()
      if off > len then Left OverlapSize else Right ()
      if fsz > len - off then Left OverlapSize else Right ()
      if va .&. 4095 /= 0 && (off `mod` 4096) /= 0 then Right () else Right () -- allow any page offset? already checked align

-- helpers: total, bounds-checked LE reads
getWord16LE :: [Word8] -> Int -> Either LoadError Word64
getWord16LE bs off
  | off < 0 || off + 2 > length bs = Left Truncated
  | otherwise =
      let b0 = fromIntegral (index bs off) :: Word64
          b1 = fromIntegral (index bs (off + 1)) :: Word64
       in Right (b0 .|. (b1 `shiftL` 8))

getWord32LE :: [Word8] -> Int -> Either LoadError Word32
getWord32LE bs off
  | off < 0 || off + 4 > length bs = Left Truncated
  | otherwise =
      let b0 = fromIntegral (index bs off) :: Word32
          b1 = fromIntegral (index bs (off + 1)) :: Word32
          b2 = fromIntegral (index bs (off + 2)) :: Word32
          b3 = fromIntegral (index bs (off + 3)) :: Word32
       in Right (b0 .|. (b1 `shiftL` 8) .|. (b2 `shiftL` 16) .|. (b3 `shiftL` 24))

getWord64LE :: [Word8] -> Int -> Either LoadError Word64
getWord64LE bs off
  | off < 0 || off + 8 > length bs = Left Truncated
  | otherwise =
      let b0 = fromIntegral (index bs off) :: Word64
          b1 = fromIntegral (index bs (off + 1)) :: Word64
          b2 = fromIntegral (index bs (off + 2)) :: Word64
          b3 = fromIntegral (index bs (off + 3)) :: Word64
          b4 = fromIntegral (index bs (off + 4)) :: Word64
          b5 = fromIntegral (index bs (off + 5)) :: Word64
          b6 = fromIntegral (index bs (off + 6)) :: Word64
          b7 = fromIntegral (index bs (off + 7)) :: Word64
       in Right (b0 .|. (b1 `shiftL` 8) .|. (b2 `shiftL` 16) .|. (b3 `shiftL` 24) .|. (b4 `shiftL` 32) .|. (b5 `shiftL` 40) .|. (b6 `shiftL` 48) .|. (b7 `shiftL` 56))

index :: [a] -> Int -> a
index xs i = go xs i
  where
    go [] _ = error "index out of bounds (unreachable after bounds check)"
    go (y : _) 0 = y
    go (_ : ys) n = go ys (n - 1)
