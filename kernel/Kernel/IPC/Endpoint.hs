-- | L4 sync rendezvous Endpoint — bounded queue 32, QSem+MVar.
-- Send blocks until paired recv/reply; trySend is non-blocking fire-and-forget.
module Kernel.IPC.Endpoint
  ( newEndpoint,
    freeEndpoint,
    send,
    recv,
    reply,
    call,
    trySend,
    endpointId,
  )
where

import Control.Concurrent (MVar, tryPutMVar)
import qualified Control.Concurrent as C
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import H.Concurrency (QSem, newQSem, withQSem)
import qualified H.Concurrency as HC
import H.Monad (H, liftIO)
import H.Mutable (Ref, modifyRef, newRef, readRef, writeRef)
import qualified H.Pages as P
import H.Unsafe (unsafePerformH)
import Kernel.IPC.Types
  ( Endpoint (..),
    EndpointId (..),
    Grant (..),
    IpcError (..),
    Message (..),
  )

-- | Maximum rendezvous queued per endpoint (HIGH OOM bound).
maxQueueDepth :: Int
maxQueueDepth = 32

-- | Internal rendezvous: message + reply slot.
data Rendezvous = Rendezvous
  { rvMsg :: Message,
    rvReplyVar :: MVar (Either IpcError Message)
  }

-- | Per-endpoint state: FIFO queue of pending rendezvous.
data EndpointState = EndpointState
  { esQueue :: [Rendezvous]
  }

-- Global table ---------------------------------------------------------------

{-# NOINLINE endpointTable #-}
endpointTable :: Ref (Map EndpointId (Ref EndpointState))
endpointTable = unsafePerformH $ newRef Map.empty

{-# NOINLINE endpointSem #-}
endpointSem :: QSem
endpointSem = unsafePerformH $ newQSem 1

{-# NOINLINE nextEpId #-}
nextEpId :: Ref Word64
nextEpId = unsafePerformH $ newRef 0

-- | Create a new endpoint (capability). Id minted under QSem.
newEndpoint :: H Endpoint
newEndpoint = withQSem endpointSem $ do
  n <- readRef nextEpId
  writeRef nextEpId (n + 1)
  let eid = EndpointId n
  st <- newRef (EndpointState [])
  modifyRef endpointTable (Map.insert eid st)
  return (Endpoint eid)

-- | Destroy endpoint, waking pending senders with NoSuchEndpoint and freeing grant pages.
freeEndpoint :: Endpoint -> H ()
freeEndpoint (Endpoint eid) = do
  mSt <- withQSem endpointSem $ do
    tbl <- readRef endpointTable
    case Map.lookup eid tbl of
      Nothing -> return Nothing
      Just st -> do
        writeRef endpointTable (Map.delete eid tbl)
        return (Just st)
  case mSt of
    Nothing -> return ()
    Just st -> do
      qs <- readRef st
      let q = esQueue qs
      mapM_ wakeNoSuch q
      writeRef st (EndpointState [])
  where
    wakeNoSuch rv = do
      case msgGrant (rvMsg rv) of
        Nothing -> return ()
        Just gg -> P.freePage (grantPage gg)
      _ <- liftIO $ tryPutMVar (rvReplyVar rv) (Left NoSuchEndpoint)
      return ()

-- | Blocking send: enqueue and wait for reply. Returns Left on QueueFull or NoSuchEndpoint.
send :: Endpoint -> Message -> H (Either IpcError Message)
send ep msg = do
  replyVar <- liftIO C.newEmptyMVar
  let rv = Rendezvous msg replyVar
  enqRes <- withQSem endpointSem $ do
    tbl <- readRef endpointTable
    case Map.lookup (epId ep) tbl of
      Nothing -> return (Left NoSuchEndpoint)
      Just st -> do
        qs <- readRef st
        if length (esQueue qs) >= maxQueueDepth
          then return (Left QueueFull)
          else do
            writeRef st (qs {esQueue = esQueue qs ++ [rv]})
            return (Right ())
  case enqRes of
    Left e -> return (Left e)
    Right () -> liftIO $ C.takeMVar replyVar

-- | Non-blocking trySend: fire-and-forget enqueue, no reply wait.
-- Returns Left QueueFull/NoSuchEndpoint immediately, Right () on enqueued.
trySend :: Endpoint -> Message -> H (Either IpcError ())
trySend ep msg = do
  replyVar <- liftIO C.newEmptyMVar
  let rv = Rendezvous msg replyVar
  withQSem endpointSem $ do
    tbl <- readRef endpointTable
    case Map.lookup (epId ep) tbl of
      Nothing -> return (Left NoSuchEndpoint)
      Just st -> do
        qs <- readRef st
        if length (esQueue qs) >= maxQueueDepth
          then return (Left QueueFull)
          else do
            writeRef st (qs {esQueue = esQueue qs ++ [rv]})
            return (Right ())

-- | Blocking recv: dequeue next rendezvous, returning message + reply handle.
-- Blocks (polls) until a sender arrives.
recv :: Endpoint -> H (Message, MVar (Either IpcError Message))
recv ep = loop
  where
    loop = do
      mRv <- withQSem endpointSem $ do
        tbl <- readRef endpointTable
        case Map.lookup (epId ep) tbl of
          Nothing -> return (Left NoSuchEndpoint)
          Just st -> do
            qs <- readRef st
            case esQueue qs of
              [] -> return (Right Nothing)
              (rv : rest) -> do
                writeRef st (qs {esQueue = rest})
                return (Right (Just rv))
      case mRv of
        Left _ -> do
          v <- liftIO C.newEmptyMVar
          _ <- liftIO $ C.putMVar v (Left NoSuchEndpoint)
          return (Message 0 [] Nothing, v)
        Right Nothing -> do
          HC.threadDelay 1000
          loop
        Right (Just rv) -> return (rvMsg rv, rvReplyVar rv)

-- | Reply to a rendezvous (unblocks sender).
reply :: MVar (Either IpcError Message) -> Either IpcError Message -> H ()
reply var res = do
  _ <- liftIO $ tryPutMVar var res
  return ()

-- | Call is alias for send (sync RPC).
call :: Endpoint -> Message -> H (Either IpcError Message)
call = send

-- | Project endpoint id.
endpointId :: Endpoint -> EndpointId
endpointId = epId
