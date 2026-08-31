{-# LANGUAGE ForeignFunctionInterface #-}

module Spike where

import Control.Monad (forM_)
import Foreign.C.Types (CULong (..))
import GHC.Conc (threadDelay)

foreign import ccall unsafe "house_uptime_ns"
  house_uptime_ns :: IO CULong

foreign export ccall house_spike_main :: IO ()

-- 4 paced threadDelay ticks, each reporting its measured wall duration;
-- the marker line is what scripts/qemu-smoke.exp asserts.
house_spike_main :: IO ()
house_spike_main = do
  putStrLn "house/aarch64: hello from stock GHC RTS via PL011"
  forM_ [1 .. 4 :: Int] $ \i -> do
    t0 <- house_uptime_ns
    threadDelay 500000
    t1 <- house_uptime_ns
    let ms = fromIntegral (t1 - t0) / (1000000 :: Double)
    putStrLn ("tick " ++ show i ++ ": " ++ show ms ++ " ms")
  putStrLn "ticks-ok"
