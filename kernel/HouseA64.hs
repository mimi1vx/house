{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}

module HouseA64 (house_main) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forM_, void, when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Char (chr, ord)
import Data.List (isPrefixOf)
import Data.Word (Word8)
import Foreign.C.String (withCString)
import GHC.Conc (
  getNumCapabilities,
  getNumProcessors,
  par,
  pseq,
  setNumCapabilities,
 )
import H.Monad (runH)
import H.Mutable (writeRef)
import H.VirtualMemory qualified as VM
import Kernel.Boot qualified as Boot
import Kernel.Driver.Dmesg qualified as Dmesg
import Kernel.Driver.GIC qualified as DGIC
import Kernel.Driver.IRQ qualified as DIRQ
import Kernel.Driver.PL011 qualified as PL011
import Kernel.Driver.PL011Server qualified as PL011S
import Kernel.Driver.Registry qualified as DrvReg
import Kernel.Driver.Types (showDriverInfo)
import Kernel.Driver.Virtio.Blk qualified as Blk
import Kernel.Driver.Virtio.Blk.Types qualified as BlkTypes
import Kernel.Driver.Virtio.Con qualified as Con
import Kernel.Driver.Virtio.Con.Types qualified as ConTypes
import Kernel.Driver.Virtio.Net qualified as Net
import Kernel.Driver.Virtio.Net.Types qualified as NetTypes
import Kernel.Driver.Virtio.Queue qualified as VQueue
import Kernel.Driver.Virtio.Transport qualified as VTrans
import Kernel.Driver.Virtio.Types qualified as VTypes
import Kernel.Driver.VirtioProbe qualified as VProbe
import Kernel.FileSystem.BlkPersist qualified as BlkPersist
import Kernel.FileSystem.RamFs qualified as RamFs
import Kernel.FileSystem.Vfs qualified as FS
import Kernel.IPC.Endpoint qualified as IPC
import Kernel.IPC.Grant qualified as G
import Kernel.IPC.Nameservice qualified as NS
import Kernel.IPC.Types (EndpointId (..), Message (..))
import Kernel.Init qualified as Init
import Kernel.Initramfs qualified as Initrd
import Kernel.LineEditor qualified as LE
import Kernel.SMP qualified as SMP
import Kernel.Shell.Foreign (c_uart_puts, conMirror)
import Kernel.Shell.Format (hexDigit, showFsError, showHex, toExecError)
import Kernel.Shell.Loop qualified as Loop
import Kernel.Shell.Mem (handleDetect, handleFree, handleMem, handlePalloc)
import Kernel.Shell.Parse (parseIpv4)
import Kernel.Shell.Posix (handleShutdown, handleUname, handleUptime)
import Kernel.Shell.Vm (handleVm)
import Kernel.Userspace qualified as U
import Kernel.Userspace.Loader qualified as ULdr
import System.Timeout (timeout)

foreign export ccall house_main :: IO ()

house_main :: IO ()
house_main = do
  caps0 <- getNumCapabilities
  procs0 <- getNumProcessors
  mask0 <- SMP.onlineSet
  withCString ("[house] rts caps=" ++ show caps0 ++ " procs=" ++ show procs0 ++ " online=" ++ show mask0 ++ "\n") c_uart_puts
  withCString "Welcome to the House shell! Enter help to see a list of commands.\n\n" c_uart_puts
  -- initramfs via QEMU -initrd: sole /bin/* source (see scripts/mk-userspace.sh)
  Boot.boot
  Init.launchPid1
  -- server manifest from initramfs: register + spawn EL0 servers
  Boot.spawnServers
  -- Link driver GIC/IRQ helpers into closure (probe-only track keeps them unused at runtime)
  _ <- runH (void (return (DGIC.enableSpi, DGIC.disableSpi, DIRQ.registerIrqForwarding)))
  Loop.loop
