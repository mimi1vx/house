{-# LANGUAGE ForeignFunctionInterface #-}

-- | Virtio split virtqueue — bounded allocation over 'H.Pages'.
-- One queue per slot, 1..64 entries (clamped), up to 3 pages.
-- Invariants: pages are 4 KiB aligned 'validPage', reclaimed via 'freeQueue'.
module Kernel.Driver.Virtio.Queue
  ( VirtQueue (..),
    allocQueue,
    freeQueue,
    queueSize,
    queueDescPa,
    queueAvailPa,
    queueUsedPa,
  )
where

import Data.Word (Word32, Word64, Word8)
import Foreign.Ptr (Ptr)
import H.Monad (H)
import qualified H.Pages as P

-- | Virtqueue backed by H.Pages.
data VirtQueue = VirtQueue
  { vqDesc :: P.Page Word8,
    vqAvail :: P.Page Word8,
    vqUsed :: P.Page Word8,
    vqSize :: Word32,
    vqDescPa :: Word64,
    vqAvailPa :: Word64,
    vqUsedPa :: Word64
  }
  deriving (Eq, Show)

-- | Max queue depth (caps host QueueNumMax for pool safety).
maxVirtQueueSize :: Word32
maxVirtQueueSize = 64

foreign import ccall unsafe "virtio_page_pa" c_pagePa :: Ptr Word8 -> Word64

-- | Allocate queue pages (1-3). Validates size, on failure rolls back.
allocQueue :: Word32 -> H (Either String VirtQueue)
allocQueue reqSize
  | reqSize == 0 = return (Left "queue size 0")
  | reqSize > maxVirtQueueSize = return (Left "queue size >64")
  | otherwise = do
      mp1 <- P.allocPage
      case mp1 of
        Nothing -> return (Left "NoSpace desc")
        Just p1 -> do
          mp2 <- P.allocPage
          case mp2 of
            Nothing -> do P.freePage p1; return (Left "NoSpace avail")
            Just p2 -> do
              mp3 <- P.allocPage
              case mp3 of
                Nothing -> do P.freePage p2; P.freePage p1; return (Left "NoSpace used")
                Just p3 -> do
                  P.zeroPage p1
                  P.zeroPage p2
                  P.zeroPage p3
                  let pa1 = c_pagePa p1
                      pa2 = c_pagePa p2
                      pa3 = c_pagePa p3
                  return (Right (VirtQueue p1 p2 p3 reqSize pa1 pa2 pa3))

-- | Free queue pages (validates validPage before free).
freeQueue :: VirtQueue -> H ()
freeQueue vq = mapM_ freeIfValid [vqDesc vq, vqAvail vq, vqUsed vq]
  where
    freeIfValid p = if P.validPage p then P.freePage p else return ()

-- | Accessors (total).
queueSize :: VirtQueue -> Word32
queueSize = vqSize

queueDescPa :: VirtQueue -> Word64
queueDescPa = vqDescPa

queueAvailPa :: VirtQueue -> Word64
queueAvailPa = vqAvailPa

queueUsedPa :: VirtQueue -> Word64
queueUsedPa = vqUsedPa
