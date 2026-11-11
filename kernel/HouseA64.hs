{-# LANGUAGE ForeignFunctionInterface #-}

module HouseA64 (house_main) where

import Control.Monad (unless, void)
import Data.Word (Word32)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Conc (
  getNumCapabilities,
  getNumProcessors,
 )
import H.Interrupts qualified as Interrupts
import H.Monad (runH)
import Kernel.Boot qualified as Boot
import Kernel.Driver.GIC qualified as DGIC
import Kernel.Driver.IRQ qualified as DIRQ
import Kernel.Driver.Virtio.Con qualified as Con
import Kernel.Driver.VirtioProbe qualified as VProbe
import Kernel.Init qualified as Init
import Kernel.SMP qualified as SMP
import Kernel.Shell.Emergency qualified as Emergency
import Kernel.Shell.Foreign (c_uart_puts)
import Kernel.Shell.Loop qualified as Loop
import System.Timeout (timeout)

foreign export ccall house_main :: IO ()

foreign import ccall unsafe "house_bootarg_present" c_bootargPresent :: CString -> IO CInt

bootQuiet :: IO Bool
bootQuiet = withCString "quiet" (fmap (/= 0) . c_bootargPresent)

autoConInit :: IO ()
autoConInit = do
  want <- withCString "house.con=auto" (fmap (/= 0) . c_bootargPresent)
  if not want
    then return ()
    else do
      infos <- runH VProbe.virtioScan
      let conSlots = [VProbe.vsiSlot i | i <- infos, VProbe.vsiPresent i, VProbe.vsiDeviceId i == (3 :: Word32)]
      case conSlots of
        [] -> withCString "con auto: no virtio-console device\n" c_uart_puts
        (slot : _) -> do
          mRes <- timeout 10000000 (runH (Con.conServerInit slot))
          case mRes of
            Just (Right _) -> return ()
            Just (Left e) -> withCString ("con auto: " ++ Con.conErrorToString e ++ "\n") c_uart_puts
            Nothing -> withCString "con auto: timeout\n" c_uart_puts

house_main :: IO ()
house_main = do
  caps0 <- getNumCapabilities
  procs0 <- getNumProcessors
  mask0 <- SMP.onlineSet
  quiet <- bootQuiet
  unless quiet $
    withCString ("[house] rts caps=" ++ show caps0 ++ " procs=" ++ show procs0 ++ " online=" ++ show mask0 ++ "\n") c_uart_puts
  -- Drain from the first Haskell instruction: before this, nothing consumed
  -- the SPSC ring, so a pushed IRQ could only overflow it silently.
  Interrupts.startDispatcher
  withCString "Welcome to the House shell! Enter help to see a list of commands.\n\n" c_uart_puts
  ringDrops0 <- Interrupts.ringDrops
  unless quiet $
    withCString ("[house] irq: pre-dispatch ring drops=" ++ show ringDrops0 ++ "\n") c_uart_puts
  -- initramfs via QEMU -initrd: sole /bin/* source (see scripts/mk-userspace.sh)
  Boot.boot
  autoConInit
  pid1 <- Init.launchPid1
  -- server manifest from initramfs: register + spawn EL0 servers
  Boot.spawnServers
  -- Link driver GIC/IRQ helpers into closure (probe-only track keeps them unused at runtime)
  _ <- runH (void (return (DGIC.enableSpi, DGIC.disableSpi, DIRQ.registerIrqForwarding)))
  -- Gate the console on the pid1 outcome: a live pid1 means the EL0
  -- init owns its sh child, so the full shell runs as its sibling;
  -- a failed pid1 falls back to the emergency shell.
  case pid1 of
    Init.Pid1Up _ -> Loop.loop
    Init.Pid1Fail _ -> Emergency.loop
