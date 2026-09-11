{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Echo
Description : Builder reproducing @userspace/echo.s@ byte-for-byte.
Stability   : experimental

Second EDSL slice (after hello). The golden test pins every byte against
the checked-in @echo.s@; @house-gen echo@ emits it for
@scripts/mk-userspace.sh@.
-}
module Userspace.Tool.Echo (
  echoInstrs,
  echoText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustW, mustX)

-- | Instruction list for @echo.s@, in file order.
echoInstrs :: [Instr]
echoInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      x3 = mustX 3
      x4 = mustX 4
      x19 = mustX 19
      x20 = mustX 20
      x21 = mustX 21
      x29 = mustX 29
      x30 = mustX 30
      w0 = mustW 0
      w3 = mustW 3
      u1 = mustU12 1
      u2 = mustU12 2
      u8 = mustU12 8
      u15 = mustU12 15
      u16 = mustU12 16
      u2048 = mustU12 2048
      svcWrite = mustSvc 0x01
      svcExit = mustSvc 0x02
   in [ Comment "EL0 echo for /bin/echo (pid1 slice, plans/pid1-init-shell.md step 4)."
      , Comment "Prints argv[1..] joined with single spaces plus a trailing newline via"
      , Comment "svc WRITE (one call per word), exits 0. Bare `echo` prints just `\\n`."
      , Comment "String scans are capped at 2048 (kernel argv strings are <=1024 by the"
      , Comment "setupArgStack contract, so the cap only fires on a hostile stack)."
      , Arch "armv8-a"
      , Text
      , Global "_start"
      , TypeDir "_start" "%function"
      , Label "_start"
      , Trail (LdrMem x19 SP) "argc"
      , CmpImm x19 u2
      , Trail (BCond Lo "newline") "0-1 args: just newline"
      , Trail (AddImm x20 SP u16) "&argv[1]"
      , Trail (MovImm x21 1) "index"
      , Label "word_loop"
      , CmpReg x21 x19
      , BCond Hs "newline"
      , Trail (LdrMem x1 x20) "argv[i]"
      , Bl "putstr"
      , AddImm x21 x21 u1
      , AddImm x20 x20 u8
      , CmpReg x21 x19
      , BCond Hs "newline"
      , MovChar w0 ' '
      , Bl "putc"
      , B "word_loop"
      , Label "newline"
      , MovImm w0 10
      , Bl "putc"
      , MovImm x0 0
      , Svc svcExit (Just "EXIT(0)")
      , Blank
      , Comment "putstr(x1): WRITE(1, x1, strlen_cap(x1, 2048)). Clobbers x0-x4."
      , Label "putstr"
      , StpPush x29 x30 SP
      , MovReg x29 SP
      , StpPush x1 x2 SP
      , MovReg x2 x1
      , MovImm x0 0
      , LocalInstr "1" (CmpImm x0 u2048)
      , BCond Hs "2f"
      , LdrbReg w3 x2 x0
      , Cbz w3 "2f"
      , AddImm x0 x0 u1
      , B "1b"
      , LocalInstr "2" (Trail (MovReg x2 x0) "len")
      , Trail (LdpPop x1 x4 SP) "x1 = ptr (x4 scratch)"
      , MovImm x0 1
      , Cbz x2 "3f"
      , Svc svcWrite Nothing
      , LocalInstr "3" (LdpPop x29 x30 SP)
      , Ret
      , Blank
      , Comment "putc(w0): WRITE(1, &byte, 1) via stack scratch (SP stays 16-byte"
      , Comment "aligned throughout). Clobbers x0-x2."
      , Label "putc"
      , StpPush x29 x30 SP
      , MovReg x29 SP
      , SubImm SP SP u16
      , StrbOff w0 SP u15
      , AddImm x1 SP u15
      , MovImm x2 1
      , MovImm x0 1
      , Svc svcWrite Nothing
      , AddImm SP SP u16
      , LdpPop x29 x30 SP
      , Ret
      , Blank
      , DataSection
      , Align 3
      , Label "scratch"
      , Quad 0
      ]

-- | Rendered @echo.s@ text.
echoText :: String
echoText = render echoInstrs
