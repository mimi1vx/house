{-# LANGUAGE ForeignFunctionInterface #-}

-- | GIC SPI helpers (thin wrappers over 'H.Interrupts').
module Kernel.Driver.GIC
  ( enableSpi,
    disableSpi,
    spiIntId,
  )
where

import Data.Word (Word32)
import H.Interrupts (IntId, spi)
import H.Monad (H, liftIO)

foreign import ccall unsafe "house_gic_enable_int" c_enableSpi :: Word32 -> IO ()

foreign import ccall unsafe "house_gic_disable_int" c_disableSpi :: Word32 -> IO ()

-- | @spiIntId n = spi n@ = @IntId (32+n)@.
spiIntId :: Word32 -> IntId
spiIntId = spi

-- | Enable SPI @n@ (INTID @32+n@) via GICD ISENABLER. Group1 Non-secure.
enableSpi :: Word32 -> H ()
enableSpi n = liftIO $ c_enableSpi (32 + n)

-- | Disable SPI @n@.
disableSpi :: Word32 -> H ()
disableSpi n = liftIO $ c_disableSpi (32 + n)
