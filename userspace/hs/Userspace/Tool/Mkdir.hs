{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Mkdir
Description : Builder reproducing @userspace/mkdir.s@ byte-for-byte.
Stability   : experimental
-}
module Userspace.Tool.Mkdir (
  mkdirInstrs,
  mkdirText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustX)

-- | Instruction list for @mkdir.s@, in file order.
mkdirInstrs :: [Instr]
mkdirInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      svcMkdir = mustSvc 0x0C
      svcWrite = mustSvc 0x01
      svcExit = mustSvc 0x02
   in [ Comment "EL0 mkdir for /bin/mkdir (pid1 slice, plans/pid1-init-shell.md steps 3-4)."
      , Comment "Creates one directory via MKDIR 0x0C (x0 = path VA, resumes 0)."
      , Comment "Needs argv[1]; prints `mkdir ok` + exit 0, else `mkdir fail` + exit 1."
      , Arch "armv8-a"
      , Text
      , Global "_start"
      , TypeDir "_start" "%function"
      , Label "_start"
      , Trail (LdrMem x0 SP) "argc"
      , CmpImm x0 (mustU12 2)
      , Trail (BCond Lo "fail") "need prog + path"
      , Trail (LdrOff x0 SP (mustU12 16)) "argv[1]"
      , Trail (Svc svcMkdir Nothing) "MKDIR -> x0 = 0"
      , Cbnz x0 "fail"
      , Adrp x1 "okmsg"
      , AddLo12 x1 x1 "okmsg"
      , MovImm x2 9
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"mkdir ok\\n\", 9)"
      , MovImm x0 0
      , Trail (Svc svcExit Nothing) "EXIT(0)"
      , Label "fail"
      , Adrp x1 "failmsg"
      , AddLo12 x1 x1 "failmsg"
      , MovImm x2 11
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"mkdir fail\\n\", 11)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "okmsg"
      , Ascii "mkdir ok\n"
      , Label "failmsg"
      , Ascii "mkdir fail\n"
      , Blank
      , DataSection
      , Align 3
      , Label "scratch"
      , Quad 0
      ]

-- | Rendered @mkdir.s@ text.
mkdirText :: String
mkdirText = render mkdirInstrs
