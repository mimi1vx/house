{- | Page-grant ownership transfer over H.Pages pool (4K per grant).
Copy header + grant-move bulk; ENOSPC on exhaustion.
-}
module Kernel.IPC.Grant (
  grantAlloc,
  grantFree,
  withGrantAllocated,
  grantSend,
  grantRecv,
)
where

import Control.Exception (bracketOnError)
import H.Monad (H, liftIO, runH)
import H.Pages qualified as P
import Kernel.IPC.Types (Grant (..), IpcError (..), Message (..), Perm (..), isValidGrant)

-- | Allocate one zeroed page as RW grant. ENOSPC maps to BadGrant/QueueFull.
grantAlloc :: H (Either IpcError Grant)
grantAlloc = do
  mp <- P.allocPage
  case mp of
    Nothing -> return (Left BadGrant)
    Just p -> do
      P.zeroPage p
      return (Right (Grant p RW))

-- | Free a grant page back to pool. Caller must own grant.
grantFree :: Grant -> H ()
grantFree (Grant p _) = P.freePage p

{- | Run @use@ with an allocated grant, freeing on async exception. Normal
error returns still free explicitly at the site; this only covers throws
between allocation and release.
-}
withGrantAllocated :: Grant -> (Grant -> H a) -> H a
withGrantAllocated g use =
  liftIO (bracketOnError (return g) (runH . grantFree) (runH . use))

-- | Validate grant for send: validPage and pageSize aligned.
grantSend :: Grant -> Either IpcError Grant
grantSend g
  | isValidGrant g = Right g
  | otherwise = Left BadGrant

-- | Extract grant from received message; caller gains ownership.
grantRecv :: Message -> Maybe Grant
grantRecv = msgGrant
