{-| Virtual Memory (section 3.2 in the paper) — aarch64 4KB granule.
 -}
module H.VirtualMemory
  ( VAddr,
    minVAddr,
    maxVAddr,
    PageMap,
    allocPageMap,
    freePageMap,
    PageInfo (..),
    setPage,
    getPage,
    toPageMap,
    fromPageMap, -- not for public use
  )
where

-- import Kernel.Debug(putStrLn)
import Control.Monad
import Data.Bits
import Data.Word (Word64, Word8)
import H.AdHocMem
import H.Monad (H, liftIO)
import H.Mutable (HUArray, newArray, readArray, writeArray)
import qualified H.Pages as P
import H.PhysicalMemory (PhysPage, fromPhysPage, toPhysPage)
import H.Unsafe (unsafePerformH)
import H.Utils

------------------------------- INTERFACE --------------------------------------

-- | @VAddr@ is a concrete type representing virtual addresses.
type VAddr = Word64

minVAddr, maxVAddr :: VAddr
minVAddr = 0x01000000
maxVAddr = 0x3FFFFFFF

-- abstract type PageMap  -- Show,Eq,Ord(!)

{-| New page maps, represented by the abstract type @PageMap@, are
obtained using @llocPageMap@. The number of available page maps may be limited;
@allocPageMap@ returns  returns @Nothing@ if no more maps are available. -}
allocPageMap :: H (Maybe PageMap)

