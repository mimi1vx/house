{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Common
Description : Total smart-constructor lookups for tool builders.
Stability   : experimental

Known-good registers/immediates/svc numbers are cased on, never
partially unwrapped. Fallbacks are valid but wrong operands the
assembler accepts; the golden tests pin the real bytes, so any misuse
fails loud there instead of at runtime.
-}
module Userspace.Tool.Common (
  mustX,
  mustW,
  mustU12,
  mustSvc,
)
where

import Data.Word (Word16, Word8)
import Userspace.Asm

-- | Total lookup for a known-good @x@ register.
mustX :: Word8 -> Reg
mustX n = case mkX n of
  Just r -> r
  Nothing -> X 31

-- | Total lookup for a known-good @w@ register.
mustW :: Word8 -> Reg
mustW n = case mkW n of
  Just r -> r
  Nothing -> W 31

-- | Total lookup for a known-good 12-bit immediate.
mustU12 :: Word16 -> U12
mustU12 n = case mkU12 n of
  Just u -> u
  Nothing -> mustU12 0

-- | Total lookup for a known-good svc number.
mustSvc :: Word8 -> SvcImm
mustSvc n = case mkSvc n of
  Just s -> s
  Nothing -> mustSvc 0x02
