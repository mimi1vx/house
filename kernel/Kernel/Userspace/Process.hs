{-# LANGUAGE ForeignFunctionInterface #-}

{-|
Module      : Kernel.Userspace.Process
Description : ELF loader -> PageMap -> EL0 entry with cleanup.
-}
module Kernel.Userspace.Process
  ( runElf,
    waitPid,
    killPid,
    procBrkGrow,
    stackTop,
  )
where

import Control.Concurrent (tryPutMVar, tryTakeMVar)
import Control.Monad (forM_, when)
import Data.Bits (complement, shiftR, (.&.))
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64, Word8)
import Foreign.C.String (withCString)
import Foreign.C.Types (CChar, CInt (..))
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import H.AdHocMem (peekElemOff, poke)
import H.Concurrency (forkH, threadDelay, withQSem)
import H.Monad (H, liftIO)
import H.Mutable (modifyRef, readRef, writeRef)
import qualified H.Pages as HPages
import H.PhysicalMemory (fromPhysPage, toPhysPage)
import H.Utils (ptrFromWord64)
import qualified H.VirtualMemory as VM
import Kernel.Userspace.Loader (Elf (..), LoadError (..), Segment (..))
import Kernel.Userspace.Types (Pid (..), Process (..), pidNext, procMap, processExitVar, userSem)

foreign import ccall unsafe "house_enter_el0" c_enter_el0 :: Word64 -> Word64 -> Ptr Word64 -> Word64 -> IO ()

foreign import ccall unsafe "house_asid_for_pdir" c_asid_for :: Ptr Word64 -> IO Word64

foreign import ccall unsafe "house_get_exit_code" c_get_exit :: IO CInt

foreign import ccall unsafe "house_clear_exit" c_clear_exit :: IO ()

foreign import ccall unsafe "house_is_exited" c_is_exited :: IO CInt

foreign import ccall unsafe "current_pdir" c_current_pdir :: IO (Ptr Word64)

foreign import ccall unsafe "house_set_recorded_pdir" c_set_pdir :: Ptr Word64 -> IO ()

foreign import ccall unsafe "uart_puts" c_uart_puts :: Ptr CChar -> IO ()

stackTop :: Word64
stackTop = 0x3FFFE000

pfW :: Word32
pfW = 2

runElf :: Elf -> [String] -> H (Either LoadError Pid)
runElf elf argv = withQSem userSem $ do
  pidInt <- readRef pidNext
  writeRef pidNext (pidInt + 1)
  let pid = Pid pidInt
  _ <- liftIO c_clear_exit
  mPdir <- VM.allocPageMap
  case mPdir of
    Nothing -> return (Left NoSpace)
    Just pdir -> do
      let pdirPtr = VM.fromPageMap pdir
      _ <- liftIO (withCString "[run] mapSegments start\n" c_uart_puts)
      mapped <- mapSegments pdir elf
      _ <- liftIO (withCString "[run] mapSegments done\n" c_uart_puts)
      case mapped of
        Left err -> do
          freePDir pdir
          return (Left err)
        Right () -> do
          let initBrk = initBreak elf
          mStack <- HPages.allocPage :: H (Maybe (Ptr Word8))
          case mStack of
            Nothing -> do freePDir pdir; return (Left NoSpace)
            Just stk -> do
              HPages.zeroPage stk
              eSp <- setupArgStack stk argv
              case eSp of
                Left err -> do HPages.freePage stk; freePDir pdir; return (Left err)
                Right sp -> do
                  let stackBase = stackTop - 4096
                  okStk <- VM.setPage pdir stackBase (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr stk), VM.writable = True, VM.dirty = False, VM.accessed = False}))
                  if not okStk
                    then do HPages.freePage stk; freePDir pdir; return (Left NoSpace)
                    else do
                      asid <- liftIO (c_asid_for pdirPtr)
                      _ <- liftIO (withCString "[run] got asid\n" c_uart_puts)
                      modifyRef procMap (Map.insert pid (Process pid pdir (elfEntry elf) initBrk))
                      _ <- liftIO (withCString "[run] before fork\n" c_uart_puts)
                      _ <- forkH $ do
                        _ <- liftIO (withCString "[run] fork enter\n" c_uart_puts)
                        liftIO (c_set_pdir pdirPtr)
                        liftIO (c_enter_el0 (elfEntry elf) sp pdirPtr asid)
                        _ <- liftIO (withCString "[run] fork after enter\n" c_uart_puts)
                        code <- liftIO c_get_exit
                        _ <- liftIO c_clear_exit
                        _ <- liftIO (tryPutMVar processExitVar (fromIntegral code) >> return ())
                        return ()
                      _ <- liftIO (withCString "[run] after fork\n" c_uart_puts)
                      return (Right pid)

