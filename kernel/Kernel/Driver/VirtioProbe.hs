{-# LANGUAGE ForeignFunctionInterface #-}

-- | Virtio-MMIO probe (slot 0..7 at 0x0a000000+i*0x200). Probe-only, no
-- queue/IRQ enable. Logs each slot to dmesg.
module Kernel.Driver.VirtioProbe
  ( VirtioSlotInfo (..),
    virtioScan,
  )
where

import Data.Word (Word32)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import H.Interrupts (IntId, spi)
import H.Monad (H, liftIO)
import qualified Kernel.Driver.Dmesg as Dmesg

-- | Per-slot probe result.
data VirtioSlotInfo = VirtioSlotInfo
  { vsiSlot :: Int,
    vsiPresent :: Bool,
    vsiDeviceId :: Word32,
    vsiVendorId :: Word32,
    vsiSpi :: Maybe IntId
  }
  deriving (Eq, Show)

foreign import ccall unsafe "virtio_probe_slot"
  c_virtio_probe_slot ::
    Int -> Ptr Word32 -> Ptr Word32 -> Ptr Word32 -> IO Int

-- | Probe all 8 MMIO slots, log to dmesg, return list.
virtioScan :: H [VirtioSlotInfo]
virtioScan = mapM probeOne [0 .. 7]
  where
    probeOne slot = do
      info <- liftIO $ alloca $ \pDid -> alloca $ \pVid -> alloca $ \pVer -> do
        r <- c_virtio_probe_slot slot pDid pVid pVer
        did <- peek pDid
        vid <- peek pVid
        let present = r /= 0
            spiId = if present then Just (spi (fromIntegral (16 + slot))) else Nothing
        return (VirtioSlotInfo slot present did vid spiId)
      let line =
            if vsiPresent info
              then "virtio slot " ++ show (vsiSlot info) ++ ": device_id=" ++ show (vsiDeviceId info) ++ " vendor=0x" ++ showHex (vsiVendorId info) ++ " spi=" ++ maybe "?" show (vsiSpi info)
              else "virtio slot " ++ show (vsiSlot info) ++ ": empty"
      Dmesg.dmesgLog line
      return info

showHex :: Word32 -> String
showHex v =
  let h = "0123456789abcdef"
   in if v < 16 then [h !! fromIntegral v] else showHex (v `div` 16) ++ [h !! fromIntegral (v `mod` 16)]
