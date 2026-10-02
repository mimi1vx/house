{-# LANGUAGE GHC2024 #-}

{- | Block device interface: filesystem depends on this record, not on
a virtio driver. The driver builds it via `blkBlockDev`, mapping
`BlkError` to `FsError` at one place.
-}
module Kernel.FileSystem.BlockDev (
  BlockDev (..),
)
where

import Data.Word (Word64, Word8)
import H.Monad (H)
import Kernel.FileSystem.Vfs (FsError)

data BlockDev = BlockDev {
  bdCapacity :: Int -> H (Either FsError Word64)
  , bdRead :: Int -> Word64 -> H (Either FsError [Word8])
  , bdWrite :: Int -> Word64 -> [Word8] -> H (Either FsError ())
  }
