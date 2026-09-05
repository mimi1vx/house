{-# LANGUAGE ForeignFunctionInterface #-}

-- | Low-level per-slot helpers over C FFI for virtio-console (ID 3).
-- Validates slot 0..7 and maps C errors to ConError.
module Kernel.Driver.Virtio.Con.Device
  ( conProbe,
    conSubmitRx,
    conSubmitTx,
    conPollUsed,
    conInvalidate,
    conSaveQueues,
    conSaveCtrlQueues,
    conSetPortQueues,
    conSubmitCtrlRx,
    conSubmitCtrlTx,
  )
where

import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import H.Monad (H, liftIO)
import Kernel.Driver.Virtio.Con.Types (ConError (..), ConKind (..))

foreign import ccall unsafe "virtio_con_submit_rx" c_submit_rx :: Int -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_submit_tx" c_submit_tx :: Int -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_poll_used" c_poll_used :: Int -> CInt -> Ptr Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_invalidate" c_invalidate :: Word64 -> Word64 -> IO ()

foreign import ccall unsafe "virtio_con_save_queues" c_save_queues :: Int -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_max_ports" c_max_ports :: Int -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_save_ctrl_queues" c_save_ctrl_queues :: Int -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_submit_ctrl_rx" c_submit_ctrl_rx :: Int -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_submit_ctrl_tx" c_submit_ctrl_tx :: Int -> Word64 -> Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_con_set_port_queues" c_set_port_queues :: Int -> Word32 -> Word32 -> IO CInt

foreign import ccall unsafe "virtio_page_pa" c_pagePa :: Ptr Word8 -> Word64

foreign import ccall unsafe "virtio_probe_slot" c_probe_slot :: Int -> Ptr Word32 -> Ptr Word32 -> Ptr Word32 -> IO Int

cErrToConError :: Int -> ConError
cErrToConError n = case n of
  -1 -> ConBadSlot
  -2 -> ConInvalidArg "BadVersion"
  -3 -> ConInvalidArg "NeedsReset"
  -4 -> ConInvalidArg "FeaturesMismatch"
  -5 -> ConNoSpace
  -6 -> ConInvalidArg "QueueFull"
  -7 -> ConNotReady
  -8 -> ConInvalidArg "SpuriousInt"
  -9 -> ConInvalidArg "EINVAL"
  _ -> ConIoError n

slotValid :: Int -> Bool
slotValid n = n >= 0 && n < 8

-- | Probe slot for virtio-console. device_id 3 is the serial bus in both
-- cases: a pure 2-queue console (cols/rows config only) yields ConConsole,
-- while a multiport bus (max_nr_ports readable, control queues q2/q3)
-- yields ConSerial — this covers virtconsole and virtserialport ports alike,
-- since virtserialport data needs the control handshake to flow.
-- device_id 11 (rproc-serial) reports ConSerial when its config carries a
-- sane port count; any other id yields ConNotCon.
conProbe :: Int -> H (Either ConError ConKind)
conProbe slot
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = liftIO $ alloca $ \pDid -> alloca $ \pVid -> alloca $ \pVer -> alloca $ \pPorts -> do
      r <- c_probe_slot slot pDid pVid pVer
      did <- peek pDid
      let present = r /= 0
      if not present
        then return (Left ConBadSlot)
        else
          if did == 3 || did == 11
            then do
              rp <- c_max_ports slot pPorts
              if rp /= 0
                then
                  if did == 3
                    then return (Right ConConsole)
                    else return (Left (cErrToConError (fromIntegral rp)))
                else do
                  n <- peek pPorts
                  let ports = fromIntegral n :: Int
                  if ports < 1 || ports > 32
                    then
                      if did == 3
                        then return (Right ConConsole)
                        else return (Left (ConInvalidArg "max_nr_ports"))
                    else return (Right (ConSerial ports))
            else return (Left ConNotCon)

-- | Submit RX buffer (single-desc WRITE). dataPtr must be Grant page.
conSubmitRx :: Int -> Ptr Word8 -> H (Either ConError Word32)
conSubmitRx slot dataPtr
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_rx slot pa 4096 pReq
      if r /= 0
        then return (Left (cErrToConError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Submit TX bytes at Grant page start. dataLen 1..4095.
conSubmitTx :: Int -> Ptr Word8 -> Word32 -> H (Either ConError Word32)
conSubmitTx slot dataPtr dataLen
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_tx slot pa dataLen pReq
      if r /= 0
        then return (Left (cErrToConError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Poll used ring for qidx 0 (rx), 1 (tx), 2 (ctrl-rx), 3 (ctrl-tx).
-- Returns Nothing if no completion.
conPollUsed :: Int -> Int -> H (Either ConError (Maybe (Word32, Word32)))
conPollUsed slot qidx
  | not (slotValid slot) = return (Left ConBadSlot)
  | qidx < 0 || qidx > 3 = return (Left (ConInvalidArg "qidx"))
  | otherwise = liftIO $ alloca $ \pId -> alloca $ \pLen -> do
      r <- c_poll_used slot (fromIntegral qidx) pId pLen
      case r of
        1 -> return (Right Nothing)
        0 -> do i <- peek pId; l <- peek pLen; return (Right (Just (i, l)))
        n -> return (Left (cErrToConError (fromIntegral n)))

-- | Invalidate cache range (dc ivac).
conInvalidate :: Word64 -> Word64 -> H ()
conInvalidate pa len = liftIO $ c_invalidate pa len

-- | Save queue PAs for C side (both rx+tx).
conSaveQueues :: Int -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> H (Either ConError ())
conSaveQueues slot rxD rxA rxU txD txA txU qr qt
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = do
      r <- liftIO $ c_save_queues slot rxD rxA rxU txD txA txU qr qt
      if r /= 0 then return (Left (cErrToConError (fromIntegral r))) else return (Right ())

-- | Save control queue PAs for C side (serial q2/q3 only).
conSaveCtrlQueues :: Int -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Word32 -> Word32 -> H (Either ConError ())
conSaveCtrlQueues slot crxD crxA crxU ctxD ctxA ctxU qr qt
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = do
      r <- liftIO $ c_save_ctrl_queues slot crxD crxA crxU ctxD ctxA ctxU qr qt
      if r /= 0 then return (Left (cErrToConError (fromIntegral r))) else return (Right ())

-- | Submit control-RX buffer (single-desc WRITE). dataPtr must be Grant page.
conSubmitCtrlRx :: Int -> Ptr Word8 -> Word32 -> H (Either ConError Word32)
conSubmitCtrlRx slot dataPtr dataLen
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_ctrl_rx slot pa dataLen pReq
      if r /= 0
        then return (Left (cErrToConError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Submit control-TX bytes at Grant page start. dataLen 1..4096.
conSubmitCtrlTx :: Int -> Ptr Word8 -> Word32 -> H (Either ConError Word32)
conSubmitCtrlTx slot dataPtr dataLen
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = liftIO $ alloca $ \pReq -> do
      let pa = c_pagePa dataPtr
      r <- c_submit_ctrl_tx slot pa dataLen pReq
      if r /= 0
        then return (Left (cErrToConError (fromIntegral r)))
        else do v <- peek pReq; return (Right v)

-- | Map the port queue pair (transport indices) used by port RX/TX submits.
-- Console default is 0/1; serial sets the discovered port pair
-- (0/1 for id 0, else 2*id+2/2*id+3) after PORT_ADD discovery.
conSetPortQueues :: Int -> Word32 -> Word32 -> H (Either ConError ())
conSetPortQueues slot rxQ txQ
  | not (slotValid slot) = return (Left ConBadSlot)
  | otherwise = do
      r <- liftIO $ c_set_port_queues slot rxQ txQ
      if r /= 0 then return (Left (cErrToConError (fromIntegral r))) else return (Right ())
