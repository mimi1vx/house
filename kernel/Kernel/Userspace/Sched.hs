{-# LANGUAGE ForeignFunctionInterface #-}

{- |
Module      : Kernel.Userspace.Sched
Description : Round-robin run queue for preempted EL0 sessions.
Stability   : experimental

The timer IRQ parks an over-quantum EL0 frame (PREEMPT); the preempted
thread hands a baton token to a live successor and blocks on its own token
(no RTS capability pinned while blocked). A successor blocked on something
other than its token (a WAIT for a child, a long IPC) never takes the
token, so handoff waits time out and the rotation tries the next candidate;
a thread with no live successor keeps its slice. Exits pass the baton
before dying; reapers wake all tokens so a thread blocked on a dead
successor re-elects. Spurious wakeups only re-elect. Tokens start full so
a session's first entry is direct; only preemption blocks.

Locking: 'schedSem' guards the ring, tokens, and caps cache. It is never
held together with 'userSem': snapshots are copied under one lock and
filtered under the other, so no lock order exists to violate.
-}
module Kernel.Userspace.Sched (
  schedRegister,
  schedUnregister,
  schedRunQueue,
  schedSuccessor,
  schedWake,
  schedWakeAll,
  schedWaitTimeout,
  schedSetQuantum,
)
where

import Control.Concurrent (tryPutMVar)
import qualified Control.Concurrent as IO (getNumCapabilities)
import Control.Monad (forM_, void, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Word (Word64)
import H.Concurrency (MVar, QSem, newMVar, newQSem, takeMVar, withQSem)
import H.Monad (H, liftIO, runH)
import H.Mutable (Ref, modifyRef, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import Kernel.Userspace.Types (Pid (..), procMap, userSem)
import qualified System.Timeout as T

foreign import ccall unsafe "house_sched_set_runnable" c_sched_set_runnable :: Word64 -> IO ()

foreign import ccall unsafe "house_sched_set_quantum" c_sched_set_quantum :: Word64 -> IO ()

{-# NOINLINE schedSem #-}
schedSem :: QSem
schedSem = unsafePerformH (newQSem 1)

{-# NOINLINE runRing #-}
runRing :: Ref [Pid]
runRing = unsafePerformH (newRef [])

{-# NOINLINE runToken #-}
runToken :: Ref (Map Pid (MVar ()))
runToken = unsafePerformH (newRef Map.empty)

{-# NOINLINE schedCaps #-}
schedCaps :: Ref Int
schedCaps = unsafePerformH (newRef 0)

-- | Publish oversubscription: live sessions beyond the EL1 reserve.
updateRunnable :: [Pid] -> H ()
updateRunnable ring = do
  caps <- readRef schedCaps
  caps' <-
    if caps <= 0
      then liftIO IO.getNumCapabilities
      else return caps
  when (caps <= 0) (writeRef schedCaps caps')
  let adv = max 0 (length ring - max 0 (caps' - 1))
  liftIO (c_sched_set_runnable (fromIntegral adv))

-- | Join the ring (token starts full: first entry is direct).
schedRegister :: Pid -> H ()
schedRegister pid = do
  tok <- newMVar ()
  withQSem schedSem $ do
    modifyRef runRing (++ [pid])
    modifyRef runToken (Map.insert pid tok)
    readRef runRing >>= updateRunnable

-- | Leave the ring (idempotent: exits and reapers both call).
schedUnregister :: Pid -> H ()
schedUnregister pid =
  withQSem schedSem $ do
    modifyRef runRing (filter (/= pid))
    modifyRef runToken (Map.delete pid)
    readRef runRing >>= updateRunnable

-- | Live ring in insertion order (snapshot; caller rotates/filters).
schedRunQueue :: H [Pid]
schedRunQueue = do
  ring <- withQSem schedSem (readRef runRing)
  mp <- withQSem userSem (readRef procMap)
  return (filter (`Map.member` mp) ring)

-- | First live pid after the given one in ring order, wrapping (never self).
schedSuccessor :: Pid -> H (Maybe Pid)
schedSuccessor self = do
  qs <- schedRunQueue
  let (pre, post) = break (== self) qs
  return $ case drop 1 post ++ pre of
    (q : _) -> Just q
    _ -> Nothing

-- | Hand the baton (non-blocking; missing token means reaped).
schedWake :: Pid -> H ()
schedWake pid = do
  mt <- withQSem schedSem (Map.lookup pid <$> readRef runToken)
  case mt of
    Nothing -> return ()
    Just t -> void (liftIO (tryPutMVar t ()))

-- | Wake every token (reaper path: unblocks threads parked on dead peers).
schedWakeAll :: H ()
schedWakeAll = do
  toks <- withQSem schedSem (Map.elems <$> readRef runToken)
  forM_ toks (\t -> void (liftIO (tryPutMVar t ())))

{- | Block until handed the baton (no lock held); True when woken, False
on timeout or when unregistered (caller re-elects or keeps its slice).
-}
schedWaitTimeout :: Pid -> Int -> H Bool
schedWaitTimeout pid micros = do
  mt <- withQSem schedSem (Map.lookup pid <$> readRef runToken)
  case mt of
    Nothing -> return False
    Just t -> isJust <$> liftIO (T.timeout micros (runH (takeMVar t)))

-- | Preempt quantum in timer ticks (0 means 1).
schedSetQuantum :: Word64 -> H ()
schedSetQuantum q = liftIO (c_sched_set_quantum q)
