{-# LANGUAGE GHC2024 #-}

{- |
Module      : Userspace.Tool.Init
Description : Builder reproducing @userspace/init.s@ byte-for-byte.
Stability   : experimental
-}
module Userspace.Tool.Init (
  initInstrs,
  initText,
)
where

import Userspace.Asm
import Userspace.Tool.Common (mustSvc, mustU12, mustX)

-- | Instruction list for @init.s@, in file order.
initInstrs :: [Instr]
initInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      x19 = mustX 19
      x20 = mustX 20
      svcYield = mustSvc 0x00
      svcWrite = mustSvc 0x01
      svcExit = mustSvc 0x02
      svcFork = mustSvc 0x08
      svcWait = mustSvc 0x09
      svcExec = mustSvc 0x0B
   in [ Comment "EL0 pid1 for /sbin/init (pid1 slice)."
      , Comment "v4: minimal getty supervisor: WRITE \"init up\" once, then respawn forever:"
      , Comment "FORK, child EXEC /bin/sh, parent WAIT + WRITE \"init done\", YIELD-paced"
      , Comment "re-loop with a bounded YIELD budget (2048 parks) so an instantly-exiting"
      , Comment "child cannot starve the shell. Exec miss fails closed per iteration (`init fail` +"
      , Comment "EXIT 1 in the child); the exit code stays visible via `init exit`"
      , Comment "from Kernel.Init's reaper thread only when init itself exits."
      , Arch "armv8-a"
      , Text
      , Global "_start"
      , TypeDir "_start" "%function"
      , Label "_start"
      , Adrp x1 "upmsg"
      , AddLo12 x1 x1 "upmsg"
      , MovImm x2 8
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"init up\\n\", 8)"
      , Label "respawn"
      , Trail (Svc svcFork Nothing) "FORK -> x0 = 0 (child) | pid (parent)"
      , Cbz x0 "child"
      , CmpImm x0 (mustU12 0)
      , Trail (BCond Lt "initfail") "negative errno: fork refused"
      , Trail (MovReg x19 x0) "child pid"
      , MovReg x0 x19
      , Trail (Svc svcWait Nothing) "WAIT(child) -> x0 = exit code"
      , Adrp x1 "donemsg"
      , AddLo12 x1 x1 "donemsg"
      , MovImm x2 10
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"init done\\n\", 10)"
      , Trail (MovImm x20 2048) "pace budget: 2048 YIELD parks, not a sleep"
      , Label "pace"
      , Trail (Svc svcYield Nothing) "YIELD: park so a fast-exiting child cannot starve the shell"
      , SubImm x20 x20 (mustU12 1)
      , Cbnz x20 "pace"
      , B "respawn"
      , Label "child"
      , Adrp x0 "shpath"
      , AddLo12 x0 x0 "shpath"
      , Trail (Svc svcExec Nothing) "EXEC(\"/bin/sh\") -> no return on success"
      , Trail (B "initfail") "exec miss: fail closed like sh"
      , Label "initfail"
      , Adrp x1 "failmsg"
      , AddLo12 x1 x1 "failmsg"
      , MovImm x2 10
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE(1, \"init fail\\n\", 10)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "upmsg"
      , Ascii "init up\n"
      , Label "donemsg"
      , Ascii "init done\n"
      , Label "failmsg"
      , Ascii "init fail\n"
      , Label "shpath"
      , Ascii "/bin/sh\0"
      , Blank
      , DataSection
      , Align 3
      , Label "scratch"
      , Quad 0
      ]

-- | Rendered @init.s@ text.
initText :: String
initText = render initInstrs
