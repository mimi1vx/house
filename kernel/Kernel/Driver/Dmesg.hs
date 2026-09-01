-- | Bounded Haskell dmesg ring (64 entries * 120 chars), coherency via WB.
-- Non-blocking: 'dmesgLog' never holds MVar across block.
module Kernel.Driver.Dmesg
  ( dmesgInit,
    dmesgLog,
    dmesgRead,
    dmesgClear,
  )
where

import Data.Word (Word64)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Monad (H, liftIO)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)

-- | Single entry with uptime seconds.
data DmesgEntry = DmesgEntry
  { dmUptime :: Word64,
    dmMsg :: String
  }
  deriving (Eq, Show)

maxDmesgEntries :: Int
maxDmesgEntries = 64

maxDmesgLine :: Int
maxDmesgLine = 120

{-# NOINLINE dmesgBuf #-}
dmesgBuf :: Ref [DmesgEntry]
dmesgBuf = unsafePerformH $ newRef []

{-# NOINLINE dmesgSem #-}
dmesgSem :: QSem
dmesgSem = unsafePerformH $ newQSem 1

foreign import ccall unsafe "house_uptime_secs" c_uptime :: IO Word64

-- | Initialize ring (call once at boot).
dmesgInit :: H ()
dmesgInit = withQSem dmesgSem $ writeRef dmesgBuf []

-- | Append entry, cap at 64 newest, truncate line at 120.
dmesgLog :: String -> H ()
dmesgLog msg = do
  up <- liftIO c_uptime
  let entry = DmesgEntry up (take maxDmesgLine msg)
  withQSem dmesgSem $ do
    xs <- readRef dmesgBuf
    writeRef dmesgBuf (take maxDmesgEntries (entry : xs))

-- | Snapshot oldest-first.
dmesgRead :: H [String]
dmesgRead = withQSem dmesgSem $ do
  xs <- readRef dmesgBuf
  return (map fmt (reverse xs))
  where
    fmt e = "[" ++ show (dmUptime e) ++ "] " ++ dmMsg e

-- | Clear ring.
dmesgClear :: H ()
dmesgClear = withQSem dmesgSem $ writeRef dmesgBuf []
