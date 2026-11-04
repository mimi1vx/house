{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Types
Description : Process bookkeeping for EL0 loader.
Stability   : experimental

Lock order: ... -> netSem -> userSem -> epSem . Never hold userSem across takeMVar or init_page_dir.
-}
module Kernel.Userspace.Types (
  Pid (..),
  supervisorPid,
  SharedObject (..),
  StopAck,
  Process (..),
  DemandTable,
  DemandObject (..),
  pidNext,
  procMap,
  procExitMap,
  procStopMap,
  userSem,
)
where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Word (Word64)
import H.Concurrency (MVar, QSem, newQSem)
import H.Mutable (Ref, newRef)
import H.PhysicalMemory (PhysPage)
import H.Unsafe (unsafePerformH)
import H.VirtualMemory (PageMap, VAddr)
import Kernel.Userspace.Loader (Segment)

newtype Pid = Pid Int
  deriving (Eq, Ord, Show)

{- | The EL1 shell supervisor. Never allocated by 'pidNext' (which starts at
1): spawns are parented here, orphaned grandchildren are adopted here on
reap/kill, and the shell reaps as this waiter, so shell job control keeps
working while EL0 wait is restricted to own children.
-}
supervisorPid :: Pid
supervisorPid = Pid 0

{- | Per-pid acknowledgement that the process's EL0 session has ended. 'killPid'
frees a root only after the target's park loop has seen the removal and
returned, so pages that are still executing from are never handed back to the
allocator.
-}
type StopAck = MVar ()

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
  , procParent :: Pid
  , procPdir :: PageMap
  , procEntry :: VAddr
  , procBrk :: VAddr
  , procSharedObjects :: [SharedObject]
  , procDemand :: DemandTable
  }
  deriving (Eq, Show)

{- | Demand-paging commitments for one process (house-q0g.11): the 'PT_LOAD'
file content backing each not-yet-materialized page. The loader plants one
marker per 'PT_LOAD' page ('H.VirtualMemory.setDemandPage') instead of
mapping it; the first touch faults, parks, and the supervisor materializes
exactly that page from the retained object bytes with the marker's final
perms, then resumes the faulting insn. Object bytes stay retained per
process and are dropped with the 'Process' record on reap; the bound is the
sum of the image's file sizes (house fixtures: single-digit KiB). A page
the loader itself must touch (relocation targets, init/fini arrays) is
materialized eagerly at load, so everything else faults in.
-}
type DemandTable = [DemandObject]

data DemandObject = DemandObject {
  demandBase :: Word64
  , demandBytes :: ByteString
  , demandSegs :: [Segment]
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

{-# NOINLINE procStopMap #-}
procStopMap :: Ref (Map Pid StopAck)
procStopMap = unsafePerformH (newRef Map.empty)