-- | Initial break: end of highest loaded segment, 16-byte aligned.
initBreak :: Elf -> Word64
initBreak elf = case elfSegs elf of
  [] -> VM.minVAddr
  segs -> align16 (maximum (map segEnd segs))
  where
    segEnd s = segVaddr s + fromIntegral (segMemSz s)
    align16 w = (w + 15) .&. complement 15

-- | Lay argc/argv on the stack page. Returns adjusted sp (16-byte aligned).
setupArgStack :: Ptr Word8 -> [String] -> H (Either LoadError Word64)
setupArgStack stk argv
  | length argv > 64 = return (Left NoSpace)
  | any (\a -> length a > 1024) argv = return (Left NoSpace)
  | otherwise = do
      let argBlobs = map (\a -> map (\c -> fromIntegral (ord c `mod` 256) :: Word8) a ++ [0]) argv
          stringsLen = sum (map length argBlobs)
          argc = length argv
          ptrsLen = (argc + 1) * 8
          total = 8 + ptrsLen + stringsLen
          aligned = ((total + 15) `div` 16) * 16
      if aligned > 4000
        then return (Left NoSpace)
        else do
          let sp = stackTop - fromIntegral aligned
              base = stackTop - 4096
              off = fromIntegral (sp - base) :: Int
              strBase = sp + 8 + fromIntegral ptrsLen
          pokeWord64LE stk off (fromIntegral argc)
          let go _ [] _ = return ()
              go idx (b : rest) va = do
                pokeWord64LE stk (off + 8 + idx * 8) va
                mapM_ (\(i, byte) -> poke (stk `plusPtr` (fromIntegral (va - base) + i)) byte) (zip [0 ..] b)
                go (idx + 1) rest (va + fromIntegral (length b))
          go 0 argBlobs strBase
          pokeWord64LE stk (off + 8 + argc * 8) 0
          return (Right sp)

pokeWord64LE :: Ptr Word8 -> Int -> Word64 -> H ()
pokeWord64LE p o w = do
  poke (p `plusPtr` o) (fromIntegral w :: Word8)
  poke (p `plusPtr` (o + 1)) (fromIntegral (w `shiftR` 8) :: Word8)
  poke (p `plusPtr` (o + 2)) (fromIntegral (w `shiftR` 16) :: Word8)
  poke (p `plusPtr` (o + 3)) (fromIntegral (w `shiftR` 24) :: Word8)
  poke (p `plusPtr` (o + 4)) (fromIntegral (w `shiftR` 32) :: Word8)
  poke (p `plusPtr` (o + 5)) (fromIntegral (w `shiftR` 40) :: Word8)
  poke (p `plusPtr` (o + 6)) (fromIntegral (w `shiftR` 48) :: Word8)
  poke (p `plusPtr` (o + 7)) (fromIntegral (w `shiftR` 56) :: Word8)

waitPid :: Pid -> H Int
waitPid pid = do
  code <- pollExit
  mProc <- withQSem userSem $ do
    mp <- readRef procMap
    case Map.lookup pid mp of
      Nothing -> return Nothing
      Just pr -> do
        writeRef procMap (Map.delete pid mp)
        return (Just pr)
  case mProc of
    Nothing -> return code
    Just pr -> do
      freePDir (procPdir pr)
      return code

killPid :: Pid -> H ()
killPid pid = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup pid mp of
    Nothing -> return ()
    Just pr -> do
      writeRef procMap (Map.delete pid mp)
      freePDir (procPdir pr)

pollExit :: H Int
pollExit = loop
  where
    loop = do
      exited <- liftIO c_is_exited
      if exited /= 0
        then do
          c <- liftIO c_get_exit
          _ <- liftIO (tryTakeMVar processExitVar >> return ())
          return (fromIntegral c)
        else do
          m <- liftIO (tryTakeMVar processExitVar)
          case m of
            Just v -> return v
            Nothing -> do
              threadDelay 1000
              loop

-- | Grow a process break within the user window. Maps zero pages for
-- [oldBrk, newBrk); over-window yields OutOfWindow, OOM yields NoSpace.
procBrkGrow :: Pid -> Word64 -> H (Either LoadError Word64)
procBrkGrow pid newBrk = withQSem userSem $ do
  mp <- readRef procMap
  case Map.lookup pid mp of
    Nothing -> return (Left (BadSegment "no such pid"))
    Just pr -> do
      let oldBrk = procBrk pr
      if newBrk <= oldBrk
        then return (Right oldBrk)
        else
          if newBrk > VM.maxVAddr || oldBrk < VM.minVAddr
            then return (Left (OutOfWindow newBrk))
            else do
              let lo = (oldBrk + 4095) `div` 4096 * 4096
                  hi = (newBrk + 4095) `div` 4096 * 4096
              r <- growPages (procPdir pr) lo hi
              case r of
                Left e -> return (Left e)
                Right () -> do
                  writeRef procMap (Map.insert pid pr {procBrk = newBrk} mp)
                  return (Right newBrk)
  where
    growPages pdir lo hi
      | lo >= hi = return (Right ())
      | otherwise = do
          mp <- HPages.allocPage :: H (Maybe (Ptr Word8))
          case mp of
            Nothing -> return (Left NoSpace)
            Just pg -> do
              HPages.zeroPage pg
              ok <- VM.setPage pdir lo (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr pg), VM.writable = True, VM.dirty = False, VM.accessed = False}))
              if not ok
                then do HPages.freePage pg; return (Left NoSpace)
                else growPages pdir (lo + 4096) hi

