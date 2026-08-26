{-# LANGUAGE ForeignFunctionInterface #-}

module Spike where

import System.IO

foreign export ccall house_spike_main :: IO ()

house_spike_main :: IO ()
house_spike_main = do
  hSetBuffering stdout NoBuffering
  putStrLn "house/aarch64: hello from stock GHC RTS via PL011"
  putStrLn "spike-ok"
