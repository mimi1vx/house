-- | Ad-hoc memory access, not necessarily safe!
module H.AdHocMem
  ( module H.AdHocMem,
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

import Data.Array.IArray (IArray, assocs, bounds)
import Data.Array.IO (IOUArray, MArray, freeze, newArray_, writeArray)
-- For SPECIALIZE pragma:
import Data.Array.Unboxed (UArray)
import Data.Ix (Ix, index, range)
import Data.Word
  ( Word16,
    Word32,
    Word64,
    Word8,
  )
import Foreign.Marshal (advancePtr)
import qualified Foreign.Marshal as IO (allocaArray, copyArray, moveBytes, withArray)
import qualified Foreign.Marshal.Alloc as IO (free, mallocBytes)
import Foreign.Ptr (Ptr, alignPtr, castPtr, minusPtr, nullPtr, plusPtr)
import qualified Foreign.Storable as IO
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
