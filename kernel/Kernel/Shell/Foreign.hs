{-# LANGUAGE ForeignFunctionInterface #-}

{- | Raw foreign surface for shell dispatch (UART, PSCI, RAM/DTB refs,
buddy stats, TTBR, mmap/mprotect, demand paging). See rust/c-abi.md.
-}
module Kernel.Shell.Foreign (
  c_uart_puts,
  conMirror,
  c_uptime,
  c_off,
  c_reset,
  c_ram_ref,
  c_stack_top_ref,
  c_ram_source_ref,
  c_smp_ref,
  c_dtb_ref,
  c_bank_count,
  c_bank_get,
  c_mem_stats,
  c_buddy_total,
  c_buddy_free,
  c_get_ttbrs,
  c_mmap,
  c_munmap,
  c_mprotect,
  c_malloc_stats,
  c_demand_single,
  c_demand_100,
  c_is_ro_page,
  c_tlb_shootdown,
  c_asid_for,
)
where

import Control.Exception (SomeException, catch)
import Control.Monad (when)
import Data.Word (Word64)
import Foreign.C.String (peekCString)
import Foreign.C.Types (CChar (..), CInt (..), CLong (..), CSize (..))
import Foreign.Ptr (Ptr)
import H.Monad (runH)
import H.Mutable (Ref, newRef, readRef)
import H.Unsafe (unsafePerformH)
import qualified Kernel.Driver.Virtio.Con as Con

foreign import ccall unsafe "uart_puts" c_uart_puts_raw :: Ptr CChar -> IO ()

{- | All shell output flows through here. Console-mirror interposition point:
when 'con mirror on', every UART line is best-effort duplicated to the
virtio-console TX queue (dropped when not inited, never blocks the shell).
-}
c_uart_puts :: Ptr CChar -> IO ()
c_uart_puts p = c_uart_puts_raw p >> mirrorOut p

{- | Best-effort mirror of one UART string to the console slot. Swallows all
exceptions; drops silently unless mirror is on and the server is inited.
-}
mirrorOut :: Ptr CChar -> IO ()
mirrorOut p = do
  on <- runH (readRef conMirror)
  when on $
    ( do
        s <- peekCString p
        slot <- runH (readRef conMirrorSlot)
        _ <- runH (Con.conWriteBytes slot (map (fromIntegral . fromEnum) (take 4096 s)))
        return ()
    )
      `catch` (\(_ :: SomeException) -> return ())

{-# NOINLINE conMirror #-}
conMirror :: Ref Bool
conMirror = unsafePerformH $ newRef False

{-# NOINLINE conMirrorSlot #-}
conMirrorSlot :: Ref Int
conMirrorSlot = unsafePerformH $ newRef 7

foreign import ccall unsafe "house_uptime_secs" c_uptime :: IO Word64

foreign import ccall unsafe "psci_system_off" c_off :: IO ()

foreign import ccall unsafe "psci_system_reset" c_reset :: IO ()

foreign import ccall unsafe "&house_ram_bytes" c_ram_ref :: Ptr Word64

foreign import ccall unsafe "&house_boot_stack_top" c_stack_top_ref :: Ptr Word64

foreign import ccall unsafe "&house_ram_source" c_ram_source_ref :: Ptr (Ptr CChar)

foreign import ccall unsafe "&house_smp" c_smp_ref :: Ptr CInt

foreign import ccall unsafe "&__boot_dtb" c_dtb_ref :: Ptr Word64

foreign import ccall unsafe "fdt_ram_bank_count" c_bank_count :: Ptr () -> IO CInt

foreign import ccall unsafe "fdt_get_ram_bank" c_bank_get :: Ptr () -> CInt -> Ptr Word64 -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "house_mem_stats" c_mem_stats :: Ptr Word64 -> Ptr Word64 -> IO ()

foreign import ccall unsafe "buddy_total_count" c_buddy_total :: IO CInt

foreign import ccall unsafe "buddy_free_count" c_buddy_free :: IO CInt

foreign import ccall unsafe "house_get_ttbrs" c_get_ttbrs :: Ptr Word64 -> Ptr Word64 -> Ptr Word64 -> IO ()

foreign import ccall unsafe "mmap" c_mmap :: Ptr () -> CSize -> CInt -> CInt -> CInt -> CLong -> IO (Ptr ())

foreign import ccall unsafe "munmap" c_munmap :: Ptr () -> CSize -> IO CInt

foreign import ccall unsafe "mprotect" c_mprotect :: Ptr () -> CSize -> CInt -> IO CInt

foreign import ccall unsafe "house_malloc_stats" c_malloc_stats :: Ptr Word64 -> Ptr Word64 -> IO ()

foreign import ccall unsafe "house_vm_demand_single" c_demand_single :: IO CInt

foreign import ccall unsafe "house_vm_demand_100" c_demand_100 :: IO CInt

foreign import ccall unsafe "house_is_ro_page" c_is_ro_page :: Word64 -> IO CInt

foreign import ccall unsafe "house_tlb_shootdown" c_tlb_shootdown :: Word64 -> IO ()

foreign import ccall unsafe "house_asid_for_pdir" c_asid_for :: Ptr Word64 -> IO Word64
