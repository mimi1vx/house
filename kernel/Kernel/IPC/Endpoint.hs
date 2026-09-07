{- | L4 sync rendezvous Endpoint — bounded queue 32, QSem+MVar.
Send blocks until paired recv/reply; trySend is non-blocking fire-and-forget.
Capability slice (Track S, log-only): 'newEndpoint' mints an owner 'CapToken';
'checkCap'/'nsLookupChecked' log mismatches to dmesg but still allow, so no
gate bricks until a deny-by-default landing proves green on both accels.
-}
module Kernel.IPC.Endpoint (
  newEndpoint,
  freeEndpoint,
  send,
  recv,
  reply,
  call,
  callTimeout,
  trySend,
  endpointId,
  lookupEndpoint,
  CapToken (..),
  endpointToken,
  checkCap,
)
where

import Control.Concurrent (MVar, tryPutMVar)
import qualified Control.Concurrent as C
import Control.Exception (bracketOnError)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import H.Concurrency (QSem, newQSem, withQSem)
import qualified H.Concurrency as HC
import H.Monad (H, liftIO, runH)
import H.Mutable (Ref, modifyRef, newRef, readRef, writeRef)
import qualified H.Pages as P
import H.Unsafe (unsafePerformH)
import qualified Kernel.Driver.Dmesg as Dmesg
import Kernel.IPC.Types (
  Endpoint (..),
  EndpointId (..),
  Grant (..),
  IpcError (..),
  Message (..),
 )
import qualified System.Timeout as T

-- | Maximum rendezvous queued per endpoint (HIGH OOM bound).
maxQueueDepth :: Int
maxQueueDepth = 32

-- | Internal rendezvous: message + reply slot.
data Rendezvous = Rendezvous {
  rvMsg :: Message
  , rvReplyVar :: MVar (Either IpcError Message)
  }

-- | Per-endpoint state: FIFO queue of pending rendezvous.
data EndpointState = EndpointState {
  esQueue :: [Rendezvous]
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

-- | Owner capability token minted per endpoint (Track S, log-only slice).
newtype CapToken = CapToken Word64
  deriving (Eq, Show)

{-# NOINLINE endpointOwner #-}
endpointOwner :: Ref (Map EndpointId CapToken)
endpointOwner = unsafePerformH $ newRef Map.empty

{-# NOINLINE capViolations #-}
capViolations :: Ref Word64
capViolations = unsafePerformH $ newRef 0

-- | Count + dmesg a capability/lookup violation. Log-only: never denies.
logCap :: String -> H ()
logCap why = do
  n <- withQSem endpointSem $ do
    c <- readRef capViolations
    let c' = c + 1
    writeRef capViolations c'
    return c'
  Dmesg.dmesgLog ("ipc cap[" ++ show n ++ "]: " ++ why)

-- | Create a new endpoint (capability). Id + owner token minted under QSem.
newEndpoint :: H Endpoint
newEndpoint = withQSem endpointSem $ do
  n <- readRef nextEpId
  writeRef nextEpId (n + 1)
  let eid = EndpointId n
  st <- newRef (EndpointState [])
  modifyRef endpointTable (Map.insert eid st)
  modifyRef endpointOwner (Map.insert eid (CapToken n))
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
        modifyRef endpointOwner (Map.delete eid)
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

-- | Project owner token (Nothing after freeEndpoint).
endpointToken :: Endpoint -> H (Maybe CapToken)
endpointToken (Endpoint eid) = withQSem endpointSem $ do
  m <- readRef endpointOwner
  return (Map.lookup eid m)

{- | Capability check, log-only: anonymous (Nothing) stays silent for compat;
a wrong token or freed id logs to dmesg but still allows. Deny-by-default
lands once ipc ping/grant stay green on both accels with this on.
-}
checkCap :: Endpoint -> Maybe CapToken -> H Bool
checkCap ep@(Endpoint eid) mtok = case mtok of
  Nothing -> return True
  Just t -> do
    owned <- endpointToken ep
    case owned of
      Just o | o == t -> return True
      _ -> do logCap ("mismatch ep=" ++ show eid); return True

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
    Left NoSuchEndpoint -> do logCap ("send to freed ep=" ++ show (epId ep)); return (Left NoSuchEndpoint)
    Left e -> return (Left e)
    -- Bracket the rendezvous: an async exception while blocked in
    -- takeMVar dequeues our entry so no orphaned slot is left behind.
    Right () -> liftIO $ bracketOnError (return ()) (\_ -> runH (dequeueReply replyVar ep)) (\_ -> C.takeMVar replyVar)

-- | Remove one queued rendezvous by reply-slot identity (abort path).
dequeueReply :: MVar (Either IpcError Message) -> Endpoint -> H ()
dequeueReply var ep = withQSem endpointSem $ do
  tbl <- readRef endpointTable
  case Map.lookup (epId ep) tbl of
    Nothing -> return ()
    Just st -> do
      qs <- readRef st
      writeRef st (qs {esQueue = filter ((/= var) . rvReplyVar) (esQueue qs)})

{- | Non-blocking trySend: fire-and-forget enqueue, no reply wait.
Returns Left QueueFull/NoSuchEndpoint immediately, Right () on enqueued.
-}
trySend :: Endpoint -> Message -> H (Either IpcError ())
trySend ep msg = do
  replyVar <- liftIO C.newEmptyMVar
  let rv = Rendezvous msg replyVar
  r <- withQSem endpointSem $ do
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
  case r of
    Left NoSuchEndpoint -> do logCap ("trySend to freed ep=" ++ show (epId ep)); return r
    _ -> return r

{- | Blocking recv: dequeue next rendezvous, returning message + reply handle.
Blocks (polls) until a sender arrives.
-}
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

{- | Bounded call: 'send' with a reply timeout (µs). Times out to WouldBlock +
dmesg instead of blocking forever on a wedged server (CWE-400).
-}
callTimeout :: Int -> Endpoint -> Message -> H (Either IpcError Message)
callTimeout us ep msg = do
  r <- liftIO $ T.timeout us (runH (send ep msg))
  case r of
    Nothing -> do logCap ("call timeout ep=" ++ show (epId ep)); return (Left WouldBlock)
    Just res -> return res

-- | Project endpoint id.
endpointId :: Endpoint -> EndpointId
endpointId = epId

{- | Lookup by numeric id for the EL0 trap path (guest passes the raw id).
EL0 carries no capability token in this slice (same log-only trust as the
EL1 path); token-checked lookup rides a later slice.
-}
lookupEndpoint :: Word64 -> H (Maybe Endpoint)
lookupEndpoint w = withQSem endpointSem $ do
  tbl <- readRef endpointTable
  let eid = EndpointId w
  case Map.lookup eid tbl of
    Nothing -> return Nothing
    Just _ -> return (Just (Endpoint eid))
