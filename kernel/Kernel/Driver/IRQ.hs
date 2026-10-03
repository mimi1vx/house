-- | IRQ forwarding helpers for drivers (thin wrapper over 'Kernel.IPC.IRQ').
module Kernel.Driver.IRQ (
  registerIrqForwarding,
  unregisterIrqForwarding,
)
where

import H.Interrupts (IntId)
import H.Monad (H)
import Kernel.Driver.Types (DriverError)
import Kernel.IPC.IRQ (irqForward, unregisterIrqForward)
import Kernel.IPC.Types (Endpoint)

{- | Forward GIC INTID to endpoint via 'irqForward' (non-blocking trySend).
Bounded `maxQueueDepth` queue; dispatcher drains to 256 behind a bounded
`c_pipeWait`. Tag encodes INTID.
-}
registerIrqForwarding :: IntId -> Endpoint -> H (Either DriverError ())
registerIrqForwarding intid ep = do
  irqForward intid ep
  return (Right ())

{- | Clear the forwarding installed by 'registerIrqForwarding'. Call before
freeing the endpoint: a handler left installed sends into a dead endpoint,
which counts as an `irqDrops` line per IRQ.
-}
unregisterIrqForwarding :: IntId -> H ()
unregisterIrqForwarding = unregisterIrqForward
