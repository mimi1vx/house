{-# LANGUAGE ForeignFunctionInterface #-}

module Spike where

import Foreign.C.String (withCString)
import Foreign.C.Types (CChar)
import Foreign.Ptr (Ptr)

foreign import ccall unsafe "uart_puts" c_uart_puts :: Ptr CChar -> IO ()

foreign export ccall house_spike_main :: IO ()

house_spike_main :: IO ()
house_spike_main = do
  withCString "house/aarch64: hello from stock GHC RTS via PL011\n" c_uart_puts
  withCString "tick 1\n" c_uart_puts
  withCString "tick 2\n" c_uart_puts
  withCString "tick 3\n" c_uart_puts
  withCString "tick 4\n" c_uart_puts
  withCString "ticks-ok\n" c_uart_puts
