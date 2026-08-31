module Kernel.Interrupts
  ( registerIRQHandler,
    callIRQHandler,
  )
where

import H.Interrupts (IntId, enableInt, eoi, installHandler)
import H.Monad (H)
import H.Mutable (HArray, newArray, readArray, writeArray)
import H.Unsafe (unsafePerformH)

{-# NOINLINE irqTable #-}
{- Keep a Haskell ghost copy of irqTable to handle user mode interrupts -}
irqTable :: HArray IntId (Maybe (H ()))
irqTable = unsafePerformH (newArray (IntId 0, IntId 1023) Nothing)

registerIRQHandler irq handler =
  do
    writeArray irqTable irq (Just wrapper)
    installHandler irq wrapper
    enableInt irq
  where
    wrapper =
      do
        handler
        eoi irq

callIRQHandler irq =
  do
    mHandler <- readArray irqTable irq
    case mHandler of
      Just handler -> handler
      Nothing -> return ()
