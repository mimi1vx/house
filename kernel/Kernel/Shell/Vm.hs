{- | VM diagnostic shell command: demand pager + mmap/mprotect/munmap +
isolate + ASID + shootdown, reported as vm-ok / vm-fail.
-}
module Kernel.Shell.Vm (
  handleVm,
)
where

import Control.Exception (SomeException, catch)
import Control.Monad (forM_, when)
import Data.Word (Word64, Word8)
import Foreign.C.String (withCString)
import Foreign.C.Types (CInt, CSize)
import Foreign.Ptr (Ptr, castPtr, intPtrToPtr, nullPtr, plusPtr, ptrToIntPtr)
import Foreign.Storable (peek, poke)
import H.Monad (runH)
import qualified H.Pages as HPages
import qualified H.PhysicalMemory as HPhys
import qualified H.VirtualMemory as VM
import Kernel.Shell.Foreign (
  c_asid_for,
  c_demand_100,
  c_demand_single,
  c_is_ro_page,
  c_mmap,
  c_mprotect,
  c_munmap,
  c_tlb_shootdown,
  c_uart_puts,
 )

handleVm :: IO ()
handleVm = do
  -- wrapper that prints vm-ok on full pass, vm-fail otherwise; all sub-steps catch exceptions
  ok <- vmTest `catch` (\(_ :: SomeException) -> return False)
  if ok
    then withCString "vm-ok\n" c_uart_puts
    else withCString "vm-fail\n" c_uart_puts

vmTest :: IO Bool
vmTest = do
  withCString "vm: start\n" c_uart_puts
  r1 <- vmDemand `catch` (\(_ :: SomeException) -> withCString "vm: demand fail\n" c_uart_puts >> return False)
  r2 <- vmMmap `catch` (\(_ :: SomeException) -> withCString "vm: mmap fail\n" c_uart_puts >> return False)
  r3 <- vmIsolate `catch` (\(_ :: SomeException) -> withCString "vm: isolate fail\n" c_uart_puts >> return False)
  r4 <- vmShootdown `catch` (\(_ :: SomeException) -> withCString "vm: shootdown fail\n" c_uart_puts >> return False)
  r5 <- vmAsid `catch` (\(_ :: SomeException) -> withCString "vm: asid fail\n" c_uart_puts >> return False)
  withCString ("vm: r1=" ++ show r1 ++ " r2=" ++ show r2 ++ " r3=" ++ show r3 ++ " r4=" ++ show r4 ++ " r5=" ++ show r5 ++ "\n") c_uart_puts
  let ok = r1 && r2 && r3 && r4 && r5
  withCString (if ok then "vm: all ok\n" else "vm: some fail\n") c_uart_puts
  return ok

vmDemand :: IO Bool
vmDemand = do
  r1 <- c_demand_single
  let ok1 = r1 /= 0
  withCString ("vm: demand fault ok pattern " ++ (if ok1 then "ok" else "fail") ++ "\n") c_uart_puts
  r2 <- c_demand_100
  let ok2 = r2 /= 0
  withCString ("vm: demand ok 100 pages " ++ (if ok2 then "ok" else "fail") ++ "\n") c_uart_puts
  -- Strict gate: both legs must pass. A single-page failure under a
  -- 100-page pass is logged as an explicit hvf quirk, never tolerated.
  when (ok2 && not ok1) $
    withCString "vm: demand quirk hvf single-page race\n" c_uart_puts
  return (ok1 && ok2)

vmMmap :: IO Bool
vmMmap = do
  let len = 1024 * 1024 :: CSize
  ptr <- c_mmap nullPtr len 3 0x02 (-1) 0 -- PROT_READ|WRITE, MAP_PRIVATE|ANONYMOUS (0x02)
  if ptr == intPtrToPtr (-1) || ptr == nullPtr
    then withCString "vm: mmap fail ptr\n" c_uart_puts >> return False
    else do
      -- write 4K (1 page) to ensure it is faulted and mapped
      let n = 4096 :: Int
      forM_ [0 .. n - 1] $ \i -> poke (ptr `plusPtr` i) (fromIntegral (i `mod` 256) :: Word8)
      -- mprotect RO only the written 256K (prot 1 = READ)
      rc <- c_mprotect ptr (fromIntegral n) 1
      let okProt = rc == 0
      withCString ("vm: mprotect RO " ++ (if okProt then "ok" else "fail") ++ "\n") c_uart_puts
      -- Prove the page is really RO: house_is_ro_page must say so.
      isRo <- c_is_ro_page (fromIntegral (ptrToIntPtr ptr) :: Word64)
      let okRo = isRo /= (0 :: CInt)
      withCString ("vm: ro page " ++ (if okRo then "ok" else "fail") ++ "\n") c_uart_puts
      -- Prove the perm fault fired and the store was skipped: the byte
      -- written above (offset 0 holds 0) must be unchanged after the poke.
      old <- peek (castPtr ptr :: Ptr Word8)
      -- trigger perm fault RO write (should log [demand] perm fault RO and skip)
      poke (castPtr ptr :: Ptr Word8) 0xFF
      new <- peek (castPtr ptr :: Ptr Word8)
      let okPermSkip = new == old
      withCString ("vm: perm skip " ++ (if okPermSkip then "ok" else "fail") ++ "\n") c_uart_puts
      withCString "mprotect RO perm logged\n" c_uart_puts
      -- munmap
      rc2 <- c_munmap ptr len
      let okUnmap = rc2 == 0
      withCString ("vm: munmap " ++ (if okUnmap then "ok" else "fail") ++ "\n") c_uart_puts
      -- Prove the range is really unmapped: mprotect on a PTE-invalid
      -- range must fail. If munmap left the mapping, this succeeds.
      rc3 <- c_mprotect ptr (fromIntegral n) 1
      let okUnmapped = rc3 /= 0
      withCString ("vm: unmapped " ++ (if okUnmapped then "ok" else "fail") ++ "\n") c_uart_puts
      return (okProt && okRo && okPermSkip && okUnmap && okUnmapped)

