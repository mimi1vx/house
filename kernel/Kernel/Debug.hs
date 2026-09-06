module Kernel.Debug (
  vDefaultConsole,
  Kernel.Debug.putStr,
  Kernel.Debug.putStrLn,
)
where

-- import Control.Concurrent.Chan
import H.Concurrency

{-P:
import Prelude hiding (putStr,putStrLn)
-}
import H.Monad (H)
import H.Unsafe (unsafePerformH)
import Kernel.Console

{-# NOINLINE vDefaultConsole #-}
vDefaultConsole :: MVar Console
vDefaultConsole = unsafePerformH newEmptyMVar

putStr :: String -> H ()
putStr = wrap putString

putStrLn :: String -> H ()
putStrLn = wrap putStringLn

wrap :: (Console -> String -> H ()) -> String -> H ()
wrap f str =
  do
    empty <- isEmptyMVar vDefaultConsole
    if empty
      then return ()
      else do
        chan <- readMVar vDefaultConsole
        f chan str
