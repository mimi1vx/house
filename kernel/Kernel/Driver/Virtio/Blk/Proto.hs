{- | Pure wire format for a virtio-blk request endpoint. No FFI, no driver
machinery: this is the parser for a request an EL1 caller can forge, so it
follows the `Loader.hs` `DT_*` allowlist convention — every rejection carries
a stated reason and returns @Left@, never @ErrorCall@.

Payload never travels inline. Read and write data moves through the grant
page, which is what the Grant mechanism exists for, and it keeps every
request at two words.

Grant ownership on the wire: the client allocates the page, the service thread
uses it, and the **client** frees it. A service thread must never free a page
it did not allocate. 'encodeReq' therefore emits the tag and words only; the
sender attaches its grant with 'attachGrant'.
-}
module Kernel.Driver.Virtio.Blk.Proto (
  BlkReq (..),
  tagCapacity,
  tagRead,
  tagWrite,
  tagError,
  encodeReq,
  attachGrant,
  decodeReq,
  encodeReply,
  decodeReply,
) where

import Data.Bits ((.&.), (.|.))
import Data.Word (Word64)
import Kernel.IPC.Types (Grant, IpcError (..), Message (..), mkMessage)

-- | A blk request: slot plus lba in block units. No payload — that is the grant's job.
data BlkReq
  = ReqCapacity Word64
  | ReqRead Word64 Word64
  | ReqWrite Word64 Word64
  deriving (Eq, Show)

tagCapacity, tagRead, tagWrite, tagError :: Word64
tagCapacity = 0
tagRead = 1
tagWrite = 2
tagError = 0x8000_0000

{- | Encode the tag and words. Two words at most, so the inline bound
('Kernel.IPC.Types.maxMsgWords') is never a constraint. Carries no grant, so
the round-trip of a read/write request is 'attachGrant' then 'decodeReq'; see
the module haddock.
-}
encodeReq :: BlkReq -> Either IpcError Message
encodeReq r = case r of
  ReqCapacity slot -> mk tagCapacity [slot] Nothing
  ReqRead slot lba -> mk tagRead [slot, lba] Nothing
  ReqWrite slot lba -> mk tagWrite [slot, lba] Nothing
  where
    mk = mkMessage

-- | Attach the client's grant to an encoded request, validating the page.
attachGrant :: Grant -> BlkReq -> Either IpcError Message
attachGrant g r = case r of
  ReqCapacity slot -> mk tagCapacity [slot] Nothing
  ReqRead slot lba -> mk tagRead [slot, lba] (Just g)
  ReqWrite slot lba -> mk tagWrite [slot, lba] (Just g)
  where
    mk = mkMessage

{- | Decode a request from a hostile message. Rejects unknown tags, wrong word
counts, and a read/write with no grant, each with its own reason so a malformed
caller is diagnosable rather than just refused.
-}
decodeReq :: Message -> Either IpcError BlkReq
decodeReq msg = case msgTag msg of
  t
    | t == tagCapacity -> capacity
    | t == tagRead -> withGrantReq ReqRead "read"
    | t == tagWrite -> withGrantReq ReqWrite "write"
    | otherwise -> Left (InvalidName ("blk: unknown tag " ++ show t))
  where
    ws = msgWords msg
    capacity = case ws of
      [slot] -> Right (ReqCapacity slot)
      _ -> Left (InvalidName (wrongArity "capacity" 1 ws))
    withGrantReq con op = case (ws, msgGrant msg) of
      ([slot, lba], Just _) -> Right (con slot lba)
      (_, Nothing) -> Left BadGrant
      (_, Just _) -> Left (InvalidName (wrongArity op 2 ws))

{- | Encode a reply. @Right v@ is the success tag plus the value (capacity in
sectors, or a byte count); @Left e@ is the error tag with the errno word folded
in, so a client can tell a failure from a zero-length success.
-}
encodeReply :: Either IpcError Word64 -> Message
encodeReply r = case r of
  Right v -> Message 0 [v] Nothing
  Left e -> Message (tagError .|. errnoWord e) [] Nothing

-- | Decode a reply, the mirror of 'encodeReply'.
decodeReply :: Message -> Either IpcError Word64
decodeReply msg
  | msgTag msg .&. tagError /= 0 = Left (InvalidName "blk: error reply")
  | otherwise = case msgWords msg of
      [v] -> Right v
      ws -> Left (InvalidName (wrongArity "reply" 1 ws))

wrongArity :: String -> Int -> [Word64] -> String
wrongArity op want ws =
  "blk: " ++ op ++ " takes " ++ show want ++ " word(s), got " ++ show (length ws)

-- | Stable errno word per IPC error, so a client sees a value it can branch on.
errnoWord :: IpcError -> Word64
errnoWord e = case e of
  NoSuchEndpoint -> 2 -- ENOENT
  WouldBlock -> 11 -- EAGAIN
  BadGrant -> 14 -- EFAULT
  QueueFull -> 11 -- EAGAIN
  NotOwner -> 1 -- EPERM
  NameExists -> 17 -- EEXIST
  NameNotFound -> 2 -- ENOENT
  InvalidName _ -> 22 -- EINVAL
