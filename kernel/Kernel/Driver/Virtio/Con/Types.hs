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
    decodeCtrlEvent,
    portQueuesFor,
  )
where

import Data.Word (Word8)
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

-- | Total control-event decoder: {id LE32, event LE16, value LE16}.
-- Needs 8 bytes; Nothing on short input (never index before length check).
decodeCtrlEvent :: [Word8] -> Maybe (Int, Int)
decodeCtrlEvent (b0 : b1 : b2 : b3 : b4 : b5 : _ : _ : _) =
  Just (pid, ev)
  where
    pid = fromIntegral b0 + fromIntegral b1 * 256 + fromIntegral b2 * 65536 + fromIntegral b3 * 16777216
    ev = fromIntegral b4 + fromIntegral b5 * 256
decodeCtrlEvent _ = Nothing

-- | Transport queue pair for a serial port id: port 0 on 0/1,
-- port N>=1 on 2*N+2/2*N+3. Total: Nothing outside 0..31.
portQueuesFor :: Int -> Maybe (Int, Int)
portQueuesFor pid
  | pid < 0 || pid > 31 = Nothing
  | pid == 0 = Just (0, 1)
  | otherwise =
      let rx = 2 * pid + 2
          tx = rx + 1
       in if tx <= 127 then Just (rx, tx) else Nothing
