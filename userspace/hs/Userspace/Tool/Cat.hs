{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Cat
Description : Builder reproducing @userspace/cat.s@ byte-for-byte.
Stability   : experimental
-}
module Userspace.Tool.Cat (
  catInstrs,
  catText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustX)

-- | Instruction list for @cat.s@, in file order.
catInstrs :: [Instr]
catInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      x19 = mustX 19
      x20 = mustX 20
      svcOpen = mustSvc 0x04
      svcRead = mustSvc 0x05
      svcClose = mustSvc 0x07
      svcWrite = mustSvc 0x01
      svcExit = mustSvc 0x02
   in [ Comment "EL0 cat for /bin/cat (pid1 slice, plans/pid1-init-shell.md step 4)."
      , Comment "Streams a file to stdout via the fd ring: OPEN 0x04, READ 0x05 loop,"
      , Comment "CLOSE 0x07. Path is argv[1], defaulting to /probe.txt so the legacy"
      , Comment "`run /bin/cat` probe (qemu-fd-el0.exp) keeps working. Prints `cat ok`"
      , Comment "and exits 0 after the full stream; a missing path prints `cat: ENOENT`"
      , Comment "(keeps the fs-harness ENOENT match), any other mismatch `cat fail`,"
      , Comment "all exit 1. Read chunk is 1024 (well under the 64K svc buffer cap)."
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
      , B "do_open"
      , Label "have_arg"
      , Trail (LdrOff x19 SP (mustU12 16)) "argv[1]"
      , Label "do_open"
      , MovReg x0 x19
      , Trail (MovImm x1 0) "O_RDONLY"
      , Trail (Svc svcOpen Nothing) "OPEN -> x0 = fd"
      , CmpImm x0 (mustU12 34)
      , BCond Hi "fail"
      , Trail (MovReg x19 x0) "fd"
      , Label "read_loop"
      , Adrp x1 "buf"
      , AddLo12 x1 x1 "buf"
      , MovImm x2 1024
      , MovReg x0 x19
      , Trail (Svc svcRead Nothing) "READ -> x0 = n"
      , CmpImm x0 (mustU12 1024)
      , Trail (BCond Hi "fail") "negative errno or over-cap"
      , Cbz x0 "eof"
      , Trail (MovReg x20 x0) "n"
      , Adrp x1 "buf"
      , AddLo12 x1 x1 "buf"
      , MovReg x2 x20
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, buf, n)"
      , B "read_loop"
      , Label "eof"
      , MovReg x0 x19
      , Trail (Svc svcClose Nothing) "CLOSE(fd)"
      , Cbnz x0 "fail"
      , Adrp x1 "okmsg"
      , AddLo12 x1 x1 "okmsg"
      , MovImm x2 7
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"cat ok\\n\", 7)"
      , MovImm x0 0
      , Trail (Svc svcExit Nothing) "EXIT(0)"
      , Label "fail"
      , MovNeg x1 2
      , CmpReg x0 x1
      , Trail (BCond Eq "enoent") "x0 is the resumed errno here"
      , Adrp x1 "failmsg"
      , AddLo12 x1 x1 "failmsg"
      , MovImm x2 9
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"cat fail\\n\", 9)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "enoent"
      , Adrp x1 "enoentmsg"
      , AddLo12 x1 x1 "enoentmsg"
      , MovImm x2 12
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"cat: ENOENT\\n\", 12)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "defpath"
      , Ascii "/probe.txt\0"
      , Label "okmsg"
      , Ascii "cat ok\n"
      , Label "failmsg"
      , Ascii "cat fail\n"
      , Label "enoentmsg"
      , Ascii "cat: ENOENT\n"
      , Blank
      , DataSection
      , Align 3
      , Label "buf"
      , Space 1024
      ]

-- | Rendered @cat.s@ text.
catText :: String
catText = render catInstrs
