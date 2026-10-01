{-# LANGUAGE ForeignFunctionInterface #-}

module HouseA64 (house_main) where

import Control.Monad (void)
import Foreign.C.String (withCString)
import GHC.Conc (
  getNumCapabilities,
  getNumProcessors,
 )
import H.Monad (runH)
import Kernel.Boot qualified as Boot
import Kernel.Driver.GIC qualified as DGIC
import Kernel.Driver.IRQ qualified as DIRQ
import Kernel.Init qualified as Init
import Kernel.SMP qualified as SMP
import Kernel.Shell.Foreign (c_uart_puts)
import Kernel.Shell.Loop qualified as Loop

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
