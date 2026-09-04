-- | IRQ forwarding via H.Interrupts -> Endpoint (non-blocking trySend).
-- Dispatcher remains bounded (drainBounded 64); handler never blocks.
module Kernel.IPC.IRQ
  ( irqForward,
  )
where

import H.Interrupts (IntId (..), installHandler)
import H.Monad (H)
import Kernel.IPC.Endpoint (trySend)
import Kernel.IPC.Types (Endpoint, Message (..))

-- | Forward GIC INTID as message tag to endpoint. Non-blocking.
-- Uses trySend so ISR dispatcher (threadDelay 20ms + drainBounded 64) never blocks on full queue.
-- Tag encodes IntId (Word32 -> Word64).
irqForward :: IntId -> Endpoint -> H ()
irqForward (IntId n) ep = do
  _ <- installHandler (IntId n) handler
  return ()
  where
    handler = do
      let msg = Message (fromIntegral n) [] Nothing
      _ <- trySend ep msg
      return ()
