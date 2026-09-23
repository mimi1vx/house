{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Loader
Description : Pure ELF64 aarch64 parser with caps (untrusted input).
Stability   : experimental

Parses static + PIE aarch64 ELF64 (LE) for the 0x01000000 window.
Validates e_ident, e_machine=183, e_type in {ET_EXEC, ET_DYN},
phnum<=8, each PT_LOAD segment p_vaddr in window,
p_filesz<=p_memsz, p_memsz<=256K, total pages<=64, entry inside a
PT_LOAD, overflow guards, no partial functions.

Dynamic (M1, kernel-is-the-loader): PT_INTERP is recorded + validated
only (must equal /lib/ld-house.so.0, never executed as EL0 code);
PT_DYNAMIC DT_NEEDED/STRTAB/STRSZ/RELA parsed with bounds;
PT_GNU_RELRO recorded + validated inside a PT_LOAD (no permission
enforcement yet beyond bind-now); RELA R_AARCH64_RELATIVE-only applied
by a pure function. JUMP_SLOT/GLOB_DAT rejected, TLS fail-closed.
-}
module Kernel.Userspace.Loader (
  LoadError (..),
  Segment (..),
  Elf (..),
  DynInfo (..),
  Rela (..),
  RelroRange (..),
  DynAcc (..),
  emptyDynInfo,
  emptyDynAcc,
  ldHousePath,
  loadElf,
  loadErrorToString,
  applyRelativeRelocs,
  applyRelocsToFile,
  findNeededCycle,
  vaToFileOff,
  maxElfBytes,
  maxPhnum,
  maxInterpLen,
  maxDynStrSz,
  maxNeeded,
  maxRelaCount,
)
where

