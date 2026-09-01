{-# LANGUAGE ForeignFunctionInterface #-}

-- | Low-level per-slot helpers over C FFI for virtio-net.
-- Validates slot 0..7 and maps C errors to NetError.
module Kernel.Driver.Virtio.Net.Device
  ( netProbeMac,
    netSubmitRx,
    netSubmitTx,
    netPollUsed,
    netInvalidate,
    netSaveQueues,
  )
where

import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peek)
import H.Monad (H, liftIO)
import Kernel.Driver.Virtio.Net.Types (Mac (..), NetError (..))

foreign import ccall unsafe "virtio_net_probe_mac" c_probe_mac :: Int -> Ptr Word8 -> IO CInt

foreign import ccall unsafe "virtio_net_submit_rx" c_submit_rx :: Int -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_net_submit_tx" c_submit_tx :: Int -> Word64 -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_net_poll_used" c_poll_used :: Int -> CInt -> Ptr Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_net_invalidate" c_invalidate :: Word64 -> Word64 -> IO ()

foreign import ccall unsafe "virtio_net_save_queues" c_save_queues :: Int -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> IO CInt

foreign import ccall unsafe "virtio_page_pa" c_pagePa :: Ptr Word8 -> Word64

foreign import ccall unsafe "virtio_probe_slot" c_probe_slot :: Int -> Ptr Word32 -> Ptr Word32 -> Ptr Word32 -> IO CInt

cErrToNetError :: Int -> NetError
cErrToNetError n = case n of
  -1 -> NetBadSlot
  -2 -> NetInvalidArg "BadVersion"
  -3 -> NetInvalidArg "NeedsReset"
  -4 -> NetInvalidArg "FeaturesMismatch"
  -5 -> NetNoSpace
  -6 -> NetInvalidArg "QueueFull"
  -7 -> NetNotReady
  -8 -> NetInvalidArg "SpuriousInt"
  -9 -> NetInvalidArg "EINVAL"
  _ -> NetIoError n

slotValid :: Int -> Bool
slotValid n = n >= 0 && n < 8

-- | Probe MAC for virtio-net slot. Validates device_id==1.
netProbeMac :: Int -> H (Either NetError Mac)
netProbeMac slot
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = liftIO $ alloca $ \pDid -> alloca $ \pVid -> alloca $ \pVer -> do
      r <- c_probe_slot slot pDid pVid pVer
      did <- peek pDid
      let present = r /= 0
      if not present
        then return (Left NetBadSlot)
        else
          if did /= 1
            then return (Left NetNotNet)
            else alloca $ \pMac -> do
              rc <- c_probe_mac slot pMac
              if rc /= 0
                then return (Left (cErrToNetError (fromIntegral rc)))
                else do
                  a <- peek pMac
                  b <- peek (pMac `plusPtr` 1)
                  c <- peek (pMac `plusPtr` 2)
                  d <- peek (pMac `plusPtr` 3)
                  e <- peek (pMac `plusPtr` 4)
                  f <- peek (pMac `plusPtr` 5)
                  return (Right (Mac a b c d e f))

-- | Submit RX buffer (single-desc WRITE). dataPtr must be Grant page.
netSubmitRx :: Int -> Ptr Word8 -> H (Either NetError Word32)
netSubmitRx slot dataPtr
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_rx slot pa 4096 pReq
      if r /= 0
        then return (Left (cErrToNetError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Submit TX (hdr 12 + data). hdrPtr and dataPtr may be same page (hdr at 0, payload at 12).
netSubmitTx :: Int -> Ptr Word8 -> Ptr Word8 -> Word32 -> H (Either NetError Word32)
netSubmitTx slot hdrPtr dataPtr dataLen
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let hdrPa = c_pagePa hdrPtr
          dataPa = c_pagePa dataPtr
          useDataPa = if hdrPtr == dataPtr then hdrPa + 12 else dataPa
      r <- c_submit_tx slot hdrPa useDataPa dataLen pReq
      if r /= 0
        then return (Left (cErrToNetError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Poll used ring for qidx 0 (rx) or 1 (tx). Returns Nothing if no completion.
netPollUsed :: Int -> Int -> H (Either NetError (Maybe (Word32, Word32)))
netPollUsed slot qidx
  | not (slotValid slot) = return (Left NetBadSlot)
  | qidx < 0 || qidx > 1 = return (Left (NetInvalidArg "qidx"))
  | otherwise = liftIO $ alloca $ \pId -> alloca $ \pLen -> do
      r <- c_poll_used slot (fromIntegral qidx) pId pLen
      case r of
        1 -> return (Right Nothing)
        0 -> do i <- peek pId; l <- peek pLen; return (Right (Just (i, l)))
        n -> return (Left (cErrToNetError (fromIntegral n)))

-- | Invalidate cache range (dc ivac).
netInvalidate :: Word64 -> Word64 -> H ()
netInvalidate pa len = liftIO $ c_invalidate pa len

-- | Save queue PAs for C side (both rx+tx).
netSaveQueues :: Int -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> H (Either NetError ())
netSaveQueues slot rxD rxA rxU txD txA txU qr qt
  | not (slotValid slot) = return (Left NetBadSlot)
  | otherwise = do
      r <- liftIO $ c_save_queues slot rxD rxA rxU txD txA txU qr qt
      if r /= 0 then return (Left (cErrToNetError (fromIntegral r))) else return (Right ())