{-# DEPRECATED freePageMap "freePageMap does nothing" #-}
freePageMap :: PageMap -> H ()

{-|
Page map entries are indexed by valid, aligned, virtual addresses.  The
entry for an unmapped page contains {\tt Nothing}; the entry for a
mapped page contains a value, @Just p@, where @p@ is
of type @PageInfo@.
-}
data PageInfo
  = PageInfo
  { physPage :: PhysPage,
    -- | indicates whether the user process has write access to the page
    writable :: Bool,
    -- | indicates that the page has been written
    dirty :: Bool,
    -- | indicates that it has been read or written
    accessed :: Bool
  }
  deriving (Eq, Show)

setPage :: PageMap -> VAddr -> Maybe PageInfo -> H Bool
getPage :: PageMap -> VAddr -> H (Maybe PageInfo)

---------- PRIVATE IMPLEMENTATION FOLLOWS -----------------------

type Desc = Word64

type Table = P.Page Desc

type PDir = Table

data PageMap = PageMap {fromPageMap :: PDir}
  deriving (Show, Eq, Ord)

toPageMap = PageMap

-- Descriptor bits (aarch64 4KB granule, page descriptor)
bValid, bTable, bAF, bNG, bUXN, bPXN :: Int
bValid = 0
bTable = 1
bAF = 10
bNG = 11
bUXN = 54
bPXN = 53

-- SW bits for dirty/accessed structure-level round-trip (never walked by HW)
bSwDirty = 55

bSwAccessed = 56

mAddress :: Word64
mAddress = 0x0000FFFFFFFFF000 -- OA [47:12]

pageFlag, tableFlag :: Word64
tableFlag = 0x3 -- Valid | Table
pageFlag = 0x3 -- page descriptor also Valid|Table at L3 plus attrs

-- Attribute encodings consistent with mmu.c MAIR (Normal attr0)
attrNormal :: Word64
attrNormal = 0 `shiftL` 2 -- AttrIdx 0

shInner :: Word64
shInner = 3 `shiftL` 8 -- Inner-shareable

apRW, apRO :: Word64
apRW = 1 `shiftL` 6 -- AP 01
apRO = 3 `shiftL` 6 -- AP 11

descToPageInfo :: Desc -> Maybe PageInfo
descToPageInfo d
  | not (testBit' bValid d) = Nothing
  | otherwise =
      Just
        ( PageInfo
            { physPage = toPhysPage (ptrFromWord64 (d .&. mAddress)),
              writable = ((d `shiftR` 6) .&. 0x3) == 0x1,
              dirty = testBit' bSwDirty d,
              accessed = testBit' bSwAccessed d
            }
        )

pageInfoToDesc :: PageInfo -> Desc
pageInfoToDesc pinfo =
  let base =
        (ptrToWord64 (fromPhysPage (physPage pinfo)) .&. mAddress)
          .|. pageFlag
          .|. (1 `shiftL` bAF)
          .|. shInner
          .|. (1 `shiftL` bNG)
          .|. (1 `shiftL` bUXN)
          .|. (1 `shiftL` bPXN)
          .|. attrNormal
      ap = if writable pinfo then apRW else apRO
      sw =
        condBit (dirty pinfo) bSwDirty
          $ condBit (accessed pinfo) bSwAccessed
          $ 0
   in base .|. ap .|. sw

-- Table helpers
descFromTable :: Table -> Desc
descFromTable tbl = (ptrToWord64 tbl .&. mAddress) .|. tableFlag

tableFromDesc :: Desc -> Maybe Table
tableFromDesc d
  | testBit' bValid d = Just (ptrFromWord64 (d .&. mAddress))
  | otherwise = Nothing

-- Indexes
l0Index, l1Index, l2Index, l3Index :: VAddr -> Int
l0Index v = fromIntegral ((v `shiftR` 39) .&. 0x1FF)
l1Index v = fromIntegral ((v `shiftR` 30) .&. 0x1FF)
l2Index v = fromIntegral ((v `shiftR` 21) .&. 0x1FF)
l3Index v = fromIntegral ((v `shiftR` 12) .&. 0x1FF)

pageEntries :: Int
pageEntries = 512

validVAddr :: VAddr -> Bool
validVAddr vaddr = vaddr >= minVAddr && vaddr <= maxVAddr

-- check if a table is empty
isEmptyTable :: Table -> H Bool
isEmptyTable tbl =
  do
    ds <- sequence [peekElemOff tbl i | i <- [0 .. pageEntries - 1]]
    return $ all (== 0) ds

-- invalidate a page in the current PDir
invalidate :: PDir -> VAddr -> H ()
invalidate pdir vaddr =
  do
    pdir0 <- currentPDir
    if pdir == pdir0
      then invalidatePage vaddr
      else return ()

getPage (PageMap l0) vaddr | validVAddr vaddr =
  do
    d0 <- peekElemOff l0 (l0Index vaddr)
    case tableFromDesc d0 of
      Nothing -> return Nothing
      Just l1 -> do
        d1 <- peekElemOff l1 (l1Index vaddr)
        case tableFromDesc d1 of
          Nothing -> return Nothing
          Just l2 -> do
            d2 <- peekElemOff l2 (l2Index vaddr)
            case tableFromDesc d2 of
              Nothing -> return Nothing
              Just l3 -> do
                d3 <- peekElemOff l3 (l3Index vaddr)
                return (descToPageInfo d3)

setPage (PageMap l0) vaddr Nothing | validVAddr vaddr =
  do
    d0 <- peekElemOff l0 (l0Index vaddr)
    case tableFromDesc d0 of
      Nothing -> return True
      Just l1 -> do
        d1 <- peekElemOff l1 (l1Index vaddr)
        case tableFromDesc d1 of
          Nothing -> return True
          Just l2 -> do
            d2 <- peekElemOff l2 (l2Index vaddr)
            case tableFromDesc d2 of
              Nothing -> return True
              Just l3 -> do
                d3 <- peekElemOff l3 (l3Index vaddr)
                case descToPageInfo d3 of
                  Nothing -> return True
                  Just _ -> do
                    pokeElemOff l3 (l3Index vaddr) 0
                    invalidate l0 vaddr
                    empty <- isEmptyTable l3
                    when empty $ do
                      pokeElemOff l2 (l2Index vaddr) 0
                      P.freePage l3
                    return True
setPage (PageMap l0) vaddr (Just pinfo) | validVAddr vaddr =
  do
    d0 <- peekElemOff l0 (l0Index vaddr)
    l1 <- case tableFromDesc d0 of
      Just t -> return t
      Nothing -> error "L1 missing — allocPageMap should have created L0→L1"
    d1 <- peekElemOff l1 (l1Index vaddr)
    l2 <- case tableFromDesc d1 of
      Just t -> return t
      Nothing -> error "L2 missing — allocPageMap should have created L1→L2"
    d2 <- peekElemOff l2 (l2Index vaddr)
    l3 <- case tableFromDesc d2 of
      Just t -> return t
      Nothing -> do
        m <- P.allocPage
        case m of
          Nothing -> return (nullPtr `plusPtr` (-4096)) -- sentinel for failure
          Just t -> do
            P.zeroPage t
            pokeElemOff l2 (l2Index vaddr) (descFromTable t)
            return t
    if l3 == (nullPtr `plusPtr` (-4096))
      then return False
      else do
        pokeElemOff l3 (l3Index vaddr) (pageInfoToDesc pinfo)
        invalidate l0 vaddr
        return True

allocPageMap =
  do
    mL0 <- P.allocPage
    case mL0 of
      Nothing -> return Nothing
      Just l0 -> do
        P.zeroPage l0
        mL1 <- P.allocPage
        case mL1 of
          Nothing -> do P.freePage l0; return Nothing
          Just l1 -> do
            P.zeroPage l1
            mL2 <- P.allocPage
            case mL2 of
              Nothing -> do P.freePage l1; P.freePage l0; return Nothing
              Just l2 -> do
                P.zeroPage l2
                pokeElemOff l0 (l0Index minVAddr) (descFromTable l1)
                pokeElemOff l1 (l1Index minVAddr) (descFromTable l2)
                let pm = PageMap l0
                initPDir l0
                P.registerPage l0 pm freePDir
                return (Just pm)

freePageMap pmap = return () -- nop; underlying Pages are freed when corresponding registered PageMap is discovered dead

freePDir :: PDir -> H ()
freePDir l0 =
  do
    pdir' <- currentPDir
    if l0 == pdir'
      then error "attempt to free current PDir"
      else do
        d0 <- peekElemOff l0 (l0Index minVAddr)
        case tableFromDesc d0 of
          Nothing -> P.freePage l0
          Just l1 -> do
            d1 <- peekElemOff l1 (l1Index minVAddr)
            case tableFromDesc d1 of
              Nothing -> do P.freePage l1; P.freePage l0
              Just l2 -> do
                -- free any L3 tables
                forM_ [0 .. pageEntries - 1] $ \i -> do
                  d2 <- peekElemOff l2 i
                  case tableFromDesc d2 of
                    Just l3 | P.validPage l3 -> P.freePage l3
                    _ -> return ()
                P.freePage l2
                P.freePage l1
                P.freePage l0

foreign import ccall unsafe "userspace.h init_page_dir" initPDirIO :: PDir -> IO ()

initPDir = liftIO . initPDirIO

foreign import ccall unsafe "userspace.h current_pdir" currentPDirIO :: IO PDir

foreign import ccall unsafe "userspace.h invalidate_page" invalidatePageIO :: VAddr -> IO ()

currentPDir = liftIO currentPDirIO

invalidatePage = liftIO . invalidatePageIO
