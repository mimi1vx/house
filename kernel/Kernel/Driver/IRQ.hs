-- | IRQ forwarding helpers for drivers (thin wrapper over 'Kernel.IPC.IRQ').
module Kernel.Driver.IRQ
  ( registerIrqForwarding,
  )
where

import H.Interrupts (IntId)
import H.Monad (H)
import Kernel.Driver.Types (DriverError)
import Kernel.IPC.IRQ (irqForward)
import Kernel.IPC.Types (Endpoint)

-- | Forward GIC INTID to endpoint via 'irqForward' (non-blocking trySend).
-- Bounded 32 queue; dispatcher stays bounded 64. Tag encodes INTID.
registerIrqForwarding :: IntId -> Endpoint -> H (Either DriverError ())
registerIrqForwarding intid ep = do
  irqForward intid ep
  return (Right ())
