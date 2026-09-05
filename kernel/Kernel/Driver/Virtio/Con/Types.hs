{-# LANGUAGE ForeignFunctionInterface #-}

-- | Virtio-console (ID 3) types — errors and device record.
-- Bounds: slot 0..7, payload <= 4096-1 per Grant page, shell echo truncates to 256.
-- Multiport serial buses (also ID 3, max_nr_ports readable) drive port 0
-- plus control queues 2/3; ID 11 is accepted the same way when sane.
module Kernel.Driver.Virtio.Con.Types
  ( ConError (..),
    conErrorToString,
    ConDevice (..),
    ConKind (..),
  )
where

import H.Interrupts (IntId)
import Kernel.Driver.Virtio.Queue (VirtQueue)
import Kernel.IPC.Types (Endpoint)

-- | Console subsystem errors (total decoder).
data ConError
  = ConBadSlot
  | ConNotCon
  | ConNotReady
  | ConNoSpace
  | ConIoError Int
  | ConInvalidArg String
  deriving (Eq, Show)

-- | Human string for error (shell).
conErrorToString :: ConError -> String
conErrorToString ConBadSlot = "ConBadSlot"
conErrorToString ConNotCon = "ConNotCon"
conErrorToString ConNotReady = "ConNotReady"
conErrorToString ConNoSpace = "ConNoSpace"
conErrorToString (ConIoError n) = "ConIoError " ++ show n
conErrorToString (ConInvalidArg s) = "ConInvalidArg: " ++ s

-- | Virtio-console device record.
data ConDevice = ConDevice
  { conSlot :: Int,
    conIntId :: IntId,
    conEndpoint :: Endpoint,
    conRxQueue :: VirtQueue,
    conTxQueue :: VirtQueue,
    conCtrl :: Maybe (VirtQueue, VirtQueue)
  }
  deriving (Eq, Show)

-- | Console kind from probe: single-port console or serial multipoint.
-- The Int is max_nr_ports (1..32); the PORT_ADD-discovered id is driven.
data ConKind
  = ConConsole
  | ConSerial Int
  deriving (Eq, Show)
