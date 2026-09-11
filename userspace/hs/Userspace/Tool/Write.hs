{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Write
Description : Builder reproducing @userspace/write.s@ byte-for-byte.
Stability   : experimental
-}
module Userspace.Tool.Write (
  writeInstrs,
  writeText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustW, mustX)

-- | Instruction list for @write.s@, in file order.
writeInstrs :: [Instr]
writeInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      x3 = mustX 3
      x4 = mustX 4
      x19 = mustX 19
      x20 = mustX 20
      x21 = mustX 21
      x22 = mustX 22
      x23 = mustX 23
      x24 = mustX 24
      w0 = mustW 0
      w3 = mustW 3
      svcOpen = mustSvc 0x04
      svcWriteFd = mustSvc 0x06
      svcClose = mustSvc 0x07
      svcWrite = mustSvc 0x01
      svcExit = mustSvc 0x02
   in [ Comment "EL0 write for /bin/write (pid1 slice, plans/pid1-init-shell.md step 4)."
      , Comment "Writes argv[2..] joined with spaces to the file at argv[1] via the fd"
      , Comment "ring: OPEN 0x04 (O_WRONLY|O_CREAT|O_TRUNC), WRITE_FD 0x06, CLOSE 0x07."
      , Comment "Needs prog + path + text; payload capped at 1024 (one WRITE_FD, under"
      , Comment "the 64K svc buffer cap). Prints `write ok` + exit 0, else `write fail`."
      , Arch "armv8-a"
      , Text
      , Global "_start"
      , TypeDir "_start" "%function"
      , Label "_start"
      , Trail (LdrMem x0 SP) "argc"
      , CmpImm x0 (mustU12 3)
      , Trail (BCond Lo "fail") "need prog + path + text"
      , Trail (LdrOff x19 SP (mustU12 16)) "path = argv[1]"
      , IndentedComment "Join argv[2..] with spaces into buf (x20 = cursor, x21 = index)."
      , Adrp x20 "buf"
      , AddLo12 x20 x20 "buf"
      , Trail (AddImm x22 SP (mustU12 24)) "&argv[2]"
      , MovImm x21 2
      , Trail (LdrMem x23 SP) "argc"
      , Label "join_loop"
      , CmpReg x21 x23
      , BCond Hs "join_done"
      , CmpImm x21 (mustU12 2)
      , BCond Eq "no_sep"
      , MovImm x0 1024
      , Adrp x1 "buf"
      , AddLo12 x1 x1 "buf"
      , SubReg x0 x20 x1
      , CmpImm x0 (mustU12 1024)
      , Trail (BCond Hs "fail") "payload cap"
      , MovChar w0 ' '
      , StrbPost w0 x20 (mustU12 1)
      , Label "no_sep"
      , Trail (LdrMem x1 x22) "argv[i]"
      , Bl "copy_capped"
      , Cbnz x0 "fail"
      , AddImm x21 x21 (mustU12 1)
      , AddImm x22 x22 (mustU12 8)
      , B "join_loop"
      , Label "join_done"
      , MovImm x0 1024
      , Adrp x1 "buf"
      , AddLo12 x1 x1 "buf"
      , Trail (SubReg x24 x20 x1) "len"
      , IndentedComment "OPEN(path, O_WRONLY|O_CREAT|O_TRUNC = 0x241)."
      , MovReg x0 x19
      , MovHex x1 0x241
      , Trail (Svc svcOpen Nothing) "OPEN -> x0 = fd"
      , CmpImm x0 (mustU12 34)
      , BCond Hi "fail"
      , Trail (MovReg x19 x0) "fd"
      , Adrp x1 "buf"
      , AddLo12 x1 x1 "buf"
      , MovReg x2 x24
      , MovReg x0 x19
      , Trail (Svc svcWriteFd Nothing) "WRITE_FD -> x0 = n"
      , CmpReg x0 x24
      , BCond Ne "fail_close"
      , MovReg x0 x19
      , Trail (Svc svcClose Nothing) "CLOSE(fd)"
      , Cbnz x0 "fail"
      , Adrp x1 "okmsg"
      , AddLo12 x1 x1 "okmsg"
      , MovImm x2 9
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"write ok\\n\", 9)"
      , MovImm x0 0
      , Trail (Svc svcExit Nothing) "EXIT(0)"
      , Label "fail_close"
      , MovReg x20 x0
      , MovReg x0 x19
      , Trail (Svc svcClose Nothing) "CLOSE(fd) before failing"
      , MovReg x0 x20
      , Cbnz x0 "fail"
      , Label "fail"
      , Adrp x1 "failmsg"
      , AddLo12 x1 x1 "failmsg"
      , MovImm x2 11
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"write fail\\n\", 11)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Blank
      , Comment "copy_capped(x1 = src NUL-terminated, x20 = cursor): appends to buf,"
      , Comment "capped at buf+1024. Returns x0 = 0 ok, 1 over-cap. Clobbers x0-x4."
      , Label "copy_capped"
      , MovImm x2 0
      , LocalInstr "1" (CmpImm x2 (mustU12 1024))
      , Trail (BCond Hs "3f") "src over-cap without NUL"
      , LdrbReg w3 x1 x2
      , Cbz w3 "2f"
      , AddImm x2 x2 (mustU12 1)
      , B "1b"
      , LocalInstr "2" (Adrp x4 "buf")
      , AddLo12 x4 x4 "buf"
      , Trail (SubReg x4 x20 x4) "used"
      , Trail (AddReg x4 x4 x2) "used + srclen"
      , CmpImm x4 (mustU12 1024)
      , BCond Hi "3f"
      , MovImm x4 0
      , LocalInstr "4" (CmpReg x4 x2)
      , BCond Hs "5f"
      , LdrbReg w3 x1 x4
      , StrbPost w3 x20 (mustU12 1)
      , AddImm x4 x4 (mustU12 1)
      , B "4b"
      , LocalInstr "5" (MovImm x0 0)
      , Ret
      , LocalInstr "3" (MovImm x0 1)
      , Ret
      , Label "okmsg"
      , Ascii "write ok\n"
      , Label "failmsg"
      , Ascii "write fail\n"
      , Blank
      , DataSection
      , Align 3
      , Label "buf"
      , Space 1024
      ]

-- | Rendered @write.s@ text.
writeText :: String
writeText = render writeInstrs
