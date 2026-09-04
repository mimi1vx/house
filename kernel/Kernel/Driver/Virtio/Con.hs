-- | Virtio-console re-export shim.
module Kernel.Driver.Virtio.Con
  ( ConError (..),
    conErrorToString,
    ConDevice (..),
    conProbe,
    conSubmitRx,
    conSubmitTx,
    conPollUsed,
    conInvalidate,
    conSaveQueues,
    ConServer (..),
    conServerInit,
    conServerTeardown,
    conWrite,
    conRead,
    conWriteBytes,
    conReadBytes,
  )
where

import Kernel.Driver.Virtio.Con.Device (conInvalidate, conPollUsed, conProbe, conSaveQueues, conSubmitRx, conSubmitTx)
import Kernel.Driver.Virtio.Con.Server (ConServer (..), conRead, conReadBytes, conServerInit, conServerTeardown, conWrite, conWriteBytes)
import Kernel.Driver.Virtio.Con.Types (ConDevice (..), ConError (..), conErrorToString)
