{-# LANGUAGE GHC2024 #-}

{- |
Module      : Kernel.Userspace.Trampoline
Description : EL0 init/fini trampoline: the AArch64 words and the call descriptor.
Stability   : experimental

A dynamic image's @DT_INIT@/@DT_INIT_ARRAY@ and @DT_FINI@/@DT_FINI_ARRAY@
constructors are ordinary functions, and House is the loader, so something
has to call them. Calling them from EL1 would execute user code on the
kernel's stack, with the kernel's @TTBR0@ installed and before the user's
fault path exists. Instead the loader fills one private page per process,
maps it executable, and enters EL0 *at the trampoline*: the stub calls each
address in the descriptor, then either branches to the image entry or
raises @svc #EXIT@. Every instruction the image's constructors run is
therefore an ordinary EL0 instruction on the process's own stack with the
process's own page directory live — the same exposure any other EL0 code
has, and the same fault path.

Layout of the mapped page:

    0x000  the stub words ('trampolineCode')
    0x400  the call descriptor ('trampolineDescriptor')

Both offsets are page-relative and the stub derives the descriptor address
from its own instruction address, so the page can be mapped at any VA.
-}
module Kernel.Userspace.Trampoline (
  TrampolineMode (..),
  maxTrampolineCalls,
  trampolinePage,
  trampolineCodeOffset,
  trampolineDescriptorOffset,
  trampolineCode,
  trampolineDescriptor,
  descriptorCallOffset,
  descriptorTargetOffset,
  descriptorModeOffset,
)
where

import Data.Word (Word32, Word64)

-- | What the stub does after the last call.
data TrampolineMode
  = -- | branch to the image entry with @x0 = 0@, matching a direct entry
    BranchToEntry
  | -- | raise @svc #EXIT@ with the descriptor's target as the exit code
    ExitProcess
  deriving (Eq, Show)

{- | Calls per phase. A bound, not a budget: the descriptor is a fixed
region of one page, so the loop is bounded by construction.
-}
maxTrampolineCalls :: Int
maxTrampolineCalls = 64

-- | The one page a loader-owned trampoline may occupy, below the stack page.
trampolinePage :: Word64
trampolinePage = 0x3FFFC000

trampolineCodeOffset :: Int
trampolineCodeOffset = 0

trampolineDescriptorOffset :: Int
trampolineDescriptorOffset = 0x400

{- | The stub, as AArch64 instruction words.

    adrp  x4, page          ; x4 = the page this instruction lives in
    add   x4, x4, #0x400    ; x4 = the descriptor
    ldr   x5, [x4]          ; x5 = call count
    mov   x6, #0            ; x6 = index
  loop:
    cmp   x6, x5
    b.hs  done
    add   x7, x4, x6, lsl #3
    add   x7, x7, #8        ; x7 = &descriptor[1 + index]
    ldr   x7, [x7]
    blr   x7
    add   x6, x6, #1
    b     loop
  done:
    add   x8, x4, x5, lsl #3
    add   x8, x8, #8        ; x8 = &descriptor[1 + count]
    ldr   x9, [x8]          ; x9 = target (entry, or exit code)
    ldr   x10, [x8, #8]     ; x10 = mode
    cmp   x10, #0
    b.ne  exiting
    mov   x0, #0
    br    x9
  exiting:
    mov   x0, x9
    svc   #0x02
    b     .                 ; svc never returns; spin rather than fall off

The loop uses only @x0@ and @x4@-@x10@, pushes nothing, and leaves @x1@
(where @house_enter_el0@ placed the argument stack pointer) untouched, so the
image entry sees exactly the state a direct entry would have given it.
-}
trampolineCode :: [Word32]
trampolineCode =
  [ 0x90000004 -- adrp x4, page
  , 0x91100084 -- add x4, x4, #0x400
  , 0xF9400085 -- ldr x5, [x4]
  , 0xD2800006 -- mov x6, #0
  , 0xEB0500DF -- cmp x6, x5
  , 0x540000E2 -- b.hs done
  , 0x8B060C87 -- add x7, x4, x6, lsl #3
  , 0x910020E7 -- add x7, x7, #8
  , 0xF94000E7 -- ldr x7, [x7]
  , 0xD63F00E0 -- blr x7
  , 0x910004C6 -- add x6, x6, #1
  , 0x17FFFFF9 -- b loop
  , 0x8B050C88 -- add x8, x4, x5, lsl #3
  , 0x91002108 -- add x8, x8, #8
  , 0xF9400109 -- ldr x9, [x8]
  , 0xF940050A -- ldr x10, [x8, #8]
  , 0xF100015F -- cmp x10, #0
  , 0x54000061 -- b.ne exiting
  , 0xD2800000 -- mov x0, #0
  , 0xD61F0120 -- br x9
  , 0xAA0903E0 -- mov x0, x9
  , 0xD4000041 -- svc #0x02
  , 0x14000000 -- b .
  ]

-- | Byte offset of the call word for @index@, from the descriptor's start.
descriptorCallOffset :: Int -> Int
descriptorCallOffset index = (index + 1) * 8

-- | Byte offset of the target word, one past the last call slot.
descriptorTargetOffset :: Int -> Int
descriptorTargetOffset count = (count + 1) * 8

-- | Byte offset of the mode word, immediately after the target.
descriptorModeOffset :: Int -> Int
descriptorModeOffset count = (count + 2) * 8

{- | The descriptor words: the call count, the addresses to call in order,
the target, and the mode. The addresses are already relocated — the loader
reads them out of the mapped image, never out of the file.
-}
trampolineDescriptor :: [Word64] -> Word64 -> TrampolineMode -> [Word64]
trampolineDescriptor calls target mode =
  [fromIntegral (length calls)] ++ calls ++ [target, modeWord mode]

modeWord :: TrampolineMode -> Word64
modeWord BranchToEntry = 0
modeWord ExitProcess = 1
