{-# LANGUAGE ForeignFunctionInterface #-}

-- | Virtio-MMIO transport types (device-agnostic).
-- Strictness: status/feature masks are strict Word32/Word64.
-- Exceptions: total decoders return Either, no partial head/fromJust/!!.
-- Bounds: slot 0..7, queue size capped at 64.
module Kernel.Driver.Virtio.Types
  ( VirtioFeature (..),
    VirtioStatus (..),
    VirtioError (..),
    virtioFeatureMask,
    virtioErrorToString,
    statusBit,
    statusWordToList,
    statusListToWord,
    viewStatus,
    cErrToVirtioError,
  )
where

import Data.Bits (complement, shiftL, (.&.), (.|.))
import Data.Char (intToDigit)
import Data.Word (Word32, Word64)

-- | Negotiated feature bits.
data VirtioFeature
  = VirtioFVersion1
  | VirtioFRingEventIdx
  deriving (Eq, Show, Enum, Bounded)

-- | Status bits as per Virtio 1.0 MMIO.
data VirtioStatus
  = VirtioAck
  | VirtioDriver
  | VirtioDriverOk
  | VirtioFeaturesOk
  | VirtioFailed
  | VirtioNeedsReset
  deriving (Eq, Show, Enum, Bounded)

-- | Transport errors (maps from C VIRTIO_ERR_*).
data VirtioError
  = BadSlot
  | BadVersion
  | NeedsReset
  | FeaturesMismatch
  | NoSpace
  | QueueFull
  | NotReady
  | SpuriousInt
  | InvalidArg String
  | UnknownError Int
  deriving (Eq, Show)

-- | Mask for a set of features.
virtioFeatureMask :: [VirtioFeature] -> Word64
virtioFeatureMask fs = foldr (.|.) 0 (map bitFor fs)
  where
    bitFor VirtioFVersion1 = (1 :: Word64) `shiftL` 32
    bitFor VirtioFRingEventIdx = (1 :: Word64) `shiftL` 29

-- | Human string for error.
virtioErrorToString :: VirtioError -> String
virtioErrorToString BadSlot = "BadSlot"
virtioErrorToString BadVersion = "BadVersion"
virtioErrorToString NeedsReset = "NeedsReset"
virtioErrorToString FeaturesMismatch = "FeaturesMismatch"
virtioErrorToString NoSpace = "NoSpace"
virtioErrorToString QueueFull = "QueueFull"
virtioErrorToString NotReady = "NotReady"
virtioErrorToString SpuriousInt = "SpuriousInt"
virtioErrorToString (InvalidArg s) = "InvalidArg: " ++ s
virtioErrorToString (UnknownError n) = "UnknownError " ++ show n

-- | Single status bit.
statusBit :: VirtioStatus -> Word32
statusBit VirtioAck = 0x01
statusBit VirtioDriver = 0x02
statusBit VirtioDriverOk = 0x04
statusBit VirtioFeaturesOk = 0x08
statusBit VirtioFailed = 0x80
statusBit VirtioNeedsReset = 0x80

-- | Decode status word to list (total).
statusWordToList :: Word32 -> [VirtioStatus]
statusWordToList w = filter (\s -> (w .&. statusBit s) /= 0) allStatuses
  where
    allStatuses = [VirtioAck, VirtioDriver, VirtioDriverOk, VirtioFeaturesOk, VirtioFailed]

-- | Encode list to word.
statusListToWord :: [VirtioStatus] -> Word32
statusListToWord = foldr (\s acc -> acc .|. statusBit s) 0

-- | Validate status word has no unknown bits beyond known mask.
viewStatus :: Word32 -> Either VirtioError [VirtioStatus]
viewStatus w =
  let knownMask = 0x01 .|. 0x02 .|. 0x04 .|. 0x08 .|. 0x80 :: Word32
      unknown = w .&. complement knownMask
   in if unknown /= 0
        then Left (InvalidArg ("unknown status bits 0x" ++ showHex32 unknown))
        else Right (statusWordToList w)
  where
    showHex32 v
      | v < 16 = [intToDigit (fromIntegral v)]
      | otherwise = showHex32 (v `div` 16) ++ [intToDigit (fromIntegral (v `mod` 16))]

-- | Map C error int to ADT.
cErrToVirtioError :: Int -> VirtioError
cErrToVirtioError n = case n of
  -1 -> BadSlot
  -2 -> BadVersion
  -3 -> NeedsReset
  -4 -> FeaturesMismatch
  -5 -> NoSpace
  -6 -> QueueFull
  -7 -> NotReady
  -8 -> SpuriousInt
  -9 -> InvalidArg "EINVAL"
  _ -> UnknownError n
