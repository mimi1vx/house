{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Ls
Description : Builder reproducing @userspace/ls.s@ byte-for-byte.
Stability   : experimental
-}
module Userspace.Tool.Ls (
  lsInstrs,
  lsText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustX)

-- | Instruction list for @ls.s@, in file order.
lsInstrs :: [Instr]
lsInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      x19 = mustX 19
      x20 = mustX 20
      svcGetdents = mustSvc 0x0F
      svcWrite = mustSvc 0x01
      svcExit = mustSvc 0x02
   in [ Comment "EL0 ls for /bin/ls (pid1 slice, plans/pid1-init-shell.md steps 3-4)."
      , Comment "Lists a directory via GETDENTS 0x0C..0x0F slice: svc #0x0F"
      , Comment "(x0 = path VA, x1 = buf VA, x2 = buflen) resumes the newline-separated"
      , Comment "listing length, which is echoed with one WRITE. Path is argv[1],"
      , Comment "defaulting to `/`. Prints `ls fail` and exits 1 on any error."
      , Arch "armv8-a"
      , Text
      , Global "_start"
      , TypeDir "_start" "%function"
      , Label "_start"
      , Trail (LdrMem x0 SP) "argc"
      , CmpImm x0 (mustU12 2)
      , BCond Hs "have_arg"
      , Adrp x19 "defpath"
      , AddLo12 x19 x19 "defpath"
      , B "do_list"
      , Label "have_arg"
      , Trail (LdrOff x19 SP (mustU12 16)) "argv[1]"
      , Label "do_list"
      , MovReg x0 x19
      , Adrp x1 "buf"
      , AddLo12 x1 x1 "buf"
      , MovImm x2 4096
      , Trail (Svc svcGetdents Nothing) "GETDENTS -> x0 = n"
      , CmpShift12 x0 (mustU12 1)
      , Trail (BCond Hi "fail") "negative errno or over-cap"
      , Trail (Cbz x0 "done") "empty dir: nothing to print"
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
      , MovImm x2 8
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"ls fail\\n\", 8)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "defpath"
      , Ascii "/\0"
      , Label "failmsg"
      , Ascii "ls fail\n"
      , Blank
      , DataSection
      , Align 3
      , Label "buf"
      , Space 4096
      ]

-- | Rendered @ls.s@ text.
lsText :: String
lsText = render lsInstrs
