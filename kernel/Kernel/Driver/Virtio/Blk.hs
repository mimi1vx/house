-- | Virtio-blk re-export shim.
module Kernel.Driver.Virtio.Blk
  ( BlkError (..),
    blkErrorToString,
    blockBytes,
    sectorBytes,
    sectorsPerBlock,
    BlkDevice (..),
    blkServerInit,
    blkServerTeardown,
    blkReadBlocks,
    blkWriteBlocks,
    blkGetCapacity,
  )
where

import Kernel.Driver.Virtio.Blk.Server (BlkDevice (..), blkGetCapacity, blkReadBlocks, blkServerInit, blkServerTeardown, blkWriteBlocks)
import Kernel.Driver.Virtio.Blk.Types (BlkError (..), blkErrorToString, blockBytes, sectorBytes, sectorsPerBlock)
