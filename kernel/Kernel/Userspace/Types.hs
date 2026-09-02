{-# LANGUAGE GHC2024 #-}

{-|
Module      : Kernel.Userspace.Types
Description : Process bookkeeping for EL0 loader.
Stability   : experimental

Lock order: ... -> netSem -> userSem -> epSem . Never hold userSem across takeMVar or init_page_dir.
-}
module Kernel.Userspace.Types
  ( Pid (..),
    Process (..),
    pidNext,
    procMap,
    userSem,
    processExitVar,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import H.Concurrency (MVar, QSem, newQSem)
import H.Concurrency qualified as HC
import H.Mutable (Ref, newRef)
import H.Unsafe (unsafePerformH)
import H.VirtualMemory (PageMap, VAddr)

newtype Pid = Pid Int
  deriving (Eq, Ord, Show)

data Process = Process
  { procPid :: Pid,
    procPdir :: PageMap,
    procEntry :: VAddr,
    procBrk :: VAddr
  }
  deriving (Eq, Show)

{-# NOINLINE pidNext #-}
pidNext :: Ref Int
pidNext = unsafePerformH (newRef 1)

{-# NOINLINE procMap #-}
procMap :: Ref (Map Pid Process)
procMap = unsafePerformH (newRef Map.empty)

{-# NOINLINE userSem #-}
userSem :: QSem
userSem = unsafePerformH (newQSem 1)

{-# NOINLINE processExitVar #-}
processExitVar :: MVar Int
processExitVar = unsafePerformH HC.newEmptyMVar
