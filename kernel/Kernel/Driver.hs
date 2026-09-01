-- | Driver framework re-export shim (mirrors 'Kernel.IPC' pattern).
module Kernel.Driver
  ( module Kernel.Driver.Types,
    module Kernel.Driver.Registry,
    module Kernel.Driver.Dmesg,
    module Kernel.Driver.GIC,
    module Kernel.Driver.VirtioProbe,
    module Kernel.Driver.IRQ,
  )
where

import Kernel.Driver.Dmesg
import Kernel.Driver.GIC
import Kernel.Driver.IRQ
import Kernel.Driver.Registry
import Kernel.Driver.Types
import Kernel.Driver.VirtioProbe
