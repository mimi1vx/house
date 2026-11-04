{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Init
Description : EL0 pid1 launcher (pid1 slice).

Loads '/sbin/init' via 'Loader.loadElf', runs it with
'["/sbin/init"]' + '["HOUSE=1","PATH=/bin"]', and reaps it in a forked
thread ('init exit CODE' to UART+dmesg). Fail-closed 'init fail E' when
missing/unparseable, so a boot without -initrd still reaches a shell.
-}
module Kernel.Init (
  Pid1Outcome (..),
  launchPid1,
)
where

import Data.ByteString qualified as BS
import Foreign.C.String (withCString)
import H.Concurrency (forkSupervisedIO)
import H.Console (c_uart_puts)
import H.Monad (runH)
import Kernel.FileSystem.Vfs qualified as FS
import Kernel.Log.Dmesg qualified as Dmesg
import Kernel.Shell.Format (toExecError)
import Kernel.Userspace qualified as U
import Kernel.Userspace.Loader qualified as ULdr

-- | Outcome of the pid1 launch: the live pid, or the fail-closed reason.
data Pid1Outcome = Pid1Up U.Pid | Pid1Fail String
  deriving (Eq, Show)

{- | Load + run /sbin/init, reap in the background. Returns the outcome so
'house_main' can gate the shell entry on it instead of ignoring it.
-}
launchPid1 :: IO Pid1Outcome
launchPid1 = do
  rInit <- runH $ do
    mBytes <- FS.vfsRead FS.defaultNamespace "/sbin/init"
    case mBytes of
      Left _ -> return (Left "no init")
      Right bytes -> case ULdr.loadElf (BS.pack bytes) of
        Left le -> return (Left (toExecError le))
        Right elf -> do
          res <- U.runElf elf ["/sbin/init"] ["HOUSE=1", "PATH=/bin"]
          case res of
            Left le2 -> return (Left (toExecError le2))
            Right (U.Pid n) -> return (Right n)
  case rInit of
    Left e -> do
      withCString ("initramfs: init fail " ++ e ++ "\n") c_uart_puts
      runH (Dmesg.dmesgLog ("initramfs: init fail " ++ e))
      return (Pid1Fail e)
    Right n -> do
      withCString ("init pid " ++ show n ++ "\n") c_uart_puts
      _ <- forkSupervisedIO $ do
        code <- runH (U.waitPid (U.Pid n))
        withCString ("init exit " ++ show code ++ "\n") c_uart_puts
        runH (Dmesg.dmesgLog ("init exit " ++ show code))
      return (Pid1Up (U.Pid n))
