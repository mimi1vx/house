{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Sh
Description : Builder reproducing @userspace/sh.s@ byte-for-byte.
Stability   : experimental
-}
module Userspace.Tool.Sh (
  shInstrs,
  shText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustX)

-- | Instruction list for @sh.s@, in file order.
shInstrs :: [Instr]
shInstrs =
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
   in [ Comment "EL0 sh for /bin/sh (dx7.2)."
      , Comment "Minimal prompt-and-echo shell over the fd ring: OPEN 0x04 /dev/console"
      , Comment "(dx7.1 reserved path, no new svc), print `sh$ `, then echo each READ 0x05"
      , Comment "chunk until an empty read (console idle poll), CLOSE 0x07 and exit 0. An"
      , Comment "open miss prints `sh: ENOENT`, any other mismatch `sh fail`, all exit 1."
      , Comment "Read chunk is 1024 (well under the 64K svc buffer cap)."
      , Arch "armv8-a"
      , Text
      , Global "_start"
      , TypeDir "_start" "%function"
      , Label "_start"
      , Adrp x19 "conpath"
      , AddLo12 x19 x19 "conpath"
      , MovReg x0 x19
      , Trail (MovImm x1 0) "O_RDONLY"
      , Trail (Svc svcOpen Nothing) "OPEN -> x0 = fd"
      , CmpImm x0 (mustU12 34)
      , BCond Hi "fail"
      , Trail (MovReg x19 x0) "fd"
      , Label "prompt"
      , Adrp x1 "promptmsg"
      , AddLo12 x1 x1 "promptmsg"
      , MovImm x2 4
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"sh$ \", 4)"
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
      , B "prompt"
      , Label "eof"
      , MovReg x0 x19
      , Trail (Svc svcClose Nothing) "CLOSE(fd)"
      , Cbnz x0 "fail"
      , MovImm x0 0
      , Trail (Svc svcExit Nothing) "EXIT(0)"
      , Label "fail"
      , MovNeg x1 2
      , CmpReg x0 x1
      , Trail (BCond Eq "enoent") "x0 is the resumed errno here"
      , Adrp x1 "failmsg"
      , AddLo12 x1 x1 "failmsg"
      , MovImm x2 8
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"sh fail\\n\", 8)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "enoent"
      , Adrp x1 "enoentmsg"
      , AddLo12 x1 x1 "enoentmsg"
      , MovImm x2 11
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"sh: ENOENT\\n\", 11)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "conpath"
      , Ascii "/dev/console\0"
      , Label "promptmsg"
      , Ascii "sh$ "
      , Label "failmsg"
      , Ascii "sh fail\n"
      , Label "enoentmsg"
      , Ascii "sh: ENOENT\n"
      , Blank
      , DataSection
      , Align 3
      , Label "buf"
      , Space 1024
      ]

-- | Rendered @sh.s@ text.
shText :: String
shText = render shInstrs
