module H.Utils where

import Data.Bits
import Data.Word (Word32, Word64)
import Foreign.Ptr (IntPtr, intPtrToPtr, ptrToIntPtr)
import H.AdHocMem (Ptr, alignPtr, minusPtr)

setBit' :: (Bits a) => Int -> a -> a
setBit' = flip setBit

clearBit' :: (Bits a) => Int -> a -> a
clearBit' = flip clearBit

testBit' :: (Bits a) => Int -> a -> Bool
testBit' = flip testBit

condBit :: (Bits a) => Bool -> Int -> a -> a
condBit True = setBit'
condBit False = clearBit'

ptrToWord32 :: Ptr a -> Word32
ptrToWord32 p = fromIntegral (ptrToIntPtr p)

ptrFromWord32 :: Word32 -> Ptr a
ptrFromWord32 w = intPtrToPtr (fromIntegral w :: IntPtr)

ptrToWord64 :: Ptr a -> Word64
ptrToWord64 p = fromIntegral (ptrToIntPtr p)

ptrFromWord64 :: Word64 -> Ptr a
ptrFromWord64 w = intPtrToPtr (fromIntegral w :: IntPtr)

-- Word64 aliases for the aarch64 port (Word32 variants cover 32-bit register windows)
ptrToWord :: Ptr a -> Word64
ptrToWord = ptrToWord64

ptrFromWord :: Word64 -> Ptr a
ptrFromWord = ptrFromWord64

validPtr :: (Ptr a, Ptr a) -> Ptr a -> Bool
validPtr (minAddr, maxAddr) p = p `minusPtr` minAddr >= 0 && maxAddr `minusPtr` p > 0

alignedPtr :: Int -> Ptr a -> Bool
alignedPtr s p = p `alignPtr` s == p
