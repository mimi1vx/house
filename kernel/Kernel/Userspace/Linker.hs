{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Linker
Description : Pure bounded planner for eager AArch64 ET_DYN objects.
Stability   : experimental

The planner validates a supplied dependency graph, assigns non-overlapping load
bases, resolves global/default exports, and returns deterministic relocation
values. It performs no I/O and mutates no input object or byte buffer.
-}
module Kernel.Userspace.Linker (
  LinkPlan (..),
  LinkRelocation (..),
  PlacedObject (..),
  RelocationPatch (..),
  linkDynamic,
)
where

import Control.Monad (foldM, unless, when)
import Data.Bits (shiftR, (.&.))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Word (Word16, Word32, Word64, Word8)
import Kernel.Userspace.Loader qualified as Ldr

mainObjectName :: String
mainObjectName = "main"

mainBase :: Word64
mainBase = 0x01000000

maxUserEnd :: Word64
maxUserEnd = 0x100000000

pageSize :: Word64
pageSize = 4096

objectAlignment :: Word64
objectAlignment = 64 * 1024

maxDependencies :: Int
maxDependencies = 8

maxObjectPages :: Word64
maxObjectPages = 64

maxTotalPages :: Word64
maxTotalPages = 256

pfWrite :: Word32
pfWrite = 2

stbGlobal, stvDefault :: Word8
stbGlobal = 1
stvDefault = 0

shnUndef, shnReservedStart :: Word16
shnUndef = 0
shnReservedStart = 0xFF00

rAarch64GlobDat, rAarch64JumpSlot :: Word32
rAarch64GlobDat = 1025
rAarch64JumpSlot = 1026

-- | Relocation families emitted by the v1 planner.
data LinkRelocation
  = LinkRelative
  | LinkGlobDat
  | LinkJumpSlot
  deriving (Eq, Show)

-- | Logical placement data for one dynamic object.
data PlacedObject = PlacedObject {
  placedObjectName :: String
  , placedObjectBase :: Word64
  , placedObjectEntry :: Word64
  , placedObjectPages :: Word64
  }
  deriving (Eq, Show)

-- | One checked eight-byte write deferred to the M2.2 mapper.
data RelocationPatch = RelocationPatch {
  patchObject :: String
  , patchProvider :: String
  , patchSymbol :: Maybe String
  , patchRelocation :: LinkRelocation
  , patchTarget :: Word64
  , patchValue :: Word64
  }
  deriving (Eq, Show)

-- | Deterministic placement and relocation data for one dynamic main object.
data LinkPlan = LinkPlan {
  linkObjects :: [PlacedObject]
  , linkPatches :: [RelocationPatch]
  }
  deriving (Eq, Show)

data PlannedObject = PlannedObject {
  plannedObject :: PlacedObject
  , plannedElf :: Ldr.Elf
  }

data ExportedSymbol = ExportedSymbol {
  exportProvider :: String
  , exportAddress :: Word64
  }
  deriving (Eq)

-- | Resolve and place a dynamic main object plus its SONAME-keyed dependencies.
linkDynamic :: Ldr.Elf -> Map String Ldr.Elf -> Either Ldr.LoadError LinkPlan
linkDynamic main deps = do
  when (Map.size deps > maxDependencies) (badLink "dependency object cap exceeded")
  validateMain main
  orderedDeps <- dependencyOrder deps (Ldr.dynNeeded (Ldr.elfDyn main))
  placed <- placeObjects ((mainObjectName, main) : orderedDeps) mainBase 0
  exports <- buildExportScope placed
  patches <- planPatches placed exports
  pure
    LinkPlan {
      linkObjects = map plannedObject placed
      , linkPatches = patches
      }

validateMain :: Ldr.Elf -> Either Ldr.LoadError ()
validateMain elf = do
  unless (Ldr.elfIsDyn elf) (badLink "main is not ET_DYN")
  unless (Ldr.elfInterp elf == Just Ldr.ldHousePath) (badLink "main interpreter mismatch")
  validateRuntimeObject "main" elf

validateDependency :: String -> Ldr.Elf -> Either Ldr.LoadError ()
validateDependency expected elf = do
  unless (Ldr.elfIsDyn elf) (badLink ("dependency " ++ expected ++ " is not ET_DYN"))
  unless (isNothing (Ldr.elfInterp elf)) (badLink ("dependency " ++ expected ++ " has PT_INTERP"))
  unless (Ldr.dynSoname (Ldr.elfDyn elf) == Just expected) (badLink ("SONAME mismatch for " ++ expected))
  validateRuntimeObject ("dependency " ++ expected) elf

