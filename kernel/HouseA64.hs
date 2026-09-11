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
import qualified H.VirtualMemory as VM
import qualified Kernel.Boot as Boot
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
import qualified Kernel.FileSystem.RamFs as RamFs
import qualified Kernel.FileSystem.Vfs as FS
import qualified Kernel.IPC.Endpoint as IPC
import qualified Kernel.IPC.Grant as G
import qualified Kernel.IPC.Nameservice as NS
import Kernel.IPC.Types (EndpointId (..), Message (..))
import qualified Kernel.Init as Init
import qualified Kernel.Initramfs as Initrd
import qualified Kernel.LineEditor as LE
import qualified Kernel.SMP as SMP
import Kernel.Shell.Foreign (c_uart_puts, conMirror)
import Kernel.Shell.Format (hexDigit, showFsError, showHex, toExecError)
import qualified Kernel.Shell.Loop as Loop
import Kernel.Shell.Mem (handleDetect, handleFree, handleMem, handlePalloc)
import Kernel.Shell.Parse (parseIpv4)
import Kernel.Shell.Posix (handleShutdown, handleUname, handleUptime)
import Kernel.Shell.Vm (handleVm)
import qualified Kernel.Userspace as U
import qualified Kernel.Userspace.Loader as ULdr
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
