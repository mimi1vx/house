{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Loader
Description : Pure ELF64 aarch64 parser with caps (bounded build output).
Stability   : experimental

Parses static + PIE/shared aarch64 ELF64 (LE) with bounded metadata.
ET_EXEC retains the 0x01000000-0xFFFFFFFF window; ET_DYN accepts standard
low relative virtual addresses and BSS. Dynamic metadata is limited to
SysV hash, eager AArch64 symbol relocations, relative relocations, and
RELRO. PT_INTERP is pinned to /lib/ld-house.so.0 and recorded only.
The pure parser accepts dynamic metadata; effectful execution requires a link plan and mapping.

Input posture: the target is House's own dynamically linked executables,
built by a toolchain House pins. The caps are therefore a resource budget
for our own build output rather than untrusted-input hardening, and a DT_*
tag we have reason to ignore may be ignored. Bounded input stays bounded:
every cap and every checked bound still holds, and an unrecognised tag is
still a Left. Only the closed, reasoned set in skipDynTag is tolerated.
-}
module Kernel.Userspace.Loader (
  LoadError (..),
  Segment (..),
  Elf (..),
  DynInfo (..),
  DynSkip (..),
  InitArray (..),
  SkipReason (..),
  DynamicSymbol (..),
  DynamicSymbols (..),
  HashStyle (..),
  SysvHash (..),
  RelocationTable (..),
  RelocationTableKind (..),
  Relocation (..),
  RelativeRelocation (..),
  EagerSymbolRelocation (..),
  RelroRange (..),
  ldHousePath,
  stackPageStart,
  loadElf,
  constructorInLoads,
  validateStaticRunElf,
  loadErrorToString,
  skipDynTag,
  skippableDynTags,
  skipSummaryLine,
  applyRelativeRelocs,
  applyRelocsToFile,
  findNeededCycle,
  vaToFileOff,
  maxElfBytes,
  maxPhnum,
  maxSegments,
  maxSegMemSz,
  maxTotalPages,
  maxInterpLen,
  maxDynStrSz,
  maxNeeded,
  maxRelaCount,
  maxDynHashBuckets,
  maxDynSymbols,
  maxSymbolNameLen,
  maxInitArrayEntries,
  verNdxGlobal,
  verNdxLocal,
)
where

