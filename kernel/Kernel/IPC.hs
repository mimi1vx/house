-- | IPC re-export shim — L4 sync rendezvous, copy+grant, both ns+cap, hybrid Haskell/EL0.
module Kernel.IPC
  ( module Kernel.IPC.Types,
    module Kernel.IPC.Endpoint,
    module Kernel.IPC.Nameservice,
    module Kernel.IPC.Grant,
    module Kernel.IPC.IRQ,
  )
where

import Kernel.IPC.Endpoint
import Kernel.IPC.Grant
import Kernel.IPC.IRQ
import Kernel.IPC.Nameservice
import Kernel.IPC.Types
