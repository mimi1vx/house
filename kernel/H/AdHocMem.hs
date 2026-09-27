-- | Ad-hoc memory access, not necessarily safe!
module H.AdHocMem (
  module H.AdHocMem,
  H,
  IO.Storable,
  Ptr,
  nullPtr,
  plusPtr,
  minusPtr,
  alignPtr,
  advancePtr,
  castPtr,
  Word32,
  Word64,
)
where

import Control.Monad (when)
import Data.Array.IArray (IArray, assocs, bounds)
import Data.Array.IO (IOUArray, MArray, freeze, newArray_, writeArray)

-- For SPECIALIZE pragma:
import Data.Array.Unboxed (UArray)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BSU
import Data.Ix (Ix, index, range)
import Data.Word (
  Word16,
  Word32,
  Word64,
  Word8,
 )
import Foreign.Marshal (advancePtr)
import Foreign.Marshal qualified as IO (allocaArray, copyArray, moveBytes, withArray)
import Foreign.Marshal.Alloc qualified as IO (free, mallocBytes)
import Foreign.Ptr (Ptr, alignPtr, castPtr, minusPtr, nullPtr, plusPtr)
import Foreign.Storable qualified as IO
import H.Monad (H, liftIO, runH)

mallocBytes :: Int -> H (Ptr a)
mallocBytes n = liftIO $ IO.mallocBytes n

free :: Ptr a -> H ()
free p = liftIO $ IO.free p

absolutePtr :: Word32 -> Ptr a
absolutePtr n = nullPtr `plusPtr` fromIntegral n

absolutePtr64 :: Word64 -> Ptr a
absolutePtr64 n = nullPtr `plusPtr` fromIntegral n

poke :: (IO.Storable a) => Ptr a -> a -> H ()
poke p x = liftIO $ IO.poke p x

peek :: (IO.Storable a) => Ptr a -> H a
peek p = liftIO $ IO.peek p

pokeByteOff :: (IO.Storable a) => Ptr b -> Int -> a -> H ()
pokeByteOff p o x = liftIO $ IO.pokeByteOff p o x

peekByteOff :: (IO.Storable a) => Ptr b -> Int -> H a
peekByteOff p o = liftIO $ IO.peekByteOff p o

pokeElemOff :: (IO.Storable a) => Ptr a -> Int -> a -> H ()
pokeElemOff p o x = liftIO $ IO.pokeElemOff p o x

peekElemOff :: (IO.Storable a) => Ptr a -> Int -> H a
peekElemOff p o = liftIO $ IO.peekElemOff p o

moveBytes :: Ptr a -> Ptr a -> Int -> H ()
moveBytes dst src n = liftIO $ IO.moveBytes dst src n

{- | Copy @count@ bytes out of a strict 'BS.ByteString' into a raw pointer.

One @memcpy@ instead of one 'H' step per byte: the ELF mapper copies a whole
segment this way, page by page, and the per-byte form puts every byte through
the interpreter.
-}
pokeBytes :: Ptr Word8 -> BS.ByteString -> Int -> Int -> H ()
pokeBytes destination source sourceOffset count = liftIO $ BSU.unsafeUseAsCStringLen source $ \(raw, len) ->
  when (sourceOffset >= 0 && count >= 0 && sourceOffset <= len && count <= len - sourceOffset) $
    IO.moveBytes destination (castPtr raw `plusPtr` sourceOffset) count

{- | Whether two raw buffers hold the same @count@ bytes.

Early-exits on the first difference, so a page that is already known to differ
stops being read instead of being walked to the end.
-}
bytesEqual :: Ptr Word8 -> Ptr Word8 -> Int -> H Bool
bytesEqual left right count
  | count <= 0 = return True
  | otherwise = go (0 :: Int)
  where
    go i
      | i >= count = return True
      | otherwise = do
          a <- peek (left `plusPtr` i) :: H Word8
          b <- peek (right `plusPtr` i) :: H Word8
          if a == b then go (i + 1) else return False

copyArray :: (IO.Storable a) => Ptr a -> Ptr a -> Int -> H ()
copyArray dst src n = liftIO $ IO.copyArray dst src n

withArray :: (IO.Storable a) => [a] -> (Ptr a -> H b) -> H b
withArray xs h = liftIO $ IO.withArray xs (runH . h)

allocaArray :: (IO.Storable a) => Int -> (Ptr a -> H b) -> H b
allocaArray i h = liftIO $ IO.allocaArray i (runH . h)

pokeArray :: (IO.Storable e, IArray UArray e, Ix Int) => Ptr e -> UArray Int e -> H ()
pokeArray p a =
  --    zipWithM_ (pokeElemOff p) [0..] (elems a) -- slow
  mapM_ (uncurry (pokeElemOff p . index b)) (assocs a) -- avoids bounds checks?
  --     sequence_ [pokeElemOff p (index b i) (a!i)|i<-range b]
  where
    b = bounds a

peekArray :: (IO.Storable e, IArray UArray e, MArray IOUArray e IO) => Ptr e -> Int -> H (UArray Int e)
peekArray p n =
  do
    let b = (0, n - 1)
    ma <- liftIO $ newArray_ b
    let t = id :: IOUArray Int a -> IOUArray Int a
    sequence_
      [ liftIO . writeArray (t ma) i
          =<< peekElemOff p i
      | i <- range b
      ]
    liftIO $ freeze ma

type PokeArray d = Ptr d -> UArray Int d -> H ()

{-# SPECIALIZE pokeArray :: PokeArray Word8 #-}
{-# SPECIALIZE pokeArray :: PokeArray Word16 #-}
{-# SPECIALIZE pokeArray :: PokeArray Word32 #-}

type PeekArray d = Ptr d -> Int -> H (UArray Int d)

{-# SPECIALIZE peekArray :: PeekArray Word8 #-}
{-# SPECIALIZE peekArray :: PeekArray Word16 #-}
{-# SPECIALIZE peekArray :: PeekArray Word32 #-}
