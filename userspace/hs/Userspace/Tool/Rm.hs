{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Rm
Description : Builder reproducing @userspace/rm.s@ byte-for-byte.
Stability   : experimental
-}
module Userspace.Tool.Rm (
  rmInstrs,
  rmText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustX)

-- | Instruction list for @rm.s@, in file order.
rmInstrs :: [Instr]
rmInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      svcUnlink = mustSvc 0x0D
      svcWrite = mustSvc 0x01
      svcExit = mustSvc 0x02
   in [ Comment "EL0 rm for /bin/rm (pid1 slice, plans/pid1-init-shell.md steps 3-4)."
      , Comment "Removes a file or empty dir via UNLINK 0x0D (x0 = path VA, resumes 0)."
      , Comment "Needs argv[1]; prints `rm ok` + exit 0, else `rm fail` + exit 1."
      , Arch "armv8-a"
      , Text
      , Global "_start"
      , TypeDir "_start" "%function"
      , Label "_start"
      , Trail (LdrMem x0 SP) "argc"
      , CmpImm x0 (mustU12 2)
      , Trail (BCond Lo "fail") "need prog + path"
      , Trail (LdrOff x0 SP (mustU12 16)) "argv[1]"
      , Trail (Svc svcUnlink Nothing) "UNLINK -> x0 = 0"
      , Cbnz x0 "fail"
      , Adrp x1 "okmsg"
      , AddLo12 x1 x1 "okmsg"
      , MovImm x2 6
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"rm ok\\n\", 6)"
      , MovImm x0 0
      , Trail (Svc svcExit Nothing) "EXIT(0)"
      , Label "fail"
      , Adrp x1 "failmsg"
      , AddLo12 x1 x1 "failmsg"
      , MovImm x2 8
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"rm fail\\n\", 8)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "okmsg"
      , Ascii "rm ok\n"
      , Label "failmsg"
      , Ascii "rm fail\n"
      , Blank
      , DataSection
      , Align 3
      , Label "scratch"
      , Quad 0
      ]

-- | Rendered @rm.s@ text.
rmText :: String
rmText = render rmInstrs
