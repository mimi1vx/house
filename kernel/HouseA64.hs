{-# LANGUAGE ForeignFunctionInterface #-}

module HouseA64 where

import Data.Word (Word64)
import Foreign.C.String (peekCString, withCString)
import Foreign.C.Types (CChar (..), CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (poke)

foreign import ccall "uart_puts" c_uart_puts :: Ptr CChar -> IO ()

foreign import ccall "uart_getc_nonblock" c_getc_nonblock :: IO CInt

foreign import ccall "uart_putc" c_putc :: CChar -> IO ()

foreign import ccall unsafe "house_uptime_secs" c_uptime :: IO Word64

foreign import ccall unsafe "psci_system_off" c_off :: IO ()

foreign import ccall unsafe "psci_system_reset" c_reset :: IO ()

foreign export ccall house_main :: IO ()

house_main :: IO ()
house_main = do
  withCString "Welcome to the House shell! Enter help to see a list of commands.\n\n" c_uart_puts
  loop
  where
    loop = do
      withCString "> " c_uart_puts
      line <- getLine
      handle line
      loop
    getLine = allocaBytes 256 $ \buf -> go buf 0
      where
        go b n = do
          c <- c_getc_nonblock
          if c == -1
            then go b n
            else
              if c == 13 || c == 10
                then do poke (b `plusPtr` n) (0 :: CChar); withCString "\n" c_uart_puts; peekCString b
                else
                  if c == 127 || c == 8
                    then if n == 0 then go b n else do c_putc 8; c_putc 32; c_putc 8; go b (n - 1)
                    else do c_putc (fromIntegral c); poke (b `plusPtr` n) (fromIntegral c :: CChar); go b (n + 1)
    handle line = case words line of
      [] -> return ()
      ("help" : _) -> withCString usage c_uart_puts
      ("echo" : ws) -> withCString (unwords ws ++ "\n") c_uart_puts
      ["clear"] -> withCString "\ESC[2J\ESC[H" c_uart_puts
      ["uname"] -> withCString "House/hOp 0.8.93 aarch64 GHC-9.14.1 QEMU-virt\n" c_uart_puts
      ["uptime"] -> do s <- c_uptime; withCString ("up " ++ show s ++ " seconds\n") c_uart_puts
      ["shutdown", "-r"] -> c_reset
      ["shutdown", "-h"] -> c_off
      ["shutdown"] -> withCString "usage: shutdown [-h|-r]\n" c_uart_puts
      ["lambda"] -> withCString "Too much to abstract!\n" c_uart_puts
      ["preempt"] -> do withCString (replicate 100 'a' ++ "\n") c_uart_puts; withCString (replicate 100 'b' ++ "\n") c_uart_puts
      ["wastemem", nStr] -> case reads nStr of
        [(n, "")] -> withCString (show (sum [1 .. n :: Integer]) ++ "\n") c_uart_puts
        _ -> withCString "usage: wastemem <number>\n" c_uart_puts
      _ -> withCString ("unknown command: " ++ line ++ "\n") c_uart_puts
    usage =
      unlines
        [ "Usage: help | echo <word>... | clear | uname | uptime | shutdown [-h|-r] -- halt or reboot the machine",
          "       lambda -- lambda demo",
          "       preempt -- preemption demo",
          "       wastemem <number> -- allocate memory"
        ]
