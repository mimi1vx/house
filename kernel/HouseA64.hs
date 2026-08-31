{-# LANGUAGE ForeignFunctionInterface #-}

module HouseA64 where

import Data.Word (Word64)
import H.Concurrency
import H.Interrupts (enableInterrupts)
import H.Monad (H, liftIO, runH)
import Kernel.Console
import Kernel.Debug (v_defaultConsole)
import Kernel.Driver.Keyboard (KeyPress)
import Kernel.Driver.PL011 (launchConsoleDriver, launchPL011KeyboardDriver)
import Kernel.LineEditor
import Monad.Util
import Util.CmdLineParser hiding ((!))
import qualified Util.CmdLineParser as P
import Prelude hiding (getLine)

foreign import ccall unsafe "psci_system_off" c_psci_off :: IO ()

foreign import ccall unsafe "psci_system_reset" c_psci_reset :: IO ()

foreign import ccall unsafe "house_uptime_secs" c_uptime :: IO Word64

-- Re-exported entry point mirrors Spike/IrqCheck convention
foreign export ccall house_main :: IO ()

house_main :: IO ()
house_main = runH mainH

mainH :: H ()
mainH = do
  enableInterrupts
  _ <- forkH idle
  console <- launchConsoleDriver
  kbdChan <- launchPL011KeyboardDriver
  putMVar v_defaultConsole console
  putString console (welcome ++ "\n\n")
  textShell console kbdChan

welcome :: String
welcome = "Welcome to the House shell! Enter help to see a list of commands."

-- Copied from House.hs: simple busy idle
idle :: H ()
idle = idle' 0
  where
    idle' :: Int -> H ()
    idle' n = do
      yield
      if n >= 100000
        then idle' 0
        else idle' (n + 1)

-- Text shell with POSIX-ish command set
textShell :: Console -> Chan KeyPress -> H ()
textShell console chan = do
  editor <- newEditor chan console
  let shellLoop = do
        line <- getLine editor "> "
        putStringLn console ""
        execute (words line)
        shellLoop
  shellLoop
  where
    putStrLn' s = putStringLn console s
    print' x = putStrLn' (show x)

    execute :: [String] -> H ()
    execute [] = done
    execute ws | not (null ws) && last ws == "&" = do
      _ <- forkH $ execute3 (init ws)
      done
    execute ws = execute3 ws

    execute3 :: [String] -> H ()
    execute3 ws =
      case parseAll grammar ws of
        Left err -> putStrLn' err
        Right action -> action

    grammar =
      oneof
        [ commands,
          debugcommands
        ]

    commands =
      oneof
        [ cmd "help" (putStrLn' $ usage "" grammar) -: "show help",
          cmd "echo" echoImpl P.<@ many (arg "<word>") -: "print arguments",
          cmd "clear" (clearScreen console) -: "clear screen",
          cmd "uname" (putStrLn' "House/hOp 0.8.93 aarch64 GHC-9.14.1 QEMU-virt") -: "print system info",
          cmd "uptime" uptimeImpl -: "show uptime",
          cmd "shutdown" shutdownImpl P.<@ flag "-r" P.<@ flag "-h" -: "halt or reboot the machine"
        ]

    debugcommands =
      oneof
        [ cmd "lambda" (putStrLn' "Too much to abstract!") -: "lambda demo",
          cmd "preempt" preempt -: "preemption demo",
          cmd "wastemem" wasteMem P.<@ number -: "allocate memory"
        ]
      where
        preempt = do
          _ <- forkH (putStrLn' (repeat 'a'))
          putStrLn' (repeat 'b')
        wasteMem n = print' $ sum (reverse [1 .. n :: Integer])

    echoImpl ws = putStrLn' (unwords ws)

    uptimeImpl = do
      secs <- liftIO c_uptime
      putStrLn' ("up " ++ show secs ++ " seconds")

    shutdownImpl r h
      | r && not h = liftIO c_psci_reset
      | h && not r = liftIO c_psci_off
      | otherwise = putStrLn' "usage: shutdown [-h|-r]"