mapSegments :: VM.PageMap -> Elf -> H (Either LoadError ())
mapSegments pdir elf = go (elfSegs elf) []
  where
    bytes = elfBytes elf
    go [] _ = return (Right ())
    go (seg : rest) allocated = do
      r <- mapOneSegment pdir bytes seg
      case r of
        Left err -> do
          cleanup allocated
          return (Left err)
        Right addrs -> go rest (addrs ++ allocated)
    cleanup addrs =
      mapM_
        ( \va -> do
            mInfo <- VM.getPage pdir va
            case mInfo of
              Nothing -> return ()
              Just info -> do
                _ <- VM.setPage pdir va Nothing
                HPages.freePage (fromPhysPage (VM.physPage info))
        )
        addrs

mapOneSegment :: VM.PageMap -> [Word8] -> Segment -> H (Either LoadError [VM.VAddr])
mapOneSegment pdir bytes seg =
  let vaddr = segVaddr seg
      foff = segFileOff seg
      fsz = segFileSz seg
      msz = segMemSz seg
      flags = segFlags seg
      writable = (flags .&. pfW) /= 0
      pages = (msz + 4095) `div` 4096
      loop idx acc
        | idx >= pages = return (Right (reverse acc))
        | otherwise = do
            let curVa = vaddr + fromIntegral (idx * 4096)
            mp <- HPages.allocPage :: H (Maybe (Ptr Word8))
            case mp of
              Nothing -> return (Left NoSpace)
              Just pg -> do
                HPages.zeroPage pg
                let pageFileStart = idx * 4096
                let remainingFile = fsz - pageFileStart
                let copyLen = if remainingFile <= 0 then 0 else min 4096 remainingFile
                mapM_ (\i -> let srcIdx = foff + pageFileStart + i; b = indexBytes bytes srcIdx in poke (pg `plusPtr` i) b) [0 .. copyLen - 1]
                ok <- VM.setPage pdir curVa (Just (VM.PageInfo {VM.physPage = toPhysPage (castPtr pg), VM.writable = writable, VM.dirty = False, VM.accessed = False}))
                if not ok
                  then do
                    HPages.freePage pg
                    return (Left NoSpace)
                  else loop (idx + 1) (curVa : acc)
   in if pages == 0
        then return (Right [])
        else loop 0 []

indexBytes :: [Word8] -> Int -> Word8
indexBytes xs i = go xs i
  where
    go [] _ = 0
    go (y : _) 0 = y
    go (_ : ys) n = go ys (n - 1)

freePDir :: VM.PageMap -> H ()
freePDir pdir = do
  curPtr <- liftIO c_current_pdir
  let l0 = VM.fromPageMap pdir
      curL0 = curPtr
  if l0 == curL0
    then return ()
    else do
      let pageEntries = 512
      let l0Idx = fromIntegral ((VM.minVAddr `div` (2 ^ (39 :: Int))) `mod` 512) :: Int
      -- Instead of recomputing, directly walk all L1 entries for the user window
      -- Simpler: iterate whole L1 table (512) and free reachable L2/L3
      d0 <- peekElemOff l0 l0Idx
      case tableFromDesc d0 of
        Nothing -> HPages.freePage l0
        Just l1 -> do
          forM_ [0 .. pageEntries - 1] $ \i1 -> do
            d1 <- peekElemOff l1 i1
            case tableFromDesc d1 of
              Nothing -> return ()
              Just l2 -> do
                if not (HPages.validPage l2)
                  then return ()
                  else do
                    forM_ [0 .. pageEntries - 1] $ \i2 -> do
                      d2 <- peekElemOff l2 i2
                      case tableFromDesc d2 of
                        Nothing -> return ()
                        Just l3 -> do
                          if not (HPages.validPage l3)
                            then return ()
                            else do
                              forM_ [0 .. 511] $ \i3 -> do
                                d3 <- peekElemOff l3 i3
                                when ((d3 .&. 1) /= 0) $ HPages.freePage (ptrFromWord64 (d3 .&. 0x0000FFFFFFFFF000) :: Ptr Word8)
                              HPages.freePage l3
                    HPages.freePage l2
          HPages.freePage l1
          HPages.freePage l0
  where
    tableFromDesc d
      | d `mod` 2 == 0 = Nothing
      | otherwise = Just (ptrFromWord64 (d .&. 0x0000FFFFFFFFF000))
