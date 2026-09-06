{- | IRQ forwarding via H.Interrupts -> Endpoint (non-blocking trySend).
Dispatcher remains bounded (drainBounded 64); handler never blocks.
Push honors the 32-deep Endpoint bound: overflow drops + dmesg-logs.
-}
module Kernel.IPC.IRQ (
  irqForward,
)
where

import Data.Word (Word64)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Interrupts (IntId (..), installHandler)
import H.Monad (H)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import qualified Kernel.Driver.Dmesg as Dmesg
import Kernel.IPC.Endpoint (trySend)
import Kernel.IPC.Types (Endpoint, Message (..))

{-# NOINLINE irqSem #-}
irqSem :: QSem
irqSem = unsafePerformH $ newQSem 1

{-# NOINLINE irqDrops #-}
irqDrops :: Ref Word64
irqDrops = unsafePerformH $ newRef 0

{- | Forward GIC INTID as message tag to endpoint. Non-blocking.
Uses trySend so ISR dispatcher (threadDelay 20ms + drainBounded 64) never blocks on full queue.
Tag encodes IntId (Word32 -> Word64). Drops (QueueFull/freed endpoint)
are counted + dmesg-logged so IRQ storms stay visible.
-}
irqForward :: IntId -> Endpoint -> H ()
irqForward (IntId n) ep = do
  _ <- installHandler (IntId n) handler
  return ()
  where
    handler = do
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
