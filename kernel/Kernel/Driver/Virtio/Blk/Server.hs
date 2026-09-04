{-# LANGUAGE ForeignFunctionInterface #-}
{-# OPTIONS_GHC -Wno-unused-top-binds -Wno-unused-imports #-}

-- | Virtio-blk server — Endpoint + Grant, 4K blocks (wire 512 sectors), IRQ->Endpoint.
-- Lock order: blkSem distinct from virtioSem/drvSem/nsSem/epSem; never hold blkSem across nsRegister.
module Kernel.Driver.Virtio.Blk.Server
  ( BlkDevice (..),
    blkServerInit,
    blkServerTeardown,
    blkReadBlocks,
    blkWriteBlocks,
    blkGetCapacity,
    blkReadBlockBytes,
    blkWriteBlockBytes,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word
  ( Word32,
    Word64,
    Word8,
  )
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peek, poke)
import H.Concurrency (QSem, newQSem, withQSem)
import qualified H.Concurrency as HC
import H.Interrupts (IntId)
import H.Monad (H, liftIO)
import H.Mutable (Ref, newRef, readRef, writeRef)
import H.Unsafe (unsafePerformH)
import qualified Kernel.Driver.Dmesg as Dmesg
import qualified Kernel.Driver.Registry as DrvReg
import Kernel.Driver.Types (DriverKind (..))
import Kernel.Driver.Virtio.Blk.Device (blkPollUsed, blkProbeCapacity, blkSubmitRead, blkSubmitWrite)
import Kernel.Driver.Virtio.Blk.Types (BlkError (..), validateLba)
import qualified Kernel.Driver.Virtio.Transport as VTrans
import qualified Kernel.IPC.Grant as G
import Kernel.IPC.Types (Endpoint, Grant (..))

foreign import ccall unsafe "house_uptime_ns" c_uptime_ns :: IO Word64

busyDelayUs :: Int -> H ()
busyDelayUs us = liftIO $ do
  t0 <- c_uptime_ns
  let target = t0 + fromIntegral us * 1000
  let loop = do
        t <- c_uptime_ns
        if t < target then loop else return ()
  loop

-- | Blk device record (mirrors VirtioDevice but block-specific).
data BlkDevice = BlkDevice
  { blkSlot :: Int,
    blkCapacity :: Word64,
    blkIntId :: IntId,
    blkEndpoint :: Endpoint,
    blkQueueSize :: Word32
  }
  deriving (Eq, Show)

{-# NOINLINE blkMap #-}
blkMap :: Ref (Map Int BlkDevice)
blkMap = unsafePerformH $ newRef Map.empty

{-# NOINLINE blkSem #-}
blkSem :: QSem
blkSem = unsafePerformH $ newQSem 1

foreign import ccall unsafe "virtio_transport_dc_flush" c_dc_flush :: Word64 -> Word64 -> IO ()

foreign import ccall unsafe "virtio_page_pa" c_pagePa :: Ptr Word8 -> Word64

foreign import ccall unsafe "virtio_blk_invalidate" c_invalidate :: Word64 -> Word64 -> IO ()

foreign import ccall unsafe "virtio_blk_reset_slot" c_reset_slot :: Int -> IO ()

slotValid :: Int -> Bool
slotValid n = n >= 0 && n < 8

-- | Copy Haskell String into Grant page (up to 4096, zero pad).
fillGrant :: Grant -> String -> H ()
fillGrant (Grant p _) s = liftIO $ do
  let bytes = map (fromIntegral . fromEnum) s :: [Word8]
      n = min (length bytes) 4096
      bounded = take n bytes
  mapM_ (\(i, b) -> poke (p `plusPtr` i) b) (zip [0 ..] bounded)
  mapM_ (\i -> poke (p `plusPtr` i) (0 :: Word8)) [n .. 4095]

-- | Extract string from Grant page (up to 4096, stops at first 0, truncate to 256 for shell).
grantToString :: Grant -> H String
grantToString (Grant p _) = liftIO $ do
  bytes <- mapM (\i -> peek (p `plusPtr` i) :: IO Word8) [0 .. 4095]
  let strBytes = takeWhile (/= 0) bytes
      limited = take 256 strBytes
  return (map (toEnum . fromIntegral) limited)

-- | Invalidate Grant page after device write.
invalidateGrant :: Grant -> H ()
invalidateGrant (Grant p _) = liftIO $ c_invalidate (c_pagePa p) 4096

-- | Helper: wait for completion of req id with bounded poll.
waitForCompletion :: Int -> Word32 -> Grant -> H (Either BlkError ())
waitForCompletion slot reqId grant = loop (200 :: Int)
  where
    loop 0 = return (Left (BlkIoError 99))
    loop n = do
      busyDelayUs 2000
      r <- blkPollUsed slot
      case r of
        Left e -> return (Left e)
        Right Nothing -> loop (n - 1)
        Right (Just (cid, st)) ->
          if cid /= reqId
            then loop (n - 1)
            else
              if st == 0
                then do
                  invalidateGrant grant
                  return (Right ())
                else return (Left (BlkIoError (fromIntegral st)))

-- | Init blk server for slot. Direct Grant path (no forked recv loop in this slice).
blkServerInit :: Int -> H (Either BlkError BlkDevice)
blkServerInit slot
  | not (slotValid slot) = return (Left BlkBadSlot)
  | otherwise = do
      mExisting <- withQSem blkSem $ do m <- readRef blkMap; return (Map.lookup slot m)
      case mExisting of
        Just _ -> return (Left (BlkInvalidArg "already initialized"))
        Nothing -> do
          capCheck <- blkProbeCapacity slot
          case capCheck of
            Left e -> return (Left e)
            Right cap -> do
              mVirt <- VTrans.virtioLookup slot
              eVirt <- case mVirt of
                Just dev -> return (Right dev)
                Nothing -> VTrans.virtioInit slot
              case eVirt of
                Left ve -> return (Left (BlkInvalidArg (show ve)))
                Right vdev -> do
                  let mEp = VTrans.vdEndpoint vdev
                      mQ = VTrans.vdQueue vdev
                  case (mEp, mQ) of
                    (Just ep, Just _vq) -> do
                      liftIO $ c_reset_slot slot
                      let qsz = 64
                          intid = VTrans.vdIntId vdev
                          blkDev = BlkDevice slot cap intid ep qsz
                      rReg <- DrvReg.registerDriver ("virtio-blk" ++ show slot) ep (Just intid) VirtioMMIO
                      case rReg of
                        Left _ -> return (Left (BlkInvalidArg "register failed"))
                        Right () -> do
                          withQSem blkSem $ do
                            m2 <- readRef blkMap
                            writeRef blkMap (Map.insert slot blkDev m2)
                          Dmesg.dmesgLog ("blk slot " ++ show slot ++ ": init ok capacity=" ++ show cap ++ " sectors (" ++ show (cap `div` 8) ++ " blocks)")
                          return (Right blkDev)
                    _ -> return (Left BlkNotReady)

-- | Teardown blk server.
blkServerTeardown :: Int -> H (Either BlkError ())
blkServerTeardown slot
  | not (slotValid slot) = return (Left BlkBadSlot)
  | otherwise = do
      mDev <- withQSem blkSem $ do m <- readRef blkMap; case Map.lookup slot m of { Nothing -> return Nothing; Just d -> do { writeRef blkMap (Map.delete slot m); return (Just d) } }
      case mDev of
        Nothing -> return (Left (BlkInvalidArg "not initialized"))
        Just _ -> do
          _ <- DrvReg.unregisterDriver ("virtio-blk" ++ show slot)
          _ <- VTrans.virtioTeardown slot
          liftIO $ c_reset_slot slot
          Dmesg.dmesgLog ("blk slot " ++ show slot ++ ": teardown")
          return (Right ())

-- | Client read: allocates Grant, direct submit/poll.
blkReadBlocks :: Int -> Word64 -> H (Either BlkError String)
blkReadBlocks slot lba = do
  mDev <- withQSem blkSem $ do m <- readRef blkMap; return (Map.lookup slot m)
  case mDev of
    Nothing -> return (Left (BlkInvalidArg "not initialized"))
    Just _dev -> do
      capRes <- blkProbeCapacity slot
      case capRes of
        Left e -> return (Left e)
        Right cap -> case validateLba lba 1 cap of
          Left e -> return (Left e)
          Right () -> do
            mg <- G.grantAlloc
            case mg of
              Left _ -> return (Left BlkNoSpace)
              Right g -> do
                let ptr = grantPage g
                sub <- blkSubmitRead slot lba ptr
                case sub of
                  Left e -> do G.grantFree g; return (Left e)
                  Right reqId -> do
                    res <- waitForCompletion slot reqId g
                    case res of
                      Left e -> do G.grantFree g; return (Left e)
                      Right () -> do s <- grantToString g; G.grantFree g; return (Right s)

-- | Client write: string -> Grant page -> direct submit/poll.
blkWriteBlocks :: Int -> Word64 -> String -> H (Either BlkError ())
blkWriteBlocks slot lba txt = do
  mDev <- withQSem blkSem $ do m <- readRef blkMap; return (Map.lookup slot m)
  case mDev of
    Nothing -> return (Left (BlkInvalidArg "not initialized"))
    Just _dev -> do
      capRes <- blkProbeCapacity slot
      case capRes of
        Left e -> return (Left e)
        Right cap -> case validateLba lba 1 cap of
          Left e -> return (Left e)
          Right () -> do
            mg <- G.grantAlloc
            case mg of
              Left _ -> return (Left BlkNoSpace)
              Right g -> do
                fillGrant g txt
                liftIO $ c_dc_flush (c_pagePa (grantPage g)) 4096
                let ptr = grantPage g
                sub <- blkSubmitWrite slot lba ptr
                case sub of
                  Left e -> do G.grantFree g; return (Left e)
                  Right reqId -> do
                    res <- waitForCompletion slot reqId g
                    case res of
                      Left e -> do G.grantFree g; return (Left e)
                      Right () -> do G.grantFree g; return (Right ())

-- | Get capacity (sectors) for shell status.
blkGetCapacity :: Int -> H (Either BlkError Word64)
blkGetCapacity = blkProbeCapacity

-- | Binary-safe full 4K block read (no zero truncation).
blkReadBlockBytes :: Int -> Word64 -> H (Either BlkError [Word8])
blkReadBlockBytes slot lba = do
  mDev <- withQSem blkSem $ do m <- readRef blkMap; return (Map.lookup slot m)
  case mDev of
    Nothing -> return (Left (BlkInvalidArg "not initialized"))
    Just _dev -> do
      capRes <- blkProbeCapacity slot
      case capRes of
        Left e -> return (Left e)
        Right cap -> case validateLba lba 1 cap of
          Left e -> return (Left e)
          Right () -> do
            mg <- G.grantAlloc
            case mg of
              Left _ -> return (Left BlkNoSpace)
              Right g -> do
                let ptr = grantPage g
                sub <- blkSubmitRead slot lba ptr
                case sub of
                  Left e -> do G.grantFree g; return (Left e)
                  Right reqId -> do
                    res <- waitForCompletion slot reqId g
                    case res of
                      Left e -> do G.grantFree g; return (Left e)
                      Right () -> do
                        bytes <- liftIO $ mapM (\i -> peek (ptr `plusPtr` i) :: IO Word8) [0 .. 4095]
                        G.grantFree g
                        return (Right bytes)

-- | Binary-safe full 4K block write (zero-padded).
blkWriteBlockBytes :: Int -> Word64 -> [Word8] -> H (Either BlkError ())
blkWriteBlockBytes slot lba bytes = do
  mDev <- withQSem blkSem $ do m <- readRef blkMap; return (Map.lookup slot m)
  case mDev of
    Nothing -> return (Left (BlkInvalidArg "not initialized"))
    Just _dev -> do
      capRes <- blkProbeCapacity slot
      case capRes of
        Left e -> return (Left e)
        Right cap -> case validateLba lba 1 cap of
          Left e -> return (Left e)
          Right () -> do
            mg <- G.grantAlloc
            case mg of
              Left _ -> return (Left BlkNoSpace)
              Right g -> do
                let ptr = grantPage g
                liftIO $ do
                  let n = min (length bytes) 4096
                  mapM_ (\(i, b) -> poke (ptr `plusPtr` i) b) (zip [0 ..] (take n bytes))
                  mapM_ (\i -> poke (ptr `plusPtr` i) (0 :: Word8)) [n .. 4095]
                liftIO $ c_dc_flush (c_pagePa ptr) 4096
                sub <- blkSubmitWrite slot lba ptr
                case sub of
                  Left e -> do G.grantFree g; return (Left e)
                  Right reqId -> do
                    res <- waitForCompletion slot reqId g
                    G.grantFree g
                    case res of
                      Left e -> return (Left e)
                      Right () -> return (Right ())