import Data.Array (Array, bounds, listArray, (!), (//))
import Data.Bits (Bits (shiftL, shiftR), (.&.), (.|.))
import Data.Char (chr)
import Data.Maybe (fromMaybe)
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

-- | M1 caps: hostile dynamic input stays bounded before expensive work.
maxInterpLen :: Int
maxInterpLen = 256

maxDynStrSz :: Int
maxDynStrSz = 64 * 1024

maxNeeded :: Int
maxNeeded = 8

maxRelaCount :: Int
maxRelaCount = 4096

maxDynEnt :: Int
maxDynEnt = 64

maxNeededNameLen :: Int
maxNeededNameLen = 128

-- | Version pin + path contract: the only accepted PT_INTERP value.
ldHousePath :: String
ldHousePath = "/lib/ld-house.so.0"

-- | Phdr types we materialize; all other types are skipped.
ptLoad :: Word32
ptLoad = 1

ptDynamic :: Word32
ptDynamic = 2

ptInterp :: Word32
ptInterp = 3

ptGnuRelro :: Word32
ptGnuRelro = 0x6474E552

{- | Dynamic tags accepted in v1 (plus DT_NULL terminator and the
bind-now markers DT_BIND_NOW/DT_FLAGS, whose values are ignored).
PT_GNU_RELRO carries the RELRO range, so no DT_RELRO tag is needed.
-}
dtNull :: Word64
dtNull = 0

dtNeeded :: Word64
dtNeeded = 1

dtStrtab :: Word64
dtStrtab = 5

dtSymtab :: Word64
dtSymtab = 6

dtRela :: Word64
dtRela = 7

dtRelasz :: Word64
dtRelasz = 8

dtRelaent :: Word64
dtRelaent = 9

dtStrsz :: Word64
dtStrsz = 10

dtBindNow :: Word64
dtBindNow = 24

dtFlags :: Word64
dtFlags = 30

-- | AArch64 dynamic reloc types (v1 is RELATIVE-only, bind-now).
rAarch64GlobDat :: Word32
rAarch64GlobDat = 1025

rAarch64JumpSlot :: Word32
rAarch64JumpSlot = 1026

rAarch64Relative :: Word32
rAarch64Relative = 1027

-- | First AArch64 TLS reloc: everything at/above is TLS fail-closed.
rAarch64TlsFirst :: Word32
rAarch64TlsFirst = 1029

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
  | BadDyn String
  | UnsupportedReloc Word32
  | TlsUnsupported
  | NeededCycle
  deriving (Eq, Show)

data Segment = Segment {
  segVaddr :: Word64
  , segFileOff :: Int
  , segFileSz :: Int
  , segMemSz :: Int
  , segFlags :: Word32
  }
  deriving (Eq, Show)

-- | Raw file offsets parsed from PT_DYNAMIC (VAs translated via LOADs).
data DynInfo = DynInfo {
  dynNeeded :: [String]
  , dynRelaOff :: Int
  , dynRelaSize :: Int
  , dynRelaEnt :: Int
  , dynStrOff :: Int
  , dynStrSz :: Int
  }
  deriving (Eq, Show)

-- | One RELA entry: r_offset is the object VA, r_addend the stored value.
data Rela = Rela {
  relaOffset :: Word64
  , relaType :: Word32
  , relaAddend :: Word64
  }
  deriving (Eq, Show)

-- | Validated PT_GNU_RELRO range (subset of one PT_LOAD).
data RelroRange = RelroRange {
  relroStart :: Word64
  , relroEnd :: Word64
  }
  deriving (Eq, Show)

-- | Accumulator for the PT_DYNAMIC tag walk.
data DynAcc = DynAcc {
  accNeeded :: [Word64]
  , accStrtab :: Maybe Word64
  , accStrsz :: Maybe Word64
  , accRela :: Maybe Word64
  , accRelasz :: Maybe Word64
  , accRelaent :: Maybe Word64
  , accDone :: Bool
  }
  deriving (Eq, Show)

data Elf = Elf {
  elfEntry :: Word64
  , elfSegs :: [Segment]
  , elfBytes :: [Word8]
  , elfIsDyn :: Bool
  , elfInterp :: Maybe String
  , elfDyn :: DynInfo
  , elfRelas :: [Rela]
  , elfRelro :: Maybe RelroRange
  }
  deriving (Eq, Show)

emptyDynInfo :: DynInfo
emptyDynInfo = DynInfo [] 0 0 0 0 0

emptyDynAcc :: DynAcc
emptyDynAcc = DynAcc [] Nothing Nothing Nothing Nothing Nothing False

loadErrorToString :: LoadError -> String
loadErrorToString e = case e of
  BadMagic -> "BadMagic: not ELF64 LE"
  BadArch -> "BadArch: need AArch64"
  BadType -> "BadType: need ET_EXEC/ET_DYN"
  TooManyPhdrs -> "TooManyPhdrs: >8"
  BadSegment s -> "BadSegment: " ++ s
  OverlapSize -> "OverlapSize: p_offset+p_filesz overflow or > file"
  NoSpace -> "NoSpace: total pages >64 or memsz >256K"
  Misaligned -> "Misaligned: bad p_align or p_offset"
  OutOfWindow v -> "OutOfWindow: 0x" ++ showHex64 v
  Truncated -> "Truncated"
  BadDyn s -> "BadDyn: " ++ s
  UnsupportedReloc t -> "UnsupportedReloc: " ++ show t
  TlsUnsupported -> "TlsUnsupported"
  NeededCycle -> "NeededCycle"

showHex64 :: Word64 -> String
showHex64 w = if w == 0 then "0" else go w
  where
    go n
      | n < 16 = [hexDigit (fromIntegral n)]
      | otherwise = go (n `div` 16) ++ [hexDigit (fromIntegral (n `mod` 16))]
    -- \| Total nibble render; index reduced mod 16.
    hexDigit :: Int -> Char
    hexDigit n = case n `mod` 16 of
      0 -> '0'
      1 -> '1'
      2 -> '2'
      3 -> '3'
      4 -> '4'
      5 -> '5'
      6 -> '6'
      7 -> '7'
      8 -> '8'
      9 -> '9'
      10 -> 'a'
      11 -> 'b'
      12 -> 'c'
      13 -> 'd'
      14 -> 'e'
      _ -> 'f'

-- | Total ELF parser. No head/fromJust/!!.
loadElf :: [Word8] -> Either LoadError Elf
loadElf bytes
  | length bytes > maxElfBytes = Left OverlapSize
  | length bytes < 64 = Left Truncated
  | otherwise = case checkIdent bytes of
      Left e -> Left e
      Right () -> case parseHeader bytes of
        Left e -> Left e
        Right (isDyn, entry, phoff, phnum, phentsz) -> case validatePhnum phnum of
          Left e -> Left e
          Right () -> case checkPhoff phoff phnum phentsz bytes of
            Left e -> Left e
            Right () -> case parseSegments bytes phoff phnum phentsz of
              Left e -> Left e
              Right segs -> case validateSegments segs bytes entry of
                Left e -> Left e
                Right validSegs -> case collectRawPhdrs bytes phoff phnum phentsz of
                  Left e -> Left e
                  Right raws -> case parseInterp raws bytes of
                    Left e -> Left e
                    Right interp -> case parseRelro raws validSegs of
                      Left e -> Left e
                      Right relro -> case parseDynamic raws bytes validSegs of
                        Left e -> Left e
                        Right (dyn, relas) ->
                          Right (Elf entry validSegs bytes isDyn interp dyn relas relro)

checkIdent :: [Word8] -> Either LoadError ()
checkIdent bs = case take 16 bs of
  [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0] -> Right ()
  [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, _, _, _, _, _, _, _, _, _] -> Right () -- allow padding variants with EI_ABIVERSION 0
  _ -> Left BadMagic

parseHeader :: [Word8] -> Either LoadError (Bool, Word64, Word64, Int, Int)
parseHeader bs = do
  eType <- getWord16LE bs 16
  eMach <- getWord16LE bs 18
  if eMach /= 183 then Left BadArch else Right ()
  isDyn <- case eType of
    2 -> Right False
    3 -> Right True
    _ -> Left BadType
  entry <- getWord64LE bs 24
  phoff <- getWord64LE bs 32
  phentsz <- getWord16LE bs 54
  phnum <- getWord16LE bs 56
  return (isDyn, entry, phoff, fromIntegral phnum, fromIntegral phentsz)

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

-- | Raw phdr row: (p_type, p_flags, p_offset, p_vaddr, p_filesz, p_memsz, p_align).
type RawPhdr = (Word32, Word32, Word64, Word64, Word64, Word64, Word64)

rawType :: RawPhdr -> Word32
rawType (t, _, _, _, _, _, _) = t

collectRawPhdrs :: [Word8] -> Word64 -> Int -> Int -> Either LoadError [RawPhdr]
collectRawPhdrs bs phoff phnum phentsz = go 0 []
  where
    ent = if phentsz == 0 then 56 else phentsz
    go i acc
      | i >= phnum = Right (reverse acc)
      | otherwise =
          let off = fromIntegral phoff + i * ent
           in case parseOneRaw bs off of
                Left e -> Left e
                Right r -> go (i + 1) (r : acc)

parseOneRaw :: [Word8] -> Int -> Either LoadError RawPhdr
parseOneRaw bs off = do
  pType <- getWord32LE bs off
  pFlags <- getWord32LE bs (off + 4)
  pOff <- getWord64LE bs (off + 8)
  pVaddr <- getWord64LE bs (off + 16)
  _pPaddr <- getWord64LE bs (off + 24)
  pFilesz <- getWord64LE bs (off + 32)
  pMemsz <- getWord64LE bs (off + 40)
  pAlign <- getWord64LE bs (off + 48)
  return (pType, pFlags, pOff, pVaddr, pFilesz, pMemsz, pAlign)

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
  if pType /= ptLoad
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
        -- entry must land inside a PT_LOAD of the same object
        -- (PIE base-bias rule: file entry is validated pre-slide).
        case filter (entryInSeg entry) loads of
          [] -> Left (BadSegment "entry not in LOAD")
          _ -> return loads
  where
    entryInSeg e s =
      let va = segVaddr s
          end = va + fromIntegral (segMemSz s)
       in end >= va && e >= va && e < end
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

-- allow any page offset (alignment already checked above)

{- | PT_INTERP record-only: at most one, filesz<=256, NUL-terminated,
must equal ldHousePath. Absent is fine (shared libs carry no INTERP).
-}
parseInterp :: [RawPhdr] -> [Word8] -> Either LoadError (Maybe String)
parseInterp raws bytes =
  case [r | r <- raws, rawType r == ptInterp] of
    [] -> Right Nothing
    [r] -> parseOneInterp r bytes
    _ -> Left (BadDyn "double-interp")

parseOneInterp :: RawPhdr -> [Word8] -> Either LoadError (Maybe String)
parseOneInterp (_, _, pOff, _, pFilesz, _, _) bytes = do
  let len = length bytes
      fsz = fromIntegral pFilesz :: Int
      off = fromIntegral pOff :: Int
  if pFilesz > fromIntegral maxInterpLen then Left (BadDyn "interp too long") else Right ()
  if fsz <= 0 then Left (BadDyn "interp empty") else Right ()
  if off < 0 || off > len then Left Truncated else Right ()
  if fsz > len - off then Left Truncated else Right ()
  let slice = take fsz (drop off bytes)
  case break (== 0) slice of
    (_, []) -> Left (BadDyn "interp not NUL-terminated")
    (name, _ : rest) -> do
      if any (/= 0) rest
        then Left (BadDyn "interp trailing bytes")
        else Right ()
      if null name then Left (BadDyn "interp empty") else Right ()
      if any (\b -> b < 32 || b > 126) name then Left (BadDyn "interp non-printable") else Right ()
      let s = map (chr . fromIntegral) name
      if s /= ldHousePath then Left (BadDyn ("interp path " ++ s)) else Right (Just s)

-- | PT_GNU_RELRO record-only: at most one, must sit inside one PT_LOAD.
parseRelro :: [RawPhdr] -> [Segment] -> Either LoadError (Maybe RelroRange)
parseRelro raws loads =
  case [r | r <- raws, rawType r == ptRelroAlias] of
    [] -> Right Nothing
    [(_, _, _, vaddr, _, memsz, _)] -> parseOneRelro vaddr memsz loads
    _ -> Left (BadDyn "double-relro")
  where
    ptRelroAlias = ptGnuRelro

parseOneRelro :: Word64 -> Word64 -> [Segment] -> Either LoadError (Maybe RelroRange)
parseOneRelro vaddr memsz loads
  | memsz == 0 = Right Nothing
  | otherwise = do
      let end = vaddr + memsz
      if end < vaddr then Left OverlapSize else Right ()
      case filter (contains vaddr end) loads of
        [] -> Left (BadDyn "relro outside LOAD")
        _ -> Right (Just (RelroRange vaddr end))
  where
    contains s e seg =
      let va = segVaddr seg
          segEnd = va + fromIntegral (segMemSz seg)
       in segEnd >= va && s >= va && s < segEnd && e > va && e <= segEnd

{- | PT_DYNAMIC parse: bounds-checked DT_* walk, VA->file translation via
LOADs, NEEDED string resolution, RELA entry decode.
-}
parseDynamic :: [RawPhdr] -> [Word8] -> [Segment] -> Either LoadError (DynInfo, [Rela])
parseDynamic raws bytes loads =
  case [r | r <- raws, rawType r == ptDynamic] of
    [] -> Right (emptyDynInfo, [])
    [(_, _, pOff, _, pFilesz, _, _)] -> parseOneDynamic pOff pFilesz bytes loads
    _ -> Left (BadDyn "double-dynamic")

parseOneDynamic :: Word64 -> Word64 -> [Word8] -> [Segment] -> Either LoadError (DynInfo, [Rela])
parseOneDynamic pOff pFilesz bytes loads = do
  let len = length bytes
      off = fromIntegral pOff :: Int
      sz = fromIntegral pFilesz :: Int
  if off < 0 || off > len then Left Truncated else Right ()
  if sz < 0 || sz > len - off then Left Truncated else Right ()
  if sz `mod` 16 /= 0 then Left (BadDyn "dynamic size") else Right ()
  let n = sz `div` 16
  if n > maxDynEnt then Left (BadDyn "dynamic too many") else Right ()
  let arr = toArr bytes
  acc <- walkDyn arr off n 0 emptyDynAcc
  finishDyn arr acc loads len

walkDyn :: Array Int Word8 -> Int -> Int -> Int -> DynAcc -> Either LoadError DynAcc
walkDyn _ _ total i a
  | i >= total = Right a
  | accDone a = Right a
walkDyn arr off total i a = do
  tag <- getU64A arr (off + i * 16)
  val <- getU64A arr (off + i * 16 + 8)
  a2 <- stepDyn tag val a
  walkDyn arr off total (i + 1) a2

stepDyn :: Word64 -> Word64 -> DynAcc -> Either LoadError DynAcc
stepDyn tag val a
  | tag == dtNull = Right a {accDone = True}
  | tag == dtNeeded = Right a {accNeeded = accNeeded a ++ [val]}
  | tag == dtStrtab = case accStrtab a of
      Just _ -> Left (BadDyn "duplicate STRTAB")
      Nothing -> Right a {accStrtab = Just val}
  | tag == dtSymtab = Right a
  | tag == dtRela = case accRela a of
      Just _ -> Left (BadDyn "duplicate RELA")
      Nothing -> Right a {accRela = Just val}
  | tag == dtRelasz = case accRelasz a of
      Just _ -> Left (BadDyn "duplicate RELASZ")
      Nothing -> Right a {accRelasz = Just val}
  | tag == dtRelaent = case accRelaent a of
      Just _ -> Left (BadDyn "duplicate RELAENT")
      Nothing -> Right a {accRelaent = Just val}
  | tag == dtStrsz = case accStrsz a of
      Just _ -> Left (BadDyn "duplicate STRSZ")
      Nothing -> Right a {accStrsz = Just val}
  | tag == dtBindNow = Right a
  | tag == dtFlags = Right a
  | otherwise = Left (BadDyn ("unsupported DT_" ++ show tag))

finishDyn :: Array Int Word8 -> DynAcc -> [Segment] -> Int -> Either LoadError (DynInfo, [Rela])
finishDyn arr acc loads len = do
  let mEnt = accRelaent acc
      mSz = accRelasz acc
      mRela = accRela acc
  ent <- case mEnt of
    Nothing -> case (mRela, mSz) of
      (Nothing, Nothing) -> Right 0
      (Nothing, Just 0) -> Right 0
      _ -> Left (BadDyn "missing RELAENT")
    Just e
      | e == 0 -> case mSz of
          Nothing -> Right 0
          Just 0 -> Right 0
          Just _ -> Left (BadDyn "relaent 0 with relasz")
      | e == 24 -> Right 24
      | otherwise -> Left (BadDyn "relaent")
  let sz64 = fromMaybe 0 mSz
  sz <- if sz64 > fromIntegral (maxBound :: Int) then Left (BadDyn "relasz overrun") else Right (fromIntegral sz64 :: Int)
  if ent == 0 && sz /= 0 then Left (BadDyn "relaent 0 with relasz") else Right ()
  if ent /= 0 && sz `mod` ent /= 0 then Left (BadDyn "relasz") else Right ()
  let count = if ent == 0 then 0 else sz `div` ent
  if count > maxRelaCount then Left (BadDyn "rela count") else Right ()
  strSz64 <- case accStrsz acc of
    Nothing -> Right 0
    Just s -> Right s
  if strSz64 > fromIntegral maxDynStrSz then Left (BadDyn "strsz overrun") else Right ()
  let neededOffs = accNeeded acc
  if length neededOffs > maxNeeded then Left (BadDyn "needed too many") else Right ()
  -- STRTAB translation: required when NEEDED present or STRSZ nonzero.
  let needStr = not (null neededOffs) || strSz64 /= 0
  strOff <- case accStrtab acc of
    Nothing -> if needStr then Left (BadDyn "missing STRTAB") else Right 0
    Just va -> case vaToFileOff loads va of
      Nothing -> Left (BadDyn "strtab outside LOAD")
      Just o -> Right o
  let strSz = fromIntegral strSz64 :: Int
  if strOff < 0 || strOff > len then Left (BadDyn "strtab bounds") else Right ()
  if strSz < 0 || strSz > len - strOff then Left (BadDyn "strtab bounds") else Right ()
  -- RELA translation.
  relaOff <- case (mRela, count) of
    (Nothing, 0) -> Right 0
    (Nothing, _) -> Left (BadDyn "missing RELA")
    (Just va, _) -> case vaToFileOff loads va of
      Nothing -> Left (BadDyn "rela outside LOAD")
      Just o -> Right o
  if relaOff < 0 || relaOff > len then Left (BadDyn "rela bounds") else Right ()
  if sz < 0 || sz > len - relaOff then Left (BadDyn "rela bounds") else Right ()
  strSlice <- sliceA arr strOff strSz
  needed <- mapM (resolveNeeded strSlice strSz) neededOffs
  relas <- parseRelas arr relaOff count loads len
  let dyn =
        DynInfo {
          dynNeeded = needed
          , dynRelaOff = relaOff
          , dynRelaSize = sz
          , dynRelaEnt = ent
          , dynStrOff = strOff
          , dynStrSz = strSz
          }
  return (dyn, relas)

resolveNeeded :: [Word8] -> Int -> Word64 -> Either LoadError String
resolveNeeded strSlice strSz off64 = do
  if off64 >= fromIntegral strSz then Left (BadDyn "needed off") else Right ()
  let off = fromIntegral off64 :: Int
      rest = drop off strSlice
  case break (== 0) rest of
    (_, []) -> Left (BadDyn "needed not NUL")
    (name, _) -> do
      if null name then Left (BadDyn "needed empty") else Right ()
      if length name > maxNeededNameLen then Left (BadDyn "needed too long") else Right ()
      if 47 `elem` name then Left (BadDyn "needed slash") else Right ()
      if any (\b -> b < 32 || b > 126) name then Left (BadDyn "needed non-printable") else Right ()
      Right (map (chr . fromIntegral) name)

parseRelas :: Array Int Word8 -> Int -> Int -> [Segment] -> Int -> Either LoadError [Rela]
parseRelas arr relaOff count loads len = go 0 []
  where
    go j acc
      | j >= count = Right (reverse acc)
      | otherwise = do
          let base = relaOff + j * 24
          rOff <- getU64A arr base
          rInfo <- getU64A arr (base + 8)
          rAdd <- getU64A arr (base + 16)
          let typ = fromIntegral (rInfo .&. 0xFFFFFFFF) :: Word32
              sym = rInfo `shiftR` 32
          r <- checkRela typ sym rOff rAdd loads len
          case r of
            Nothing -> go (j + 1) acc
            Just rela -> go (j + 1) (rela : acc)

-- | Classify one RELA entry fail-closed. Nothing = R_NONE skip.
checkRela :: Word32 -> Word64 -> Word64 -> Word64 -> [Segment] -> Int -> Either LoadError (Maybe Rela)
checkRela typ sym rOff rAdd loads len
  | typ == 0 = Right Nothing
  | typ == rAarch64Relative =
      if sym /= 0
        then Left (UnsupportedReloc typ)
        else case vaToFileOff loads rOff of
          Nothing -> Left (BadDyn "rela outside LOAD")
          Just foff ->
            if foff < 0 || foff + 8 > len
              then Left (BadDyn "rela outside LOAD")
              else Right (Just (Rela rOff typ rAdd))
  | typ == rAarch64GlobDat = Left (UnsupportedReloc typ)
  | typ == rAarch64JumpSlot = Left (UnsupportedReloc typ)
  | typ >= rAarch64TlsFirst = Left TlsUnsupported
  | otherwise = Left (UnsupportedReloc typ)

-- helpers: total, bounds-checked LE reads
getWord16LE :: [Word8] -> Int -> Either LoadError Word64
getWord16LE bs off
  | off < 0 || off + 2 > length bs = Left Truncated
  | otherwise = do
      b0 <- index bs off
      b1 <- index bs (off + 1)
      let w0 = fromIntegral b0 :: Word64
          w1 = fromIntegral b1 :: Word64
      Right (w0 .|. (w1 `shiftL` 8))

getWord32LE :: [Word8] -> Int -> Either LoadError Word32
getWord32LE bs off
  | off < 0 || off + 4 > length bs = Left Truncated
  | otherwise = do
      b0 <- index bs off
      b1 <- index bs (off + 1)
      b2 <- index bs (off + 2)
      b3 <- index bs (off + 3)
      let w0 = fromIntegral b0 :: Word32
          w1 = fromIntegral b1 :: Word32
          w2 = fromIntegral b2 :: Word32
          w3 = fromIntegral b3 :: Word32
      Right (w0 .|. (w1 `shiftL` 8) .|. (w2 `shiftL` 16) .|. (w3 `shiftL` 24))

getWord64LE :: [Word8] -> Int -> Either LoadError Word64
getWord64LE bs off
  | off < 0 || off + 8 > length bs = Left Truncated
  | otherwise = do
      b0 <- index bs off
      b1 <- index bs (off + 1)
      b2 <- index bs (off + 2)
      b3 <- index bs (off + 3)
      b4 <- index bs (off + 4)
      b5 <- index bs (off + 5)
      b6 <- index bs (off + 6)
      b7 <- index bs (off + 7)
      let w0 = fromIntegral b0 :: Word64
          w1 = fromIntegral b1 :: Word64
          w2 = fromIntegral b2 :: Word64
          w3 = fromIntegral b3 :: Word64
          w4 = fromIntegral b4 :: Word64
          w5 = fromIntegral b5 :: Word64
          w6 = fromIntegral b6 :: Word64
          w7 = fromIntegral b7 :: Word64
      Right (w0 .|. (w1 `shiftL` 8) .|. (w2 `shiftL` 16) .|. (w3 `shiftL` 24) .|. (w4 `shiftL` 32) .|. (w5 `shiftL` 40) .|. (w6 `shiftL` 48) .|. (w7 `shiftL` 56))

{- | Total index; Left Truncated on out-of-range (callers pre-check bounds,
so Left is unreachable in practice but typed, never ErrorCall).
-}
index :: [Word8] -> Int -> Either LoadError Word8
index = go
  where
    go [] _ = Left Truncated
    go (y : _) 0 = Right y
    go (_ : ys) n
      | n < 0 = Left Truncated
      | otherwise = go ys (n - 1)

{- | Dependency-cycle check over a DT_NEEDED adjacency map
(M2 resolves deps via VFS; M1 parses + validates single objects, and
this pure helper pins the fail-closed cycle rule with hostile vectors).
Path-local DFS: diamonds revisit nodes off-path without a false cycle.
-}
findNeededCycle :: [(String, [String])] -> Either LoadError ()
findNeededCycle graph = mapM_ (visit [] . fst) graph
  where
    visit path n
      | n `elem` path = Left NeededCycle
      | otherwise = case lookup n graph of
          Nothing -> Right ()
          Just deps -> mapM_ (visit (n : path)) deps

-- | Array view of file bytes for O(1) dynamic/reloc reads.
toArr :: [Word8] -> Array Int Word8
toArr [] = listArray (0, -1) []
toArr bs = listArray (0, length bs - 1) bs

arrLen :: Array Int Word8 -> Int
arrLen arr =
  let (lo, hi) = bounds arr
   in if hi < lo then 0 else hi - lo + 1

getU64A :: Array Int Word8 -> Int -> Either LoadError Word64
getU64A arr off
  | off < 0 || off + 8 > arrLen arr = Left Truncated
  | otherwise =
      let b i = fromIntegral (arr ! (lo0 + off + i)) :: Word64
          (lo0, _) = bounds arr
       in Right
            ( b 0
                .|. (b 1 `shiftL` 8)
                .|. (b 2 `shiftL` 16)
                .|. (b 3 `shiftL` 24)
                .|. (b 4 `shiftL` 32)
                .|. (b 5 `shiftL` 40)
                .|. (b 6 `shiftL` 48)
                .|. (b 7 `shiftL` 56)
            )

sliceA :: Array Int Word8 -> Int -> Int -> Either LoadError [Word8]
sliceA arr off sz
  | off < 0 || sz < 0 || off + sz > arrLen arr = Left Truncated
  | otherwise =
      let (lo0, _) = bounds arr
       in Right [arr ! (lo0 + i) | i <- [off .. off + sz - 1]]

-- | VA -> file offset via the containing PT_LOAD (first hit wins).
vaToFileOff :: [Segment] -> Word64 -> Maybe Int
vaToFileOff loads va = go loads
  where
    go [] = Nothing
    go (s : rest) =
      let sv = segVaddr s
          end = sv + fromIntegral (segMemSz s)
       in if end >= sv && va >= sv && va < end
            then
              let delta = va - sv
               in if delta > fromIntegral maxSegMemSz
                    then go rest
                    else Just (segFileOff s + fromIntegral delta)
            else go rest

-- | Checked u64 add for RELATIVE slides (overflow is a hostile input).
checkedAdd :: Word64 -> Word64 -> Either LoadError Word64
checkedAdd base add
  | add > maxBound - base = Left OverlapSize
  | otherwise = Right (base + add)

leBytes :: Word64 -> [Word8]
leBytes w =
  [ fromIntegral w
  , fromIntegral (w `shiftR` 8)
  , fromIntegral (w `shiftR` 16)
  , fromIntegral (w `shiftR` 24)
  , fromIntegral (w `shiftR` 32)
  , fromIntegral (w `shiftR` 40)
  , fromIntegral (w `shiftR` 48)
  , fromIntegral (w `shiftR` 56)
  ]

patchAt :: Array Int Word8 -> Int -> Word64 -> Either LoadError (Array Int Word8)
patchAt arr idx val
  | idx < 0 || idx + 8 > arrLen arr = Left (BadDyn "rela outside image")
  | otherwise =
      let (lo0, _) = bounds arr
          ups = zip [lo0 + idx .. lo0 + idx + 7] (leBytes val)
       in Right (arr // ups)

{- | Pure RELATIVE-only RELA application over a memory image based at @base@
(bytes[i] covers VA base+i). Re-checks types fail-closed so a caller
can never smuggle JUMP_SLOT/GLOB_DAT/TLS through a prebuilt list.
-}
applyRelativeRelocs :: Word64 -> [Rela] -> [Word8] -> Either LoadError [Word8]
applyRelativeRelocs base relas bytes = do
  let len = length bytes
      arr0 = toArr bytes
  arrN <- go len arr0 relas
  return (elemsOf arrN)
  where
    elemsOf arr = case bounds arr of
      (lo, hi)
        | hi < lo -> []
        | otherwise -> [arr ! i | i <- [lo .. hi]]
    go _ arr [] = Right arr
    go n arr (r : rest) = do
      let typ = relaType r
      val <- case typ of
        t
          | t == 0 -> Right Nothing
          | t == rAarch64Relative -> do
              v <- checkedAdd base (relaAddend r)
              Right (Just v)
          | t == rAarch64GlobDat -> Left (UnsupportedReloc t)
          | t == rAarch64JumpSlot -> Left (UnsupportedReloc t)
          | t >= rAarch64TlsFirst -> Left TlsUnsupported
          | otherwise -> Left (UnsupportedReloc t)
      case val of
        Nothing -> go n arr rest
        Just v -> do
          let roff = relaOffset r
          if roff < base
            then Left (BadDyn "rela below base")
            else do
              let diff = roff - base
              if diff > fromIntegral n
                then Left (BadDyn "rela outside image")
                else do
                  let idx = fromIntegral diff :: Int
                  arr2 <- patchAt arr idx v
                  go n arr2 rest

-- | File-image RELA application with per-object LOAD containment.
applyRelocsToFile :: [Segment] -> Word64 -> [Rela] -> [Word8] -> Either LoadError [Word8]
applyRelocsToFile segs base relas bytes = do
  let len = length bytes
      arr0 = toArr bytes
  arrN <- go len arr0 relas
  return (elemsOf arrN)
  where
    elemsOf arr = case bounds arr of
      (lo, hi)
        | hi < lo -> []
        | otherwise -> [arr ! i | i <- [lo .. hi]]
    go _ arr [] = Right arr
    go n arr (r : rest) = do
      let typ = relaType r
      v <- case typ of
        t
          | t == 0 -> Right Nothing
          | t == rAarch64Relative -> do
              x <- checkedAdd base (relaAddend r)
              Right (Just x)
          | t == rAarch64GlobDat -> Left (UnsupportedReloc t)
          | t == rAarch64JumpSlot -> Left (UnsupportedReloc t)
          | t >= rAarch64TlsFirst -> Left TlsUnsupported
          | otherwise -> Left (UnsupportedReloc t)
      case v of
        Nothing -> go n arr rest
        Just patched -> case vaToFileOff segs (relaOffset r) of
          Nothing -> Left (BadDyn "rela outside LOAD")
          Just foff -> do
            if foff < 0 || foff + 8 > n
              then Left (BadDyn "rela outside LOAD")
              else do
                arr2 <- patchAt arr foff patched
                go n arr2 rest
