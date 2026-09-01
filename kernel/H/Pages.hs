-- #hide, prune, ingore-exports

-- | Support for access to raw physical pages of all kinds
--  Not for direct use by H clients
module H.Pages (Page, pageSize, allocPage, freePage, registerPage, zeroPage, validPage, freePageCount) where

import Data.Word (Word8)
import Foreign.C.Types (CInt (..))
import H.AdHocMem (Ptr, castPtr, nullPtr, peek, plusPtr, poke)
import H.Concurrency
import H.Monad (liftIO)
import H.Mutable
import H.Unsafe (unsafePerformH)
import H.Utils (alignedPtr, validPtr)
import qualified System.Mem.Weak as W

--------------------------INTERFACE-------------------

type Page a = Ptr a

pageSize :: Int
pageSize = 4096 -- bytes

allocPage :: H (Maybe (Page a))
freePage :: Page a -> H () -- caller must ensure arg is valid
registerPage :: Page a -> b -> (Page a -> H ()) -> H ()
zeroPage :: Page a -> H ()
validPage :: Page a -> Bool
freePageCount :: H Int
------------PRIVATE IMPLEMENTATION FOLLOWS---------------

allocPage = do
  cleanRegisteredPages
  allocPageFromList

freePage a = freePageToList a

-- Following specify absolute range of available pages.
-- Can safely assume these contain constants.
foreign import ccall unsafe "userspace.h & min_user_addr" minAddrRef :: Ptr (Ptr a)

foreign import ccall unsafe "userspace.h & max_user_addr" maxAddrRef :: Ptr (Ptr a)

minAddr, maxAddr :: Ptr a
minAddr = unsafePerformH (peek minAddrRef)
maxAddr = unsafePerformH (peek maxAddrRef)

foreign import ccall unsafe "buddy_alloc_page" buddyAllocPageIO :: IO (Ptr a)

foreign import ccall unsafe "buddy_free_page" buddyFreePageIO :: Ptr a -> IO ()

foreign import ccall unsafe "buddy_contains" buddyContainsIO :: Ptr a -> IO CInt

foreign import ccall unsafe "buddy_free_count" buddyFreeCountIO :: IO CInt

buddyContains :: Ptr a -> Bool
buddyContains p = unsafePerformH (do v <- liftIO (buddyContainsIO p); return (v /= 0))

validPage p = (validPtr (minAddr, maxAddr) p && alignedPtr pageSize p) || (alignedPtr pageSize p && buddyContains p)

{-# NOINLINE freeList #-}
freeList :: Ref [Ptr a]
freeList = unsafePerformH $ newRef allPages
  where
    allPages = enumPages minAddr

    enumPages a =
      if a < maxAddr
        then a : enumPages (a `plusPtr` pageSize)
        else []

{-# NOINLINE pageSem #-}
pageSem :: QSem
pageSem = unsafePerformH $ newQSem 1

allocPageFromList :: H (Maybe (Ptr a))
allocPageFromList =
  withQSem pageSem $
    do
      pages <- readRef freeList
      case pages of
        (page : rest) -> do
          writeRef freeList rest
          return (Just page)
        [] -> do
          mp <- liftIO buddyAllocPageIO
          if mp == nullPtr
            then return Nothing
            else return (Just mp)

freePageToList :: Ptr a -> H ()
freePageToList page =
  if buddyContains page
    then liftIO (buddyFreePageIO page)
    else withQSem pageSem $ do modifyRef freeList (page :)

-- putStrLn ("freePage:" ++ (show page))

-- Weak page register

{-# NOINLINE registered #-}
registered :: Ref [(Page a, Weak (), Page a -> H ())]
registered = unsafePerformH (newRef [])

registerPage p k f =
  do
    w <- mkSimpleWeak k
    withQSem pageSem $
      modifyRef registered ((p, w, f) :)

-- note we are careful to release the lock before we begin to finalize
-- pages (since finalizers typically need the lock).
cleanRegisteredPages :: H ()
cleanRegisteredPages =
  do
    cs <- withQSem pageSem $
      do
        rs <- readRef registered
        (rs', cs) <- spanM check rs
        writeRef registered rs'
        return cs
    mapM_ clean cs
  where
    check (_, w, _) =
      do
        s <- deRefWeak w
        return (s /= Nothing)
    clean (p, _, f) = f p
    spanM _q [] = return ([], [])
    spanM q (x : xs) =
      do
        (ys, zs) <- spanM q xs
        keep <- q x
        if keep
          then
            return (x : ys, zs)
          else
            return (ys, x : zs)

zeroPage p = sequence_ [poke ((castPtr p) `plusPtr` i) (0 :: Word8) | i <- [0 .. pageSize - 1]]

freePageCount = do
  n <- withQSem pageSem $ do pages <- readRef freeList; return (length pages)
  bc <- liftIO buddyFreeCountIO
  return (n + fromIntegral bc)

type Weak v = W.Weak v

mkSimpleWeak :: k -> H (Weak ())
mkSimpleWeak k = liftIO $ W.mkWeak k () Nothing

deRefWeak :: Weak v -> H (Maybe v)
deRefWeak w = liftIO $ W.deRefWeak w
