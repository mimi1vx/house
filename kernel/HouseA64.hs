{-# LANGUAGE ForeignFunctionInterface #-}

module HouseA64 where

import Control.Monad (when)
import H.Concurrency
import H.Interrupts (enableInterrupts)
import H.Monad (H, runH)
import Kernel.Console
import Kernel.Debug (v_defaultConsole)
import Kernel.Driver.Keyboard (KeyPress)
import Kernel.Driver.PL011 (launchConsoleDriver, launchPL011KeyboardDriver)
import Kernel.LineEditor
import Monad.Util
import Util.CmdLineParser hiding ((!))
import qualified Util.CmdLineParser as P
import Prelude hiding (getLine)

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
    idle' n = do
      yield
      if n >= 100000
        then idle' 0
        else idle' (n + 1)

-- Text shell with bare-minimum command set: help, lambda, preempt, wastemem
textShell :: Console -> Chan KeyPress -> H ()
textShell console chan = do
  editor <- newEditor chan console
  let loop = do
        line <- getLine editor "> "
        putStringLn console ""
        execute (words line)
        loop
  loop
  where
    putStrLn' s = putStringLn console s
    putStr' s = putString console s
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
        [ cmd "help" (putStrLn' $ usage "" grammar)
        ]

    debugcommands =
      oneof
        [ cmd "lambda" (putStrLn' "Too much to abstract!"),
          cmd "preempt" preempt,
          cmd "wastemem" wasteMem P.<@ number
        ]
      where
        preempt = do
          _ <- forkH (putStrLn' (repeat 'a'))
          putStrLn' (repeat 'b')
        wasteMem n = print' $ sum (reverse [1 .. n :: Integer])
