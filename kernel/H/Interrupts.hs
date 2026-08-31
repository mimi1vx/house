{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | GIC-native interrupts (aarch64). Replaces the i8259 PIC programming
-- via H.IOPorts and C-side setIRQTable.
module H.Interrupts
  ( IntId (..),
    ppiVirtTimer,
    ppiPhysTimer,
    spi,
    enableInt,
    disableInt,
    eoi,
    installHandler,
    enableInterrupts,
    disableInterrupts,
  )
where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, catch)
import Data.Array.IO (IOArray, newArray, readArray, writeArray)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Ix (Ix)
import Data.Word (Word32)
import Foreign.StablePtr (StablePtr, deRefStablePtr, newStablePtr)
import GHC.Conc (threadDelay)
import H.Monad (H, liftIO, runH)
import System.IO.Unsafe (unsafePerformIO)

-- | GIC INTID (interrupt identifier). PPIs 16-31, SPIs 32+.
newtype IntId = IntId Word32
  deriving (Eq, Ord, Ix, Enum, Show)

ppiVirtTimer, ppiPhysTimer :: IntId
ppiVirtTimer = IntId 27 -- CNTV (virtual timer), confirmed on QEMU virt
ppiPhysTimer = IntId 30 -- CNTP (non-secure physical timer) — QEMU virt reports 30; 29 is secure alias

spi :: Word32 -> IntId
spi n = IntId (32 + n)

-- FFI to GIC/irq helpers (see platform/aarch64/irq.h)
foreign import ccall unsafe "house_gic_enable_int" c_enableInt :: Word32 -> IO ()

foreign import ccall unsafe "house_gic_disable_int" c_disableInt :: Word32 -> IO ()

foreign import ccall unsafe "house_irq_enable" c_irqEnable :: IO ()

foreign import ccall unsafe "house_irq_disable" c_irqDisable :: IO ()

foreign import ccall unsafe "house_irq_pop" c_irqPop :: IO Int

foreign import ccall unsafe "house_irq_pipe_drain" c_irqPipeDrain :: IO ()

enableInt :: IntId -> H ()
enableInt (IntId n) = liftIO $ c_enableInt n

disableInt :: IntId -> H ()
disableInt (IntId n) = liftIO $ c_disableInt n

-- | End-of-interrupt. No-op on aarch64: the ISR already EOIs via
-- ICC_EOIR1_EL1 (EOImode=0 does priority drop+deactivate together).
-- Kept for API compatibility; downstream wrappers no longer need to call it
-- after the handler.
eoi :: IntId -> H ()
eoi _ = return ()

enableInterrupts :: H ()
enableInterrupts = liftIO c_irqEnable

disableInterrupts :: H ()
disableInterrupts = liftIO c_irqDisable

-- Handler table: IntId 0..1023 (GICv3 max ~1020). Stored as StablePtr (H ()).
{-# NOINLINE handlerTable #-}
handlerTable :: IOArray Int (Maybe (StablePtr (H ())))
handlerTable = unsafePerformIO $ newArray (0, 1023) Nothing

{-# NOINLINE dispatcherStarted #-}
dispatcherStarted :: IORef Bool
dispatcherStarted = unsafePerformIO $ newIORef False

-- | Install a handler for an INTID. Idempotently starts the dispatcher thread
-- on first call. The dispatcher blocks in threadWaitRead on the IRQ pipe fd
-- (poll shim proven by phase-2 timerfd) and drains the SPSC ring.
installHandler :: IntId -> H () -> H ()
installHandler (IntId n) handler = liftIO $ do
  sptr <- newStablePtr handler
  let idx = fromIntegral n
  if idx >= 0 && idx < 1024
    then writeArray handlerTable idx (Just sptr)
    else return ()
  -- start dispatcher once
  started <- readIORef dispatcherStarted
  if started
    then return ()
    else do
      writeIORef dispatcherStarted True
      -- fork dispatcher; exceptions inside handler are caught so one bad handler
      -- cannot kill the dispatcher
      _ <- forkIO dispatcherLoop
      return ()
  return ()

-- Dispatcher: drains the SPSC ring the ISR fills and runs the matching handler.
-- Wakeup uses the plan's threadDelay-polled fallback (not threadWaitRead): with
-- the stock single-capability RTS the select-based IO manager plus a sub-tick
-- (1ms) delay stalls other threads' threadDelay. A 20ms poll (two timer ticks)
-- is prompt and provably live; handler latency is bounded by the poll period.
dispatcherLoop :: IO ()
dispatcherLoop = loop
  where
    loop = do
      threadDelay 20000
      c_irqPipeDrain
      drainBounded (64 :: Int)
      loop

    -- Drain at most n entries per wakeup so the dispatcher always yields back
    -- to the scheduler; the ring refills at the timer rate and the next poll
    -- picks up the rest. Unbounded draining here starved other threads'
    -- threadDelay under the single-capability RTS.
    drainBounded 0 = return ()
    drainBounded n = do
      intid <- c_irqPop
      if intid == -1
        then return ()
        else do
          mh <-
            if intid >= 0 && intid < 1024
              then readArray handlerTable intid
              else return Nothing
          case mh of
            Nothing -> drainBounded (n - 1)
            Just sptr -> do
              h <- deRefStablePtr sptr
              (runH h `catch` \(_ :: SomeException) -> return ())
              drainBounded (n - 1)
