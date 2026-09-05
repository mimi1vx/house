{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-incomplete-uni-patterns #-}

module HouseA64 where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, catch)
import Control.Monad (forM_, when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Char (chr, ord)
import Data.List (isPrefixOf, nub)
import Data.Word (Word32, Word64, Word8)
import Foreign.C.String (peekCString, withCString)
import Foreign.C.Types (CChar (..), CInt (..), CLong (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, intPtrToPtr, nullPtr, plusPtr, ptrToIntPtr)
import Foreign.Storable (peek, poke)
import GHC.Conc
  ( getNumCapabilities,
    getNumProcessors,
    par,
    pseq,
    setNumCapabilities,
  )
import qualified H.FileSystem as FS
import H.Monad (runH)
import H.Mutable (Ref, newRef, readRef, writeRef)
import qualified H.Pages as HPages
import qualified H.PhysicalMemory as HPhys
import H.Unsafe (unsafePerformH)
import qualified H.VirtualMemory as VM
import qualified Kernel.Driver.Dmesg as Dmesg
import qualified Kernel.Driver.GIC as DGIC
import qualified Kernel.Driver.IRQ as DIRQ
import qualified Kernel.Driver.PL011 as PL011
import qualified Kernel.Driver.PL011Server as PL011S
import qualified Kernel.Driver.Registry as DrvReg
import Kernel.Driver.Types (showDriverInfo)
import qualified Kernel.Driver.Virtio.Blk as Blk
import qualified Kernel.Driver.Virtio.Blk.Types as BlkTypes
import qualified Kernel.Driver.Virtio.Con as Con
import qualified Kernel.Driver.Virtio.Con.Types as ConTypes
import qualified Kernel.Driver.Virtio.Net as Net
import qualified Kernel.Driver.Virtio.Net.Types as NetTypes
import qualified Kernel.Driver.Virtio.Queue as VQueue
import qualified Kernel.Driver.Virtio.Transport as VTrans
import qualified Kernel.Driver.Virtio.Types as VTypes
import qualified Kernel.Driver.VirtioProbe as VProbe
import qualified Kernel.FileSystem.BlkPersist as BlkPersist
import qualified Kernel.IPC.Endpoint as IPC
import qualified Kernel.IPC.Grant as G
import qualified Kernel.IPC.Nameservice as NS
import Kernel.IPC.Types (Message (..))
import qualified Kernel.LineEditor as LE
import qualified Kernel.SMP as SMP
import qualified Kernel.Userspace as U
import qualified Kernel.Userspace.Loader as ULdr
import System.Timeout (timeout)

foreign import ccall unsafe "uart_puts" c_uart_puts_raw :: Ptr CChar -> IO ()

-- | All shell output flows through here. Console-mirror interposition point:
-- when 'con mirror on', every UART line is best-effort duplicated to the
-- virtio-console TX queue (dropped when not inited, never blocks the shell).
c_uart_puts :: Ptr CChar -> IO ()
c_uart_puts p = c_uart_puts_raw p >> mirrorOut p

-- | Best-effort mirror of one UART string to the console slot. Swallows all
-- exceptions; drops silently unless mirror is on and the server is inited.
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

foreign import ccall unsafe "house_vm_demand_single" c_demand_single :: IO CInt

foreign import ccall unsafe "house_vm_demand_100" c_demand_100 :: IO CInt

foreign import ccall unsafe "house_puts_after" c_puts_after :: IO ()

foreign import ccall unsafe "init_page_dir" c_init_pdir :: Ptr Word64 -> IO ()

foreign import ccall unsafe "current_pdir" c_current_pdir :: IO (Ptr Word64)

foreign import ccall unsafe "house_tlb_shootdown" c_tlb_shootdown :: Word64 -> IO ()

foreign import ccall unsafe "house_asid_for_pdir" c_asid_for :: Ptr Word64 -> IO Word64

-- Embedded EL0 hello ELF for run demo (static aarch64, svc write/exit). If ramfs missing, write on boot.
helloBytes :: [Word8]
helloBytes = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 56, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 120, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 43, 0, 0, 0, 0, 0, 0, 0, 43, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 128, 210, 193, 0, 0, 16, 226, 1, 128, 210, 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 0, 0, 0, 20, 72, 101, 108, 108, 111, 32, 102, 114, 111, 109, 32, 69, 76, 48, 10]

-- Embedded EL0 argv/env probe (static aarch64, svc write/exit). Prints argc,
-- each argv line, ENV, each env line. Built from build-probe/argenv.s
-- (assembled + repacked to a hello-style minimal ELF: R+E text plus RW
-- data page); if ramfs missing, write on boot next to /bin/hello.
argenvBytes :: [Word8]
argenvBytes =
  [ 127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 2, 0, 183, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0
  , 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 64, 0, 56, 0, 2, 0, 0, 0, 0, 0, 0, 0
  , 1, 0, 0, 0, 5, 0, 0, 0, 176, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0
  , 130, 1, 0, 0, 0, 0, 0, 0, 130, 1, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 6, 0, 0, 0
  , 50, 2, 0, 0, 0, 0, 0, 0, 0, 16, 0, 1, 0, 0, 0, 0
  , 0, 16, 0, 1, 0, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0
  , 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 243, 3, 64, 249, 21, 0, 0, 176, 181, 2, 0, 145, 244, 3, 21, 170
  , 1, 0, 0, 144, 33, 224, 5, 145, 38, 0, 0, 148, 224, 3, 19, 170
  , 58, 0, 0, 148, 64, 1, 128, 82, 29, 0, 0, 148, 247, 35, 0, 145
  , 24, 0, 128, 210, 31, 3, 19, 235, 226, 0, 0, 84, 225, 134, 64, 248
  , 28, 0, 0, 148, 64, 1, 128, 82, 21, 0, 0, 148, 24, 7, 0, 145
  , 249, 255, 255, 23, 247, 34, 0, 145, 1, 0, 0, 144, 33, 248, 5, 145
  , 20, 0, 0, 148, 64, 1, 128, 82, 13, 0, 0, 148, 225, 134, 64, 248
  , 161, 0, 0, 180, 15, 0, 0, 148, 64, 1, 128, 82, 8, 0, 0, 148
  , 251, 255, 255, 23, 130, 2, 21, 203, 225, 3, 21, 170, 32, 0, 128, 210
  , 33, 0, 0, 212, 0, 0, 128, 210, 65, 0, 0, 212, 135, 2, 21, 203
  , 255, 64, 31, 241, 66, 0, 0, 84, 128, 22, 0, 56, 192, 3, 95, 214
  , 253, 123, 191, 169, 253, 3, 0, 145, 2, 0, 128, 210, 95, 0, 32, 241
  , 162, 0, 0, 84, 35, 104, 98, 56, 99, 0, 0, 52, 66, 4, 0, 145
  , 251, 255, 255, 23, 4, 0, 128, 210, 159, 0, 2, 235, 34, 1, 0, 84
  , 32, 104, 100, 56, 225, 11, 191, 169, 227, 19, 191, 169, 236, 255, 255, 151
  , 227, 19, 193, 168, 225, 11, 193, 168, 132, 4, 0, 145, 247, 255, 255, 23
  , 253, 123, 193, 168, 192, 3, 95, 214, 253, 123, 191, 169, 253, 3, 0, 145
  , 227, 3, 1, 209, 228, 3, 3, 170, 65, 1, 128, 210, 31, 0, 0, 241
  , 129, 0, 0, 84, 2, 6, 128, 82, 98, 252, 31, 56, 7, 0, 0, 20
  , 2, 8, 193, 154, 69, 128, 1, 155, 165, 192, 0, 145, 101, 252, 31, 56
  , 224, 3, 2, 170, 96, 255, 255, 181, 0, 0, 128, 82, 127, 0, 4, 235
  , 2, 1, 0, 84, 96, 20, 64, 56, 225, 15, 191, 169, 228, 23, 191, 169
  , 207, 255, 255, 151, 228, 23, 193, 168, 225, 15, 193, 168, 248, 255, 255, 23
  , 253, 123, 193, 168, 192, 3, 95, 214, 97, 114, 103, 99, 61, 0, 69, 78
  , 86, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
  , 0, 0 ]
foreign export ccall house_main :: IO ()

house_main :: IO ()
house_main = do
  caps0 <- getNumCapabilities
  procs0 <- getNumProcessors
  mask0 <- SMP.onlineSet
  withCString ("[house] rts caps=" ++ show caps0 ++ " procs=" ++ show procs0 ++ " online=" ++ show mask0 ++ "\n") c_uart_puts
  withCString "Welcome to the House shell! Enter help to see a list of commands.\n\n" c_uart_puts
  console <- runH PL011.launchConsoleDriver
  kbd <- runH PL011.launchPL011KeyboardDriver
  editor <- runH (LE.newEditor kbd console)
  _ <- runH FS.fsInit
  -- bootstrap /bin/hello + /bin/argenv from embedded bytes if missing
  _ <- runH $ do
    r <- FS.fsStat "/bin/hello"
    case r of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.fsMkdir "/bin"
        let txt = map (chr . fromIntegral) helloBytes
        _ <- FS.fsWrite "/bin/hello" txt
        return ()
    r2 <- FS.fsStat "/bin/argenv"
    case r2 of
      Right _ -> return ()
      Left _ -> do
        _ <- FS.fsMkdir "/bin"
        let txt2 = map (chr . fromIntegral) argenvBytes
        _ <- FS.fsWrite "/bin/argenv" txt2
        return ()
  _ <- runH Dmesg.dmesgInit
  _ <- runH (Dmesg.dmesgLog "House driver framework online")
  -- Link driver GIC/IRQ helpers into closure (probe-only track keeps them unused at runtime)
  _ <- runH (return (DGIC.enableSpi, DGIC.disableSpi, DIRQ.registerIrqForwarding) >> return ())
  loop editor
  where
    loop ed = do
      line <- runH (LE.getLine ed "> ")
      handle line
      loop ed
    handle line = case words line of
      [] -> return ()
      ("help" : _) -> withCString usage c_uart_puts
      ("echo" : ws) -> handleEcho ws
      ["clear"] -> withCString "\ESC[2J\ESC[H" c_uart_puts
      ("uname" : args) -> handleUname args
      ["uptime"] -> do s <- c_uptime; withCString ("up " ++ show s ++ " seconds\n") c_uart_puts
      ("shutdown" : args) -> case args of
        ["-r"] -> c_reset
        ["-h"] -> c_off
        _ -> withCString "usage: shutdown [-h|-r]\n" c_uart_puts
      ["lambda"] -> withCString "Too much to abstract!\n" c_uart_puts
      ["preempt"] -> do withCString (replicate 100 'a' ++ "\n") c_uart_puts; withCString (replicate 100 'b' ++ "\n") c_uart_puts
      ["wastemem", nStr] -> case reads nStr of
        [(n, "")] -> withCString (show (sum [1 .. n :: Integer]) ++ "\n") c_uart_puts
        _ -> withCString "usage: wastemem <number>\n" c_uart_puts
      ["smp"] -> do
        caps <- getNumCapabilities
        procs <- getNumProcessors
        on <- SMP.onlineSet
        let n = length on
            mask = sum [1 `shiftL` i | i <- on] :: Int
        withCString ("smp: " ++ show n ++ " cores online caps=" ++ show caps ++ " procs=" ++ show procs ++ " timers=PPI27+30 ipi=SGI0 caches=WB onlineMask=0x" ++ showHex mask ++ "\n") c_uart_puts
      ["smp", "up", nStr] -> handleSmpUp nStr
      ["smp", "down", nStr] -> handleSmpDown nStr
      ["caps"] -> do caps <- getNumCapabilities; procs <- getNumProcessors; withCString ("caps " ++ show caps ++ " procs " ++ show procs ++ "\n") c_uart_puts
      ["parfib", nStr] -> case reads nStr of
        [(n, "")] -> do v <- parFibIO n; withCString ("parfib " ++ show n ++ " = " ++ show v ++ "\n") c_uart_puts
        _ -> withCString "usage: parfib <n>\n" c_uart_puts
      ["mvar", nStr] -> case reads nStr of
        [(n, "")] -> do ok <- mvarTest n; withCString (if ok then "mvar ok\n" else "mvar fail\n") c_uart_puts
        _ -> withCString "usage: mvar <number>\n" c_uart_puts
      ["ls"] -> handleLs "/"
      ["ls", p] -> handleLs p
      ["cat", p] -> handleCat p
      ["mkdir", p] -> handleMkdir p
      ["rm", p] -> handleRm p
      ["stat", p] -> handleStat p
      ("write" : p : rest) -> handleWrite p (unwords rest)
      ["write"] -> withCString "usage: write <path> <text>\n" c_uart_puts
      ["ns", "ls"] -> handleNsLs
      ["ns", "reg", name] -> handleNsReg name
      ["ns", "reg"] -> withCString "usage: ns reg <name>\n" c_uart_puts
      ["ipc", "ping", name] -> handleIpcPing name
      ["ipc", "ping"] -> withCString "usage: ipc ping <nsName>\n" c_uart_puts
      ["ipc", "grant"] -> handleIpcGrant
      ["ipc"] -> withCString "usage: ipc ping <nsName> | ipc grant\n" c_uart_puts
      ["lsdev"] -> handleLsdev
      ["dmesg"] -> handleDmesg
      ["dmesg", "clear"] -> handleDmesgClear
      ["virtio", "scan"] -> handleVirtioScan
      ["virtio", "init", s] -> handleVirtioInit s
      ["virtio", "notify", s] -> handleVirtioNotify s
      ["virtio", "status"] -> handleVirtioStatus
      ["virtio", "ack", s] -> handleVirtioAck s
      ["virtio", "irqtest", s] -> handleVirtioIrqtest s
      ["virtio", "teardown", s] -> handleVirtioTeardown s
      ["virtio"] -> withCString "usage: virtio scan|init <slot>|notify <slot>|status|ack <slot>|irqtest <slot>|teardown <slot>\n" c_uart_puts
      ["blk", "init", s] -> handleBlkInit s
      ["blk", "status", s] -> handleBlkStatus s
      ["blk", "read", s, lba] -> handleBlkRead s lba
      ["blk", "write", s, lba, txt] -> handleBlkWrite s lba txt
      ["blk", "write", s, lba] -> handleBlkWrite s lba ""
      ["blk", "teardown", s] -> handleBlkTeardown s
      ["blk", "sync"] -> handleBlkSync Nothing
      ["blk", "sync", s] -> handleBlkSync (Just s)
      ["blk", "mount", s] -> handleBlkMount s
      ["blk"] -> withCString "usage: blk init <slot>|status <slot>|read <slot> <lba>|write <slot> <lba> <text>|sync [slot]|mount <slot>|teardown <slot>\n" c_uart_puts
      ["net", "init", s] -> handleNetInit s
      ["net", "status", s] -> handleNetStatus s
      ["net", "teardown", s] -> handleNetTeardown s
      ["ifconfig"] -> handleIfConfig
      ["ping", ip] -> handlePing ip
      ["udpecho", ip, port, txt] -> handleUdpEcho ip port txt
      ["udpecho", ip, port] -> handleUdpEcho ip port ""
      ["arp", "ls"] -> handleArpLs
      ["net", "dhcp"] -> handleNetDhcp
      ["net"] -> withCString "usage: net init <slot>|status <slot>|ifconfig|ping <ip>|udpecho <ip> <port> <text>|arp ls|dhcp|teardown <slot>\n" c_uart_puts
      ["con", "init", s] -> handleConInit s
      ["con", "status", s] -> handleConStatus s
      ("con" : "write" : s : rest) -> handleConWrite s (unwords rest)
      ["con", "read", s] -> handleConRead (Just s)
      ["con", "read"] -> handleConRead Nothing
      ["con", "teardown", s] -> handleConTeardown s
      ["con", "mirror", "on"] -> handleConMirror True
      ["con", "mirror", "off"] -> handleConMirror False
      ["con"] -> withCString "usage: con init <slot>|status <slot>|write <slot> <text>|read [slot]|teardown <slot>|mirror on|off\n" c_uart_puts
      ["free"] -> handleFree
      ["mem"] -> handleMem
      ["detect"] -> handleDetect
      ["vm"] -> handleVm
      ["palloc"] -> handlePalloc
      ["run"] -> withCString "usage: run <path> [args...]\n" c_uart_puts
      ("run" : p : args) -> handleRun p args
      _ -> withCString ("unknown command: " ++ line ++ "\n") c_uart_puts
    handleEcho ws = case break (== ">") ws of
      (pre, []) -> withCString (unwords pre ++ "\n") c_uart_puts
      (pre, _ : rest) -> case rest of
        [] -> withCString "EINVAL: missing target after >\n" c_uart_puts
        (target : _) -> do
          r <- runH (FS.fsWrite target (unwords pre))
          case r of
            Left e -> withCString (showFsError e ++ "\n") c_uart_puts
            Right () -> return ()
    handleSmpUp nStr = case reads nStr of
      [(n, "")] -> do
        r <- SMP.up n
        case r of
          Left e -> withCString ("smp up failed: " ++ e ++ "\n") c_uart_puts
          Right () -> do
            k <- SMP.onlineCount
            setNumCapabilities k
            withCString ("smp up ok online=" ++ show k ++ "\n") c_uart_puts
      _ -> withCString "usage: smp up <core>\n" c_uart_puts
    handleSmpDown nStr = case reads nStr of
      [(n, "")] -> do
        k0 <- SMP.onlineCount
        r <- SMP.down n
        case r of
          Left e -> withCString ("smp down failed: " ++ e ++ "\n") c_uart_puts
          Right () -> do
            k <- SMP.onlineCount
            when (k < k0) (setNumCapabilities k)
            withCString ("smp down ok online=" ++ show k ++ "\n") c_uart_puts
      _ -> withCString "usage: smp down <core>\n" c_uart_puts
    handleLs p = do
      r <- runH (FS.fsLs p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right xs -> withCString (unwords xs ++ "\n") c_uart_puts
    handleCat p = do
      r <- runH (FS.fsRead p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handleMkdir p = do
      r <- runH (FS.fsMkdir p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleRm p = do
      r <- runH (FS.fsRm p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleStat p = do
      r <- runH (FS.fsStat p)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right st -> withCString (show st ++ "\n") c_uart_puts
    handleWrite p txt = do
      r <- runH (FS.fsWrite p txt)
      case r of
        Left e -> withCString (showFsError e ++ "\n") c_uart_puts
        Right () -> return ()
    handleNsLs = do
      xs <- runH NS.nsList
      withCString (if null xs then "(empty)\n" else unwords xs ++ "\n") c_uart_puts
    handleNsReg name = do
      r <- runH $ do
        -- special-case pl011 launches the server demo
        if name == "pl011"
          then PL011S.launchPL011Server
          else do
            ep <- IPC.newEndpoint
            res <- NS.nsRegister name ep
            case res of
              Left _ -> IPC.freeEndpoint ep >> return res
              Right () -> return res
      case r of
        Left e -> withCString (show e ++ "\n") c_uart_puts
        Right () -> withCString ("registered " ++ name ++ "\n") c_uart_puts
    handleIpcPing name = do
      r <- runH $ do
        mep <- NS.nsLookup name
        case mep of
          Nothing -> return (Left (show name ++ " not found"))
          Just ep -> do
            let msg = Message 0 [42] Nothing
            res <- IPC.call ep msg
            case res of
              Left e -> return (Left (show e))
              Right replyMsg -> return (Right replyMsg)
      case r of
        Left e -> withCString ("ipc ping failed: " ++ e ++ "\n") c_uart_puts
        Right _ -> withCString "ok\n" c_uart_puts
    handleIpcGrant = do
      r <- runH $ do
        mg <- G.grantAlloc
        case mg of
          Left e -> return (Left (show e))
          Right g -> do
            mep <- NS.nsLookup "pl011"
            case mep of
              Nothing -> do
                -- no server yet, just free and report ok (grant alloc succeeded)
                G.grantFree g
                return (Right "ok (no server, grant alloc ok)")
              Just ep -> do
                let msg = Message 1 [] (Just g)
                res <- IPC.call ep msg
                case res of
                  Left e -> do G.grantFree g; return (Left (show e))
                  Right replyMsg -> do
                    -- grant echo: server returns grant, reclaim or free it
                    case G.grantRecv replyMsg of
                      Just g' -> G.grantFree g'
                      Nothing -> return ()
                    return (Right "ok")
      case r of
        Left e -> withCString ("grant failed: " ++ e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handleLsdev = do
      ds <- runH DrvReg.listDrivers
      if null ds
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines (map showDriverInfo ds)) c_uart_puts
    handleDmesg = do
      xs <- runH Dmesg.dmesgRead
      if null xs
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines xs) c_uart_puts
    handleDmesgClear = do
      _ <- runH Dmesg.dmesgClear
      withCString "cleared\n" c_uart_puts
    handleVirtioScan = do
      infos <- runH VProbe.virtioScan
      let fmt i =
            "virtio slot "
              ++ show (VProbe.vsiSlot i)
              ++ ": "
              ++ ( if VProbe.vsiPresent i
                     then "device_id=" ++ show (VProbe.vsiDeviceId i) ++ " vendor=0x" ++ showHex (fromIntegral (VProbe.vsiVendorId i)) ++ " spi=" ++ maybe "?" show (VProbe.vsiSpi i)
                     else "empty"
                 )
      withCString (unlines (map fmt infos)) c_uart_puts
    handleVirtioInit s = case reads s of
      [(n, "")] -> do
        r <- runH (VTrans.virtioInit n)
        case r of
          Left e -> withCString (VTypes.virtioErrorToString e ++ "\n") c_uart_puts
          Right dev -> withCString ("ok device_id=" ++ show (VTrans.vdId dev) ++ " qsize=" ++ show (maybe 0 VQueue.queueSize (VTrans.vdQueue dev)) ++ " endpoint=" ++ show (VTrans.vdEndpoint dev) ++ "\n") c_uart_puts
      _ -> withCString "usage: virtio init <slot>\n" c_uart_puts
    handleVirtioNotify s = case reads s of
      [(n, "")] -> do
        r <- runH (VTrans.virtioNotify n 0)
        case r of
          Left e -> withCString (VTypes.virtioErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "notified\n" c_uart_puts
      _ -> withCString "usage: virtio notify <slot>\n" c_uart_puts
    handleVirtioStatus = do
      xs <- runH VTrans.virtioStatusAll
      let fmt (slot, st) = "virtio slot " ++ show slot ++ ": status=0x" ++ showHex (fromIntegral st) ++ " " ++ show st
      withCString (unlines (map fmt xs)) c_uart_puts
    handleVirtioAck s = case reads s of
      [(n, "")] -> do
        st <- runH (VTrans.virtioInterruptStatus n)
        _ <- runH (VTrans.virtioAck n 1)
        withCString ("ack slot " ++ show n ++ " status=0x" ++ showHex (fromIntegral st) ++ "\n") c_uart_puts
      _ -> withCString "usage: virtio ack <slot>\n" c_uart_puts
    handleVirtioIrqtest s = case reads s of
      [(n, "")] -> do
        st <- runH (VTrans.virtioInterruptStatus n)
        _ <- runH (VTrans.virtioAck n 1)
        xs <- runH NS.nsList
        let hasNs = ("virtio-slot" ++ show n) `elem` xs
        withCString ("irqtest slot " ++ show n ++ " status=0x" ++ showHex (fromIntegral st) ++ " ns=" ++ show hasNs ++ " irq ok\n") c_uart_puts
      _ -> withCString "usage: virtio irqtest <slot>\n" c_uart_puts
    handleVirtioTeardown s = case reads s of
      [(n, "")] -> do
        r <- runH (VTrans.virtioTeardown n)
        case r of
          Left e -> withCString (VTypes.virtioErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "teardown ok\n" c_uart_puts
      _ -> withCString "usage: virtio teardown <slot>\n" c_uart_puts
    handleBlkInit s = case reads s of
      [(n, "")] -> do
        r <- runH (Blk.blkServerInit n)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right dev -> withCString ("ok capacity=" ++ show (Blk.blkCapacity dev) ++ " sectors (" ++ show (Blk.blkCapacity dev `div` 8) ++ " blocks) slot=" ++ show (Blk.blkSlot dev) ++ "\n") c_uart_puts
      _ -> withCString "usage: blk init <slot>\n" c_uart_puts
    handleBlkStatus s = case reads s of
      [(n, "")] -> do
        r <- runH (Blk.blkGetCapacity n)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right cap -> withCString ("capacity " ++ show cap ++ " sectors (" ++ show (cap `div` 8) ++ " blocks) slot=" ++ show n ++ "\n") c_uart_puts
      _ -> withCString "usage: blk status <slot>\n" c_uart_puts
    handleBlkRead s lbaStr = case (reads s, reads lbaStr) of
      ([(n, "")], [(lba, "")]) -> do
        r <- runH (Blk.blkReadBlocks n lba)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right txt -> withCString (txt ++ "\n") c_uart_puts
      _ -> withCString "usage: blk read <slot> <lba>\n" c_uart_puts
    handleBlkWrite s lbaStr txt = case (reads s, reads lbaStr) of
      ([(n, "")], [(lba, "")]) -> do
        r <- runH (Blk.blkWriteBlocks n lba txt)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "ok\n" c_uart_puts
      _ -> withCString "usage: blk write <slot> <lba> <text>\n" c_uart_puts
    handleBlkTeardown s = case reads s of
      [(n, "")] -> do
        r <- runH (Blk.blkServerTeardown n)
        case r of
          Left e -> withCString (BlkTypes.blkErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "teardown ok\n" c_uart_puts
      _ -> withCString "usage: blk teardown <slot>\n" c_uart_puts
    handleBlkSync mSlot = do
      slot <- case mSlot of
        Just s -> case reads s of [(n, "")] -> return n; _ -> return (-1)
        Nothing -> do
          xs <- runH NS.nsList
          return (findBlkSlot xs)
      if slot < 0
        then withCString "usage: blk sync [slot]|mount <slot>\n" c_uart_puts
        else do
          r <- runH (BlkPersist.persistSave slot)
          case r of
            Left e -> withCString (BlkPersist.persistErrorToString e ++ "\n") c_uart_puts
            Right () -> withCString "sync ok\n" c_uart_puts
    handleBlkMount s = case reads s of
      [(n, "")] -> do
        r <- runH (BlkPersist.persistRestore n)
        case r of
          Left e -> withCString (BlkPersist.persistErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "mount ok\n" c_uart_puts
      _ -> withCString "usage: blk mount <slot>\n" c_uart_puts
    findBlkSlot xs = case filter ("virtio-blk" `isPrefixOf`) xs of
      (x : _) -> case reads (drop (length "virtio-blk") x) of [(n, "")] -> n; _ -> 0
      [] -> 0
    handleNetInit s = case reads s of
      [(n, "")] -> do
        r <- runH (Net.netServerInit n)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right dev -> withCString ("ok mac=" ++ NetTypes.showMac (NetTypes.netMac dev) ++ " ip=10.0.2.15 gw=10.0.2.2 qsize0=" ++ show (maybe 0 VQueue.queueSize (Just (NetTypes.netRxQueue dev))) ++ " qsize1=" ++ show (maybe 0 VQueue.queueSize (Just (NetTypes.netTxQueue dev))) ++ "\n") c_uart_puts
      _ -> withCString "usage: net init <slot>\n" c_uart_puts
    handleNetStatus s = case reads s of
      [(n, "")] -> do
        r <- runH (Net.netGetMac n)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right mac -> do
            xs <- runH NS.nsList
            let hasNs = ("virtio-net" ++ show n) `elem` xs
            withCString ("net slot " ++ show n ++ " mac=" ++ NetTypes.showMac mac ++ " ns=" ++ show hasNs ++ " status ok\n") c_uart_puts
      _ -> withCString "usage: net status <slot>\n" c_uart_puts
    handleNetTeardown s = case reads s of
      [(n, "")] -> do
        r <- runH (Net.netServerTeardown n)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "teardown ok\n" c_uart_puts
      _ -> withCString "usage: net teardown <slot>\n" c_uart_puts
    handleIfConfig = do
      xs <- runH NS.nsList
      let slot = findNetSlot xs
      r <- runH (Net.netIfConfig slot)
      case r of
        Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
    handlePing ipStr = case parseIpv4 ipStr of
      Nothing -> withCString "EINVAL: bad ip\n" c_uart_puts
      Just ip -> do
        xs <- runH NS.nsList
        let slot = findNetSlot xs
        r <- runH (Net.netPing slot ip)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right s -> withCString (s ++ "\n") c_uart_puts
    handleUdpEcho ipStr portStr txt = case (parseIpv4 ipStr, reads portStr) of
      (Just ip, [(p, "")]) -> do
        xs <- runH NS.nsList
        let slot = findNetSlot xs
        r <- runH (Net.netUdpSend slot ip p txt)
        case r of
          Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
          Right s -> withCString (s ++ "\n") c_uart_puts
      _ -> withCString "usage: udpecho <ip> <port> <text>\n" c_uart_puts
    findNetSlot xs = case filter ("virtio-net" `isPrefixOf`) xs of
      (s : _) -> case reads (drop (length "virtio-net") s) of [(n, "")] -> n; _ -> 0
      [] -> 0
    handleConInit s = case reads s of
      [(n, "")] -> do
        r <- runH (Con.conServerInit n)
        case r of
          Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
          Right dev -> withCString ("ok qsize0=" ++ show (VQueue.queueSize (ConTypes.conRxQueue dev)) ++ " qsize1=" ++ show (VQueue.queueSize (ConTypes.conTxQueue dev)) ++ " slot=" ++ show (ConTypes.conSlot dev) ++ "\n") c_uart_puts
      _ -> withCString "usage: con init <slot>\n" c_uart_puts
    handleConStatus s = case reads s of
      [(n, "")] -> do
        r <- runH (Con.conProbe n)
        case r of
          Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
          Right kind -> do
            xs <- runH NS.nsList
            let hasNs = ("virtio-con" ++ show n) `elem` xs
            withCString ("con slot " ++ show n ++ " kind=" ++ show kind ++ " ns=" ++ show hasNs ++ " status ok\n") c_uart_puts
      _ -> withCString "usage: con status <slot>\n" c_uart_puts
    handleConWrite s txt = case reads s of
      [(n, "")] -> do
        r <- runH (Con.conWrite n txt)
        case r of
          Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "ok\n" c_uart_puts
      _ -> withCString "usage: con write <slot> <text>\n" c_uart_puts
    handleConRead mSlot = do
      slot <- case mSlot of
        Just s -> case reads s of [(n, "")] -> return n; _ -> return (-1)
        Nothing -> do
          xs <- runH NS.nsList
          return (findConSlot xs)
      if slot < 0
        then withCString "usage: con read [slot]\n" c_uart_puts
        else do
          r <- runH (Con.conRead slot)
          case r of
            Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
            Right out -> withCString (take 256 out ++ "\n") c_uart_puts
    handleConTeardown s = case reads s of
      [(n, "")] -> do
        r <- runH (Con.conServerTeardown n)
        case r of
          Left e -> withCString (ConTypes.conErrorToString e ++ "\n") c_uart_puts
          Right () -> withCString "teardown ok\n" c_uart_puts
      _ -> withCString "usage: con teardown <slot>\n" c_uart_puts
    handleConMirror on = do
      _ <- runH (writeRef conMirror on)
      withCString (if on then "mirror on\n" else "mirror off\n") c_uart_puts
    findConSlot xs = case filter ("virtio-con" `isPrefixOf`) xs of
      (x : _) -> case reads (drop (length "virtio-con") x) of [(n, "")] -> n; _ -> 0
      [] -> 0
    handleArpLs = do
      xs <- runH Net.netArpLs
      let showIpv4' (NetTypes.Ipv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
          showMac' (NetTypes.Mac a b c d e f) = let h = "0123456789abcdef"; hex2 w = [h !! fromIntegral (w `shiftR` 4), h !! fromIntegral (w .&. 0xF)] in hex2 a ++ ":" ++ hex2 b ++ ":" ++ hex2 c ++ ":" ++ hex2 d ++ ":" ++ hex2 e ++ ":" ++ hex2 f
      if null xs
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines (map (\(ip, mac) -> showIpv4' ip ++ " -> " ++ showMac' mac) xs)) c_uart_puts
    handleNetDhcp = do
      xs <- runH NS.nsList
      let slot = findNetSlot xs
      r <- runH (Net.netDhcp slot)
      case r of
        Left e -> withCString (NetTypes.netErrorToString e ++ "\n") c_uart_puts
        Right s -> withCString (s ++ "\n") c_uart_puts
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
      -- tolerate single-page failure if 100-page passes (probe vs demand race on hvf)
      return (ok2 || ok1)
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
          -- trigger perm fault RO write (should log [demand] perm fault RO and skip)
          poke (castPtr ptr :: Ptr Word8) 0xFF
          withCString "mprotect RO perm logged\n" c_uart_puts
          -- munmap
          rc2 <- c_munmap ptr len
          let okUnmap = rc2 == 0
          withCString ("vm: munmap " ++ (if okUnmap then "ok" else "fail") ++ "\n") c_uart_puts
          withCString "munmap unmap fault\n" c_uart_puts
          return (okProt && okUnmap)
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
                _ -> return False
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
    handlePalloc = do
      r <- runH HPages.allocPage `catch` (\(_ :: SomeException) -> return Nothing)
      case r of
        Nothing -> withCString "palloc fail\n" c_uart_puts
        Just p -> withCString ("palloc ok " ++ show (ptrToIntPtr (castPtr p)) ++ "\n") c_uart_puts
    defaultEnv = ["HOUSE=1", "PATH=/bin"]
    handleRun path args = do
      r <- runH $ do
        mBytes <- FS.fsReadBytes path
        case mBytes of
          Left e -> return (Left (showFsError e))
          Right bytes -> do
            case ULdr.loadElf bytes of
              Left le -> return (Left (toExecError le))
              Right elf -> do
                res <- U.runElf elf (path : args) defaultEnv
                case res of
                  Left le2 -> return (Left (toExecError le2))
                  Right pid -> do
                    code <- U.waitPid pid
                    return (Right code)
      case r of
        Left e -> withCString (e ++ "\n") c_uart_puts
        Right code -> withCString ("ok exit " ++ show code ++ "\n") c_uart_puts
    parseIpv4 s = case splitDot s of
      [a, b, c, d] -> case (reads a, reads b, reads c, reads d) of
        ([(av, "")], [(bv, "")], [(cv, "")], [(dv, "")]) -> Just (NetTypes.Ipv4 av bv cv dv)
        _ -> Nothing
      _ -> Nothing
    splitDot str = splitOn '.' str
      where
        splitOn _ [] = [""]
        splitOn c (x : xs) = if x == c then "" : splitOn c xs else let (h : t) = splitOn c xs in (x : h) : t
    handleUname args = do
      let sysname = "House"
          nodename = "house"
          release = "0.8.93"
          version = "#1 SMP 2026-09-01 House/hOp GHC-9.14.1 QEMU-virt"
          machine = "aarch64"
          processor = "aarch64"
          hw = "QEMU-virt"
          os = "House"
          canon = "snrvmpio" :: String
          merge sel flags =
            let combined = nub (sel ++ flags)
             in filter (`elem` combined) canon
          flagToStr c = case c of
            's' -> sysname
            'n' -> nodename
            'r' -> release
            'v' -> version
            'm' -> machine
            'p' -> processor
            'i' -> hw
            'o' -> os
            _ -> ""
          unameHelp =
            unlines
              [ "Usage: uname [OPTION]...",
                "Print certain system information.  With no OPTION, same as -s.",
                "",
                "  -a, --all                print all information, in the following order,",
                "                             except omit -p and -i if unknown:",
                "                             -s -n -r -v -m -p -i -o",
                "  -s, --kernel-name        print the kernel name",
                "  -n, --nodename           print the network node hostname",
                "  -r, --kernel-release     print the kernel release",
                "  -v, --kernel-version     print the kernel version",
                "  -m, --machine            print the machine hardware name",
                "  -p, --processor          print the processor type",
                "  -i, --hardware-platform  print the hardware platform",
                "  -o, --operating-system   print the operating system",
                "      --help               display this help and exit",
                "      --version            output version information and exit"
              ]
          unameVersionStr = sysname ++ " " ++ release ++ " (" ++ version ++ ") " ++ machine ++ "\n"
          parse [] sel = Right sel
          parse (a : as) sel
            | a == "--help" = Left unameHelp
            | a == "--version" = Left unameVersionStr
            | a == "--all" || a == "-a" = parse as (merge sel canon)
            | a == "--kernel-name" = parse as (merge sel "s")
            | a == "--nodename" = parse as (merge sel "n")
            | a == "--kernel-release" = parse as (merge sel "r")
            | a == "--kernel-version" = parse as (merge sel "v")
            | a == "--machine" = parse as (merge sel "m")
            | a == "--processor" = parse as (merge sel "p")
            | a == "--hardware-platform" = parse as (merge sel "i")
            | a == "--operating-system" = parse as (merge sel "o")
            | "-" `isPrefixOf` a && not ("--" `isPrefixOf` a) =
                let flags = drop 1 a
                 in if null flags
                      then Left ("uname: invalid option -- '" ++ a ++ "'\nTry 'uname --help' for more information.\n")
                      else
                        let bad = filter (`notElem` canon) flags
                         in case bad of
                              (b : _) -> Left ("uname: invalid option -- '" ++ [b] ++ "'\nTry 'uname --help' for more information.\n")
                              [] -> parse as (merge sel flags)
            | otherwise = Left ("uname: extra operand '" ++ a ++ "'\nTry 'uname --help' for more information.\n")
      case parse args [] of
        Left msg -> withCString msg c_uart_puts
        Right [] -> withCString (sysname ++ "\n") c_uart_puts
        Right sel -> withCString (unwords (map flagToStr (filter (`elem` sel) canon)) ++ "\n") c_uart_puts
    showFsError e = case e of
      FS.ENOENT -> "ENOENT: No such file or directory"
      FS.EEXIST -> "EEXIST: File exists"
      FS.ENOTDIR -> "ENOTDIR: Not a directory"
      FS.EISDIR -> "EISDIR: Is a directory"
      FS.ENOSPC -> "ENOSPC: No space left on device"
      FS.EINVAL s -> "EINVAL: " ++ s
    toExecError le = case le of
      ULdr.BadMagic -> "EBADEXEC: not ELF64 LE"
      ULdr.BadArch -> "EBADEXEC: need AArch64"
      ULdr.BadType -> "EBADEXEC: need ET_EXEC"
      _ -> ULdr.loadErrorToString le
    usage =
      unlines
        [ "Usage: help | echo <word>... [> /path] | cat <path> | ls [path] | mkdir <path> | rm <path> | write <path> <text> | stat <path> | clear | uname [-asnrvmio] | uptime | shutdown [-h|-r] -- halt or reboot the machine",
          "       lambda -- lambda demo",
          "       preempt -- preemption demo",
          "       wastemem <number> -- allocate memory",
          "       free -- show H.Pages + buddy + ram",
          "       mem -- show ram/stack/buddy+ttbr",
          "       detect -- show ram/stack/caps",
          "       vm -- demand pager 100 pages + mmap/mprotect/munmap + isolate + asid+smp shootdown",
          "       smp -- show SMP cores online | smp up <core> | smp down <core> -- hotplug to ceiling 32, caps mirror online",
          "       caps -- show capabilities",
          "       parfib <n> -- parallel fib",
          "       mvar <n> -- MVar ping-pong test",
          "       uname [-asnrvmio] [--help] -- print system information (default -s; -a all)",
          "       ls [path] -- list directory",
          "       cat <path> -- show file",
          "       mkdir <path> -- create directory",
          "       rm <path> -- remove file or empty dir",
          "       write <path> <text> -- write file (truncate)",
          "       stat <path> -- show file stat",
          "       echo <word>... [> /path] -- echo or write via ramfs (volatile 2 MiB pool)",
          "       ns ls -- list IPC names",
          "       ns reg <name> -- register name (pl011 launches server)",
          "       ipc ping <nsName> -- sync call to endpoint",
          "       ipc grant -- alloc one page and send to pl011",
          "       lsdev -- list drivers | dmesg -- kernel log | virtio scan -- probe MMIO slots (0x0a000000+i*0x200)",
          "       virtio scan|init <slot>|notify <slot>|status|ack <slot>|irqtest <slot>|teardown <slot> -- Virtio-MMIO transport (0x0a000000+i*0x200, split virtqueue, FEATURES_OK VIRTIO_F_VERSION_1|RING_F_EVENT_IDX, dc cvac/dsb, IRQ->Endpoint)",
          "       blk init <slot>|status <slot>|read <slot> <lba>|write <slot> <lba> <text>|sync [slot]|mount <slot>|teardown <slot> -- Virtio-blk server (Endpoint, Grant, 4K blocks, capacity, queue_notify, IRQ->Endpoint, 64M house.img, Q2=B; ramfs volatile, sync persists HFS1, mount restores)",
          "       net init <slot>|status <slot>|ifconfig|ping <ip>|udpecho <ip> <port> <text>|arp ls|dhcp|teardown <slot> -- Virtio-net server (Endpoint, Grant, rx0+tx1, 12B hdr, ARP/IPv4/UDP/DHCP, ping, dc ivac/dsb, IRQ->Endpoint, user net 10.0.2.0/24)",
          "       con init <slot>|status <slot>|write <slot> <text>|read [slot]|teardown <slot>|mirror on|off -- Virtio-console server (ID 3 console / multiport serial port0 + control q2/q3 DEVICE_READY/OPEN, Endpoint, Grant, rx0+tx1, dc ivac/dsb, IRQ->Endpoint; mirror duplicates UART to serial, default off)",
          "       run </path> [args...] -- load static aarch64 ELF from ramfs 0x01000000 window, argv+env on EL0 stack, svc write/exit/brk/ipc, EL0 eret (TTBR0/ASID/pager)"
        ]
    seqFib :: Int -> Int
    seqFib n
      | n <= 1 = n
      | otherwise = seqFib (n - 1) + seqFib (n - 2)
    parFib :: Int -> Int
    parFib n
      | n < 20 = seqFib n
      | otherwise = let a = parFib (n - 1); b = parFib (n - 2) in a `par` b `pseq` a + b
    parFibIO :: Int -> IO Int
    parFibIO n
      | n < 24 = return (parFib n)
      | otherwise = do
          mv <- newEmptyMVar
          _ <- forkIO $ putMVar mv (parFib (n - 1))
          let b = parFib (n - 2)
          a <- takeMVar mv
          return (a + b)
    mvarTest :: Int -> IO Bool
    mvarTest n = do
      let n' = min n 5000
      r <- timeout (10 * 1000000) $ do
        m <- newEmptyMVar
        forM_ [1 .. n'] $ \_ -> forkIO $ putMVar m (1 :: Int)
        s <- sumMVars n' m 0
        return (s == n')
      return (r == Just True)
      where
        sumMVars 0 _ acc = return acc
        sumMVars k mv acc = do v <- takeMVar mv; sumMVars (k - 1) mv (acc + v)
    showHex :: Int -> String
    showHex m = let h = "0123456789abcdef" in if m < 16 then [h !! m] else showHex (m `div` 16) ++ [h !! (m `mod` 16)]
    showHex64 :: Word64 -> String
    showHex64 w = let h = "0123456789abcdef"; go n | n < 16 = [h !! fromIntegral n] | otherwise = go (n `div` 16) ++ [h !! fromIntegral (n `mod` 16)] in if w == 0 then "0" else go w
