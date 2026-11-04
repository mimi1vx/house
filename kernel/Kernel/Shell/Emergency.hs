{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Shell.Emergency
Description : Fallback console shell when pid1 fails to come up.

Entered from 'house_main' on 'Kernel.Init.Pid1Fail'. Owns the same
console/line-editor pair as the full shell ('Kernel.Shell.Loop' keeps
its own copy; only one loop runs per boot) and answers @help@,
@uname@, and @dmesg@. Everything else reports unknown, exactly like
the full shell's fallback arm. No command table import: the full
shell's dispatch ('Kernel.Shell.Commands') stays the single source
for the full verb set.
-}
module Kernel.Shell.Emergency (
  loop,
)
where

import Control.Exception (SomeException, catch)
import Foreign.C.String (withCString)
import H.Monad (runH)
import Kernel.Driver.PL011 qualified as PL011
import Kernel.LineEditor qualified as LE
import Kernel.Log.Dmesg qualified as Dmesg
import Kernel.Shell.Foreign (c_uart_puts)
import Kernel.Shell.Posix (handleUname)

{- | Banner + mini loop. The @init fail E@ line itself is printed by
'Kernel.Init.launchPid1' before this runs; the banner names the shell.
-}
loop :: IO ()
loop = do
  withCString "House emergency shell (pid1 failed; type help).\n" c_uart_puts
  console <- runH PL011.launchConsoleDriver
  kbd <- runH PL011.launchPL011KeyboardDriver
  editor <- runH (LE.newEditor kbd console)
  go editor
  where
    -- Same dispatch boundary as the full shell: one throwing handler
    -- must not unwind into house_main and idle the machine.
    go ed = do
      line <- runH (LE.getLine ed "emergency> ")
      handle (words line) `catch` \(e :: SomeException) -> do
        withCString ("shell: " ++ show e ++ "\n") c_uart_puts
        runH (Dmesg.dmesgLog ("shell handler: " ++ show e))
      go ed
    handle ws = case ws of
      [] -> return ()
      ("help" : _) -> withCString helpText c_uart_puts
      ("uname" : args) -> handleUname args
      ("dmesg" : _) -> handleDmesg
      _ -> withCString ("unknown command: " ++ unwords ws ++ "\n") c_uart_puts
    handleDmesg = do
      xs <- runH Dmesg.dmesgRead
      if null xs
        then withCString "(empty)\n" c_uart_puts
        else withCString (unlines xs) c_uart_puts
    helpText =
      "emergency commands: help | uname [-asnrvmio] | dmesg\n"
