{- | IRQ forwarding via H.Interrupts -> Endpoint (non-blocking trySend).
Dispatcher drains to 256 behind a bounded `c_pipeWait`; handler never blocks.
Push honors the `maxQueueDepth` Endpoint bound: overflow drops + dmesg-logs.
-}
module Kernel.IPC.IRQ (
  irqForward,
  unregisterIrqForward,
  irqDrops,
  readIrqDrops,
  drainIrqDrops,
  forwardIrq,
)
where

import Data.Word (Word64)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Interrupts (IntId (..), installHandler, removeHandler)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import Kernel.Driver.Dmesg qualified as Dmesg
import Kernel.IPC.Endpoint (trySend)
import Kernel.IPC.Types (Endpoint, Message (..))

{-# NOINLINE irqSem #-}
irqSem :: QSem
irqSem = unsafePerformH $ newQSem 1

{-# NOINLINE irqDrops #-}
irqDrops :: Ref Word64
irqDrops = unsafePerformH $ newRef 0

{- | Forward GIC INTID as message tag to endpoint. Non-blocking.
Uses trySend so the handler never blocks on a full queue; the dispatcher
drains to 256 behind a bounded `c_pipeWait`.
Tag encodes IntId (Word32 -> Word64). Drops (QueueFull/freed endpoint)
are counted + dmesg-logged so IRQ storms stay visible.
-}
irqForward :: IntId -> Endpoint -> H ()
irqForward (IntId n) ep = do
  _ <- installHandler (IntId n) handler
  return ()
  where
    handler = forwardIrq (IntId n) ep

{- | Stop forwarding an INTID: drop the installed handler so no later IRQ
`trySend`s into an endpoint that is about to be freed.
-}
unregisterIrqForward :: IntId -> H ()
unregisterIrqForward = removeHandler

-- | Single forward attempt, countable from host tests without GIC wiring.
forwardIrq :: IntId -> Endpoint -> H ()
forwardIrq (IntId n) ep = do
  let msg = Message (fromIntegral n) [] Nothing
  r <- trySend ep msg
  case r of
    Right () -> return ()
    Left e -> do
      c <- withQSem irqSem $ do
        n0 <- readRef irqDrops
        let n1 = n0 + 1
        writeRef irqDrops n1
        return n1
      Dmesg.dmesgLog ("irq drop intid=" ++ show n ++ " " ++ show e ++ " drops=" ++ show c)

-- | Read the drop counter without resetting (monotonic for `lsdev`).
readIrqDrops :: H Word64
readIrqDrops = withQSem irqSem (readRef irqDrops)

-- | Read and reset the drop counter (shell verbs report *new* drops).
drainIrqDrops :: H Word64
drainIrqDrops = withQSem irqSem $ do
  n <- readRef irqDrops
  writeRef irqDrops 0
  return n
