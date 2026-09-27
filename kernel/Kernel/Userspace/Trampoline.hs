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
    0x780  the stub's one scratch word ('trampolineScratchOffset')

Both offsets are page-relative and the stub derives the descriptor address
from its own instruction address, so the page can be mapped at any VA.
-}
module Kernel.Userspace.Trampoline (
  TrampolineMode (..),
  maxTrampolineCalls,
  trampolinePage,
  trampolineCodeOffset,
  trampolineDescriptorOffset,
  trampolineScratchOffset,
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

{- | The one word the stub needs beyond the descriptor. @house_enter_el0@ hands
the argument stack pointer over in @x1@, which AAPCS64 lets every callee
clobber, and the loop calls into the image, so the loader records it here
before the phase starts and the stub reloads it on the branch-to-entry path
only. The stub never stores: its page is read-only from the moment the loader
erets into it.

Page-relative, i.e. the @0x380@ the stub's @ldr@ scales up from
@trampolineDescriptorOffset@. It sits above the descriptor's largest extent,
which the test pins.
-}
trampolineScratchOffset :: Int
trampolineScratchOffset = 0x780

{- | The stub, as AArch64 instruction words.

Every register the loop still needs after a constructor is one AAPCS64
callee-saved register: @x19@-@x22@, plus @x1@ reloaded from the scratch word
the loader filled. @x0@, @x9@ and @x10@ carry the descriptor's target and mode
and are written only after the final @blr@. The encoded words come from
assembling this listing; the decoder test in @kernel\/test@ pins the branch
destinations and asserts that no caller-saved register is read across a
@blr@.

    adrp  x20, page          ; x20 = the page this instruction lives in
    add   x20, x20, #0x400    ; x20 = the descriptor
    ldr   x19, [x20]         ; x19 = call count
    mov   x21, #0            ; x21 = index
  loop:
    cmp   x21, x19
    b.hs  done
    add   x22, x20, x21, lsl #3
    add   x22, x22, #8        ; x22 = &descriptor[1 + index]
    ldr   x22, [x22]
    blr   x22                ; x19/x20/x21/x22 are callee-saved
    add   x21, x21, #1
    b     loop
  done:
    add   x22, x20, x19, lsl #3
    add   x22, x22, #8        ; x22 = &descriptor[1 + count]
    ldr   x9, [x22]           ; x9 = target (entry, or exit code)
    ldr   x10, [x22, #8]      ; x10 = mode
    cmp   x10, #0
    b.ne  exiting
    mov   x0, #0
    ldr   x1, [x20, #0x380]   ; the argument stack pointer the loader recorded
    br    x9
  exiting:
    mov   x0, x9
    svc   #0x02
    b     .                 ; svc never returns; spin rather than fall off

The loop pushes nothing, preserves @x0@ and @sp@, and restores @x1@, so the
image entry sees exactly the state a direct entry would have given it.
@x19@-@x22@ are stub scratch: the AArch64 ELF psABI leaves them unspecified at
process entry and glibc's @_start@ does not read them.
-}
trampolineCode :: [Word32]
trampolineCode =
  [ 0x90000014 -- adrp x20, page
  , 0x91100294 -- add x20, x20, #0x400
  , 0xF9400293 -- ldr x19, [x20]
  , 0xD2800015 -- mov x21, #0
  , 0xEB1302BF -- cmp x21, x19
  , 0x540000E2 -- b.hs done
  , 0x8B150E96 -- add x22, x20, x21, lsl #3
  , 0x910022D6 -- add x22, x22, #8
  , 0xF94002D6 -- ldr x22, [x22]
  , 0xD63F02C0 -- blr x22
  , 0x910006B5 -- add x21, x21, #1
  , 0x17FFFFF9 -- b loop
  , 0x8B130E96 -- add x22, x20, x19, lsl #3
  , 0x910022D6 -- add x22, x22, #8
  , 0xF94002C9 -- ldr x9, [x22]
  , 0xF94006CA -- ldr x10, [x22, #8]
  , 0xF100015F -- cmp x10, #0
  , 0x54000081 -- b.ne exiting
  , 0xD2800000 -- mov x0, #0
  , 0xF941C281 -- ldr x1, [x20, #0x380]
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
