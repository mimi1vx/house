{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Types
Description : Process bookkeeping for EL0 loader.
Stability   : experimental

Lock order: ... -> netSem -> userSem -> epSem . Never hold userSem across takeMVar or init_page_dir.
-}
module Kernel.Userspace.Types (
  Pid (..),
  SharedObject (..),
  Process (..),
  pidNext,
  procMap,
  procExitMap,
  userSem,
  processExitVar,
)
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word64)
import H.Concurrency (MVar, QSem, newQSem)
import H.Concurrency qualified as HC
import H.Mutable (Ref, newRef)
import H.PhysicalMemory (PhysPage)
import H.Unsafe (unsafePerformH)
import H.VirtualMemory (PageMap, VAddr)

newtype Pid = Pid Int
  deriving (Eq, Ord, Show)

{- | Finalized read-only pages of one dependency object. The metadata is
retained by a live process so a later mapping can compare and share the
exact relocated bytes rather than trusting a SONAME alone.
-}
data SharedObject = SharedObject {
  sharedObjectName :: String
  , sharedObjectBase :: Word64
  , sharedObjectPages :: [(VAddr, PhysPage)]
  }
  deriving (Eq, Show)

data Process = Process {
  procPid :: Pid
  , procPdir :: PageMap
  , procEntry :: VAddr
  , procBrk :: VAddr
  , procSharedObjects :: [SharedObject]
  }
  deriving (Eq, Show)

{-# NOINLINE pidNext #-}
pidNext :: Ref Int
pidNext = unsafePerformH (newRef 1)

{-# NOINLINE procMap #-}
procMap :: Ref (Map Pid Process)
procMap = unsafePerformH (newRef Map.empty)

{-# NOINLINE procExitMap #-}
procExitMap :: Ref (Map Pid (MVar Int))
procExitMap = unsafePerformH (newRef Map.empty)

{-# NOINLINE userSem #-}
userSem :: QSem
userSem = unsafePerformH (newQSem 1)

{-# NOINLINE processExitVar #-}
processExitVar :: MVar Int
processExitVar = unsafePerformH HC.newEmptyMVar
