module Kernel.Driver.PL011
  ( launchConsoleDriver,
  )
where

import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CChar (..))
import H.Concurrency
import H.Monad (H, liftIO)
import Kernel.Types.Console

-- Provided by kernel/platform/aarch64/uart.c (freestanding, no base)
foreign import ccall unsafe "uart_putc" c_uart_putc :: CChar -> IO ()

foreign import ccall unsafe "uart_puts" c_uart_puts_raw :: CString -> IO ()

cPutStr :: String -> IO ()
cPutStr s = withCString s c_uart_puts_raw

launchConsoleDriver :: H Console
launchConsoleDriver = do
  chan <- newChan
  vConsole <-
    newMVar
      ConsoleData
        { consoleChan = chan,
          consoleHeight = 25,
          consoleWidth = 80
        }
  _ <- forkH $ consumer chan
  return (Console vConsole)
  where
    consumer :: Chan ConsoleCommand -> H ()
    consumer chan = loop
      where
        loop = do
          cmd <- readChan chan
          liftIO $ dispatch cmd
          loop

    dispatch :: ConsoleCommand -> IO ()
    dispatch NewLine = c_uart_putc (fromIntegral (fromEnum '\n'))
    dispatch CarriageReturn = c_uart_putc (fromIntegral (fromEnum '\r'))
    dispatch (PutChar _ c) = c_uart_putc (fromIntegral (fromEnum c))
    dispatch (MoveCursorBackward n) = mapM_ (\_ -> c_uart_putc 0x08) [1 .. n]
    dispatch ClearScreen = cPutStr "\ESC[2J\ESC[H"
    dispatch ClearEOL = cPutStr "\ESC[K"
