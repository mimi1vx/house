-- | Virtio-console re-export shim.
module Kernel.Driver.Virtio.Con
  ( ConError (..),
    conErrorToString,
    ConDevice (..),
    ConKind (..),
    conProbe,
    conSubmitRx,
    conSubmitTx,
    conPollUsed,
    conInvalidate,
    conSaveQueues,
    conSaveCtrlQueues,
    conSetPortQueues,
    conSubmitCtrlRx,
    conSubmitCtrlTx,
    ConServer (..),
    conServerInit,
    conServerTeardown,
    conWrite,
    conRead,
    conWriteBytes,
    conReadBytes,
  )
where

import Kernel.Driver.Virtio.Con.Device (conInvalidate, conPollUsed, conProbe, conSaveCtrlQueues, conSaveQueues, conSetPortQueues, conSubmitCtrlRx, conSubmitCtrlTx, conSubmitRx, conSubmitTx)
import Kernel.Driver.Virtio.Con.Server (ConServer (..), conRead, conReadBytes, conServerInit, conServerTeardown, conWrite, conWriteBytes)
import Kernel.Driver.Virtio.Con.Types (ConDevice (..), ConError (..), ConKind (..), conErrorToString)
