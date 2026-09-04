{-# LANGUAGE ForeignFunctionInterface #-}

-- | Low-level per-slot helpers over C FFI for virtio-console (ID 3).
-- Validates slot 0..7 and maps C errors to ConError.
module Kernel.Driver.Virtio.Con.Device
  ( conProbe,
    conSubmitRx,
    conSubmitTx,
    conPollUsed,
    conInvalidate,
    conSaveQueues,
  )
where

import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import H.Monad (H, liftIO)
import Kernel.Driver.Virtio.Con.Types (ConError (..))

foreign import ccall unsafe "virtio_con_submit_rx" c_submit_rx :: Int -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_submit_tx" c_submit_tx :: Int -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_poll_used" c_poll_used :: Int -> CInt -> Ptr Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_invalidate" c_invalidate :: Word64 -> Word64 -> IO ()

foreign import ccall unsafe "virtio_con_save_queues" c_save_queues :: Int -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> IO CInt

foreign import ccall unsafe "virtio_page_pa" c_pagePa :: Ptr Word8 -> Word64

foreign import ccall unsafe "virtio_probe_slot" c_probe_slot :: Int -> Ptr Word32 -> Ptr Word32 -> Ptr Word32 -> IO Int

cErrToConError :: Int -> ConError
cErrToConError n = case n of
  -1 -> ConBadSlot
  -2 -> ConInvalidArg "BadVersion"
  -3 -> ConInvalidArg "NeedsReset"
  -4 -> ConInvalidArg "FeaturesMismatch"
  -5 -> ConNoSpace
  -6 -> ConInvalidArg "QueueFull"
  -7 -> ConNotReady
  -8 -> ConInvalidArg "SpuriousInt"
  -9 -> ConInvalidArg "EINVAL"
  _ -> ConIoError n

slotValid :: Int -> Bool
slotValid n = n >= 0 && n < 8

-- | Probe slot for virtio-console. Validates present && device_id==3.
-- device_id 11 (virtio-serial multipoint) reports ConNotCon deferred hook.
conProbe :: Int -> H (Either ConError ())
conProbe slot
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = liftIO $ alloca $ \pDid -> alloca $ \pVid -> alloca $ \pVer -> do
      r <- c_probe_slot slot pDid pVid pVer
      did <- peek pDid
      let present = r /= 0
      if not present
        then return (Left ConBadSlot)
        else
          if did == 11
            then return (Left ConNotCon)
            else
              if did /= 3
                then return (Left ConNotCon)
                else return (Right ())

-- | Submit RX buffer (single-desc WRITE). dataPtr must be Grant page.
conSubmitRx :: Int -> Ptr Word8 -> H (Either ConError Word32)
conSubmitRx slot dataPtr
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_rx slot pa 4096 pReq
      if r /= 0
        then return (Left (cErrToConError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Submit TX bytes at Grant page start. dataLen 1..4095.
conSubmitTx :: Int -> Ptr Word8 -> Word32 -> H (Either ConError Word32)
conSubmitTx slot dataPtr dataLen
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_tx slot pa dataLen pReq
      if r /= 0
        then return (Left (cErrToConError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Poll used ring for qidx 0 (rx) or 1 (tx). Returns Nothing if no completion.
conPollUsed :: Int -> Int -> H (Either ConError (Maybe (Word32, Word32)))
conPollUsed slot qidx
  | not (slotValid slot) = return (Left ConBadSlot)
  | qidx < 0 || qidx > 1 = return (Left (ConInvalidArg "qidx"))
  | otherwise = liftIO $ alloca $ \pId -> alloca $ \pLen -> do
      r <- c_poll_used slot (fromIntegral qidx) pId pLen
      case r of
        1 -> return (Right Nothing)
        0 -> do i <- peek pId; l <- peek pLen; return (Right (Just (i, l)))
        n -> return (Left (cErrToConError (fromIntegral n)))

-- | Invalidate cache range (dc ivac).
conInvalidate :: Word64 -> Word64 -> H ()
conInvalidate pa len = liftIO $ c_invalidate pa len

-- | Save queue PAs for C side (both rx+tx).
conSaveQueues :: Int -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> H (Either ConError ())
conSaveQueues slot rxD rxA rxU txD txA txU qr qt
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = do
      r <- liftIO $ c_save_queues slot rxD rxA rxU txD txA txU qr qt
      if r /= 0 then return (Left (cErrToConError (fromIntegral r))) else return (Right ())
