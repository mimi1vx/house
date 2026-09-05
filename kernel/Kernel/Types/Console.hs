module Kernel.Types.Console where

import Data.Word (Word8)
import H.Concurrency (Chan, MVar)

type VideoAttributes = Word8

type Row = Int

type Col = Int

data ConsoleCommand
  = NewLine
  | CarriageReturn
  | ClearEOL
  | PutChar VideoAttributes Char
  | MoveCursorBackward Int
  | ClearScreen
  | -- Drain barrier: consumer acks after all prior commands hit the UART,
    -- so producers (LineEditor Accept) can order output before direct
    -- uart_puts writers (shell command output).
    Sync (MVar ())

data ConsoleData = ConsoleData
  { consoleChan :: Chan ConsoleCommand,
    consoleHeight :: Int,
    consoleWidth :: Int
  }

data Console = Console (MVar ConsoleData)