validateRuntimeObject :: String -> Ldr.Elf -> Either Ldr.LoadError ()
validateRuntimeObject name elf = do
  let dynInfo = Ldr.elfDyn elf
  unless (Ldr.dynPresent dynInfo) (badLink (name ++ " has no PT_DYNAMIC"))
  unless (Ldr.dynBindNow dynInfo) (badLink (name ++ " is not bind-now"))
  unless (length (Ldr.dynNeeded dynInfo) <= Ldr.maxNeeded) (badLink (name ++ " NEEDED count exceeds cap"))
  unless (length (Ldr.elfBytes elf) <= Ldr.maxElfBytes) (badLink (name ++ " exceeds maxElfBytes"))
  pages <- objectPageCount name elf
  when (pages > maxObjectPages) (badLink (name ++ " exceeds object page cap"))
  validateRelro name elf
  validateSymbolMetadata name dynInfo
  validateEntry name elf

validateRelro :: String -> Ldr.Elf -> Either Ldr.LoadError ()
validateRelro name elf = case Ldr.elfRelro elf of
  Nothing -> badLink (name ++ " has no RELRO")
  Just relro -> do
    unless (Ldr.relroEnd relro > Ldr.relroStart relro) (badLink (name ++ " has empty RELRO"))
    unless (any (containsRelro relro) (Ldr.elfSegs elf)) (badLink (name ++ " RELRO outside LOAD"))

validateSymbolMetadata :: String -> Ldr.DynInfo -> Either Ldr.LoadError ()
validateSymbolMetadata name dynInfo = case (Ldr.dynHashStyle dynInfo, Ldr.dynSymbols dynInfo) of
  (Ldr.SysVHash hash, Just symbols) -> do
    let count = length (Ldr.dynamicSymbolEntries symbols)
    when (Ldr.sysvHashBuckets hash == 0) (badLink (name ++ " has no SysV hash buckets"))
    when (count /= Ldr.sysvHashSymbols hash) (badLink (name ++ " SysV symbol count mismatch"))
    when (count > Ldr.maxDynSymbols) (badLink (name ++ " dynamic symbol count exceeds cap"))
    unless (Ldr.dynamicSymbolsEntSize symbols == 24) (badLink (name ++ " dynamic symbol entry size unsupported"))
  _ -> badLink (name ++ " requires SysV symbols")

validateEntry :: String -> Ldr.Elf -> Either Ldr.LoadError ()
validateEntry name elf =
  unless (any (containsEntry (Ldr.elfEntry elf)) (Ldr.elfSegs elf)) (badLink (name ++ " entry outside LOAD"))

dependencyOrder :: Map String Ldr.Elf -> [String] -> Either Ldr.LoadError [(String, Ldr.Elf)]
dependencyOrder deps roots = do
  (orderedRev, _) <- go Set.empty Set.empty [] roots
  pure (reverse orderedRev)
  where
    go _ done orderedRev [] = Right (orderedRev, done)
    go active done orderedRev (name : rest)
      | name `Set.member` done = go active done orderedRev rest
      | name `Set.member` active = Left Ldr.NeededCycle
      | otherwise = case Map.lookup name deps of
          Nothing -> badLink ("missing dependency " ++ name)
          Just elf -> do
            validateDependency name elf
            (childOrderedRev, childDone) <- go (Set.insert name active) done ((name, elf) : orderedRev) (Ldr.dynNeeded (Ldr.elfDyn elf))
            go active (Set.insert name childDone) childOrderedRev rest

