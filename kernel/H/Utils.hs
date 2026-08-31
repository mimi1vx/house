module H.Utils where

import Data.Bits
import Data.Word (Word32, Word64)
import H.AdHocMem (Ptr, absolutePtr64, alignPtr, minusPtr, nullPtr)

setBit' :: (Bits a) => Int -> a -> a
setBit' b = flip setBit b

clearBit' :: (Bits a) => Int -> a -> a
clearBit' b = flip clearBit b

testBit' :: (Bits a) => Int -> a -> Bool
testBit' b = flip testBit b

condBit :: (Bits a) => Bool -> Int -> a -> a
condBit True = setBit'
condBit False = clearBit'

ptrToWord32 :: Ptr a -> Word32
ptrToWord32 p =
  fromIntegral (p `minusPtr` nullPtr) -- hack assuming nullPtr = 0

ptrFromWord32 :: Word32 -> Ptr a
ptrFromWord32 w = absolutePtr64 (fromIntegral w) -- hack assuming nullPtr = 0

ptrToWord64 :: Ptr a -> Word64
ptrToWord64 p = fromIntegral (p `minusPtr` nullPtr)

ptrFromWord64 :: Word64 -> Ptr a
ptrFromWord64 = absolutePtr64

-- Word64 aliases for the aarch64 port (keep Word32 for i386 compat)
ptrToWord :: Ptr a -> Word64
ptrToWord = ptrToWord64

ptrFromWord :: Word64 -> Ptr a
ptrFromWord = ptrFromWord64

validPtr :: (Ptr a, Ptr a) -> Ptr a -> Bool
validPtr (minAddr, maxAddr) p = p `minusPtr` minAddr >= 0 && maxAddr `minusPtr` p >= 0

alignedPtr :: Int -> Ptr a -> Bool
alignedPtr s p = p `alignPtr` s == p
