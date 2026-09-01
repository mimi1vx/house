-- | Driver framework types.
module Kernel.Driver.Types
  ( DriverKind (..),
    DriverInfo (..),
    DriverError (..),
    driverErrorToIpcError,
    showDriverInfo,
  )
where

import H.Interrupts (IntId)
import Kernel.IPC.Types (Endpoint, IpcError)
import qualified Kernel.IPC.Types as IPC

-- | Kind of driver (informational for @lsdev@).
data DriverKind
  = VirtioMMIO
  | PL011
  | RamFS
  | Unknown
  deriving (Eq, Show)

-- | Metadata kept per registered driver. Invariants: @diName@ non-empty,
-- no '/', @<=255@ chars; @diEndpoint@ is a valid 'Endpoint' minted via
-- 'Kernel.IPC.Endpoint.newEndpoint'; @diIntId@ is @Just (spi n)@ iff
-- @diKind == VirtioMMIO@.
data DriverInfo = DriverInfo
  { diName :: String,
    diEndpoint :: Endpoint,
    diKind :: DriverKind,
    diIntId :: Maybe IntId,
    diSlot :: Maybe Int
  }
  deriving (Eq, Show)

-- | Registry-level errors (maps from 'IpcError' without exposing it directly).
data DriverError
  = AlreadyRegistered
  | NotFound
  | InvalidName String
  deriving (Eq, Show)

-- | Map 'DriverError' to the underlying 'IpcError' for IPC-aware callers.
driverErrorToIpcError :: DriverError -> IpcError
driverErrorToIpcError AlreadyRegistered = IPC.NameExists
driverErrorToIpcError NotFound = IPC.NameNotFound
driverErrorToIpcError (InvalidName s) = IPC.InvalidName s

-- | Human-readable one-liner for @lsdev@ output.
showDriverInfo :: DriverInfo -> String
showDriverInfo di =
  diName di
    ++ " kind="
    ++ show (diKind di)
    ++ " endpoint="
    ++ show (diEndpoint di)
    ++ maybe "" (\i -> " irq=" ++ show i) (diIntId di)
    ++ maybe "" (\s -> " slot=" ++ show s) (diSlot di)
