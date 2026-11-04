module Kernel.Console (
  Console,
  putString,
  putStringLn,
  putStr,
  Kernel.Console.putChar,
  putChar',
  clearScreen,
  moveCursorBackward,
  clearEOL,
  syncConsole,
)
where

import H.Concurrency
import Prelude hiding (putStr)

{-P:
import Prelude hiding (putChar)
-}
import H.Monad (H)
import Kernel.Types.Console

defaultAttrs :: VideoAttributes
defaultAttrs = 0x17

putString :: Console -> String -> H ()
putString (Console vConsole) str =
  withMVar vConsole $ \console ->
    writeList2Chan (consoleChan console) $ map putc str

putc :: Char -> ConsoleCommand
putc '\n' = NewLine
putc c = PutChar defaultAttrs c

putStringLn :: Console -> String -> H ()
putStringLn (Console vConsole) str =
  withMVar vConsole $ \con ->
    do
      writeList2Chan (consoleChan con) $ map putc str
      writeChan (consoleChan con) NewLine

{- | Single uart_puts unit (see ConsoleCommand PutStr): one chan entry, one
UART lock hold. Use for byte runs that must stay contiguous against
concurrent EL0 WRITE fd 1 output.
-}
putStr :: Console -> String -> H ()
putStr (Console vConsole) str =
  withMVar vConsole $ \console ->
    do writeChan (consoleChan console) $ PutStr str

putChar :: Console -> Char -> H ()
putChar (Console vConsole) char =
  withMVar vConsole $ \console ->
    do writeChan (consoleChan console) $ putc char

putChar' :: Console -> VideoAttributes -> Char -> H ()
putChar' (Console vConsole) attrs char =
  withMVar vConsole $ \console ->
    do writeChan (consoleChan console) $ PutChar attrs char

clearScreen :: Console -> H ()
clearScreen (Console vConsole) =
  withMVar vConsole $ \console ->
    do writeChan (consoleChan console) ClearScreen

moveCursorBackward :: Console -> Int -> H ()
moveCursorBackward (Console vConsole) count =
  withMVar vConsole $ \console ->
    writeChan (consoleChan console) $ MoveCursorBackward count

clearEOL :: Console -> H ()
clearEOL (Console vConsole) =
  withMVar vConsole $ \console ->
    writeChan (consoleChan console) ClearEOL

-- | Block until all previously queued commands reach the UART.
syncConsole :: Console -> H ()
syncConsole (Console vConsole) =
  withMVar vConsole $ \console ->
    do
      ack <- newEmptyMVar
      writeChan (consoleChan console) (Sync ack)
      takeMVar ack
