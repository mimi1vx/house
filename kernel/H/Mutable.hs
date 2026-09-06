-- | Mutable data
module H.Mutable (module H.Mutable, H, MArray, Ix) where

import Data.Array.IO (IOArray, IOUArray, Ix, MArray)
import qualified Data.Array.IO as IO (newArray, readArray, writeArray)
import Data.IORef
import H.Monad (H, liftIO)

------------------------ INTERFACE ---------------------------------------------

type Ref = IORef

type HArray = IOArray

type HUArray = IOUArray

newRef :: a -> H (Ref a)
modifyRef :: Ref a -> (a -> a) -> H ()
readRef :: Ref a -> H a
writeRef :: Ref a -> a -> H ()
newArray :: (MArray a b IO, Ix c) => (c, c) -> b -> H (a c b)
readArray :: (MArray a b IO, Ix c) => a c b -> c -> H b
writeArray :: (MArray a b IO, Ix c) => a c b -> c -> b -> H ()
------------------------ IMPLEMENTATION ----------------------------------------
newRef x = liftIO $ newIORef x

readRef r = liftIO $ readIORef r

writeRef r x = liftIO $ writeIORef r x

modifyRef r f = liftIO $ modifyIORef r f

newArray r v = liftIO $ IO.newArray r v

writeArray a i v = liftIO $ IO.writeArray a i v

readArray a i = liftIO $ IO.readArray a i
