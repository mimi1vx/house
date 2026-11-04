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
  | -- One uart_puts unit: emitted under a single UART lock hold, so the
    -- bytes stay contiguous against concurrent trap-context UART writers
    -- (EL0 WRITE fd 1 bypasses this queue). Use for runs whose splitting
    -- breaks a consumer: the shell prompt's two-space signature in
    -- particular (see LineEditor.getLine). '\n' renders as CRLF, matching
    -- uart_putc. Bound: uart_puts caps at 4K + NUL-terminates, so keep
    -- PutStr short, NUL-free ASCII.
    PutStr String
  | MoveCursorBackward Int
  | ClearScreen
  | -- Drain barrier: consumer acks after all prior commands hit the UART,
    -- so producers (LineEditor Accept) can order output before direct
    -- uart_puts writers (shell command output).
    Sync (MVar ())

data ConsoleData = ConsoleData {
  consoleChan :: Chan ConsoleCommand
  , consoleHeight :: Int
  , consoleWidth :: Int
  }

data Console = Console (MVar ConsoleData)
