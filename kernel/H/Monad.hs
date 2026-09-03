-- | The Hardware Monad (section 3 in the paper)
module H.Monad (H, trappedRunH, runH, trace, LiftH (..), H.Monad.liftIO) where

import Control.Exception as Exception
import Control.Monad.Trans (MonadIO (..), MonadTrans, lift)
import Foreign.C (CString, withCString)

------------------------------- INTERFACE --------------------------------------

-- abstract type H a  -- Functor, Monad

runH :: H a -> IO a
trappedRunH :: H a -> IO ()
trace :: (Show a) => a -> H ()

-- | A class for lifting of H operations through arbitrary monad transformers
class LiftH m where
  liftH :: H a -> m a

liftIO :: IO a -> H a

------------------------- PRIVATE IMPLEMENTATION FOLLOWS -----------------------

-- | The Hardware Monad
newtype H a = H {unH :: IO a}

-- deriving (Functor,Monad) -- pfe doesn't support this (yet)

runH = unH

trappedRunH h = Exception.handle (\(e :: Exception.SomeException) -> cPrint (show e)) $
  do
    _ <- runH h
    return ()

liftIO = H

instance Functor H where fmap f (H m) = H (fmap f m)

instance Applicative H where
  pure x = H (return x)
  H f <*> H x = H (f <*> x)

instance Monad H where
  return = pure
  H m1 >>= xm2 = H (runH . xm2 =<< m1)

instance LiftH H where
  liftH = id

instance (MonadTrans t, Monad m, LiftH m) => LiftH (t m) where
  liftH = lift . liftH

instance MonadIO H where liftIO = H.Monad.liftIO

trace = H . cPrint . show

foreign import ccall unsafe "c_print" c_print :: CString -> IO ()

cPrint :: String -> IO ()
cPrint str = withCString str c_print
