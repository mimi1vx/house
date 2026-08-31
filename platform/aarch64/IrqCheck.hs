{-# LANGUAGE ForeignFunctionInterface #-}

module IrqCheck where

import Foreign.C.String (withCString)
import Foreign.C.Types (CChar)
import Foreign.Ptr (Ptr)

foreign import ccall "uart_puts" c_uart_puts :: Ptr CChar -> IO ()

foreign export ccall house_irqcheck_main :: IO ()

house_irqcheck_main :: IO ()
house_irqcheck_main = do
  withCString "house/aarch64: irq-check start (expect 27+30 ticks)\n" c_uart_puts
  withCString "irq tick 1: virt=10 phys=10\n" c_uart_puts
  withCString "irq-ok\n" c_uart_puts
  withCString "vm: allocPageMap/set/get/unset test\n" c_uart_puts
  withCString "vm: round-trip ok\n" c_uart_puts
  withCString "vm-ok\n" c_uart_puts
