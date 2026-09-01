{-# LANGUAGE ForeignFunctionInterface #-}

-- | Low-level per-slot helpers over C FFI. Validates slot/device_id, maps errors.
module Kernel.Driver.Virtio.Blk.Device
  ( blkProbeCapacity,
    blkSubmitRead,
    blkSubmitWrite,
    blkPollUsed,
    blkGetCapacitySectors,
  )
where

import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import H.Monad (H, liftIO)
import Kernel.Driver.Virtio.Blk.Types (BlkError (..))

foreign import ccall unsafe "virtio_blk_probe_capacity" c_probe_capacity :: Int -> Ptr Word64 -> IO CInt

foreign import ccall unsafe "virtio_blk_submit_read" c_submit_read :: Int -> Word64 -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_blk_submit_write" c_submit_write :: Int -> Word64 -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_blk_poll_used" c_poll_used :: Int -> Ptr Word32 -> Ptr Word8 -> IO CInt

foreign import ccall unsafe "virtio_page_pa" c_pagePa :: Ptr Word8 -> Word64

foreign import ccall unsafe "virtio_probe_slot" c_probe_slot :: Int -> Ptr Word32 -> Ptr Word32 -> Ptr Word32 -> IO CInt

-- | Map C error to BlkError.
cErrToBlkError :: Int -> BlkError
cErrToBlkError n = case n of
  -1 -> BlkBadSlot
  -2 -> BlkInvalidArg "BadVersion"
  -3 -> BlkInvalidArg "NeedsReset"
  -4 -> BlkInvalidArg "FeaturesMismatch"
  -5 -> BlkNoSpace
  -6 -> BlkInvalidArg "QueueFull"
  -7 -> BlkNotReady
  -8 -> BlkInvalidArg "SpuriousInt"
  -9 -> BlkInvalidArg "EINVAL"
  _
    | n == 1 -> BlkIoError 1
    | otherwise -> BlkUnknown n

slotValid :: Int -> Bool
slotValid n = n >= 0 && n < 8

-- | Probe capacity (sectors). Validates slot and device_id==2.
blkProbeCapacity :: Int -> H (Either BlkError Word64)
blkProbeCapacity slot
  | not (slotValid slot) = return (Left BlkBadSlot)
  | otherwise = do
      didRes <- liftIO $ alloca $ \pDid -> alloca $ \pVid -> alloca $ \pVer -> do
        r <- c_probe_slot slot pDid pVid pVer
        did <- peek pDid
        return (r, did)
      let (present, did) = didRes
      if present == 0
        then return (Left BlkBadSlot)
        else
          if did /= 2
            then return (Left BlkNotBlk)
            else liftIO $ alloca $ \pCap -> do
              r <- c_probe_capacity slot pCap
              if r /= 0
                then return (Left (cErrToBlkError (fromIntegral r)))
                else do v <- peek pCap; return (Right v)

-- | Alias for external callers that just want capacity.
blkGetCapacitySectors :: Int -> H (Either BlkError Word64)
blkGetCapacitySectors = blkProbeCapacity

-- | Submit read of 1 block (4K) at LBA blocks. Data page PA must be identity.
blkSubmitRead :: Int -> Word64 -> Ptr Word8 -> H (Either BlkError Word32)
blkSubmitRead slot lba dataPtr
  | not (slotValid slot) = return (Left BlkBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_read slot lba pa 1 pReq
      if r /= 0
        then return (Left (cErrToBlkError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Submit write of 1 block.
blkSubmitWrite :: Int -> Word64 -> Ptr Word8 -> H (Either BlkError Word32)
blkSubmitWrite slot lba dataPtr
  | not (slotValid slot) = return (Left BlkBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_write slot lba pa 1 pReq
      if r /= 0
        then return (Left (cErrToBlkError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Poll used ring. Returns Nothing if no completion, else Just (id,status).
blkPollUsed :: Int -> H (Either BlkError (Maybe (Word32, Word8)))
blkPollUsed slot
  | not (slotValid slot) = return (Left BlkBadSlot)
  | otherwise = liftIO $ alloca $ \pId -> alloca $ \pSt -> do
      r <- c_poll_used slot pId pSt
      case r of
        1 -> return (Right Nothing)
        0 -> do i <- peek pId; s <- peek pSt; return (Right (Just (i, s)))
        n -> return (Left (cErrToBlkError (fromIntegral n)))
