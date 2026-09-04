module Kernel.Driver.PL011
  ( launchConsoleDriver,
    launchPL011KeyboardDriver,
  )
where

import Data.Char (chr)
import Data.Set qualified as Set
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CChar (..), CInt (..))
import H.Concurrency
import H.Monad (H, liftIO)
import Kernel.Driver.Keyboard (Key (..), KeyPress (..))
import Kernel.Types.Console

-- Provided by platform/aarch64/uart.c (freestanding, no base)
foreign import ccall unsafe "uart_putc" c_uart_putc :: CChar -> IO ()

foreign import ccall unsafe "uart_puts" c_uart_puts_raw :: CString -> IO ()

foreign import ccall unsafe "uart_getc_nonblock" c_uart_getc_nonblock :: IO CInt

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

-- | PL011 RX → KeyPress producer. Polls the UART non-blocking register
-- with a 10 ms threadDelay so the single-capability RTS can still service
-- the GIC dispatcher and ticker. Each received byte is mapped to a minimal
-- KeyPress (Set.empty modifiers) sufficient for LineEditor.
launchPL011KeyboardDriver :: H (Chan KeyPress)
launchPL011KeyboardDriver = do
  chan <- newChan
  _ <- forkH $ rxLoop chan
  return chan
  where
    rxLoop :: Chan KeyPress -> H ()
    rxLoop chan = loop
      where
        loop = do
          ci <- liftIO c_uart_getc_nonblock
          if ci == -1
            then do
              threadDelay 10000
              loop
            else do
              let c = chr (fromIntegral ci)
              if c == '\ESC'
                then handleEscape
                else do
                  writeChan chan (charToKeyPress c)
                  loop
        -- After ESC, wait briefly for '[' + final byte; bare ESC yields EscapeKey.
        handleEscape = do
          m2 <- waitByte 5
          case m2 of
            Nothing -> do
              writeChan chan (KeyPress Set.empty EscapeKey)
              loop
            Just '[' -> do
              m3 <- waitByte 5
              case m3 of
                Just 'A' -> writeChan chan (KeyPress Set.empty UpKey) >> loop
                Just 'B' -> writeChan chan (KeyPress Set.empty DownKey) >> loop
                Just 'C' -> writeChan chan (KeyPress Set.empty RightKey) >> loop
                Just 'D' -> writeChan chan (KeyPress Set.empty LeftKey) >> loop
                Just 'H' -> writeChan chan (KeyPress Set.empty HomeKey) >> loop
                Just 'F' -> writeChan chan (KeyPress Set.empty EndKey) >> loop
                Just c3 -> do
                  writeChan chan (KeyPress Set.empty EscapeKey)
                  writeChan chan (charToKeyPress c3)
                  loop
                Nothing -> do
                  writeChan chan (KeyPress Set.empty EscapeKey)
                  loop
            Just c2 -> do
              writeChan chan (KeyPress Set.empty EscapeKey)
              writeChan chan (charToKeyPress c2)
              loop
        waitByte :: Int -> H (Maybe Char)
        waitByte 0 = return Nothing
        waitByte n = do
          ci <- liftIO c_uart_getc_nonblock
          if ci == -1
            then do threadDelay 2000; waitByte (n - 1)
            else return (Just (chr (fromIntegral ci)))

    charToKeyPress :: Char -> KeyPress
    charToKeyPress c
      | c == '\r' || c == '\n' = KeyPress Set.empty ReturnKey
      | c == '\DEL' || c == '\BS' = KeyPress Set.empty BackspaceKey
      | c == '\t' = KeyPress Set.empty TabKey
      | c == '\ESC' = KeyPress Set.empty EscapeKey
      | c >= ' ' && c <= '~' = KeyPress Set.empty (Key c)
      | otherwise = KeyPress Set.empty (Key c)
