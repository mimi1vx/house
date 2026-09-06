-- | Unsafe operations
module H.Unsafe where

import H.Monad (H, runH)
import System.IO.Unsafe (unsafePerformIO)

unsafePerformH :: H a -> a
unsafePerformH = unsafePerformIO . runH
