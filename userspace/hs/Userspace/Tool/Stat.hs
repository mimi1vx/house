{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Stat
Description : Builder reproducing @userspace/stat.s@ byte-for-byte.
Stability   : experimental
-}
module Userspace.Tool.Stat (
  statInstrs,
  statText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustX)

-- | Instruction list for @stat.s@, in file order.
statInstrs :: [Instr]
statInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      x20 = mustX 20
      svcStat = mustSvc 0x0E
      svcWrite = mustSvc 0x01
      svcExit = mustSvc 0x02
   in [ Comment "EL0 stat for /bin/stat (pid1 slice, plans/pid1-init-shell.md steps 3-4)."
      , Comment "Stats a path via STAT 0x0E (x0 = path VA, x1 = buf VA, x2 = buflen):"
      , Comment "the kernel renders one text line (`dir ...` / `file ...`), resumes its"
      , Comment "length, and this echoes it. Needs argv[1]; exits 0, else `stat fail` + 1."
      , Arch "armv8-a"
      , Text
      , Global "_start"
      , TypeDir "_start" "%function"
      , Label "_start"
      , Trail (LdrMem x0 SP) "argc"
      , CmpImm x0 (mustU12 2)
      , Trail (BCond Lo "fail") "need prog + path"
      , Trail (LdrOff x0 SP (mustU12 16)) "argv[1]"
      , Adrp x1 "buf"
      , AddLo12 x1 x1 "buf"
      , MovImm x2 128
      , Trail (Svc svcStat Nothing) "STAT -> x0 = n"
      , CmpImm x0 (mustU12 128)
      , Trail (BCond Hi "fail") "negative errno or over-cap"
      , Trail (Cbz x0 "done") "zero-length render: nothing to print"
      , MovReg x20 x0
      , Adrp x1 "buf"
      , AddLo12 x1 x1 "buf"
      , MovReg x2 x20
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, buf, n)"
      , Label "done"
      , MovImm x0 0
      , Trail (Svc svcExit Nothing) "EXIT(0)"
      , Label "fail"
      , Adrp x1 "failmsg"
      , AddLo12 x1 x1 "failmsg"
      , MovImm x2 10
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"stat fail\\n\", 10)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "failmsg"
      , Ascii "stat fail\n"
      , Blank
      , DataSection
      , Align 3
      , Label "buf"
      , Space 128
      ]

-- | Rendered @stat.s@ text.
statText :: String
statText = render statInstrs
