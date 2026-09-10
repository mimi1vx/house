{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE ForeignFunctionInterface #-}

{- | Initramfs facade: probe QEMU `-initrd` via the DTB and copy the
archive bytes into Haskell.

Range validation is fail-closed: @start < end@, inside the detected
RAM window, length within the 8 MiB archive cap — otherwise 'Nothing'.
-}
module Kernel.Initramfs (
  Cpio.CpioEntry (..),
  Cpio.CpioError (..),
  Cpio.parseCpio,
  Unpack.unpackEntries,
  Unpack.parseManifest,
  Unpack.maxManifestEntries,
  probeInitrd,
  initrdRange,
  maxInitrdBytes,
)
where

import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr, intPtrToPtr)
import H.AdHocMem (allocaArray, peek, peekElemOff)
import H.Monad (H, liftIO)
import Kernel.Initramfs.Cpio qualified as Cpio
import Kernel.Initramfs.Unpack qualified as Unpack

foreign import ccall unsafe "fdt_get_initrd" c_fdt_get_initrd :: Ptr () -> Ptr Word64 -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "&__boot_dtb" c_dtb_ref :: Ptr Word64

foreign import ccall unsafe "&house_ram_bytes" c_ram_ref :: Ptr Word64

-- | Initrd length cap: 8 MiB (matches the cpio archive cap).
maxInitrdBytes :: Word64
maxInitrdBytes = 8 * 1024 * 1024

-- | Detected RAM base (`__ram_base`, see `platform/aarch64/aarch64.ld`).
ramBase :: Word64
ramBase = 0x40000000

{- | Validated @(start, end)@ of the QEMU initrd window, or 'Nothing'
when absent or out of range.
-}
initrdRange :: H (Maybe (Word64, Word64))
initrdRange = do
  dtbAddr <- peek c_dtb_ref
  ram <- peek c_ram_ref
  let dtbPtr = intPtrToPtr (fromIntegral dtbAddr) :: Ptr ()
  allocaArray 1 $ \pStart ->
    allocaArray 1 $ \pEnd -> do
      r <- liftIO (c_fdt_get_initrd dtbPtr pStart pEnd)
      if r /= 1
        then return Nothing
        else do
          start <- peek pStart
          end <- peek pEnd
          return (checkRange ram start end)
  where
    checkRange ram start end
      | end <= start = Nothing
      | len > maxInitrdBytes = Nothing
      | start < ramBase = Nothing
      | end > ramBase + ram = Nothing
      | otherwise = Just (start, end)
      where
        len = end - start

{- | Copy the validated initrd window into a byte list, or 'Nothing'
when absent or out of range.
-}
probeInitrd :: H (Maybe [Word8])
probeInitrd = do
  mr <- initrdRange
  case mr of
    Nothing -> return Nothing
    Just (start, end) -> do
      let len = fromIntegral (end - start) :: Int
          ptr = intPtrToPtr (fromIntegral start) :: Ptr Word8
      bs <- copyBytes ptr len
      return (Just bs)

copyBytes :: Ptr Word8 -> Int -> H [Word8]
copyBytes p n = go 0 []
  where
    go i acc
      | i >= n = return (reverse acc)
      | otherwise = do
          b <- peekElemOff p i
          go (i + 1) (b : acc)
