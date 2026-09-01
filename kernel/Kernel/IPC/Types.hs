-- | IPC Types: L4 sync rendezvous primitives.
-- Copy + page-grant payload, bounded words, capability Endpoint.
module Kernel.IPC.Types
  ( Perm (..),
    Grant (..),
    IpcError (..),
    EndpointId (..),
    Message (..),
    Endpoint (..),
    mkMessage,
    isValidGrant,
    maxMsgWords,
    maxNameLen,
  )
where

import Data.Word (Word64, Word8)
import qualified H.Pages as P

-- | Maximum inline words per message (header copy, bulk via grant).
maxMsgWords :: Int
maxMsgWords = 8

-- | Maximum registry name length (matches H.FileSystem.splitPath 255).
maxNameLen :: Int
maxNameLen = 255

-- | Grant permissions for a moved page.
data Perm = RO | RW
  deriving (Eq, Show)

-- | Page grant — ownership transfer of one 'P.Page Word8'.
-- Invariant: 'grantPage' satisfies 'P.validPage' and is pageSize-aligned.
data Grant = Grant
  { grantPage :: P.Page Word8,
    grantPerm :: Perm
  }
  deriving (Eq, Show)

-- | IPC error codes returned as 'Left' from send/call.
data IpcError
  = NoSuchEndpoint
  | WouldBlock
  | BadGrant
  | QueueFull
  | NotOwner
  | NameExists
  | NameNotFound
  | InvalidName String
  deriving (Eq, Show)

-- | Endpoint identifier — mint under QSem, not forgeable by construction.
newtype EndpointId = EndpointId Word64
  deriving (Eq, Ord, Show)

-- | Synchronous rendezvous message: tag + up to 8 words + optional grant.
data Message = Message
  { msgTag :: Word64,
    msgWords :: [Word64],
    msgGrant :: Maybe Grant
  }
  deriving (Eq, Show)

-- | Endpoint handle — duplicable capability (Id generated under QSem).
-- Actual queue lives in 'Kernel.IPC.Endpoint.EndpointState'.
data Endpoint = Endpoint
  { epId :: EndpointId
  }
  deriving (Eq, Show)

-- | Smart constructor: total, rejects length>8 with Left.
-- Grant validity is checked via 'P.validPage'.
mkMessage :: Word64 -> [Word64] -> Maybe Grant -> Either IpcError Message
mkMessage tag ws mg
  | length ws > maxMsgWords = Left QueueFull
  | otherwise = case mg of
      Nothing -> Right (Message tag ws Nothing)
      Just g ->
        if isValidGrant g
          then Right (Message tag ws (Just g))
          else Left BadGrant

-- | Validate grant page alignment and range.
isValidGrant :: Grant -> Bool
isValidGrant (Grant p _) = P.validPage p
