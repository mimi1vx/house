{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Hello
Description : Builder reproducing @userspace/hello.s@ byte-for-byte.
Stability   : experimental

Slice 1 of the EDSL pivot. The golden test pins every byte against the
checked-in @hello.s@; @house-gen hello@ emits it for
@scripts/mk-userspace.sh@.
-}
module Userspace.Tool.Hello (
  helloInstrs,
  helloText,
)
where

import Userspace.Asm

{- | Instruction list for @hello.s@, in file order. Known-good registers
and svc numbers are cased on, never partially unwrapped: the @Nothing@
arm is an assembler-rejected sentinel, so misuse fails loud via the
golden test instead of a runtime partial.
-}
helloInstrs :: [Instr]
helloInstrs = case (mkX 0, mkX 1, mkX 2, mkSvc 0x01, mkSvc 0x02) of
  (Just x0, Just x1, Just x2, Just svcWrite, Just svcExit) ->
    [ Comment "EL0 hello for /bin/hello (pid1 slice, plans/pid1-init-shell.md step 4)."
    , Comment "Source twin of the historic helloBytes blob: prints `Hello from EL0`"
    , Comment "via svc WRITE and exits 0. /sbin/init execs this as its v1 child, and"
    , Comment "qemu-userspace/qemu-fork (exec leg) assert this exact line."
    , Arch "armv8-a"
    , Text
    , Global "_start"
    , TypeDir "_start" "%function"
    , Label "_start"
    , Adrp x1 "msg"
    , AddLo12 x1 x1 "msg"
    , MovImm x2 15
    , MovImm x0 1
    , Svc svcWrite (Just "WRITE(1, \"Hello from EL0\\n\", 15)")
    , MovImm x0 0
    , Svc svcExit (Just "EXIT(0)")
    , Label "msg"
    , Ascii "Hello from EL0\n"
    , Blank
    , DataSection
    , Align 3
    , Label "scratch"
    , Quad 0
    ]
  _ -> [Comment "invalid hello operands (unreachable: 0-2/0x01-0x02 in range)"]

-- | Rendered @hello.s@ text.
helloText :: String
helloText = render helloInstrs
