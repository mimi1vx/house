-- | Memory/filesystem-status shell commands: free, mem, detect, palloc.
module Kernel.Shell.Mem
  ( handleFree,
    handleMem,
    handleDetect,
    handlePalloc,
  )
where

import Control.Exception (SomeException, catch)
import Foreign.C.String (peekCString, withCString)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr, intPtrToPtr, ptrToIntPtr)
import Foreign.Storable (peek)
import GHC.Conc (getNumCapabilities, getNumProcessors)
import H.Monad (runH)
import qualified H.Pages as HPages
import Kernel.Shell.Foreign
  ( c_bank_count,
    c_bank_get,
    c_buddy_free,
    c_buddy_total,
    c_dtb_ref,
    c_get_ttbrs,
    c_mem_stats,
    c_ram_ref,
    c_ram_source_ref,
    c_smp_ref,
    c_stack_top_ref,
    c_uart_puts,
  )
import Kernel.Shell.Format (showHex, showHex64)

handleFree :: IO ()

handleFree = do
  fc <- runH HPages.freePageCount
  tot <- c_buddy_total
  freeB <- c_buddy_free
  ram <- peek c_ram_ref
  srcPtr <- peek c_ram_source_ref
  src <- peekCString srcPtr
  smpV <- peek c_smp_ref
  alloca $ \pTot -> alloca $ \pFree -> do
    c_mem_stats pTot pFree
    t <- peek pTot
    f <- peek pFree
    withCString ("free: H.Pages=" ++ show fc ++ " buddy " ++ show freeB ++ "/" ++ show tot ++ " mem " ++ show f ++ "/" ++ show t ++ " ram " ++ show (ram `div` (1024 * 1024)) ++ "M src=" ++ src ++ " smp=" ++ show smpV ++ "\n") c_uart_puts
handleMem :: IO ()
handleMem = do
  ram <- peek c_ram_ref
  stk <- peek c_stack_top_ref
  srcPtr <- peek c_ram_source_ref
  src <- peekCString srcPtr
  smpV <- peek c_smp_ref
  dtbAddr <- peek c_dtb_ref
  let dtbPtr = intPtrToPtr (fromIntegral dtbAddr) :: Ptr ()
  nb <- c_bank_count dtbPtr
  b0 <- alloca $ \pBase -> alloca $ \pSize ->
    if nb > 0
      then do
        r <- c_bank_get dtbPtr 0 pBase pSize
        if r /= 0
          then do
            b <- peek pBase
            s <- peek pSize
            return (" bank0 base=0x" ++ showHex64 b ++ " size=" ++ show (s `div` (1024 * 1024)) ++ "M")
          else return ""
      else return ""
  tot <- c_buddy_total
  fr <- c_buddy_free
  alloca $ \p0 -> alloca $ \p1 -> alloca $ \pt -> do
    c_get_ttbrs p0 p1 pt
    t0 <- peek p0
    t1 <- peek p1
    tc <- peek pt
    withCString ("mem: ram " ++ show (ram `div` (1024 * 1024)) ++ "M src=" ++ src ++ " banks=" ++ show nb ++ b0 ++ " smp=" ++ show smpV ++ " stack_top 0x" ++ showHex (fromIntegral stk) ++ " buddy " ++ show fr ++ "/" ++ show tot ++ " pages ttbr0 0x" ++ showHex64 t0 ++ " ttbr1 0x" ++ showHex64 t1 ++ " tcr 0x" ++ showHex64 tc ++ "\n") c_uart_puts
handleDetect :: IO ()
handleDetect = do
  ram <- peek c_ram_ref
  stk <- peek c_stack_top_ref
  srcPtr <- peek c_ram_source_ref
  src <- peekCString srcPtr
  smpV <- peek c_smp_ref
  dtbAddr <- peek c_dtb_ref
  let dtbPtr = intPtrToPtr (fromIntegral dtbAddr) :: Ptr ()
  nb <- c_bank_count dtbPtr
  caps <- getNumCapabilities
  procs <- getNumProcessors
  withCString ("detect: ram " ++ show (ram `div` (1024 * 1024)) ++ "M src=" ++ src ++ " banks=" ++ show nb ++ " smp=" ++ show smpV ++ " stack_top 0x" ++ showHex (fromIntegral stk) ++ " caps=" ++ show caps ++ " procs=" ++ show procs ++ "\n") c_uart_puts

-- | Allocate one page, report its address, release it back to the pool.
handlePalloc :: IO ()
handlePalloc = do
  r <- runH HPages.allocPage `catch` (\(_ :: SomeException) -> return Nothing)
  case r of
    Nothing -> withCString "palloc fail\n" c_uart_puts
    Just p -> do
      withCString ("palloc ok " ++ show (ptrToIntPtr (castPtr p)) ++ "\n") c_uart_puts
      runH (HPages.freePage p) `catch` (\(_ :: SomeException) -> return ())