import Data.Bits (Bits (shiftL, shiftR), (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Word (Word16, Word32, Word64, Word8)

maxElfBytes :: Int
maxElfBytes = 1 `shiftL` 24

{- | Total program headers, a parse-work bound over every header a linker
emits. 16 covers ld.lld's 8 and glibc's 13 with margin; the mapping-work
bound is 'maxSegments' instead.
-}
maxPhnum :: Int
maxPhnum = 16

{- | Size-bearing segments (a @PT_LOAD@ with a non-zero file or memory size),
the quantity that actually bounds mapping work. Distinct from
'maxPhnum', which bounds total parse work over every program header.
-}
maxSegments :: Int
maxSegments = 8

maxSegMemSz :: Int
maxSegMemSz = 1024 * 1024

maxTotalPages :: Int
maxTotalPages = 256

minExecVAddr :: Word64
minExecVAddr = 0x01000000

maxVAddr :: Word64
maxVAddr = 0xFFFFFFFF

maxInterpLen :: Int
maxInterpLen = 256

maxDynStrSz :: Int
maxDynStrSz = 64 * 1024

maxNeeded :: Int
maxNeeded = 16

maxRelaCount :: Int
maxRelaCount = 32768

maxDynEnt :: Int
maxDynEnt = 64

maxNeededNameLen :: Int
maxNeededNameLen = 128

maxDynHashBuckets :: Int
maxDynHashBuckets = 4096

maxDynSymbols :: Int
maxDynSymbols = 16384

maxSymbolNameLen :: Int
maxSymbolNameLen = 256

-- | Constructor pointers per @DT_INIT_ARRAY@ / @DT_FINI_ARRAY@.
maxInitArrayEntries :: Int
maxInitArrayEntries = 64

ldHousePath :: String
ldHousePath = "/lib/ld-house.so.0"

stackPageStart :: Word64
stackPageStart = 0x3FFFD000

ptLoad, ptDynamic, ptInterp, ptTls :: Word32
ptLoad = 1
ptDynamic = 2
ptInterp = 3
ptTls = 7

ptGnuRelro :: Word32
ptGnuRelro = 0x6474E552

pfW :: Word32
pfW = 2

dtNull, dtNeeded, dtPltGot, dtStrtab, dtSymtab :: Word64
dtNull = 0
dtNeeded = 1
dtPltGot = 3
dtStrtab = 5
dtSymtab = 6

dtRela, dtRelasz, dtRelaent, dtStrsz, dtSyment :: Word64
dtRela = 7
dtRelasz = 8
dtRelaent = 9
dtStrsz = 10
dtSyment = 11

dtSoname, dtInit, dtFini :: Word64
dtSoname = 14
dtInit = 12
dtFini = 13

dtRel, dtRelsz, dtRelent, dtDebug, dtTextrel :: Word64
dtRel = 17
dtRelsz = 18
dtRelent = 19
dtDebug = 21
dtTextrel = 22

dtJmpRel, dtPltRelsz, dtPltRel, dtBindNow, dtFlags :: Word64
dtJmpRel = 23
dtPltRelsz = 2
dtPltRel = 20
dtBindNow = 24
dtFlags = 30

dtInitArray, dtFiniArray, dtInitArraySz, dtFiniArraySz :: Word64
dtInitArray = 25
dtFiniArray = 26
dtInitArraySz = 27
dtFiniArraySz = 28

dtRunPath, dtPreinitArray :: Word64
dtRunPath = 29
dtPreinitArray = 32

-- | 34 is DT_SYMTAB_SHNDX; there is no DT_PREINIT_ARRAYSZENT.
dtPreinitArraySz, dtSymtabShndx :: Word64
dtPreinitArraySz = 33
dtSymtabShndx = 34

dtRelaCount, dtHash, dtGnuHash, dtFlags1 :: Word64
dtRelaCount = 0x6FFFFFF9
dtHash = 4
dtGnuHash = 0x6FFFFEF5
dtFlags1 = 0x6FFFFFFB

dtRelr, dtRelrSz, dtRelrEnt :: Word64
dtRelr = 36
dtRelrSz = 35
dtRelrEnt = 37

dtVerSym, dtVerDef, dtVerNeed :: Word64
dtVerSym = 0x6FFFFFF0
dtVerDef = 0x6FFFFFFC
dtVerNeed = 0x6FFFFFFE

dtVerDefNum, dtVerNeedNum :: Word64
dtVerDefNum = 0x6FFFFFFD
dtVerNeedNum = 0x6FFFFFFF

dtTlsDescPlt, dtTlsDescGot, dtTlsMod, dtTlsLo, dtTlsHi :: Word64
dtTlsDescPlt = 0x6FFFFEF6
dtTlsDescGot = 0x6FFFFEF7
dtTlsMod = 0x6FFFFEF9
dtTlsLo = 0x6FFFFEFA
dtTlsHi = 0x6FFFFEFB

rAarch64Abs64 :: Word32
rAarch64Abs64 = 257

rAarch64GlobDat, rAarch64JumpSlot, rAarch64Relative :: Word32
rAarch64GlobDat = 1025
rAarch64JumpSlot = 1026
rAarch64Relative = 1027

rAarch64TlsFirst, rAarch64IRelative :: Word32
rAarch64TlsFirst = 1028
rAarch64IRelative = 1037

dfBindNow, dfTextrel :: Word64
dfBindNow = 0x8
dfTextrel = 0x4

df1Now :: Word64
df1Now = 0x1

sttTls :: Word8
sttTls = 6

{- | @VER_NDX_GLOBAL@: the symbol is not bound to a named version. A higher
index names one @VERDEF@ / @VERNEED@ entry, and that numbering is private to
the object that declares it, so an index is never comparable across DSOs.
-}
verNdxGlobal :: Word16
verNdxGlobal = 1

{- | @VER_NDX_LOCAL@: a hidden definition, bindable only inside the object that
defines it. It is an index like any other, so it has to be named rather than
left to read as \"absent\".
-}
verNdxLocal :: Word16
verNdxLocal = 0

data LoadError
  = BadMagic
  | BadArch
  | BadType
  | TooManyPhdrs
  | TooManySegments
  | BadSegment String
  | OverlapSize
  | NoSpace
  | Misaligned
  | OutOfWindow Word64
  | Truncated
  | BadDyn String
  | DependencyMissing String
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

data HashStyle
  = NoHash
  | SysVHash SysvHash
  deriving (Eq, Show)

data SysvHash = SysvHash {
  sysvHashOffset :: Int
  , sysvHashSize :: Int
  , sysvHashBuckets :: Int
  , sysvHashSymbols :: Int
  }
  deriving (Eq, Show)

data DynamicSymbol = DynamicSymbol {
  dynamicSymbolName :: String
  , dynamicSymbolInfo :: Word8
  , dynamicSymbolOther :: Word8
  , dynamicSymbolSection :: Word16
  , dynamicSymbolValue :: Word64
  , dynamicSymbolSize :: Word64
  , dynamicSymbolVersion :: Word16
  }
  deriving (Eq, Show)

data DynamicSymbols = DynamicSymbols {
  dynamicSymbolsOffset :: Int
  , dynamicSymbolsEntSize :: Int
  , dynamicSymbolEntries :: [DynamicSymbol]
  , -- Built once in 'parseDynamicSymbols': a relocation names its symbol by
    -- index, and walking the list per relocation is O(symbols x relocations)
    -- over input the caps otherwise admit.
    dynamicSymbolIndex :: Map Word32 DynamicSymbol
  }
  deriving (Eq, Show)

data RelocationTableKind
  = DynamicRelocations
  | PltRelocations
  deriving (Eq, Show)

data RelativeRelocation = RelativeRelocation {
  relativeOffset :: Word64
  , relativeAddend :: Word64
  }
  deriving (Eq, Show)

data EagerSymbolRelocation = EagerSymbolRelocation {
  eagerOffset :: Word64
  , eagerType :: Word32
  , eagerSymbolIndex :: Word32
  , eagerSymbolName :: String
  , eagerAddend :: Word64
  , eagerSymbolVersion :: Word16
  }
  deriving (Eq, Show)

data Relocation
  = RelativeBinding RelativeRelocation
  | EagerSymbolBinding EagerSymbolRelocation
  deriving (Eq, Show)

data RelocationTable = RelocationTable {
  relocationTableKind :: RelocationTableKind
  , relocationTableOffset :: Int
  , relocationTableSize :: Int
  , relocationTableEntSize :: Int
  , relocationTableEntries :: [Relocation]
  }
  deriving (Eq, Show)

data DynInfo = DynInfo {
  dynPresent :: Bool
  , dynNeeded :: [String]
  , dynSoname :: Maybe String
  , dynHashStyle :: HashStyle
  , dynBindNow :: Bool
  , dynFlags1 :: Word64
  , dynPltGot :: Maybe Word64
  , dynStrOff :: Int
  , dynStrSz :: Int
  , dynSymbols :: Maybe DynamicSymbols
  , dynRelocations :: [RelocationTable]
  , dynSkipped :: [DynSkip]
  , dynInitFn :: Maybe Word64
  , dynFiniFn :: Maybe Word64
  , dynInitArray :: Maybe InitArray
  , dynFiniArray :: Maybe InitArray
  }
  deriving (Eq, Show)

{- | A @DT_*@ tag the parser meets, does not need, and can prove cannot
change what is mapped or run. Each reason is the property that makes
ignoring the tag safe for a House-built image; there is no wildcard, and
'tag' returns 'Nothing' for everything else so an unrecognised tag still
fails.
-}
data SkipReason
  = SkipVersionedResolution
  | SkipRunPath
  | SkipRelocationHint
  | SkipExtendedSymbolIndex
  deriving (Eq, Show)

-- | One tolerated tag: its numeric value and why it is ignored.
data DynSkip = DynSkip {
  dynSkipTag :: Word64
  , dynSkipReason :: SkipReason
  }
  deriving (Eq, Show)

{- | The tolerated set, as a total function over an explicit enumeration.
A tag outside it is rejected: skipping an unknown tag would turn a refusal
into a silent misparse.
-}
skipDynTag :: Word64 -> Maybe SkipReason
skipDynTag tag
  | tag `elem` [dtVerNeed, dtVerNeedNum, dtVerDef, dtVerDefNum] = Just SkipVersionedResolution
  | tag == dtRunPath = Just SkipRunPath
  | tag == dtRelaCount = Just SkipRelocationHint
  | tag == dtSymtabShndx = Just SkipExtendedSymbolIndex
  | otherwise = Nothing

-- | The same set, enumerated so a test can pin it against a literal list.
skippableDynTags :: [Word64]
skippableDynTags = [dtVerNeed, dtVerNeedNum, dtVerDef, dtVerDefNum, dtRunPath, dtRelaCount, dtSymtabShndx]

-- | Short reason codes, in first-seen order, for the one dmesg line.
skipReasonCode :: SkipReason -> String
skipReasonCode reason = case reason of
  SkipVersionedResolution -> "ver"
  SkipRunPath -> "rpath"
  SkipRelocationHint -> "relacount"
  SkipExtendedSymbolIndex -> "xindex"

{- | The single bounded line naming what an image's dynamic table made the
loader ignore, or 'Nothing' when nothing was skipped. Distinct reasons only,
so the line is bounded by the size of the enumeration rather than by the
number of tags an image carries.
-}
skipSummaryLine :: String -> [DynSkip] -> Maybe String
skipSummaryLine name skipped
  | null reasons = Nothing
  | otherwise = Just ("dyn skip " ++ name ++ ": " ++ commaJoin codes ++ " (" ++ show (length skipped) ++ " tags)")
  where
    reasons = nubOn dynSkipReason skipped
    codes = map (skipReasonCode . dynSkipReason) reasons
    commaJoin [] = ""
    commaJoin (first : rest) = first ++ concatMap (',' :) rest
    nubOn key = foldr (\entry seen -> if key entry `elem` map key seen then seen else entry : seen) []

{- | One constructor array: where it lives in the object and how many
eight-byte entries it holds. The values are not known until the image is
relocated, so the parser records the table rather than the function
addresses it will contain.
-}
data InitArray = InitArray {
  initArrayVaddr :: Word64
  , initArrayEntries :: Int
  }
  deriving (Eq, Show)

data RelroRange = RelroRange {
  relroStart :: Word64
  , relroEnd :: Word64
  }
  deriving (Eq, Show)

data Elf = Elf {
  elfEntry :: Word64
  , elfSegs :: [Segment]
  , elfBytes :: ByteString
  , elfIsDyn :: Bool
  , elfInterp :: Maybe String
  , elfDyn :: DynInfo
  , elfRelro :: Maybe RelroRange
  }
  deriving (Eq, Show)

data DynAcc = DynAcc {
  accNeeded :: [Word64]
  , accSoname :: Maybe Word64
  , accStrtab :: Maybe Word64
  , accStrsz :: Maybe Word64
  , accSymtab :: Maybe Word64
  , accSyment :: Maybe Word64
  , accVerSym :: Maybe Word64
  , accHash :: Maybe Word64
  , accRela :: Maybe Word64
  , accRelasz :: Maybe Word64
  , accRelaent :: Maybe Word64
  , accJmpRel :: Maybe Word64
  , accPltRelsz :: Maybe Word64
  , accPltRel :: Maybe Word64
  , accPltGot :: Maybe Word64
  , accFlags :: Maybe Word64
  , accFlags1 :: Maybe Word64
  , accBindNowTag :: Bool
  , accDebugTag :: Bool
  , accSkipped :: [DynSkip]
  , accInitFn :: Maybe Word64
  , accFiniFn :: Maybe Word64
  , accInitArray :: Maybe Word64
  , accInitArraySz :: Maybe Word64
  , accFiniArray :: Maybe Word64
  , accFiniArraySz :: Maybe Word64
  , accDone :: Bool
  }
  deriving (Eq, Show)

emptyDynAcc :: DynAcc
emptyDynAcc =
  DynAcc {
    accNeeded = []
    , accSoname = Nothing
    , accStrtab = Nothing
    , accStrsz = Nothing
    , accSymtab = Nothing
    , accSyment = Nothing
    , accVerSym = Nothing
    , accHash = Nothing
    , accRela = Nothing
    , accRelasz = Nothing
    , accRelaent = Nothing
    , accJmpRel = Nothing
    , accPltRelsz = Nothing
    , accPltRel = Nothing
    , accPltGot = Nothing
    , accFlags = Nothing
    , accFlags1 = Nothing
    , accBindNowTag = False
    , accDebugTag = False
    , accSkipped = []
    , accInitFn = Nothing
    , accFiniFn = Nothing
    , accInitArray = Nothing
    , accInitArraySz = Nothing
    , accFiniArray = Nothing
    , accFiniArraySz = Nothing
    , accDone = False
    }

emptyDynInfo :: DynInfo
emptyDynInfo =
  DynInfo {
    dynPresent = False
    , dynNeeded = []
    , dynSoname = Nothing
    , dynHashStyle = NoHash
    , dynBindNow = False
    , dynFlags1 = 0
    , dynPltGot = Nothing
    , dynStrOff = 0
    , dynStrSz = 0
    , dynSymbols = Nothing
    , dynRelocations = []
    , dynSkipped = []
    , dynInitFn = Nothing
    , dynFiniFn = Nothing
    , dynInitArray = Nothing
    , dynFiniArray = Nothing
    }

loadErrorToString :: LoadError -> String
loadErrorToString e = case e of
  BadMagic -> "BadMagic: not ELF64 LE"
  BadArch -> "BadArch: need AArch64"
  BadType -> "BadType: need ET_EXEC/ET_DYN"
  TooManyPhdrs -> "TooManyPhdrs: >" ++ show maxPhnum ++ " program headers"
  TooManySegments -> "TooManySegments: >" ++ show maxSegments ++ " size-bearing segments"
  BadSegment s -> "BadSegment: " ++ s
  OverlapSize -> "OverlapSize: p_offset+p_filesz overflow or > file"
  NoSpace -> "NoSpace: total pages >" ++ show maxTotalPages ++ " or memsz >" ++ show maxSegMemSz
  Misaligned -> "Misaligned: bad p_align or p_offset"
  OutOfWindow v -> "OutOfWindow: 0x" ++ showHex64 v
  Truncated -> "Truncated"
  BadDyn s -> "BadDyn: " ++ s
  DependencyMissing s -> "DependencyMissing: " ++ s
  UnsupportedReloc t -> "UnsupportedReloc: " ++ show t
  TlsUnsupported -> "TlsUnsupported"
  NeededCycle -> "NeededCycle"

showHex64 :: Word64 -> String
showHex64 w = if w == 0 then "0" else go w
  where
    go n
      | n < 16 = [hexDigit (fromIntegral n)]
      | otherwise = go (n `div` 16) ++ [hexDigit (fromIntegral (n `mod` 16))]
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

loadElf :: ByteString -> Either LoadError Elf
loadElf bytes
  | BS.length bytes > maxElfBytes = Left OverlapSize
  | BS.length bytes < 64 = Left Truncated
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
              Right segs -> case validateSegments segs bytes entry isDyn of
                Left e -> Left e
                Right validSegs -> case collectRawPhdrs bytes phoff phnum phentsz of
                  Left e -> Left e
                  Right raws -> case parseInterp raws bytes of
                    Left e -> Left e
                    Right interp -> case parseRelro raws validSegs of
                      Left e -> Left e
                      Right relro -> case parseDynamic raws bytes validSegs of
                        Left e -> Left e
                        Right dyn -> Right (Elf entry validSegs bytes isDyn interp dyn relro)

validateStaticRunElf :: Elf -> Either LoadError ()
validateStaticRunElf elf
  | elfIsDyn elf || isJust (elfInterp elf) || dynPresent (elfDyn elf) = Left (BadDyn "dynamic ELF rejected for static execution")
  | otherwise = Right ()

{- | Magic, ELF64, little-endian, and current version. Bytes 7-15 (OS/ABI
and padding) are unconstrained, as before.
-}
elfIdent :: ByteString
elfIdent = BS.pack [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1]

checkIdent :: ByteString -> Either LoadError ()
checkIdent bs = if BS.take 7 bs == elfIdent then Right () else Left BadMagic

parseHeader :: ByteString -> Either LoadError (Bool, Word64, Word64, Int, Int)
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

checkPhoff :: Word64 -> Int -> Int -> ByteString -> Either LoadError ()
checkPhoff phoff phnum phentsz bs
  | phoff > fromIntegral (maxBound :: Int) = Left OverlapSize
  | otherwise =
      let ent = if phentsz == 0 then 56 else phentsz
          needed = fromIntegral phoff + phnum * ent
       in if needed > BS.length bs
            then Left Truncated
            else
              if ent /= 56 && phnum > 0
                then Left (BadSegment "phentsz !=56")
                else Right ()

type RawPhdr = (Word32, Word32, Word64, Word64, Word64, Word64, Word64)

rawType :: RawPhdr -> Word32
rawType (t, _, _, _, _, _, _) = t

collectRawPhdrs :: ByteString -> Word64 -> Int -> Int -> Either LoadError [RawPhdr]
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

parseOneRaw :: ByteString -> Int -> Either LoadError RawPhdr
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

parseSegments :: ByteString -> Word64 -> Int -> Int -> Either LoadError [Segment]
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

parseOneSegment :: ByteString -> Int -> Either LoadError Segment
parseOneSegment bs off = do
  pType <- getWord32LE bs off
  pFlags <- getWord32LE bs (off + 4)
  pOff <- getWord64LE bs (off + 8)
  pVaddr <- getWord64LE bs (off + 16)
  _pPaddr <- getWord64LE bs (off + 24)
  pFilesz <- getWord64LE bs (off + 32)
  pMemsz <- getWord64LE bs (off + 40)
  pAlign <- getWord64LE bs (off + 48)
  if pType == ptTls
    then Left TlsUnsupported
    else
      if pType /= ptLoad
        then Right (Segment pVaddr (fromIntegral pOff) 0 0 pFlags)
        else do
          if pFilesz > fromIntegral maxSegMemSz || pMemsz > fromIntegral maxSegMemSz
            then Left NoSpace
            else Right ()
          if pFilesz > pMemsz then Left (BadSegment "filesz > memsz") else Right ()
          if not (validAlign pAlign) then Left Misaligned else Right ()
          if pAlign /= 0 && ((pVaddr - pOff) .&. (pAlign - 1)) /= 0
            then Left Misaligned
            else Right ()
          Right (Segment pVaddr (fromIntegral pOff) (fromIntegral pFilesz) (fromIntegral pMemsz) pFlags)
  where
    validAlign a = a == 0 || (a >= 4096 && a <= 65536 && isPowerOfTwo a)
    isPowerOfTwo 0 = False
    isPowerOfTwo x = (x .&. (x - 1)) == 0

validateSegments :: [Segment] -> ByteString -> Word64 -> Bool -> Either LoadError [Segment]
validateSegments segs bytes entry isDyn =
  let loads = sortOn segVaddr (filter (\s -> segMemSz s > 0 || segFileSz s > 0) segs)
      len = BS.length bytes
   in do
        checkVaddr entry
        if not isDyn && any (\s -> segFileSz s < segMemSz s) loads
          then Left (BadSegment "static BSS unsupported")
          else Right ()
        if length loads > maxSegments then Left TooManySegments else Right ()
        mapM_ (checkSeg len) loads
        checkPageOverlap loads
        checkStackCollision loads
        let pages = sum [lastPage - firstPage + 1 | (firstPage, lastPage) <- map pageBounds loads]
        if pages > fromIntegral maxTotalPages then Left NoSpace else Right ()
        case filter (entryInSeg entry) loads of
          [] -> Left (BadSegment "entry not in LOAD")
          _ -> Right loads
  where
    checkVaddr v
      | isDyn = if v > maxVAddr then Left (OutOfWindow v) else Right ()
      | otherwise = if v < minExecVAddr || v > maxVAddr then Left (OutOfWindow v) else Right ()
    entryInSeg e s =
      let va = segVaddr s
          end = va + fromIntegral (segMemSz s)
       in end >= va && e >= va && e < end
    checkSeg len s = do
      let va = segVaddr s
          off = segFileOff s
          fsz = segFileSz s
          msz = segMemSz s
      checkVaddr va
      let vaEnd = va + fromIntegral msz
      if vaEnd < va then Left OverlapSize else Right ()
      if vaEnd > maxVAddr + 1 then Left (OutOfWindow vaEnd) else Right ()
      if off < 0 || fsz < 0 || off > len || fsz > len - off then Left OverlapSize else Right ()
    pageBounds s =
      let va = segVaddr s
          end = va + fromIntegral (segMemSz s)
       in (va `div` 4096, (end - 1) `div` 4096)
    checkPageOverlap [] = Right ()
    checkPageOverlap (s : rest) = do
      mapM_ (checkPair s) rest
      checkPageOverlap rest
    checkPair a b =
      let (aFirst, aLastPage) = pageBounds a
          (bFirst, bLastPage) = pageBounds b
       in if aFirst <= bLastPage && bFirst <= aLastPage
            then Left (BadSegment "overlapping LOAD pages")
            else Right ()
    checkStackCollision = mapM_ checkStack
    checkStack s =
      let (first, lastPage) = pageBounds s
          stackPage = stackPageStart `div` 4096
       in if first <= stackPage && stackPage <= lastPage
            then Left (BadSegment "stack page collision")
            else Right ()

parseInterp :: [RawPhdr] -> ByteString -> Either LoadError (Maybe String)
parseInterp raws bytes =
  case [r | r <- raws, rawType r == ptInterp] of
    [] -> Right Nothing
    [r] -> parseOneInterp r bytes
    _ -> Left (BadDyn "double-interp")

parseOneInterp :: RawPhdr -> ByteString -> Either LoadError (Maybe String)
parseOneInterp (_, _, pOff, _, pFilesz, _, _) bytes = do
  let len = BS.length bytes
      fsz = fromIntegral pFilesz :: Int
      off = fromIntegral pOff :: Int
  if pFilesz > fromIntegral maxInterpLen then Left (BadDyn "interp too long") else Right ()
  if fsz <= 0 then Left (BadDyn "interp empty") else Right ()
  if off < 0 || off > len then Left Truncated else Right ()
  if fsz > len - off then Left Truncated else Right ()
  let raw = BS.take fsz (BS.drop off bytes)
  case BS.elemIndex 0 raw of
    Nothing -> Left (BadDyn "interp not NUL-terminated")
    Just end -> do
      let name = BS.take end raw
          rest = BS.drop (end + 1) raw
      if BS.any (/= 0) rest then Left (BadDyn "interp trailing bytes") else Right ()
      if BS.null name then Left (BadDyn "interp empty") else Right ()
      if BS.any (\b -> b < 32 || b > 126) name then Left (BadDyn "interp non-printable") else Right ()
      let s = map (chr . fromIntegral) (BS.unpack name)
      if s /= ldHousePath then Left (BadDyn ("interp path " ++ s)) else Right (Just s)

parseRelro :: [RawPhdr] -> [Segment] -> Either LoadError (Maybe RelroRange)
parseRelro raws loads =
  case [r | r <- raws, rawType r == ptGnuRelro] of
    [] -> Right Nothing
    [(_, _, _, vaddr, _, memsz, _)] -> parseOneRelro vaddr memsz loads
    _ -> Left (BadDyn "double-relro")

parseOneRelro :: Word64 -> Word64 -> [Segment] -> Either LoadError (Maybe RelroRange)
parseOneRelro vaddr memsz loads
  | memsz == 0 = Right Nothing
  | otherwise = do
      let end = vaddr + memsz
      if end < vaddr then Left OverlapSize else Right ()
      if any (contains vaddr end) loads
        then Right (Just (RelroRange vaddr end))
        else Left (BadDyn "relro outside LOAD")
  where
    contains s e seg =
      let va = segVaddr seg
          segEnd = va + fromIntegral (segMemSz seg)
       in segEnd >= va && s >= va && s < segEnd && e > va && e <= segEnd

parseDynamic :: [RawPhdr] -> ByteString -> [Segment] -> Either LoadError DynInfo
parseDynamic raws bytes loads =
  case [r | r <- raws, rawType r == ptDynamic] of
    [] -> Right emptyDynInfo
    [(_, _, pOff, _, pFilesz, _, _)] -> parseOneDynamic pOff pFilesz bytes loads
    _ -> Left (BadDyn "double-dynamic")

parseOneDynamic :: Word64 -> Word64 -> ByteString -> [Segment] -> Either LoadError DynInfo
parseOneDynamic pOff pFilesz bytes loads = do
  let len = BS.length bytes
      off = fromIntegral pOff :: Int
      sz = fromIntegral pFilesz :: Int
  if off < 0 || off > len then Left Truncated else Right ()
  if sz < 0 || sz > len - off then Left Truncated else Right ()
  if sz `mod` 16 /= 0 then Left (BadDyn "dynamic size") else Right ()
  let n = sz `div` 16
  if n > maxDynEnt then Left (BadDyn "dynamic too many") else Right ()
  acc <- walkDyn bytes off n 0 emptyDynAcc
  if not (accDone acc) then Left (BadDyn "missing DT_NULL") else Right ()
  finishDyn bytes acc loads len

walkDyn :: ByteString -> Int -> Int -> Int -> DynAcc -> Either LoadError DynAcc
walkDyn _ _ total i a
  | i >= total = Right a
  | accDone a = Right a
walkDyn bytes off total i a = do
  tag <- getU64 bytes (off + i * 16)
  val <- getU64 bytes (off + i * 16 + 8)
  a2 <- stepDyn tag val a
  walkDyn bytes off total (i + 1) a2

stepDyn :: Word64 -> Word64 -> DynAcc -> Either LoadError DynAcc
stepDyn tag val a
  | tag == dtNull = Right a {accDone = True}
  | tag == dtNeeded = Right a {accNeeded = accNeeded a ++ [val]}
  | tag == dtSoname = setOnce "SONAME" accSoname (\x v -> x {accSoname = v}) val a
  | tag == dtStrtab = setOnce "STRTAB" accStrtab (\x v -> x {accStrtab = v}) val a
  | tag == dtStrsz = setOnce "STRSZ" accStrsz (\x v -> x {accStrsz = v}) val a
  | tag == dtSymtab = setOnce "SYMTAB" accSymtab (\x v -> x {accSymtab = v}) val a
  | tag == dtSyment = setOnce "SYMENT" accSyment (\x v -> x {accSyment = v}) val a
  | tag == dtVerSym = setOnce "VERSYM" accVerSym (\x v -> x {accVerSym = v}) val a
  | tag == dtHash = setOnce "HASH" accHash (\x v -> x {accHash = v}) val a
  | tag == dtRela = setOnce "RELA" accRela (\x v -> x {accRela = v}) val a
  | tag == dtRelasz = setOnce "RELASZ" accRelasz (\x v -> x {accRelasz = v}) val a
  | tag == dtRelaent = setOnce "RELAENT" accRelaent (\x v -> x {accRelaent = v}) val a
  | tag == dtJmpRel = setOnce "JMPREL" accJmpRel (\x v -> x {accJmpRel = v}) val a
  | tag == dtPltRelsz = setOnce "PLTRELSZ" accPltRelsz (\x v -> x {accPltRelsz = v}) val a
  | tag == dtPltRel = setOnce "PLTREL" accPltRel (\x v -> x {accPltRel = v}) val a
  | tag == dtPltGot = setOnce "PLTGOT" accPltGot (\x v -> x {accPltGot = v}) val a
  | tag == dtFlags = setOnce "FLAGS" accFlags (\x v -> x {accFlags = v}) val a
  | tag == dtFlags1 = setOnce "FLAGS_1" accFlags1 (\x v -> x {accFlags1 = v}) val a
  | tag == dtBindNow =
      if accBindNowTag a
        then Left (BadDyn "duplicate BIND_NOW")
        else Right a {accBindNowTag = True}
  | tag == dtDebug =
      if accDebugTag a
        then Left (BadDyn "duplicate DEBUG")
        else Right a {accDebugTag = True}
  | tag == dtGnuHash = Left (BadDyn "GNU hash unsupported")
  | tag == dtTextrel = Left (BadDyn "TEXTREL unsupported")
  | tag `elem` [dtRel, dtRelsz, dtRelent] = Left (BadDyn "S REL unsupported")
  | tag == dtInit = setOnce "INIT" accInitFn (\x v -> x {accInitFn = v}) val a
  | tag == dtFini = setOnce "FINI" accFiniFn (\x v -> x {accFiniFn = v}) val a
  | tag == dtInitArray = setOnce "INIT_ARRAY" accInitArray (\x v -> x {accInitArray = v}) val a
  | tag == dtInitArraySz = setOnce "INIT_ARRAYSZ" accInitArraySz (\x v -> x {accInitArraySz = v}) val a
  | tag == dtFiniArray = setOnce "FINI_ARRAY" accFiniArray (\x v -> x {accFiniArray = v}) val a
  | tag == dtFiniArraySz = setOnce "FINI_ARRAYSZ" accFiniArraySz (\x v -> x {accFiniArraySz = v}) val a
  | tag `elem` [dtPreinitArray, dtPreinitArraySz] = Left (BadDyn "preinit array unsupported")
  | tag `elem` [dtRelr, dtRelrSz, dtRelrEnt] = Left (BadDyn "RELR unsupported")
  | tag `elem` [dtTlsDescPlt, dtTlsDescGot, dtTlsMod, dtTlsLo, dtTlsHi] = Left TlsUnsupported
  | otherwise = case skipDynTag tag of
      Just reason -> Right a {accSkipped = accSkipped a ++ [DynSkip tag reason]}
      Nothing -> Left (BadDyn ("unsupported DT_" ++ show tag))
  where
    setOnce :: String -> (DynAcc -> Maybe Word64) -> (DynAcc -> Maybe Word64 -> DynAcc) -> Word64 -> DynAcc -> Either LoadError DynAcc
    setOnce name get set value acc = case get acc of
      Just _ -> Left (BadDyn ("duplicate " ++ name))
      Nothing -> Right (set acc (Just value))

finishDyn :: ByteString -> DynAcc -> [Segment] -> Int -> Either LoadError DynInfo
finishDyn bytes acc loads len = do
  strSz64 <- case accStrsz acc of
    Nothing -> Right 0
    Just n
      | n > fromIntegral maxDynStrSz -> Left (BadDyn "strsz overrun")
      | otherwise -> Right n
  let strSz = fromIntegral strSz64 :: Int
      needStr =
        not (null (accNeeded acc))
          || isJust (accSoname acc)
          || isJust (accHash acc)
          || isJust (accSymtab acc)
          || strSz /= 0
  strOff <- case accStrtab acc of
    Nothing -> if needStr then Left (BadDyn "missing STRTAB") else Right 0
    Just va -> do
      (off, _) <- vaTableOff loads va strSz
      if off < 0 || off > len || strSz > len - off then Left (BadDyn "strtab bounds") else Right off
  strSlice <- sliceBytes bytes strOff strSz
  needed <- mapM (resolveNeeded strSlice strSz) (accNeeded acc)
  soname <- traverse (resolveString "soname" maxSymbolNameLen strSlice strSz) (accSoname acc)
  (hashStyle, symbols) <- parseHashAndSymbols bytes acc strSlice strSz loads
  bindNow <- dynamicBindNow acc
  mainTable <- parseMainRelocations bytes acc loads symbols bindNow
  pltTable <- parsePltRelocations bytes acc loads symbols bindNow
  pltGot <- traverse (validatePltGot loads) (accPltGot acc)
  let tables = maybe [] pure mainTable ++ maybe [] pure pltTable
      totalCount = sum (map (\t -> relocationTableSize t `div` relocationTableEntSize t) tables)
  if totalCount > maxRelaCount then Left (BadDyn "rela count") else Right ()
  initFn <- validateMaybeConstructor "DT_INIT" loads (accInitFn acc)
  finiFn <- validateMaybeConstructor "DT_FINI" loads (accFiniFn acc)
  initArray <- validateConstructorArray "init" loads (accInitArray acc) (accInitArraySz acc)
  finiArray <- validateConstructorArray "fini" loads (accFiniArray acc) (accFiniArraySz acc)
  let flags1 = fromMaybe 0 (accFlags1 acc)
  Right
    DynInfo {
      dynPresent = True
      , dynNeeded = needed
      , dynSoname = soname
      , dynHashStyle = hashStyle
      , dynBindNow = bindNow
      , dynFlags1 = flags1
      , dynPltGot = pltGot
      , dynStrOff = strOff
      , dynStrSz = strSz
      , dynSymbols = symbols
      , dynRelocations = tables
      , dynSkipped = accSkipped acc
      , dynInitFn = initFn
      , dynFiniFn = finiFn
      , dynInitArray = initArray
      , dynFiniArray = finiArray
      }

validateMaybeConstructor :: String -> [Segment] -> Maybe Word64 -> Either LoadError (Maybe Word64)
validateMaybeConstructor _ _ Nothing = Right Nothing
validateMaybeConstructor label loads (Just va) = Just <$> validateConstructorFn label loads va

{- | A @DT_INIT@ / @DT_FINI@ value must name code inside one of this
object's own PT_LOADs, so the runtime never calls an unbounded address.
-}
validateConstructorFn :: String -> [Segment] -> Word64 -> Either LoadError Word64
validateConstructorFn label loads va
  | constructorInLoads 0 loads va = Right va
  | otherwise = Left (BadDyn (label ++ " outside LOAD"))

{- | Whether @va@, relocated by @base@, names code inside one of the object's
own PT_LOADs. One bound for both the @DT_INIT@ / @DT_FINI@ values the parser
sees and the @DT_INIT_ARRAY@ / @DT_FINI_ARRAY@ targets the runtime reads out of
the mapped image: the array's contents are only written by relocation, so the
check on them cannot live at parse time.
-}
constructorInLoads :: Word64 -> [Segment] -> Word64 -> Bool
constructorInLoads base loads va = any inside loads
  where
    inside segment =
      let start = base + segVaddr segment
          end = start + fromIntegral (segMemSz segment)
       in va >= start && va < end

{- | A constructor array must be complete (address and size), a whole number
of pointers, file-backed inside this object's own PT_LOADs, and within the
entry cap. A half-present array is a refusal, not a guess.
-}
validateConstructorArray :: String -> [Segment] -> Maybe Word64 -> Maybe Word64 -> Either LoadError (Maybe InitArray)
validateConstructorArray _ _ Nothing Nothing = Right Nothing
validateConstructorArray label loads (Just va) (Just size)
  | size `mod` 8 /= 0 = Left (BadDyn (label ++ " array size"))
  | entries > maxInitArrayEntries = Left (BadDyn (label ++ " array entries exceed cap"))
  | not (any fileBacked loads) = Left (BadDyn (label ++ " array outside LOAD"))
  | otherwise = pure (Just (InitArray va entries))
  where
    entries = fromIntegral (size `div` 8) :: Int
    fileBacked segment =
      let start = segVaddr segment
          fileEnd = start + fromIntegral (segFileSz segment)
       in va >= start && va + size <= fileEnd
validateConstructorArray label _ _ _ = Left (BadDyn ("incomplete " ++ label ++ " array metadata"))

dynamicBindNow :: DynAcc -> Either LoadError Bool
dynamicBindNow acc
  | (flags .&. dfTextrel) /= 0 = Left (BadDyn "TEXTREL unsupported")
  | otherwise = Right (accBindNowTag acc || (flags .&. dfBindNow) /= 0 || (flags1 .&. df1Now) /= 0)
  where
    flags = fromMaybe 0 (accFlags acc)
    flags1 = fromMaybe 0 (accFlags1 acc)

parseHashAndSymbols :: ByteString -> DynAcc -> ByteString -> Int -> [Segment] -> Either LoadError (HashStyle, Maybe DynamicSymbols)
parseHashAndSymbols bytes acc strSlice strSz loads =
  case (accHash acc, accSymtab acc) of
    (Nothing, Nothing)
      | isJust (accSyment acc) -> Left (BadDyn "SYMENT without symbol metadata")
      | isJust (accVerSym acc) -> Left (BadDyn "VERSYM without symbol metadata")
      | otherwise -> Right (NoHash, Nothing)
    (Just hashVa, Just symVa) -> do
      hash <- parseSysvHash bytes hashVa loads
      syment <- case accSyment acc of
        Nothing -> Right 24
        Just n
          | n == 24 -> Right 24
          | otherwise -> Left (BadDyn "syment")
      versions <- parseSymbolVersions bytes (accVerSym acc) (sysvHashSymbols hash) loads
      symbols <- parseDynamicSymbols bytes symVa (sysvHashSymbols hash) syment versions strSlice strSz loads
      Right (SysVHash hash, Just symbols)
    _ -> Left (BadDyn "incomplete symbol metadata")

{- | One @Elf64_Half@ per dynamic symbol, index-aligned with the symbol
table. An object carrying no @DT_VERSYM@ versions nothing, so every symbol
reads as 'verNdxGlobal'.
-}
parseSymbolVersions :: ByteString -> Maybe Word64 -> Int -> [Segment] -> Either LoadError [Word16]
parseSymbolVersions _ Nothing _ _ = Right []
parseSymbolVersions bytes (Just va) count loads = do
  let total = count * 2
  (off, tableSize) <- vaTableOff loads va total
  if tableSize /= total then Left (BadDyn "versym bounds") else Right ()
  mapM (\i -> getU16 bytes (off + 2 * i)) [0 .. count - 1]

parseSysvHash :: ByteString -> Word64 -> [Segment] -> Either LoadError SysvHash
parseSysvHash bytes hashVa loads = do
  (off, _) <- vaTableOff loads hashVa 8
  buckets <- getU32 bytes off
  symbols <- getU32 bytes (off + 4)
  if buckets == 0 then Left (BadDyn "hash buckets") else Right ()
  if buckets > fromIntegral maxDynHashBuckets then Left (BadDyn "hash buckets") else Right ()
  if symbols == 0 || symbols > fromIntegral maxDynSymbols then Left (BadDyn "symbol count") else Right ()
  let total = 8 + 4 * (fromIntegral buckets + fromIntegral symbols)
  (tableOff, tableSize) <- vaTableOff loads hashVa total
  if tableSize /= total then Left (BadDyn "hash bounds") else Right ()
  mapM_ (checkBucket off symbols) [0 .. fromIntegral buckets - 1]
  mapM_ (checkChain off (fromIntegral buckets) symbols) [0 .. fromIntegral symbols - 1]
  Right (SysvHash tableOff tableSize (fromIntegral buckets) (fromIntegral symbols))
  where
    checkBucket tableOff count i = do
      bucketIndex <- getU32 bytes (tableOff + 8 + 4 * i)
      if bucketIndex >= count then Left (BadDyn "hash bucket index") else Right ()
    checkChain tableOff bucketCount count i = do
      chainIndex <- getU32 bytes (tableOff + 8 + 4 * bucketCount + 4 * i)
      if chainIndex /= 0 && chainIndex >= count then Left (BadDyn "hash chain index") else Right ()

parseDynamicSymbols :: ByteString -> Word64 -> Int -> Int -> [Word16] -> ByteString -> Int -> [Segment] -> Either LoadError DynamicSymbols
parseDynamicSymbols bytes symVa count syment versions strSlice strSz loads = do
  let total = count * 24
  (off, tableSize) <- vaTableOff loads symVa total
  if tableSize /= total then Left (BadDyn "symtab bounds") else Right ()
  -- The VERSYM table is index-aligned with the symbol table, so it is walked
  -- alongside it: indexing a list once per symbol makes the parse quadratic in
  -- the symbol count, which the cap admits.
  parsed <- mapM (parseOne off) (zip [0 .. count - 1] (versions ++ repeat verNdxGlobal))
  let entries = catMaybes parsed
  Right (DynamicSymbols off syment entries (Map.fromList (zip [0 ..] entries)))
  where
    parseOne tableOff (i, version) = do
      let base = tableOff + i * 24
      nameOff <- getU32 bytes base
      info <- getU8 bytes (base + 4)
      other <- getU8 bytes (base + 5)
      shndx <- getU16 bytes (base + 6)
      value <- getU64 bytes (base + 8)
      symbolSize <- getU64 bytes (base + 16)
      name <- resolveMaybeSymbolName strSlice strSz nameOff
      if (info .&. 0x0F) == sttTls then Left (BadDyn "TLS symbol unsupported") else Right ()
      Right (Just (DynamicSymbol name info other shndx value symbolSize version))

resolveMaybeSymbolName :: ByteString -> Int -> Word32 -> Either LoadError String
resolveMaybeSymbolName strSlice strSz nameOff
  | fromIntegral nameOff >= strSz = Left (BadDyn "symbol name offset")
  | otherwise = resolvePrintable "symbol" maxSymbolNameLen strSlice strSz (fromIntegral nameOff)

resolveNeeded :: ByteString -> Int -> Word64 -> Either LoadError String
resolveNeeded strSlice strSz off64 = do
  if off64 >= fromIntegral strSz then Left (BadDyn "needed off") else Right ()
  let off = fromIntegral off64 :: Int
  name <- resolvePrintable "needed" maxNeededNameLen strSlice strSz off
  if null name then Left (BadDyn "needed empty") else Right ()
  if '/' `elem` name then Left (BadDyn "needed slash") else Right name

resolveString :: String -> Int -> ByteString -> Int -> Word64 -> Either LoadError String
resolveString label limit strSlice strSz off = do
  name <- resolvePrintable label limit strSlice strSz (fromIntegral off)
  if null name then Left (BadDyn (label ++ " empty")) else Right name

resolvePrintable :: String -> Int -> ByteString -> Int -> Int -> Either LoadError String
resolvePrintable label limit strSlice strSz off
  | off < 0 || off >= strSz = Left (BadDyn (label ++ " offset"))
  | otherwise =
      case BS.elemIndex 0 (BS.drop off strSlice) of
        Nothing -> Left (BadDyn (label ++ " not NUL"))
        Just end ->
          let name = BS.take end (BS.drop off strSlice)
           in if BS.length name > limit
                then Left (BadDyn (label ++ " too long"))
                else
                  if BS.any (\b -> b < 32 || b > 126) name
                    then Left (BadDyn (label ++ " non-printable"))
                    else Right (map (chr . fromIntegral) (BS.unpack name))

parseMainRelocations :: ByteString -> DynAcc -> [Segment] -> Maybe DynamicSymbols -> Bool -> Either LoadError (Maybe RelocationTable)
parseMainRelocations bytes acc loads symbols bindNow = do
  count <- tableCount "RELA" (accRela acc) (accRelasz acc) (accRelaent acc)
  case (count, accRela acc) of
    (0, _) -> Right Nothing
    (_, Nothing) -> Left (BadDyn "missing RELA")
    (_, Just va) -> Just <$> parseRelaTable DynamicRelocations bytes va count loads symbols bindNow

parsePltRelocations :: ByteString -> DynAcc -> [Segment] -> Maybe DynamicSymbols -> Bool -> Either LoadError (Maybe RelocationTable)
parsePltRelocations bytes acc loads symbols bindNow =
  case (accJmpRel acc, accPltRelsz acc, accPltRel acc) of
    (Nothing, Nothing, Nothing) -> Right Nothing
    (Just va, Just size, Just kind) -> do
      if kind /= dtRela then Left (BadDyn "PLTREL unsupported") else Right ()
      count <- tableCount "PLT" (Just va) (Just size) (Just 24)
      if count == 0
        then Right Nothing
        else Just <$> parseRelaTable PltRelocations bytes va count loads symbols bindNow
    _ -> Left (BadDyn "incomplete PLT relocation metadata")

tableCount :: String -> Maybe Word64 -> Maybe Word64 -> Maybe Word64 -> Either LoadError Int
tableCount label address size entry = do
  let hasMetadata = isJust address || isJust size || isJust entry
  if not hasMetadata
    then Right 0
    else case (address, size, entry) of
      (Just _, Just sizeN, Just entryN)
        | entryN == 24 && sizeN `mod` 24 == 0 ->
            let count = sizeN `div` 24
             in if count > fromIntegral maxRelaCount
                  then Left (BadDyn "rela count")
                  else Right (fromIntegral count)
      _ -> Left (BadDyn ("incomplete " ++ label ++ " metadata"))

parseRelaTable :: RelocationTableKind -> ByteString -> Word64 -> Int -> [Segment] -> Maybe DynamicSymbols -> Bool -> Either LoadError RelocationTable
parseRelaTable kind bytes va count loads symbols bindNow = do
  let size = count * 24
  (off, tableSize) <- vaTableOff loads va size
  if tableSize /= size then Left (BadDyn "rela bounds") else Right ()
  parsed <- mapM (parseOne off) [0 .. count - 1]
  let entries = catMaybes parsed
  Right (RelocationTable kind off size 24 entries)
  where
    parseOne tableOff i = do
      let base = tableOff + i * 24
      rOff <- getU64 bytes base
      info <- getU64 bytes (base + 8)
      add <- getU64 bytes (base + 16)
      let typ = fromIntegral (info .&. 0xFFFFFFFF) :: Word32
          sym = fromIntegral (info `shiftR` 32) :: Word32
      parseRelocation typ sym rOff add loads symbols bindNow

parseRelocation :: Word32 -> Word32 -> Word64 -> Word64 -> [Segment] -> Maybe DynamicSymbols -> Bool -> Either LoadError (Maybe Relocation)
parseRelocation typ sym rOff add loadsRequired symbols bindNow
  | typ == 0 = if sym == 0 then Right Nothing else Left (BadDyn "R_NONE symbol index")
  | typ == rAarch64Relative = do
      if sym /= 0 then Left (UnsupportedReloc typ) else Right ()
      if not (relocTargetIn loadsRequired rOff False) then Left (BadDyn "rela outside LOAD") else Right ()
      Right (Just (RelativeBinding (RelativeRelocation rOff add)))
  | typ == rAarch64GlobDat || typ == rAarch64JumpSlot || typ == rAarch64Abs64 = do
      {- ABS64 writes the absolute address itself rather than a PLT or GOT
      slot, so it is eager by construction: refusing it without bind-now
      would refuse every library that does not ask to be bind-now. -}
      if typ /= rAarch64Abs64 && not bindNow then Left (BadDyn "eager relocation without bind-now") else Right ()
      if sym == 0 then Left (BadDyn "eager relocation symbol zero") else Right ()
      if not (relocTargetIn loadsRequired rOff True) then Left (BadDyn "rela target not writable") else Right ()
      symbol <- case symbols of
        Nothing -> Left (BadDyn "eager relocation without SYMTAB")
        Just table -> case Map.lookup sym (dynamicSymbolIndex table) of
          Nothing -> Left (BadDyn "eager relocation symbol index")
          Just found -> Right found
      if null (dynamicSymbolName symbol)
        then Left (BadDyn "eager relocation symbol name")
        else Right ()
      Right (Just (EagerSymbolBinding (EagerSymbolRelocation rOff typ sym (dynamicSymbolName symbol) add (dynamicSymbolVersion symbol))))
  | typ >= rAarch64TlsFirst && typ /= rAarch64IRelative = Left TlsUnsupported
  | typ == rAarch64IRelative = Left (BadDyn "IRELATIVE unsupported")
  | otherwise = Left (UnsupportedReloc typ)

relocTargetIn :: [Segment] -> Word64 -> Bool -> Bool
relocTargetIn loads target requireWritable =
  any inside loads
  where
    inside seg =
      let start = segVaddr seg
          end = start + fromIntegral (segMemSz seg)
          writable = (segFlags seg .&. pfW) /= 0
       in segMemSz seg >= 8
            && end >= start
            && target >= start
            && target <= end - 8
            && (not requireWritable || writable)

validatePltGot :: [Segment] -> Word64 -> Either LoadError Word64
validatePltGot loads va
  | any (\s -> va >= segVaddr s && va < segVaddr s + fromIntegral (segMemSz s)) loads = Right va
  | otherwise = Left (BadDyn "PLTGOT outside LOAD")

vaToFileOff :: [Segment] -> Word64 -> Maybe Int
vaToFileOff loads va = case vaTableFileRange loads va 8 of
  Right (off, _) -> Just off
  Left _ -> Nothing

vaTableOff :: [Segment] -> Word64 -> Int -> Either LoadError (Int, Int)
vaTableOff loads va size = do
  (off, available) <- vaTableFileRange loads va size
  if available < size then Left (BadDyn "table outside LOAD") else Right (off, size)

vaTableFileRange :: [Segment] -> Word64 -> Int -> Either LoadError (Int, Int)
vaTableFileRange _loads _va size
  | size < 0 || size > maxElfBytes = Left OverlapSize
vaTableFileRange loads va size = case findFileSegment loads va size of
  Nothing -> Left (BadDyn "table outside LOAD")
  Just (seg, delta) -> Right (segFileOff seg + delta, segFileSz seg - delta)
  where
    findFileSegment [] _ _ = Nothing
    findFileSegment (seg : rest) address _size
      | address < segVaddr seg = Nothing
      | otherwise =
          let delta = address - segVaddr seg
              fileSize = fromIntegral (segFileSz seg)
           in if delta < fileSize || (size == 0 && delta == fileSize)
                then Just (seg, fromIntegral delta)
                else findFileSegment rest address size

getWord16LE :: ByteString -> Int -> Either LoadError Word64
getWord16LE bs off
  | off < 0 || off > BS.length bs - 2 = Left Truncated
  | otherwise = do
      b0 <- byteAt bs off
      b1 <- byteAt bs (off + 1)
      Right (fromIntegral b0 + fromIntegral b1 * 256)

getWord32LE :: ByteString -> Int -> Either LoadError Word32
getWord32LE bs off
  | off < 0 || off > BS.length bs - 4 = Left Truncated
  | otherwise = do
      b0 <- byteAt bs off
      b1 <- byteAt bs (off + 1)
      b2 <- byteAt bs (off + 2)
      b3 <- byteAt bs (off + 3)
      Right (fromIntegral b0 .|. (fromIntegral b1 `shiftL` 8) .|. (fromIntegral b2 `shiftL` 16) .|. (fromIntegral b3 `shiftL` 24))

getWord64LE :: ByteString -> Int -> Either LoadError Word64
getWord64LE bs off = do
  low <- getU32 bs off
  high <- getU32 bs (off + 4)
  Right (fromIntegral low .|. (fromIntegral high `shiftL` 32))

byteAt :: ByteString -> Int -> Either LoadError Word8
byteAt bs off
  | off < 0 || off >= BS.length bs = Left Truncated
  | otherwise = Right (BS.index bs off)

getU8 :: ByteString -> Int -> Either LoadError Word8
getU8 = byteAt

getU16 :: ByteString -> Int -> Either LoadError Word16
getU16 bs off = do
  b0 <- byteAt bs off
  b1 <- byteAt bs (off + 1)
  Right (fromIntegral b0 .|. (fromIntegral b1 `shiftL` 8))

getU32 :: ByteString -> Int -> Either LoadError Word32
getU32 bs off = do
  b0 <- getU16 bs off
  b1 <- getU16 bs (off + 2)
  Right (fromIntegral b0 .|. (fromIntegral b1 `shiftL` 16))

getU64 :: ByteString -> Int -> Either LoadError Word64
getU64 bs off = do
  b0 <- getU32 bs off
  b1 <- getU32 bs (off + 4)
  Right (fromIntegral b0 .|. (fromIntegral b1 `shiftL` 32))

sliceBytes :: ByteString -> Int -> Int -> Either LoadError ByteString
sliceBytes bs off size
  | off < 0 || size < 0 || off > BS.length bs - size = Left Truncated
  | otherwise = Right (BS.take size (BS.drop off bs))

findNeededCycle :: [(String, [String])] -> Either LoadError ()
findNeededCycle graph = mapM_ (visit [] . fst) graph
  where
    visit path n
      | n `elem` path = Left NeededCycle
      | otherwise = case lookup n graph of
          Nothing -> Right ()
          Just deps -> mapM_ (visit (n : path)) deps

checkedAdd :: Word64 -> Word64 -> Either LoadError Word64
checkedAdd base add
  | add > maxBound - base = Left OverlapSize
  | otherwise = Right (base + add)

leBytes :: Word64 -> ByteString
leBytes w = BS.pack [fromIntegral (w `shiftR` shift) | shift <- [0, 8, 16, 24, 32, 40, 48, 56]]

{- | Write eight-byte little-endian patches into a copy of the image. The
result is a new 'ByteString' built in one splice; the input is never
mutated. Every offset is bounds-checked before any byte is copied, and a
repeated offset keeps its last write.
-}
patchBytes :: ByteString -> [(Int, Word64)] -> Either LoadError ByteString
patchBytes bytes patches
  | any outOfRange patches = Left (BadDyn "rela outside image")
  | otherwise = Right (BS.concat (go 0 (Map.toAscList writes)))
  where
    len = BS.length bytes
    outOfRange (off, _) = off < 0 || off > len - 8
    writes :: Map Int Word64
    writes = Map.fromList patches
    go cursor [] = [BS.drop cursor bytes]
    go cursor ((off, value) : rest) =
      BS.take (off - cursor) (BS.drop cursor bytes) : leBytes value : go (off + 8) rest

applyRelativeRelocs :: Word64 -> [Relocation] -> ByteString -> Either LoadError ByteString
applyRelativeRelocs base relocs bytes = do
  patches <- mapM (imagePatch (BS.length bytes)) relocs
  patchBytes bytes patches
  where
    imagePatch len rel = case rel of
      RelativeBinding r -> do
        val <- checkedAdd base (relativeAddend r)
        let roff = relativeOffset r
        if roff < base
          then Left (BadDyn "rela below base")
          else
            let diff = roff - base
             in if diff > fromIntegral len
                  then Left (BadDyn "rela outside image")
                  else Right (fromIntegral diff, val)
      EagerSymbolBinding r -> Left (UnsupportedReloc (eagerType r))

applyRelocsToFile :: [Segment] -> Word64 -> [Relocation] -> ByteString -> Either LoadError ByteString
applyRelocsToFile segs base relocs bytes = do
  patches <- mapM (filePatch (BS.length bytes)) relocs
  patchBytes bytes patches
  where
    filePatch len rel = case rel of
      RelativeBinding r -> do
        val <- checkedAdd base (relativeAddend r)
        case vaToFileOff segs (relativeOffset r) of
          Nothing -> Left (BadDyn "rela outside LOAD")
          Just off
            | off < 0 || off > len - 8 -> Left (BadDyn "rela outside LOAD")
            | otherwise -> Right (off, val)
      EagerSymbolBinding r -> Left (UnsupportedReloc (eagerType r))
