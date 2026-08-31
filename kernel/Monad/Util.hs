-- | Some useful monadic combinators missing from the standard libraries
module Monad.Util where

import Control.Monad (ap, when)

infixl 1 #, #!, <#

-- | Apply a pure function to the result of a monadic computation
(#) :: (Functor f) => (a -> b) -> f a -> f b
f # x = fmap f x

-- | Apply a function returned by a monadic computation to an argument returned
-- by a monadic computation
(<#) :: (Monad m) => m (a -> b) -> m a -> m b
f <# x = ap f x

-- | Perform two monadic computation and return the result from the second one
(#!) :: (Monad m) => m b -> m a -> m b
x #! y = const # x <# y

-- It is a scandal that monadic composition isn't defined in the libraries...
infixr 1 @@

-- | Kleiski composition
(@@) :: (Monad m) => (a -> m b) -> (t -> m a) -> t -> m b
(m1 @@ m2) i = m1 =<< m2 i

-- | Infinite loops
loop :: (Monad m) => m a -> m b
loop m = l where l = m >> l

-- | While loops
whileM :: (Monad m) => m Bool -> m a -> m ()
whileM cndM bodyM = go
  where
    go = do
      more <- cndM
      when more (bodyM >> go)

-- | Repeat m while it returns True
repeatM :: (Monad m) => m Bool -> m ()
repeatM m = whileM m (return ())

done :: (Monad m) => m ()
done = return ()
