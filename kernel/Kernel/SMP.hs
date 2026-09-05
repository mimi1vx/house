{-# LANGUAGE ForeignFunctionInterface #-}

-- Threaded-RTS seam: unsafe-only FFI; caps mirror the live
-- online mask via fixed `+RTS -N` (see house-boot c_start).
module Kernel.SMP (onlineSet, onlineCount, up, down) where

import Data.Bits (testBit)
import Data.Word (Word32)
import Foreign.C.Types (CInt (..))

foreign import ccall unsafe "house_smp_online" c_online :: IO Word32

foreign import ccall unsafe "house_smp_up" c_up :: CInt -> IO CInt

foreign import ccall unsafe "house_smp_down" c_down :: CInt -> IO CInt

onlineSet :: IO [Int]
onlineSet = do
  m <- c_online
  return [i | i <- [0 .. 31], testBit m i]

onlineCount :: IO Int
onlineCount = length <$> onlineSet

rcToEither :: CInt -> Either String ()
rcToEither 0 = Right ()
rcToEither e = Left ("errno " ++ show e)

up :: Int -> IO (Either String ())
up n
  | n < 0 || n > 31 = return (Left "EINVAL: core 0..31")
  | n == 0 = return (Left "EBUSY: core 0 never goes down/up")
  | otherwise = rcToEither <$> c_up (fromIntegral n)

down :: Int -> IO (Either String ())
down n
  | n < 0 || n > 31 = return (Left "EINVAL: core 0..31")
  | n == 0 = return (Left "EINVAL: refusing core 0 down")
  | otherwise = rcToEither <$> c_down (fromIntegral n)