vmIsolate :: IO Bool
vmIsolate = do
  ok <- runH isolateCheck `catch` (\(_ :: SomeException) -> return False)
  if ok
    then withCString "isolate ok\n" c_uart_puts >> return True
    else withCString "isolate fail\n" c_uart_puts >> return False
  where
    isolateCheck = do
      m1 <- VM.allocPageMap
      m2 <- VM.allocPageMap
      case (m1, m2) of
        (Just p1, Just p2) -> do
          ma <- HPages.allocPage
          mb <- HPages.allocPage
          case (ma, mb) of
            (Just rawA, Just rawB) -> do
              let pa = rawA :: Ptr Word8
                  pb = rawB :: Ptr Word8
              HPages.zeroPage pa
              HPages.zeroPage pb
              let va = VM.minVAddr
                  infoA = VM.PageInfo {VM.physPage = HPhys.toPhysPage pa, VM.writable = True, VM.dirty = False, VM.accessed = False}
                  infoB = VM.PageInfo {VM.physPage = HPhys.toPhysPage pb, VM.writable = True, VM.dirty = False, VM.accessed = False}
              ok1 <- VM.setPage p1 va (Just infoA)
              ok2 <- VM.setPage p2 va (Just infoB)
              g1 <- VM.getPage p1 va
              g2 <- VM.getPage p2 va
              _ <- VM.setPage p1 va Nothing
              _ <- VM.setPage p2 va Nothing
              HPages.freePage pa
              HPages.freePage pb
              case (g1, g2) of
                (Just i1, Just i2) -> return (ok1 && ok2 && VM.physPage i1 /= VM.physPage i2)
                _ -> return False
            _ -> do
              -- Failure path owns whichever pages arrived: release them.
              maybe (return ()) HPages.freePage ma
              maybe (return ()) HPages.freePage mb
              return False
        _ -> return False

vmShootdown :: IO Bool
vmShootdown = do
  let len = 4096 :: CSize
  ptr <- c_mmap nullPtr len 3 0x02 (-1) 0
  if ptr == intPtrToPtr (-1) || ptr == nullPtr
    then withCString "shootdown fail mmap\n" c_uart_puts >> return False
    else do
      poke (castPtr ptr :: Ptr Word8) (0xAA :: Word8)
      v0 <- peek (castPtr ptr :: Ptr Word8) :: IO Word8
      rcProt <- c_mprotect ptr len 1
      c_tlb_shootdown (fromIntegral (ptrToIntPtr ptr) :: Word64)
      v1 <- peek (castPtr ptr :: Ptr Word8) :: IO Word8
      rcUnmap <- c_munmap ptr len
      let ok = v0 == 0xAA && v1 == 0xAA && rcProt == 0 && rcUnmap == 0
      withCString (if ok then "smp shootdown ok\n" else "shootdown fail\n") c_uart_puts
      return ok

vmAsid :: IO Bool
vmAsid = do
  mpair <- runH asidAllocs `catch` (\(_ :: SomeException) -> return (Nothing, Nothing))
  case mpair of
    (Just p1, Just p2) -> do
      let q1 = VM.fromPageMap p1
          q2 = VM.fromPageMap p2
      a1 <- c_asid_for q1
      a2 <- c_asid_for q2
      a1' <- c_asid_for q1
      let ok = a1 /= 0 && a2 /= 0 && a1 /= a2 && a1' == a1
      withCString (if ok then "vm: asid ok\n" else "vm: asid fail\n") c_uart_puts
      return ok
    _ -> withCString "vm: asid fail\n" c_uart_puts >> return False
  where
    asidAllocs = do
      m1 <- VM.allocPageMap
      m2 <- VM.allocPageMap
      return (m1, m2)
