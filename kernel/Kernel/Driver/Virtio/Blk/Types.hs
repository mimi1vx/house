{-# LANGUAGE ForeignFunctionInterface #-}

-- | Virtio-blk types — 4K blocks, wire 512B sectors (Q2=B).
-- Strictness: capacity and LBA are strict Word64, counts strict Word32.
-- Exceptions: all validation returns Either, no partial head/fromJust/!!.
-- Bounds: slot 0..7, block count 1 per Grant page, LBA *8 <= capacity.
module Kernel.Driver.Virtio.Blk.Types
  ( BlkError (..),
    blkErrorToString,
    blockBytes,
    sectorBytes,
    sectorsPerBlock,
    maxBlocksPerGrant,
    validateLba,
  )
where

import Data.Word (Word32, Word64)

-- | Blk subsystem errors (total decoder via cErrToBlkError in Device).
data BlkError
  = BlkBadSlot
  | BlkNotBlk
  | BlkNotReady
  | BlkNoSpace
  | BlkIoError Int
  | BlkInvalidArg String
  | BlkUnknown Int
  deriving (Eq, Show)

-- | Human string for error (used in shell).
blkErrorToString :: BlkError -> String
blkErrorToString BlkBadSlot = "BlkBadSlot"
blkErrorToString BlkNotBlk = "BlkNotBlk"
blkErrorToString BlkNotReady = "BlkNotReady"
blkErrorToString BlkNoSpace = "BlkNoSpace"
blkErrorToString (BlkIoError n) = "BlkIoError " ++ show n
blkErrorToString (BlkInvalidArg s) = "BlkInvalidArg: " ++ s
blkErrorToString (BlkUnknown n) = "BlkUnknown " ++ show n

-- | I/O unit constants (Q2=B).
blockBytes :: Word64
blockBytes = 4096

sectorBytes :: Word64
sectorBytes = 512

sectorsPerBlock :: Word64
sectorsPerBlock = 8

maxBlocksPerGrant :: Word32
maxBlocksPerGrant = 1

-- | Validate LBA (in 4K blocks) + count (blocks) against capacity (sectors).
-- Returns unit on success. Arithmetic runs in Integer so a wrapping
-- Word64 LBA cannot alias into range (hostile capacity/LBA bytes).
validateLba :: Word64 -> Word32 -> Word64 -> Either BlkError ()
validateLba lba count capSectors
  | count == 0 = Left (BlkInvalidArg "count 0")
  | count > maxBlocksPerGrant = Left (BlkInvalidArg "count >1")
  | sector + nsectors > toInteger capSectors = Left (BlkInvalidArg "LBA out of range")
  | otherwise = Right ()
  where
    sector = toInteger lba * toInteger sectorsPerBlock
    nsectors = toInteger count * toInteger sectorsPerBlock
