{-# LANGUAGE ForeignFunctionInterface #-}

-- | Virtio-MMIO transport — device-agnostic negotiation + queue + IRQ->Endpoint.
-- Lock order: virtioSem distinct from drvSem/nsSem/epSem; never hold virtioSem across nsRegister.
module Kernel.Driver.Virtio.Transport
  ( VirtioDevice (..),
    virtioInit,
    virtioTeardown,
    virtioNotify,
    virtioInterruptStatus,
    virtioAck,
    virtioGetStatus,
    virtioStatusAll,
    virtioLookup,
  )
where

import Data.Bits ((.&.), (.|.))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import H.Concurrency (QSem, newQSem, withQSem)
import H.Interrupts (IntId, spi)
import H.Monad (H, liftIO)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import qualified Kernel.Driver.Dmesg as Dmesg
import qualified Kernel.Driver.GIC as DGIC
import qualified Kernel.Driver.IRQ as DIRQ
import Kernel.Driver.Virtio.Queue (VirtQueue, allocQueue, freeQueue, queueAvailPa, queueDescPa, queueUsedPa)
import Kernel.Driver.Virtio.Types (VirtioError (..), VirtioFeature (..), cErrToVirtioError, virtioFeatureMask)
import qualified Kernel.IPC.Endpoint as IPC
import qualified Kernel.IPC.Nameservice as NS
import Kernel.IPC.Types (Endpoint)

-- | Device record kept in transport map.
data VirtioDevice = VirtioDevice
  { vdSlot :: Int,
    vdId :: Word32,
    vdVendor :: Word32,
    vdStatus :: Word32,
    vdIntId :: IntId,
    vdQueue :: Maybe VirtQueue,
    vdEndpoint :: Maybe Endpoint
  }
  deriving (Eq, Show)

{-# NOINLINE virtioMap #-}
virtioMap :: Ref (Map Int VirtioDevice)
virtioMap = unsafePerformH $ newRef Map.empty

{-# NOINLINE virtioSem #-}
virtioSem :: QSem
virtioSem = unsafePerformH $ newQSem 1

-- FFI
foreign import ccall unsafe "virtio_probe_slot" c_probe_slot :: Int -> Ptr Word32 -> Ptr Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_transport_init" c_init :: Int -> Ptr Word32 -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_transport_set_features" c_set_features :: Int -> Word64 -> IO CInt

foreign import ccall unsafe "virtio_transport_get_status" c_get_status :: Int -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_transport_set_status" c_set_status :: Int -> Word32 -> IO CInt

foreign import ccall unsafe "virtio_transport_queue_max" c_queue_max :: Int -> Ptr Word32 -> IO CInt

foreign import ccall unsafe "virtio_transport_queue_setup" c_queue_setup :: Int -> Word64 -> Word64 -> Word64 -> Word32 -> IO CInt

foreign import ccall unsafe "virtio_transport_notify" c_notify :: Int -> Word32 -> IO CInt

foreign import ccall unsafe "virtio_transport_interrupt_status" c_int_status :: Int -> IO Word32

foreign import ccall unsafe "virtio_transport_ack" c_ack :: Int -> Word32 -> IO ()

foreign import ccall unsafe "virtio_transport_dc_flush" c_dc_flush :: Word64 -> Word64 -> IO ()

foreign import ccall unsafe "virtio_blk_save_queue" c_save_blk_queue :: Int -> Word64 -> Word64 -> Word64 -> Word32 -> IO ()

wantedMask :: Word64
wantedMask = virtioFeatureMask [VirtioFVersion1, VirtioFRingEventIdx]

slotValid :: Int -> Bool
slotValid n = n >= 0 && n < 8

-- | Init one slot: probe, negotiate, allocate queue, enable SPI+IRQ->Endpoint.
virtioInit :: Int -> H (Either VirtioError VirtioDevice)
virtioInit slot
  | not (slotValid slot) = return (Left BadSlot)
  | otherwise = do
      -- Check already initialized
      mExisting <- withQSem virtioSem $ do
        m <- readRef virtioMap
        return (Map.lookup slot m)
      case mExisting of
        Just _ -> return (Left (InvalidArg "already initialized"))
        Nothing -> do
          -- Probe device presence
          probeRes <- liftIO $ alloca $ \pDid -> alloca $ \pVid -> alloca $ \pVer -> do
            r <- c_probe_slot slot pDid pVid pVer
            did <- peek pDid
            vid <- peek pVid
            return (r, did, vid)
          let (present, did, vid) = probeRes
          if present == 0
            then return (Left BadSlot)
            else do
              -- Init transport (ACK|DRIVER)
              initRes <- liftIO $ alloca $ \pLo -> alloca $ \pHi -> c_init slot pLo pHi
              if initRes /= 0
                then do Dmesg.dmesgLog ("virtio init slot " ++ show slot ++ " initRes=" ++ show initRes); return (Left (cErrToVirtioError (fromIntegral initRes)))
                else do
                  featRes <- liftIO $ c_set_features slot wantedMask
                  if featRes /= 0
                    then do
                      _ <- liftIO $ c_set_status slot 0x80
                      Dmesg.dmesgLog ("virtio featRes slot " ++ show slot ++ "=" ++ show featRes)
                      return (Left (cErrToVirtioError (fromIntegral featRes)))
                    else do
                      -- Queue max
                      qmaxRes <- liftIO $ alloca $ \pMax -> do
                        r <- c_queue_max slot pMax
                        if r /= 0 then return (Left r) else do v <- peek pMax; return (Right v)
                      case qmaxRes of
                        Left e -> do Dmesg.dmesgLog ("virtio qmaxRes slot " ++ show slot ++ "=" ++ show e); return (Left (cErrToVirtioError (fromIntegral e)))
                        Right qmax -> do
                          let qsize = min qmax 64
                          if qsize == 0
                            then return (Left (InvalidArg "QueueNumMax 0"))
                            else do
                              qRes <- allocQueue qsize
                              case qRes of
                                Left _ -> return (Left NoSpace)
                                Right vq -> do
                                  -- Flush before setup (WB)
                                  liftIO $ c_dc_flush (queueDescPa vq) 4096
                                  liftIO $ c_dc_flush (queueAvailPa vq) 4096
                                  liftIO $ c_dc_flush (queueUsedPa vq) 4096
                                  setupRes <- liftIO $ c_queue_setup slot (queueDescPa vq) (queueAvailPa vq) (queueUsedPa vq) qsize
                                  if setupRes /= 0
                                    then do
                                      qmaxDbg <- liftIO $ alloca $ \pM -> do _ <- c_queue_max slot pM; peek pM
                                      stDbg <- liftIO $ alloca $ \pS -> do _ <- c_get_status slot pS; peek pS
                                      Dmesg.dmesgLog ("virtio setupRes slot " ++ show slot ++ "=" ++ show setupRes ++ " qsize=" ++ show qsize ++ " qmax=" ++ show qmaxDbg ++ " status=" ++ show stDbg)
                                      freeQueue vq
                                      return (Left (cErrToVirtioError (fromIntegral setupRes)))
                                    else do
                                      liftIO $ c_save_blk_queue slot (queueDescPa vq) (queueAvailPa vq) (queueUsedPa vq) qsize
                                      -- Set DRIVER_OK
                                      stRes <- liftIO $ alloca $ \pSt -> do
                                        _ <- c_get_status slot pSt
                                        st <- peek pSt
                                        let st2 = st .|. 0x04
                                        r <- c_set_status slot st2
                                        return r
                                      if stRes /= 0
                                        then do Dmesg.dmesgLog ("virtio stRes slot " ++ show slot ++ "=" ++ show stRes); freeQueue vq; return (Left (cErrToVirtioError (fromIntegral stRes)))
                                        else do
                                          -- Verify not FAILED
                                          stCheck <- liftIO $ alloca $ \pSt -> do _ <- c_get_status slot pSt; peek pSt
                                          if (stCheck .&. 0x80) /= 0
                                            then do freeQueue vq; return (Left NeedsReset)
                                            else do
                                              -- GIC + Endpoint wiring (outside virtioSem)
                                              DGIC.enableSpi (fromIntegral (16 + slot))
                                              ep <- IPC.newEndpoint
                                              _ <- DIRQ.registerIrqForwarding (spi (fromIntegral (16 + slot))) ep
                                              _ <- NS.nsRegister ("virtio-slot" ++ show slot) ep
                                              let intid = spi (fromIntegral (16 + slot))
                                              let dev = VirtioDevice slot did vid stCheck intid (Just vq) (Just ep)
                                              withQSem virtioSem $ do
                                                m <- readRef virtioMap
                                                writeRef virtioMap (Map.insert slot dev m)
                                              Dmesg.dmesgLog ("virtio slot " ++ show slot ++ ": init ok device_id=" ++ show did ++ " qsize=" ++ show qsize)
                                              return (Right dev)

-- | Teardown slot.
virtioTeardown :: Int -> H (Either VirtioError ())
virtioTeardown slot
  | not (slotValid slot) = return (Left BadSlot)
  | otherwise = do
      mDev <- withQSem virtioSem $ do
        m <- readRef virtioMap
        case Map.lookup slot m of
          Nothing -> return Nothing
          Just dev -> do writeRef virtioMap (Map.delete slot m); return (Just dev)
      case mDev of
        Nothing -> return (Left (InvalidArg "not initialized"))
        Just dev -> do
          DGIC.disableSpi (fromIntegral (16 + slot))
          case vdEndpoint dev of
            Just ep -> do
              _ <- NS.nsUnregister ("virtio-slot" ++ show slot)
              IPC.freeEndpoint ep
            Nothing -> return ()
          case vdQueue dev of
            Just vq -> freeQueue vq
            Nothing -> return ()
          _ <- liftIO $ c_set_status slot 0
          Dmesg.dmesgLog ("virtio slot " ++ show slot ++ ": teardown")
          return (Right ())

-- | Notify queue 0.
virtioNotify :: Int -> Word32 -> H (Either VirtioError ())
virtioNotify slot qidx
  | not (slotValid slot) = return (Left BadSlot)
  | otherwise = do
      mDev <- withQSem virtioSem $ do m <- readRef virtioMap; return (Map.lookup slot m)
      case mDev of
        Nothing -> return (Left (InvalidArg "not initialized"))
        Just dev -> case vdQueue dev of
          Nothing -> return (Left NotReady)
          Just vq -> do
            liftIO $ c_dc_flush (queueDescPa vq) 4096
            liftIO $ c_dc_flush (queueAvailPa vq) 4096
            r <- liftIO $ c_notify slot qidx
            if r /= 0 then return (Left (cErrToVirtioError (fromIntegral r))) else return (Right ())

-- | Read InterruptStatus.
virtioInterruptStatus :: Int -> H Word32
virtioInterruptStatus slot
  | not (slotValid slot) = return 0
  | otherwise = liftIO $ c_int_status slot

-- | Ack interrupt.
virtioAck :: Int -> Word32 -> H ()
virtioAck slot mask
  | not (slotValid slot) = return ()
  | otherwise = liftIO $ c_ack slot mask

-- | Get status word.
virtioGetStatus :: Int -> H (Either VirtioError Word32)
virtioGetStatus slot
  | not (slotValid slot) = return (Left BadSlot)
  | otherwise = do
      r <- liftIO $ alloca $ \pSt -> do
        rc <- c_get_status slot pSt
        if rc /= 0 then return (Left (cErrToVirtioError (fromIntegral rc))) else do v <- peek pSt; return (Right v)
      return r

-- | Lookup device by slot (if initialized).
virtioLookup :: Int -> H (Maybe VirtioDevice)
virtioLookup slot
  | not (slotValid slot) = return Nothing
  | otherwise = withQSem virtioSem $ do m <- readRef virtioMap; return (Map.lookup slot m)

-- | All slots status.
virtioStatusAll :: H [(Int, Word32)]
virtioStatusAll = mapM getOne [0 .. 7]
  where
    getOne s = do
      r <- virtioGetStatus s
      case r of
        Right v -> return (s, v)
        Left _ -> return (s, 0)