placeObjects :: [(String, Ldr.Elf)] -> Word64 -> Word64 -> Either Ldr.LoadError [PlannedObject]
placeObjects [] _ _ = Right []
placeObjects ((name, elf) : rest) cursor totalPages = do
  pages <- objectPageCount name elf
  totalPages' <- checkedAdd "total mapped pages" totalPages pages
  when (totalPages' > maxTotalPages) (badLink "total mapped page cap exceeded")
  objectEnd <- objectEndOffset name elf
  absoluteEnd <- checkedAdd (name ++ " load end") cursor objectEnd
  when (absoluteEnd > maxUserEnd) (badLink (name ++ " load exceeds 4GiB user window"))
  entry <- checkedAdd (name ++ " entry") cursor (Ldr.elfEntry elf)
  validatePlacedRanges name cursor entry elf
  next <- alignUpChecked (name ++ " next base") absoluteEnd objectAlignment
  tailPlaced <- placeObjects rest next totalPages'
  let placed =
        PlacedObject {
          placedObjectName = name
          , placedObjectBase = cursor
          , placedObjectEntry = entry
          , placedObjectPages = pages
          }
  pure (PlannedObject placed elf : tailPlaced)

objectPageCount :: String -> Ldr.Elf -> Either Ldr.LoadError Word64
objectPageCount name elf = do
  when (null (Ldr.elfSegs elf)) (badLink (name ++ " has no PT_LOAD"))
  mapM_ validateSegment (Ldr.elfSegs elf)
  foldM addPage 0 (Ldr.elfSegs elf)
  where
    validateSegment segment = do
      when (Ldr.segFileSz segment < 0 || Ldr.segMemSz segment < 0) (badLink (name ++ " has negative segment size"))
      when (Ldr.segFileSz segment > Ldr.segMemSz segment) (badLink (name ++ " has filesz above memsz"))
      end <- checkedAdd (name ++ " segment end") (Ldr.segVaddr segment) (fromIntegral (Ldr.segMemSz segment))
      when (end > maxUserEnd) (badLink (name ++ " segment exceeds 4GiB user window"))
    addPage total segment =
      checkedAdd (name ++ " page count") total (segmentPages segment)

segmentPages :: Ldr.Segment -> Word64
segmentPages segment
  | Ldr.segMemSz segment == 0 = 0
  | otherwise = (fromIntegral (Ldr.segMemSz segment) - 1) `div` pageSize + 1

objectEndOffset :: String -> Ldr.Elf -> Either Ldr.LoadError Word64
objectEndOffset name elf = foldM step 0 (Ldr.elfSegs elf)
  where
    step current segment = do
      end <- checkedAdd (name ++ " segment end") (Ldr.segVaddr segment) (fromIntegral (Ldr.segMemSz segment))
      pure (max current end)

validatePlacedRanges :: String -> Word64 -> Word64 -> Ldr.Elf -> Either Ldr.LoadError ()
validatePlacedRanges name base entry elf = do
  mapM_ validateSegmentRange (Ldr.elfSegs elf)
  unless (any (containsEntry entry . relocateSegment base) (Ldr.elfSegs elf)) (badLink (name ++ " relocated entry outside LOAD"))
  where
    validateSegmentRange segment =
      when (rangeTouchesStack (relocateSegment base segment)) (badLink (name ++ " load reaches reserved stack page"))

buildExportScope :: [PlannedObject] -> Either Ldr.LoadError (Map String ExportedSymbol)
buildExportScope = foldM addObject Map.empty
  where
    addObject scope planned = case Ldr.dynSymbols (Ldr.elfDyn (plannedElf planned)) of
      Nothing -> badLink (plannedName planned ++ " has no dynamic symbols")
      Just symbols -> foldM (addSymbol planned) scope (Ldr.dynamicSymbolEntries symbols)
    addSymbol planned scope symbol
      | null (Ldr.dynamicSymbolName symbol) = pure scope
      | otherwise = do
          unless (symbolBinding symbol == stbGlobal) (badLink ("unsupported symbol binding for " ++ Ldr.dynamicSymbolName symbol))
          unless (symbolVisibility symbol == stvDefault) (badLink ("unsupported symbol visibility for " ++ Ldr.dynamicSymbolName symbol))
          unless (symbolType symbol `elem` [0, 1, 2]) (badLink ("unsupported symbol type for " ++ Ldr.dynamicSymbolName symbol))
          let section = Ldr.dynamicSymbolSection symbol
          if section == shnUndef
            then pure scope
            else
              if section >= shnReservedStart
                then badLink ("unsupported symbol section for " ++ Ldr.dynamicSymbolName symbol)
                else do
                  address <- exportedAddress planned symbol
                  when (Map.member (Ldr.dynamicSymbolName symbol) scope) (badLink ("duplicate export " ++ Ldr.dynamicSymbolName symbol))
                  pure (Map.insert (Ldr.dynamicSymbolName symbol) (ExportedSymbol (plannedName planned) address) scope)

planPatches :: [PlannedObject] -> Map String ExportedSymbol -> Either Ldr.LoadError [RelocationPatch]
planPatches planned exports = concat <$> mapM planObject planned
  where
    planObject object = go Set.empty [] (concatMap Ldr.relocationTableEntries (Ldr.dynRelocations (Ldr.elfDyn (plannedElf object))))
      where
        go _ acc [] = Right (reverse acc)
        go seen acc (relocation : rest) = do
          target <- relocationTarget object relocation
          when (target > maxBound - 7) (badLink (plannedName object ++ " relocation target overflows patch"))
          when (target `Set.member` seen) (badLink (plannedName object ++ " duplicate relocation target"))
          patch <- planRelocation object exports target relocation
          go (Set.insert target seen) (patch : acc) rest

relocationTarget :: PlannedObject -> Ldr.Relocation -> Either Ldr.LoadError Word64
relocationTarget planned relocation = do
  offset <- case relocation of
    Ldr.RelativeBinding relative -> pure (Ldr.relativeOffset relative)
    Ldr.EagerSymbolBinding eager -> pure (Ldr.eagerOffset eager)
  target <- checkedAdd (plannedName planned ++ " relocation target") (plannedBase planned) offset
  unless (relocationTargetInObject planned target relocation) (badLink (plannedName planned ++ " relocation target outside LOAD"))
  pure target

relocationTargetInObject :: PlannedObject -> Word64 -> Ldr.Relocation -> Bool
relocationTargetInObject planned target relocation = any (inside . relocateSegment (plannedBase planned)) (Ldr.elfSegs (plannedElf planned))
  where
    writable = case relocation of
      Ldr.EagerSymbolBinding _ -> True
      Ldr.RelativeBinding _ -> False
    inside segment =
      let start = Ldr.segVaddr segment
          end = start + fromIntegral (Ldr.segMemSz segment)
          writableSegment = (Ldr.segFlags segment .&. pfWrite) /= 0
       in Ldr.segMemSz segment >= 8
            && target >= start
            && target <= end - 8
            && (not writable || writableSegment)

planRelocation :: PlannedObject -> Map String ExportedSymbol -> Word64 -> Ldr.Relocation -> Either Ldr.LoadError RelocationPatch
planRelocation planned scope target relocation = case relocation of
  Ldr.RelativeBinding relative -> do
    value <- checkedRelocationValue (plannedName planned ++ " RELATIVE value") (plannedBase planned) (Ldr.relativeAddend relative)
    pure
      RelocationPatch {
        patchObject = plannedName planned
        , patchProvider = plannedName planned
        , patchSymbol = Nothing
        , patchRelocation = LinkRelative
        , patchTarget = target
        , patchValue = value
        }
  Ldr.EagerSymbolBinding eager -> do
    kind <- relocationKind (Ldr.eagerType eager)
    validateEagerSymbol planned eager
    export <- case Map.lookup (Ldr.eagerSymbolName eager) scope of
      Nothing -> badLink ("unresolved relocation symbol " ++ Ldr.eagerSymbolName eager)
      Just found -> pure found
    value <- checkedRelocationValue (Ldr.eagerSymbolName eager ++ " relocation value") (exportAddress export) (Ldr.eagerAddend eager)
    pure
      RelocationPatch {
        patchObject = plannedName planned
        , patchProvider = exportProvider export
        , patchSymbol = Just (Ldr.eagerSymbolName eager)
        , patchRelocation = kind
        , patchTarget = target
        , patchValue = value
        }

relocationKind :: Word32 -> Either Ldr.LoadError LinkRelocation
relocationKind relocationType
  | relocationType == rAarch64GlobDat = Right LinkGlobDat
  | relocationType == rAarch64JumpSlot = Right LinkJumpSlot
  | otherwise = Left (Ldr.UnsupportedReloc relocationType)

validateEagerSymbol :: PlannedObject -> Ldr.EagerSymbolRelocation -> Either Ldr.LoadError ()
validateEagerSymbol planned eager = case Ldr.dynSymbols (Ldr.elfDyn (plannedElf planned)) of
  Nothing -> badLink (plannedName planned ++ " eager relocation has no symbols")
  Just symbols -> case drop (fromIntegral (Ldr.eagerSymbolIndex eager)) (Ldr.dynamicSymbolEntries symbols) of
    symbol : _
      | Ldr.dynamicSymbolName symbol == Ldr.eagerSymbolName eager -> pure ()
    _ -> badLink (plannedName planned ++ " eager relocation symbol mismatch")

exportedAddress :: PlannedObject -> Ldr.DynamicSymbol -> Either Ldr.LoadError Word64
exportedAddress planned symbol = do
  end <- checkedAdd (Ldr.dynamicSymbolName symbol ++ " symbol end") (Ldr.dynamicSymbolValue symbol) (Ldr.dynamicSymbolSize symbol)
  unless (any (containsSymbol (Ldr.dynamicSymbolValue symbol) end) (Ldr.elfSegs (plannedElf planned))) (badLink ("symbol outside LOAD: " ++ Ldr.dynamicSymbolName symbol))
  checkedAdd (Ldr.dynamicSymbolName symbol ++ " provider") (plannedBase planned) (Ldr.dynamicSymbolValue symbol)

plannedName :: PlannedObject -> String
plannedName = placedObjectName . plannedObject

plannedBase :: PlannedObject -> Word64
plannedBase = placedObjectBase . plannedObject

containsSymbol :: Word64 -> Word64 -> Ldr.Segment -> Bool
containsSymbol start end segment =
  let segmentStart = Ldr.segVaddr segment
      segmentEnd = segmentStart + fromIntegral (Ldr.segMemSz segment)
   in start >= segmentStart
        && start < segmentEnd
        && end >= start
        && end <= segmentEnd

symbolBinding :: Ldr.DynamicSymbol -> Word8
symbolBinding symbol = Ldr.dynamicSymbolInfo symbol `shiftR` 4

symbolVisibility :: Ldr.DynamicSymbol -> Word8
symbolVisibility symbol = Ldr.dynamicSymbolOther symbol .&. 3

symbolType :: Ldr.DynamicSymbol -> Word8
symbolType symbol = Ldr.dynamicSymbolInfo symbol .&. 0x0F

relocateSegment :: Word64 -> Ldr.Segment -> Ldr.Segment
relocateSegment base segment =
  Ldr.Segment
    (base + Ldr.segVaddr segment)
    (Ldr.segFileOff segment)
    (Ldr.segFileSz segment)
    (Ldr.segMemSz segment)
    (Ldr.segFlags segment)

rangeTouchesStack :: Ldr.Segment -> Bool
rangeTouchesStack segment
  | Ldr.segMemSz segment == 0 = False
  | otherwise =
      let firstPage = Ldr.segVaddr segment `div` pageSize
          lastPage = (Ldr.segVaddr segment + fromIntegral (Ldr.segMemSz segment) - 1) `div` pageSize
          stackPage = Ldr.stackPageStart `div` pageSize
       in firstPage <= stackPage && stackPage <= lastPage

containsRelro :: Ldr.RelroRange -> Ldr.Segment -> Bool
containsRelro relro segment =
  let start = Ldr.segVaddr segment
      end = start + fromIntegral (Ldr.segMemSz segment)
   in Ldr.relroStart relro >= start
        && Ldr.relroStart relro < end
        && Ldr.relroEnd relro > start
        && Ldr.relroEnd relro <= end

containsEntry :: Word64 -> Ldr.Segment -> Bool
containsEntry entry segment =
  let start = Ldr.segVaddr segment
      end = start + fromIntegral (Ldr.segMemSz segment)
   in entry >= start && entry < end

alignUpChecked :: String -> Word64 -> Word64 -> Either Ldr.LoadError Word64
alignUpChecked label value alignment
  | remainder == 0 = pure value
  | otherwise = checkedAdd label value (alignment - remainder)
  where
    remainder = value `mod` alignment

checkedRelocationValue :: String -> Word64 -> Word64 -> Either Ldr.LoadError Word64
checkedRelocationValue label base addend
  | value < 0 || value >= toInteger maxUserEnd = badLink (label ++ " outside 4GiB user window")
  | otherwise = pure (fromInteger value)
  where
    signedAddend = toInteger (fromIntegral addend :: Int64)
    value = toInteger base + signedAddend

checkedAdd :: String -> Word64 -> Word64 -> Either Ldr.LoadError Word64
checkedAdd label left right
  | right > maxBound - left = badLink (label ++ " overflows")
  | otherwise = pure (left + right)

badLink :: String -> Either Ldr.LoadError a
badLink = Left . Ldr.BadDyn . ("link: " ++)
