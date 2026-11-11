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
import Userspace.Tool.Common (mustSvc, mustU12, mustW, mustX)

-- | Instruction list for @sh.s@, in file order.
shInstrs :: [Instr]
shInstrs =
  let x0 = mustX 0
      x1 = mustX 1
      x2 = mustX 2
      x8 = mustX 8
      x9 = mustX 9
      x10 = mustX 10
      x11 = mustX 11
      x12 = mustX 12
      x13 = mustX 13
      x14 = mustX 14
      x15 = mustX 15
      x16 = mustX 16
      x17 = mustX 17
      x18 = mustX 18
      x19 = mustX 19
      x20 = mustX 20
      x21 = mustX 21
      x22 = mustX 22
      x23 = mustX 23
      x24 = mustX 24
      x25 = mustX 25
      x26 = mustX 26
      x27 = mustX 27
      x28 = mustX 28
      x29 = mustX 29
      x30 = mustX 30
      w0 = mustW 0
      w1 = mustW 1
      w9 = mustW 9
      w10 = mustW 10
      w11 = mustW 11
      w12 = mustW 12
      w15 = mustW 15
      w23 = mustW 23
      w27 = mustW 27
      w28 = mustW 28
      u0 = mustU12 0
      u1 = mustU12 1
      u2 = mustU12 2
      u6 = mustU12 6
      u8 = mustU12 8
      u10 = mustU12 10
      u16 = mustU12 16
      u64 = mustU12 64
      u32 = mustU12 32
      u34 = mustU12 34
      u48 = mustU12 48
      u60 = mustU12 60
      u62 = mustU12 62
      u100 = mustU12 100
      u124 = mustU12 124
      u128 = mustU12 128
      u256 = mustU12 256
      svcOpen = mustSvc 0x04
      svcRead = mustSvc 0x05
      svcClose = mustSvc 0x07
      svcFork = mustSvc 0x08
      svcWait = mustSvc 0x09
      svcSeek = mustSvc 0x0A
      svcExec = mustSvc 0x0B
      svcPipe = mustSvc 0x19
      svcDup2 = mustSvc 0x1A
      svcWrite = mustSvc 0x06
      svcExit = mustSvc 0x02
      -- Print the rodata string @lbl@ of length @n@ via fd 1. Clobbers x0-x2.
      emitLit lbl n =
        [ Adrp x1 lbl
        , AddLo12 x1 x1 lbl
        , MovImm x2 n
        , Bl "printm"
        ]
      -- Parse error tail: print @lbl@ and leave runline (single exit).
      failWith lbl n = emitLit lbl n ++ [B "rl_exit"]
   in [ Comment "EL0 sh for /bin/sh (dx7.2 + house-1mo.2 + house-1mo.5 + house-1mo.6 + house-1mo.7)."
      , Comment "Line discipline over the fd ring: OPEN 0x04 /dev/console"
      , Comment "(dx7.1 reserved path, no new svc), login prompt then `sh$ `, then accumulate"
      , Comment "READ 0x05 chunks into a 4 KiB line buffer until `\\n`. Per-byte:"
      , Comment "`\\n` echoes + reprompts, BS/DEL drops one byte (echo `\\b \\b`),"
      , Comment "Ctrl-U drops the line, Ctrl-C drops + reprompts. Overflow flushes"
      , Comment "as-is (bytes already echoed per-byte, so reset, no wrap). Empty"
      , Comment "read (console idle poll) is tolerated a few times (~5s each) so a"
      , Comment "fragmented line still completes; only consecutive empties CLOSE +"
      , Comment "EXIT 0. `sh: ENOENT` and"
      , Comment "`sh fail` stay byte-identical, all exit 1. Chunk is 1024, line"
      , Comment "cap is 4096 (both well under the 64K svc buffer cap)."
      , Comment "house-1mo.6: startup binds fd 0 to the console and ensures fd 1"
      , Comment "via a zero-length WRITE_FD probe (no bytes escape on a bound fd;"
      , Comment "EBADF means unbound, so OPEN /dev/console O_WRONLY + DUP2(c, 1))."
      , Comment "Each line parses into stage [args] [</>] [>|>>] [| ...]: words"
      , Comment "split on space/tab (16 args, 256 B each); consumed gaps are NULed,"
      , Comment "so both skip loops skip NUL as well as space/tab; `|`, `>`, `>>`, `<` are"
      , Comment "standalone fields only, so `echo a|b` stays one word. Executor:"
      , Comment "N-1 PIPEs, per-stage FORK, child DUP2 wiring (stdin: console or"
      , Comment "`<` file or pipe; stdout: probe-bound default or `>`/`>>` file or"
      , Comment "pipe), child closes ALL pipe fds, parent closes its copies at once"
      , Comment "(else EOF never arrives) then WAITs left-to-right, reporting"
      , Comment "`ok exit <last>`. Builtins (exit/help/echo) run in a forked child"
      , Comment "with the same wiring instead of EXEC. `>>` is OPEN + SEEK_END +"
      , Comment "write (no O_APPEND in the fd layer; single-user TOCTOU accepted)."
      , Comment "EXEC carries argv extras in x1 (pointer array, 0 when none); a"
      , Comment "miss on both /bin/<argv0> and <argv0> prints `sh: not found`."
      , Comment "house-1mo.7: login: after console bind print `house login: `, read one"
      , Comment "line into loginbuf (33 B, silent truncate at 32, empty => root), log"
      , Comment "`login <name>` to fd 1, then prompt. Ctrl-C reprints login (no exit)."
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
      , CmpImm x0 u34
      , BCond Hi "fail"
      , Trail (MovReg x19 x0) "fd"
      , Adrp x24 "buf"
      , AddLo12 x24 x24 "buf"
      , Adrp x26 "linebuf"
      , AddLo12 x26 x26 "linebuf"
      , Trail (MovImm x20 0) "len = 0"
      , Trail (MovImm x27 0) "empties = 0"
      , Trail (MovReg x0 x19) "confd"
      , MovImm x1 0
      , Trail (Svc svcDup2 Nothing) "DUP2(confd, 0)"
      , CmpImm x0 u0
      , Trail (BCond Lt "fail") "negative errno"
      , MovImm x0 1
      , MovReg x1 x24
      , MovImm x2 0
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, buf, 0) probe: silent when bound"
      , CmpImm x0 u0
      , Trail (BCond Lt "bind1") "EBADF: fd 1 unbound"
      , B "login"
      , Label "bind1"
      , Adrp x9 "conpath"
      , AddLo12 x9 x9 "conpath"
      , MovReg x0 x9
      , Trail (MovImm x1 1) "O_WRONLY"
      , Trail (Svc svcOpen Nothing) "OPEN -> x0 = fd"
      , CmpImm x0 u34
      , BCond Hi "nofd1"
      , Trail (MovReg x25 x0) "stash across DUP2"
      , MovReg x0 x25
      , MovImm x1 1
      , Trail (Svc svcDup2 Nothing) "DUP2(c, 1)"
      , MovReg x0 x25
      , Trail (Svc svcClose Nothing) "CLOSE(c)"
      , Label "nofd1"
      , Label "login"
      , Adrp x1 "loginmsg"
      , AddLo12 x1 x1 "loginmsg"
      , MovImm x2 13
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"house login: \", 13)"
      , Adrp x26 "loginbuf"
      , AddLo12 x26 x26 "loginbuf"
      , Trail (MovImm x20 0) "login len = 0"
      , Trail (MovImm x27 0) "login empties = 0"
      , Label "login_read_chunk"
      , Trail (MovReg x1 x24) "buf"
      , MovImm x2 1024
      , MovReg x0 x19
      , Trail (Svc svcRead Nothing) "READ -> x0 = n"
      , CmpImm x0 (mustU12 1024)
      , Trail (BCond Hi "fail") "negative errno or over-cap"
      , Cbnz x0 "login_got_data"
      , Trail (AddImm x27 x27 u1) "empties++"
      , CmpImm x27 u6
      , Trail (BCond Hs "eof") "6 consecutive empties: EOF"
      , B "login_read_chunk"
      , Label "login_got_data"
      , Trail (MovImm x27 0) "empties = 0"
      , Trail (MovReg x21 x0) "n"
      , Trail (MovImm x22 0) "i = 0"
      , Label "login_byte_loop"
      , CmpReg x22 x21
      , Trail (BCond Hs "login_read_chunk") "i >= n: next chunk"
      , LdrbReg w23 x24 x22
      , Trail (AddImm x22 x22 u1) "i++"
      , CmpImm w23 (mustU12 10)
      , Trail (BCond Eq "login_nl") "newline"
      , CmpImm w23 (mustU12 127)
      , Trail (BCond Eq "login_bs") "DEL"
      , CmpImm w23 (mustU12 8)
      , Trail (BCond Eq "login_bs") "BS"
      , CmpImm w23 (mustU12 21)
      , Trail (BCond Eq "login_cu") "Ctrl-U"
      , CmpImm w23 (mustU12 3)
      , Trail (BCond Eq "login_cc") "Ctrl-C"
      , CmpImm x20 u32
      , Trail (BCond Hs "login_byte_loop") "len >= 32: silent truncate, ignore"
      , AddReg x1 x26 x20
      , StrbOff w23 x1 u0
      , Trail (AddImm x20 x20 u1) "len++"
      , MovImm x2 1
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, byte, 1)"
      , B "login_byte_loop"
      , Label "login_bs"
      , Cbz x20 "login_byte_loop"
      , Trail (SubImm x20 x20 u1) "len--"
      , Adrp x1 "bsmsg"
      , AddLo12 x1 x1 "bsmsg"
      , MovImm x2 3
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"\\b \\b\", 3)"
      , B "login_byte_loop"
      , Label "login_cu"
      , Trail (MovImm x20 0) "drop line"
      , B "login_byte_loop"
      , Label "login_cc"
      , Trail (MovImm x20 0) "drop line"
      , Adrp x1 "loginmsg"
      , AddLo12 x1 x1 "loginmsg"
      , MovImm x2 13
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"house login: \", 13)"
      , B "login_byte_loop"
      , Label "login_nl"
      , Adrp x1 "nlmsg"
      , AddLo12 x1 x1 "nlmsg"
      , MovImm x2 1
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"\\n\", 1)"
      , AddReg x1 x26 x20
      , MovImm w0 0
      , Trail (StrbOff w0 x1 u0) "NUL-terminate (loginbuf has 33 B)"
      , Cbz x20 "login_empty"
      , B "login_print"
      , Label "login_empty"
      , Trail (MovReg x9 x26) "dest = loginbuf"
      , MovChar w10 'r'
      , StrbPost w10 x9 u1
      , MovChar w10 'o'
      , StrbPost w10 x9 u1
      , MovChar w10 'o'
      , StrbPost w10 x9 u1
      , MovChar w10 't'
      , StrbPost w10 x9 u1
      , Trail (MovImm x20 4) "empty => root"
      , Label "login_print"
      , Adrp x1 "loginprefix"
      , AddLo12 x1 x1 "loginprefix"
      , MovImm x2 6
      , Bl "printm"
      , Trail (MovReg x1 x26) "loginbuf"
      , Trail (MovReg x2 x20) "len"
      , Bl "printm"
      , Adrp x1 "nlmsg"
      , AddLo12 x1 x1 "nlmsg"
      , MovImm x2 1
      , Bl "printm"
      , Adrp x26 "linebuf"
      , AddLo12 x26 x26 "linebuf"
      , Trail (MovImm x20 0) "len = 0"
      , Trail (MovImm x27 0) "empties = 0"
      , Label "prompt"
      , Adrp x1 "promptmsg"
      , AddLo12 x1 x1 "promptmsg"
      , MovImm x2 4
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"sh$ \", 4)"
      , Label "read_chunk"
      , Trail (MovReg x1 x24) "buf"
      , MovImm x2 1024
      , MovReg x0 x19
      , Trail (Svc svcRead Nothing) "READ -> x0 = n"
      , CmpImm x0 (mustU12 1024)
      , Trail (BCond Hi "fail") "negative errno or over-cap"
      , Cbnz x0 "got_data"
      , -- Empty poll: the console was quiet for ~5s, not necessarily gone.
        -- Tolerate a few (slow typists, loaded hosts) before EOF-exiting so a
        -- fragmented line still completes in this instance.
        Trail (AddImm x27 x27 u1) "empties++"
      , CmpImm x27 u6
      , Trail (BCond Hs "eof") "6 consecutive empties: EOF"
      , B "read_chunk"
      , Label "got_data"
      , Trail (MovImm x27 0) "empties = 0"
      , Trail (MovReg x21 x0) "n"
      , Trail (MovImm x22 0) "i = 0"
      , Label "byte_loop"
      , CmpReg x22 x21
      , Trail (BCond Hs "read_chunk") "i >= n: next chunk"
      , LdrbReg w23 x24 x22
      , Trail (AddImm x22 x22 u1) "i++"
      , CmpImm w23 (mustU12 10)
      , Trail (BCond Eq "handle_nl") "newline"
      , CmpImm w23 (mustU12 127)
      , Trail (BCond Eq "handle_bs") "DEL"
      , CmpImm w23 (mustU12 8)
      , Trail (BCond Eq "handle_bs") "BS"
      , CmpImm w23 (mustU12 21)
      , Trail (BCond Eq "handle_cu") "Ctrl-U"
      , CmpImm w23 (mustU12 3)
      , Trail (BCond Eq "handle_cc") "Ctrl-C"
      , CmpShift12 x20 (mustU12 1)
      , Trail (BCond Lo "store") "len < 4096"
      , Trail (MovImm x20 0) "overflow: flush-as-is, reset"
      , Label "store"
      , AddReg x1 x26 x20
      , StrbOff w23 x1 u0
      , Trail (AddImm x20 x20 u1) "len++"
      , MovImm x2 1
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, byte, 1)"
      , B "byte_loop"
      , Label "handle_nl"
      , Adrp x1 "nlmsg"
      , AddLo12 x1 x1 "nlmsg"
      , MovImm x2 1
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"\\n\", 1)"
      , AddReg x1 x26 x20
      , MovImm w0 0
      , Trail (StrbOff w0 x1 u0) "NUL-terminate (linespare guards len == 4096)"
      , Bl "runline"
      , Trail (MovImm x20 0) "len = 0"
      , Trail (MovImm x27 0) "empties = 0 (runline clobbers x27)"
      , Adrp x1 "promptmsg"
      , AddLo12 x1 x1 "promptmsg"
      , MovImm x2 4
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"sh$ \", 4)"
      , B "byte_loop"
      , Label "handle_bs"
      , Cbz x20 "byte_loop"
      , Trail (SubImm x20 x20 u1) "len--"
      , Adrp x1 "bsmsg"
      , AddLo12 x1 x1 "bsmsg"
      , MovImm x2 3
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"\\b \\b\", 3)"
      , B "byte_loop"
      , Label "handle_cu"
      , Trail (MovImm x20 0) "drop line"
      , B "byte_loop"
      , Label "handle_cc"
      , Trail (MovImm x20 0) "drop line"
      , Adrp x1 "promptmsg"
      , AddLo12 x1 x1 "promptmsg"
      , MovImm x2 4
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"sh$ \", 4)"
      , B "byte_loop"
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
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"sh fail\\n\", 8)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , Label "enoent"
      , Adrp x1 "enoentmsg"
      , AddLo12 x1 x1 "enoentmsg"
      , MovImm x2 11
      , MovImm x0 1
      , Trail (Svc svcWrite Nothing) "WRITE_FD(1, \"sh: ENOENT\\n\", 11)"
      , MovImm x0 1
      , Trail (Svc svcExit Nothing) "EXIT(1)"
      , -- Parse + execute one line. Preserves x19/x24/x26; clobbers the rest.
        -- Called from handle_nl with x20 = len; returns via rl_exit always
        -- (forked children EXIT, never return).
        Label "runline"
      , StpPush x29 x30 SP
      , MovReg x29 SP
      , Cbz x20 "rl_exit"
      , Trail (MovImm x27 0) "stage = 0"
      , Trail (MovImm x28 0) "argc = 0"
      , Trail (MovImm x16 0) "have_in = 0"
      , Trail (MovImm x17 0) "have_out = 0"
      , Trail (MovImm x18 0) "append = 0"
      , Trail (MovImm x8 0) "zero index for ldrb [base, x8]"
      , Trail (MovImm x25 0) "pos = 0"
      , Adrp x10 "argvtab"
      , AddLo12 x10 x10 "argvtab"
      , Adrp x11 "argc_tab"
      , AddLo12 x11 x11 "argc_tab"
      , Adrp x12 "in_tab"
      , AddLo12 x12 x12 "in_tab"
      , Adrp x13 "out_tab"
      , AddLo12 x13 x13 "out_tab"
      , Trail (MovImm x15 0) "clear stale redirect tables each line"
      , Trail (MovImm x14 0) "(in/out ptrs persist across lines)"
      , Label "rl_cleartabs"
      , StrReg x15 x12 x14
      , StrReg x15 x13 x14
      , Trail (AddImm x14 x14 u8) "off += 8"
      , Trail (CmpImm x14 u64) "off >= 64: done"
      , BCond Lo "rl_cleartabs"
      , B "rl_skip"
      , Label "rl_skip"
      , CmpReg x25 x20
      , Trail (BCond Hs "rl_endline") "pos >= len"
      , LdrbReg w23 x26 x25
      , Trail (AddImm x25 x25 u1) "pos++"
      , CmpImm w23 u32
      , BCond Eq "rl_skip"
      , CmpImm w23 (mustU12 9)
      , BCond Eq "rl_skip"
      , CmpImm w23 u0
      , BCond Eq "rl_skip"
      , Trail (SubImm x9 x25 u1) "field_start = pos - 1"
      , MovReg x14 x9
      , Label "rl_scanloop"
      , CmpReg x14 x20
      , Trail (BCond Hs "rl_fend") "end of line"
      , LdrbReg w23 x26 x14
      , CmpImm w23 u32
      , BCond Eq "rl_fend"
      , CmpImm w23 (mustU12 9)
      , BCond Eq "rl_fend"
      , Trail (AddImm x14 x14 u1) "end++"
      , B "rl_scanloop"
      , Label "rl_fend"
      , Trail (SubReg x15 x14 x9) "len = end - start"
      , CmpImm x15 u256
      , Trail (BCond Hi "rl_toolong") "field > 256 B"
      , CmpReg x14 x20
      , Trail (BCond Hs "rl_class") "at end: NUL already in place"
      , LdrbReg w23 x26 x14
      , CmpImm w23 u32
      , BCond Eq "rl_nul"
      , CmpImm w23 (mustU12 9)
      , Trail (BCond Ne "rl_class") "operator abuts: keep the char"
      , Label "rl_nul"
      , AddReg x0 x26 x14
      , MovImm w23 0
      , StrbOff w23 x0 u0
      , Label "rl_class"
      , LdrbReg w23 x26 x9
      , CmpImm x15 u1
      , Trail (BCond Ne "rl_maybeappend") "len != 1"
      , CmpImm w23 u124
      , BCond Eq "rl_pipe"
      , CmpImm w23 u62
      , BCond Eq "rl_redirout"
      , CmpImm w23 u60
      , BCond Eq "rl_redirin"
      , B "rl_word"
      , Label "rl_maybeappend"
      , CmpImm x15 u2
      , Trail (BCond Ne "rl_word") "len != 2"
      , AddReg x0 x26 x9
      , LdrbReg w1 x0 x8
      , CmpImm w1 u62
      , Trail (BCond Ne "rl_word") "second char is not >"
      , CmpImm w23 u62
      , Trail (BCond Ne "rl_word") "first char is not >"
      , B "rl_redirappend"
      , Label "rl_word"
      , CmpImm x28 u16
      , Trail (BCond Hs "rl_manyargs") "argc >= 16"
      , AddReg x0 x26 x9
      , StrMem x0 x10
      , Trail (AddImm x10 x10 u8) "argv ptr += 8"
      , Trail (AddImm x28 x28 u1) "argc++"
      , MovReg x25 x14
      , B "rl_skip"
      , Label "rl_pipe"
      , Cbz x28 "rl_missing"
      , StrbOff w28 x11 u0
      , CmpImm x27 (mustU12 7)
      , Trail (BCond Hs "rl_pipelong") "stage 7 piped: a 9th stage"
      , Trail (AddImm x27 x27 u1) "stage++"
      , MovImm x28 0
      , MovImm x16 0
      , MovImm x17 0
      , MovImm x18 0
      , Trail (AddImm x11 x11 u1) "argc ptr += 1"
      , Trail (AddImm x12 x12 u8) "in ptr += 8"
      , Trail (AddImm x13 x13 u8) "out ptr += 8"
      , Adrp x10 "argvtab"
      , AddLo12 x10 x10 "argvtab"
      , MovReg x15 x27
      , Label "rl_psloop"
      , Cbz x15 "rl_pipedone"
      , Trail (AddImm x10 x10 u128) "argv ptr += 128"
      , Trail (SubImm x15 x15 u1) "stage--"
      , B "rl_psloop"
      , Label "rl_pipedone"
      , MovReg x25 x14
      , B "rl_skip"
      , Label "rl_redirout"
      , MovImm x0 1
      , B "rl_redir"
      , Label "rl_redirappend"
      , MovImm x0 2
      , B "rl_redir"
      , Label "rl_redirin"
      , MovImm x0 0
      , Label "rl_redir"
      , Trail (MovReg x25 x14) "pos = end"
      , Label "rl_rskip"
      , CmpReg x25 x20
      , Trail (BCond Hs "rl_missing") "dangling redirect"
      , LdrbReg w23 x26 x25
      , Trail (AddImm x25 x25 u1) "pos++"
      , CmpImm w23 u32
      , BCond Eq "rl_rskip"
      , CmpImm w23 (mustU12 9)
      , BCond Eq "rl_rskip"
      , CmpImm w23 u0
      , BCond Eq "rl_rskip"
      , Trail (SubImm x9 x25 u1) "filename start = pos - 1"
      , MovReg x14 x9
      , Label "rl_rscan"
      , CmpReg x14 x20
      , Trail (BCond Hs "rl_rfend") "end of line"
      , LdrbReg w23 x26 x14
      , CmpImm w23 u32
      , BCond Eq "rl_rfend"
      , CmpImm w23 (mustU12 9)
      , BCond Eq "rl_rfend"
      , Trail (AddImm x14 x14 u1) "end++"
      , B "rl_rscan"
      , Label "rl_rfend"
      , Trail (SubReg x15 x14 x9) "len = end - start"
      , CmpImm x15 u256
      , Trail (BCond Hi "rl_toolong") "filename > 256 B"
      , CmpReg x14 x20
      , Trail (BCond Hs "rl_rnot1") "at end: NUL already in place"
      , LdrbReg w23 x26 x14
      , CmpImm w23 u32
      , BCond Eq "rl_rnul"
      , CmpImm w23 (mustU12 9)
      , Trail (BCond Ne "rl_rnot1") "operator abuts: keep the char"
      , Label "rl_rnul"
      , AddReg x1 x26 x14
      , MovImm w23 0
      , StrbOff w23 x1 u0
      , Label "rl_rnot1"
      , CmpImm x15 u1
      , Trail (BCond Ne "rl_rnot2") "len != 1"
      , LdrbReg w23 x26 x9
      , CmpImm w23 u124
      , BCond Eq "rl_missing"
      , CmpImm w23 u62
      , BCond Eq "rl_missing"
      , CmpImm w23 u60
      , BCond Eq "rl_missing"
      , B "rl_rstore"
      , Label "rl_rnot2"
      , CmpImm x15 u2
      , Trail (BCond Ne "rl_rstore") "len != 2"
      , LdrbReg w23 x26 x9
      , CmpImm w23 u62
      , Trail (BCond Ne "rl_rstore") "not >>"
      , AddReg x1 x26 x9
      , LdrbReg w1 x1 x8
      , CmpImm w1 u62
      , Trail (BCond Ne "rl_rstore") "not >>"
      , B "rl_missing"
      , Label "rl_rstore"
      , CmpImm x0 u0
      , BCond Eq "rl_storein"
      , Cbnz x17 "rl_ambiguous"
      , AddReg x1 x26 x9
      , StrMem x1 x13
      , Trail (MovImm x17 1) "have_out = 1"
      , CmpImm x0 u2
      , Trail (BCond Ne "rl_routdone") "truncate, not append"
      , Trail (MovImm x18 1) "append = 1"
      , Label "rl_routdone"
      , MovReg x25 x14
      , B "rl_skip"
      , Label "rl_storein"
      , Cbnz x16 "rl_ambiguous"
      , AddReg x1 x26 x9
      , StrMem x1 x12
      , Trail (MovImm x16 1) "have_in = 1"
      , MovReg x25 x14
      , B "rl_skip"
      , Label "rl_endline"
      , Cbnz x28 "rl_exec"
      , Cbnz x27 "rl_missing"
      , Cbnz x16 "rl_missing"
      , Cbnz x17 "rl_missing"
      , B "rl_exit"
      , Label "rl_missing"
      ]
        ++ failWith "missingmsg" 20
        ++ [ Label "rl_ambiguous"
           ]
        ++ failWith "ambigmsg" 24
        ++ [ Label "rl_manyargs"
           ]
        ++ failWith "manyargsmsg" 18
        ++ [ Label "rl_toolong"
           ]
        ++ failWith "toolongmsg" 19
        ++ [ Label "rl_pipelong"
           ]
        ++ failWith "pipelongmsg" 22
        ++ [ Label "rl_exec"
           , StrbOff w28 x11 u0
           , Trail (AddImm x22 x27 u1) "nstages = stage + 1"
           , Trail (SubImm x27 x22 u1) "pipes = nstages - 1"
           , Cbz x27 "rl_forkinit"
           , Trail (MovImm x21 0) "i = 0"
           , Adrp x23 "pipefds"
           , AddLo12 x23 x23 "pipefds"
           , Label "rl_mkpipes"
           , CmpReg x21 x27
           , Trail (BCond Hs "rl_forkinit") "i >= pipes"
           , MovImm x0 0
           , Adrp x1 "wfd_slot"
           , AddLo12 x1 x1 "wfd_slot"
           , MovImm x2 0
           , Trail (Svc svcPipe Nothing) "PIPE -> x0 = rd, [x1] = wr"
           , CmpImm x0 u34
           , Trail (BCond Hi "rl_pipefail") "negative errno or over-cap"
           , StrbOff w0 x23 u0
           , Trail (AddImm x23 x23 u1) "pipefds += 1"
           , Adrp x9 "wfd_slot"
           , AddLo12 x9 x9 "wfd_slot"
           , LdrMem x9 x9
           , StrbOff w9 x23 u0
           , Trail (AddImm x23 x23 u1) "pipefds += 1"
           , Trail (AddImm x21 x21 u1) "i++"
           , B "rl_mkpipes"
           , Label "rl_pipefail"
           , -- No child spawned yet, but close the pairs made so far so a
             -- later line never inherits a half-built pipeline.
             Trail (MovReg x27 x21) "made = i"
           , Trail (AddReg x27 x27 x27) "made = 2 * made"
           , Trail (MovImm x25 0) "idx = 0"
           , Label "rl_pfailclose"
           , CmpReg x25 x27
           , Trail (BCond Hs "rl_pfailexit") "all closed"
           , Adrp x9 "pipefds"
           , AddLo12 x9 x9 "pipefds"
           , LdrbReg w0 x9 x25
           , Trail (Svc svcClose Nothing) "CLOSE(pipefd)"
           , Trail (AddImm x25 x25 u1) "idx++"
           , B "rl_pfailclose"
           , Label "rl_pfailexit"
           ]
        ++ failWith "brokenmsg" 16
        ++ [ Label "rl_forkinit"
           , Trail (MovImm x21 0) "stage idx = 0"
           , Adrp x23 "stage_pids"
           , AddLo12 x23 x23 "stage_pids"
           , Label "rl_forkloop"
           , CmpReg x21 x22
           , Trail (BCond Hs "rl_parentclose") "all stages forked"
           , Trail (Svc svcFork Nothing) "FORK -> x0 = 0 (child) | pid (parent)"
           , Cbz x0 "rl_child"
           , CmpImm x0 u0
           , Trail (BCond Lt "rl_forkfail") "negative errno"
           , StrMem x0 x23
           , Trail (AddImm x23 x23 u8) "pids += 8"
           , Trail (AddImm x21 x21 u1) "stage++"
           , B "rl_forkloop"
           , Label "rl_forkfail"
           ]
        ++ emitLit "brokenmsg" 16
        ++ [ -- Close every pipe end the parent holds, then reap what spawned.
             Trail (SubImm x27 x22 u1) "total = nstages - 1"
           , Trail (AddReg x27 x27 x27) "total = 2 * total"
           , Trail (MovImm x25 0) "idx = 0"
           , Label "rl_ffclose"
           , CmpReg x25 x27
           , Trail (BCond Hs "rl_ffreap") "all closed"
           , Adrp x9 "pipefds"
           , AddLo12 x9 x9 "pipefds"
           , LdrbReg w0 x9 x25
           , Trail (Svc svcClose Nothing) "CLOSE(pipefd)"
           , Trail (AddImm x25 x25 u1) "idx++"
           , B "rl_ffclose"
           , Label "rl_ffreap"
           , Adrp x23 "stage_pids"
           , AddLo12 x23 x23 "stage_pids"
           , Trail (MovImm x25 0) "idx = 0"
           , Label "rl_ffwait"
           , CmpReg x25 x21
           , Trail (BCond Hs "rl_exit") "all reaped"
           , LdrMem x0 x23
           , Trail (Svc svcWait Nothing) "WAIT(reaped)"
           , Trail (AddImm x23 x23 u8) "pids += 8"
           , Trail (AddImm x25 x25 u1) "idx++"
           , B "rl_ffwait"
           , Label "rl_parentclose"
           , Trail (SubImm x27 x22 u1) "total = nstages - 1"
           , Trail (AddReg x27 x27 x27) "total = 2 * total"
           , Trail (MovImm x25 0) "idx = 0"
           , Label "rl_pclose"
           , CmpReg x25 x27
           , Trail (BCond Hs "rl_waitinit") "all closed: readers see EOF"
           , Adrp x9 "pipefds"
           , AddLo12 x9 x9 "pipefds"
           , LdrbReg w0 x9 x25
           , Trail (Svc svcClose Nothing) "CLOSE(pipefd)"
           , Trail (AddImm x25 x25 u1) "idx++"
           , B "rl_pclose"
           , Label "rl_waitinit"
           , Trail (MovImm x21 0) "stage idx = 0"
           , Adrp x23 "stage_pids"
           , AddLo12 x23 x23 "stage_pids"
           , Trail (MovImm x27 0) "lastcode = 0"
           , Label "rl_waitloop"
           , CmpReg x21 x22
           , Trail (BCond Hs "rl_report") "all stages reaped"
           , LdrMem x0 x23
           , Trail (Svc svcWait Nothing) "WAIT(stage)"
           , CmpImm x0 u0
           , Trail (BCond Lt "rl_waitfail") "negative errno"
           , MovReg x27 x0
           , Trail (AddImm x23 x23 u8) "pids += 8"
           , Trail (AddImm x21 x21 u1) "stage++"
           , B "rl_waitloop"
           , Label "rl_waitfail"
           ]
        ++ emitLit "brokenmsg" 16
        ++ [ Trail (AddImm x23 x23 u8) "pids += 8"
           , Trail (AddImm x21 x21 u1) "stage++"
           , B "rl_waitloop"
           , Label "rl_report"
           ]
        ++ emitLit "okexitmsg" 8
        ++ [ -- itoa: lastcode (0..255) into numbuf, hundreds/tens/ones.
             Trail (MovImm x9 0) "hundreds = 0"
           , Label "rl_h100"
           , CmpImm x27 u100
           , Trail (BCond Lo "rl_tens") "code < 100"
           , Trail (SubImm x27 x27 u100) "code -= 100"
           , Trail (AddImm x9 x9 u1) "hundreds++"
           , B "rl_h100"
           , Label "rl_tens"
           , Trail (MovImm x10 0) "tens = 0"
           , Label "rl_t10"
           , CmpImm x27 u10
           , Trail (BCond Lo "rl_digits") "code < 10"
           , Trail (SubImm x27 x27 u10) "code -= 10"
           , Trail (AddImm x10 x10 u1) "tens++"
           , B "rl_t10"
           , Label "rl_digits"
           , Adrp x11 "numbuf"
           , AddLo12 x11 x11 "numbuf"
           , Trail (MovImm x12 0) "count = 0"
           , Trail (MovImm x13 0) "printed = 0"
           , Cbz x9 "rl_notens0"
           , Trail (AddImm x9 x9 u48) "hundreds += '0'"
           , StrbPost w9 x11 u1
           , Trail (AddImm x12 x12 u1) "count++"
           , Trail (MovImm x13 1) "printed = 1"
           , Label "rl_notens0"
           , Cbnz x13 "rl_dotens"
           , Cbz x10 "rl_ones"
           , Label "rl_dotens"
           , Trail (AddImm x10 x10 u48) "tens += '0'"
           , StrbPost w10 x11 u1
           , Trail (AddImm x12 x12 u1) "count++"
           , Trail (MovImm x13 1) "printed = 1"
           , Label "rl_ones"
           , Trail (AddImm x27 x27 u48) "ones += '0'"
           , StrbPost w27 x11 u1
           , Trail (AddImm x12 x12 u1) "count++"
           , Adrp x1 "numbuf"
           , AddLo12 x1 x1 "numbuf"
           , MovReg x2 x12
           , Bl "printm"
           ]
        ++ emitLit "nlmsg" 1
        ++ [ B "rl_exit"
           , -- Forked child: wire fds, then run a builtin or EXEC. Never returns.
             Label "rl_child"
           , CmpImm x21 u0
           , Trail (BCond Ne "ch_pipein") "stage > 0 reads the pipe"
           , Adrp x9 "in_tab"
           , AddLo12 x9 x9 "in_tab"
           , LdrMem x9 x9
           , Cbz x9 "ch_outsel"
           , MovReg x0 x9
           , Trail (MovImm x1 0) "O_RDONLY"
           , Trail (Svc svcOpen Nothing) "OPEN(<file) -> x0 = fd"
           , CmpImm x0 u34
           , Trail (BCond Hi "ch_broken") "negative errno or over-cap"
           , Trail (MovReg x25 x0) "stash across DUP2"
           , MovReg x0 x25
           , MovImm x1 0
           , Trail (Svc svcDup2 Nothing) "DUP2(f, 0)"
           , CmpImm x0 u0
           , Trail (BCond Lt "ch_broken") "negative errno"
           , MovReg x0 x25
           , Trail (Svc svcClose Nothing) "CLOSE(f)"
           , B "ch_outsel"
           , Label "ch_pipein"
           , Trail (SubImm x9 x21 u1) "idx = 2 * (i - 1)"
           , Trail (AddReg x9 x9 x9) "idx = 2 * idx"
           , Adrp x10 "pipefds"
           , AddLo12 x10 x10 "pipefds"
           , LdrbReg w0 x10 x9
           , MovImm x1 0
           , Trail (Svc svcDup2 Nothing) "DUP2(pipeR, 0)"
           , CmpImm x0 u0
           , Trail (BCond Lt "ch_broken") "negative errno"
           , Label "ch_outsel"
           , Trail (SubImm x9 x22 u1) "last = nstages - 1"
           , CmpReg x21 x9
           , Trail (BCond Ne "ch_pipeout") "not the last stage"
           , Adrp x9 "out_tab"
           , AddLo12 x9 x9 "out_tab"
           , MovReg x15 x21
           , Label "ch_outwalk"
           , Cbz x15 "ch_outptr"
           , Trail (AddImm x9 x9 u8) "out ptr += 8"
           , Trail (SubImm x15 x15 u1) "stage--"
           , B "ch_outwalk"
           , Label "ch_outptr"
           , LdrMem x9 x9
           , Cbz x9 "ch_probe1"
           , MovReg x0 x9
           , Cbnz x18 "ch_outapp"
           , MovHex x1 0x241
           , B "ch_outopen"
           , Label "ch_outapp"
           , MovHex x1 0x41
           , Label "ch_outopen"
           , Trail (Svc svcOpen Nothing) "OPEN(>file, 0x241 | >>file, 0x41)"
           , CmpImm x0 u34
           , Trail (BCond Hi "ch_broken") "negative errno or over-cap"
           , Trail (MovReg x25 x0) "stash across DUP2"
           , MovReg x0 x25
           , MovImm x1 1
           , Trail (Svc svcDup2 Nothing) "DUP2(f, 1)"
           , CmpImm x0 u0
           , Trail (BCond Lt "ch_broken") "negative errno"
           , Cbz x18 "ch_outclose"
           , -- Append is OPEN + SEEK_END + write: no O_APPEND in the fd layer.
             -- Two writers racing here could interleave (single-user test box).
             MovReg x0 x25
           , MovImm x1 0
           , MovImm x2 2
           , Trail (Svc svcSeek Nothing) "SEEK(fd, 0, END)"
           , CmpImm x0 u0
           , Trail (BCond Lt "ch_broken") "negative errno"
           , Label "ch_outclose"
           , MovReg x0 x25
           , Trail (Svc svcClose Nothing) "CLOSE(f)"
           , B "ch_execwire"
           , Label "ch_probe1"
           , MovImm x0 1
           , MovReg x1 x24
           , MovImm x2 0
           , Trail (Svc svcWrite Nothing) "WRITE_FD(1, buf, 0) probe: silent when bound"
           , CmpImm x0 u0
           , Trail (BCond Lt "ch_bind1") "EBADF: fd 1 unbound"
           , B "ch_execwire"
           , Label "ch_bind1"
           , Adrp x9 "conpath"
           , AddLo12 x9 x9 "conpath"
           , MovReg x0 x9
           , Trail (MovImm x1 1) "O_WRONLY"
           , Trail (Svc svcOpen Nothing) "OPEN -> x0 = fd"
           , CmpImm x0 u34
           , Trail (BCond Hi "ch_nooutput") "no console and fd 1 unbound"
           , Trail (MovReg x25 x0) "stash across DUP2"
           , MovReg x0 x25
           , MovImm x1 1
           , Trail (Svc svcDup2 Nothing) "DUP2(c, 1)"
           , CmpImm x0 u0
           , Trail (BCond Lt "ch_nooutput") "negative errno"
           , MovReg x0 x25
           , Trail (Svc svcClose Nothing) "CLOSE(c)"
           , B "ch_execwire"
           , Label "ch_nooutput"
           ]
        ++ emitLit "nooutputmsg" 14
        ++ [ MovImm x0 1
           , Trail (Svc svcExit Nothing) "EXIT(1)"
           , Label "ch_pipeout"
           , Trail (AddReg x9 x21 x21) "idx = 2 * i + 1"
           , Trail (AddImm x9 x9 u1) "idx += 1"
           , Adrp x10 "pipefds"
           , AddLo12 x10 x10 "pipefds"
           , LdrbReg w0 x10 x9
           , MovImm x1 1
           , Trail (Svc svcDup2 Nothing) "DUP2(pipeW, 1)"
           , CmpImm x0 u0
           , Trail (BCond Lt "ch_broken") "negative errno"
           , Label "ch_execwire"
           , -- Close every inherited pipe end: readers see EOF only when no
             -- writer (and no stray reader-side alias) remains open.
             Trail (SubImm x27 x22 u1) "total = nstages - 1"
           , Trail (AddReg x27 x27 x27) "total = 2 * total"
           , Trail (MovImm x25 0) "idx = 0"
           , Label "ch_closeloop"
           , CmpReg x25 x27
           , Trail (BCond Hs "ch_builtin") "all closed"
           , Adrp x9 "pipefds"
           , AddLo12 x9 x9 "pipefds"
           , LdrbReg w0 x9 x25
           , Trail (Svc svcClose Nothing) "CLOSE(pipefd)"
           , Trail (AddImm x25 x25 u1) "idx++"
           , B "ch_closeloop"
           , Label "ch_builtin"
           , Trail (MovImm x8 0) "zero index for ldrb [base, x8]"
           , Adrp x9 "argvtab"
           , AddLo12 x9 x9 "argvtab"
           , MovReg x15 x21
           , Label "ch_argwalk"
           , Cbz x15 "ch_argbase"
           , Trail (AddImm x9 x9 u128) "argv ptr += 128"
           , Trail (SubImm x15 x15 u1) "stage--"
           , B "ch_argwalk"
           , Label "ch_argbase"
           , LdrMem x10 x9
           , Trail (MovReg x25 x10) "argv0 survives until the bare EXEC attempt"
           , Adrp x11 "exitname"
           , AddLo12 x11 x11 "exitname"
           , Bl "streq"
           , Cbnz x0 "ch_exit"
           , LdrMem x10 x9
           , Adrp x11 "helpname"
           , AddLo12 x11 x11 "helpname"
           , Bl "streq"
           , Cbnz x0 "ch_help"
           , LdrMem x10 x9
           , Adrp x11 "echoname"
           , AddLo12 x11 x11 "echoname"
           , Bl "streq"
           , Cbnz x0 "ch_echo"
           , B "ch_execbin"
           , Label "ch_exit"
           , Adrp x9 "argc_tab"
           , AddLo12 x9 x9 "argc_tab"
           , LdrbReg w9 x9 x21
           , CmpImm w9 u2
           , Trail (BCond Lo "ch_exit0") "no code arg"
           , Adrp x9 "argvtab"
           , AddLo12 x9 x9 "argvtab"
           , MovReg x15 x21
           , Label "ch_argwalkex"
           , Cbz x15 "ch_argbaseex"
           , Trail (AddImm x9 x9 u128) "argv ptr += 128"
           , Trail (SubImm x15 x15 u1) "stage--"
           , B "ch_argwalkex"
           , Label "ch_argbaseex"
           , Trail (AddImm x9 x9 u8) "skip argv0"
           , LdrMem x11 x9
           , Trail (MovImm x9 0) "acc = 0"
           , Trail (MovImm x12 0) "idx = 0"
           , Label "ch_atoiloop"
           , LdrbReg w0 x11 x12
           , Cbz w0 "ch_atoiexit"
           , Trail (SubImm w0 w0 u48) "digit = c - '0'"
           , CmpImm w0 u10
           , Trail (BCond Hs "ch_atoiexit") "non-digit stops"
           , MovReg x13 x9
           , Trail (AddReg x9 x9 x13) "acc += acc (x2)"
           , Trail (AddReg x9 x9 x13) "acc += acc (x3)"
           , Trail (AddReg x9 x9 x13) "acc += acc (x4)"
           , Trail (AddReg x9 x9 x13) "acc += acc (x5)"
           , Trail (AddReg x9 x9 x13) "acc += acc (x6)"
           , Trail (AddReg x9 x9 x13) "acc += acc (x7)"
           , Trail (AddReg x9 x9 x13) "acc += acc (x8)"
           , Trail (AddReg x9 x9 x13) "acc += acc (x9)"
           , Trail (AddReg x9 x9 x13) "acc += acc (x10)"
           , Trail (AddReg x9 x9 x0) "acc += digit"
           , Trail (AddImm x12 x12 u1) "idx++"
           , B "ch_atoiloop"
           , Label "ch_atoiexit"
           , MovReg x0 x9
           , Trail (Svc svcExit Nothing) "EXIT(code)"
           , Label "ch_exit0"
           , MovImm x0 0
           , Trail (Svc svcExit Nothing) "EXIT(0)"
           , Label "ch_help"
           ]
        ++ emitLit "helpmsg" 15
        ++ [ MovImm x0 0
           , Trail (Svc svcExit Nothing) "EXIT(0)"
           , Label "ch_echo"
           , Adrp x9 "argc_tab"
           , AddLo12 x9 x9 "argc_tab"
           , LdrbReg w10 x9 x21
           , Adrp x9 "argvtab"
           , AddLo12 x9 x9 "argvtab"
           , MovReg x15 x21
           , Label "ch_argwalkec"
           , Cbz x15 "ch_argbaseec"
           , Trail (AddImm x9 x9 u128) "argv ptr += 128"
           , Trail (SubImm x15 x15 u1) "stage--"
           , B "ch_argwalkec"
           , Label "ch_argbaseec"
           , Trail (MovImm x27 1) "j = 1"
           , Label "ch_echoloop"
           , CmpReg x27 x10
           , Trail (BCond Hs "ch_echodone") "j >= argc"
           , MovReg x11 x9
           , MovReg x13 x27
           , Label "ch_echowalk"
           , Cbz x13 "ch_echoword"
           , Trail (AddImm x11 x11 u8) "word ptr += 8"
           , Trail (SubImm x13 x13 u1) "j--"
           , B "ch_echowalk"
           , Label "ch_echoword"
           , LdrMem x1 x11
           , Trail (MovImm x2 0) "len = 0"
           , Label "ch_strlen"
           , LdrbReg w12 x1 x2
           , Cbz w12 "ch_printword"
           , Trail (AddImm x2 x2 u1) "len++"
           , CmpImm x2 u256
           , Trail (BCond Lo "ch_strlen") "cap at 256"
           , Label "ch_printword"
           , Bl "printm"
           , Trail (AddImm x13 x27 u1) "j + 1"
           , CmpReg x13 x10
           , Trail (BCond Hs "ch_echonext") "last word: no space"
           , MovChar w0 ' '
           , Bl "emitb"
           , Label "ch_echonext"
           , Trail (AddImm x27 x27 u1) "j++"
           , B "ch_echoloop"
           , Label "ch_echodone"
           , MovImm w0 10
           , Bl "emitb"
           , MovImm x0 0
           , Trail (Svc svcExit Nothing) "EXIT(0)"
           , Label "ch_execbin"
           , Trail (MovImm x8 0) "zero index for ldrb [base, x8]"
           , Adrp x9 "binprefix"
           , AddLo12 x9 x9 "binprefix"
           , Adrp x10 "binbuf"
           , AddLo12 x10 x10 "binbuf"
           , Label "ch_copybin"
           , LdrbReg w0 x9 x8
           , Cbz w0 "ch_copyarg0"
           , StrbPost w0 x10 u1
           , Trail (AddImm x9 x9 u1) "prefix++"
           , B "ch_copybin"
           , Label "ch_copyarg0"
           , Trail (MovImm x12 0) "idx = 0"
           , Label "ch_copyarg1"
           , LdrbReg w0 x25 x12
           , Cbz w0 "ch_copyarg2"
           , StrbPost w0 x10 u1
           , Trail (AddImm x12 x12 u1) "idx++"
           , CmpImm x12 u256
           , Trail (BCond Lo "ch_copyarg1") "cap at 256"
           , Label "ch_copyarg2"
           , MovImm w0 0
           , StrbOff w0 x10 u0
           , Adrp x9 "argc_tab"
           , AddLo12 x9 x9 "argc_tab"
           , LdrbReg w15 x9 x21
           , CmpImm w15 u2
           , Trail (BCond Lo "ch_execbare") "no extras: x1 = 0"
           , Adrp x9 "argvtab"
           , AddLo12 x9 x9 "argvtab"
           , MovReg x15 x21
           , Label "ch_argwalkeb"
           , Cbz x15 "ch_argbaseeb"
           , Trail (AddImm x9 x9 u128) "argv ptr += 128"
           , Trail (SubImm x15 x15 u1) "stage--"
           , B "ch_argwalkeb"
           , Label "ch_argbaseeb"
           , Trail (AddImm x9 x9 u8) "skip argv0"
           , Adrp x10 "argptrs"
           , AddLo12 x10 x10 "argptrs"
           , MovReg x15 x21
           , Adrp x11 "argc_tab"
           , AddLo12 x11 x11 "argc_tab"
           , LdrbReg w11 x11 x21
           , Trail (SubImm x11 x11 u1) "extras = argc - 1"
           , Label "ch_argcopy"
           , Cbz x11 "ch_argnull"
           , LdrMem x0 x9
           , StrMem x0 x10
           , Trail (AddImm x9 x9 u8) "argv += 8"
           , Trail (AddImm x10 x10 u8) "argptrs += 8"
           , Trail (SubImm x11 x11 u1) "extras--"
           , B "ch_argcopy"
           , Label "ch_argnull"
           , MovImm x0 0
           , StrMem x0 x10
           , Adrp x1 "argptrs"
           , AddLo12 x1 x1 "argptrs"
           , Trail (MovImm x27 1) "has extras"
           , B "ch_execgo"
           , Label "ch_execbare"
           , MovImm x1 0
           , Trail (MovImm x27 0) "no extras"
           , Label "ch_execgo"
           , Adrp x9 "saved_argv0"
           , AddLo12 x9 x9 "saved_argv0"
           , StrMem x25 x9
           , Adrp x9 "saved_hasextras"
           , AddLo12 x9 x9 "saved_hasextras"
           , StrMem x27 x9
           , Adrp x0 "binbuf"
           , AddLo12 x0 x0 "binbuf"
           , Trail (Svc svcExec Nothing) "EXEC(/bin/<argv0>)"
           , Adrp x9 "saved_argv0"
           , AddLo12 x9 x9 "saved_argv0"
           , LdrMem x25 x9
           , Adrp x9 "saved_hasextras"
           , AddLo12 x9 x9 "saved_hasextras"
           , LdrMem x27 x9
           , -- A failed EXEC resumes with x0 = errno and every other register
             -- unreliable, so restore argv0/has-extras and rebuild x0/x1
             -- for the bare-path attempt.
             Cbz x27 "ch_execgo0"
           , Adrp x1 "argptrs"
           , AddLo12 x1 x1 "argptrs"
           , B "ch_execgo1"
           , Label "ch_execgo0"
           , MovImm x1 0
           , Label "ch_execgo1"
           , MovReg x0 x25
           , Trail (Svc svcExec Nothing) "EXEC(<argv0>)"
           ]
        ++ emitLit "notfoundmsg" 15
        ++ [ MovImm x0 127
           , Trail (Svc svcExit Nothing) "EXIT(127)"
           , Label "ch_broken"
           ]
        ++ emitLit "brokenmsg" 16
        ++ [ MovImm x0 1
           , Trail (Svc svcExit Nothing) "EXIT(1)"
           , Label "rl_exit"
           , LdpPop x29 x30 SP
           , Ret
           , Blank
           , Comment "printm(x1 = ptr, x2 = len): WRITE_FD(1, ptr, len). Clobbers x0."
           , Label "printm"
           , MovImm x0 1
           , Svc svcWrite Nothing
           , Ret
           , Blank
           , Comment "emitb(w0 = byte): WRITE_FD(1, &cell, 1) via .data. Clobbers x0-x2."
           , Label "emitb"
           , Adrp x1 "emitcell"
           , AddLo12 x1 x1 "emitcell"
           , StrbOff w0 x1 u0
           , MovImm x2 1
           , MovImm x0 1
           , Svc svcWrite Nothing
           , Ret
           , Blank
           , Comment "streq(x10 = hay, x11 = needle): x0 = 1 when NUL-equal. Clobbers x0-x2/x12."
           , Label "streq"
           , MovImm x12 0
           , Label "streq_loop"
           , LdrbReg w0 x10 x12
           , LdrbReg w1 x11 x12
           , CmpReg w0 w1
           , Trail (BCond Ne "streq_no") "bytes differ"
           , Cbz w0 "streq_yes"
           , Trail (AddImm x12 x12 u1) "idx++"
           , B "streq_loop"
           , Label "streq_yes"
           , MovImm x0 1
           , Ret
           , Label "streq_no"
           , MovImm x0 0
           , Ret
           , Blank
           , Label "conpath"
           , Ascii "/dev/console\0"
           , Label "promptmsg"
           , Ascii "sh$ "
           , Label "bsmsg"
           , Ascii "\b \b"
           , Label "nlmsg"
           , Ascii "\n"
           , Label "failmsg"
           , Ascii "sh fail\n"
           , Label "enoentmsg"
           , Ascii "sh: ENOENT\n"
           , Label "notfoundmsg"
           , Ascii "sh: not found\n"
           , Label "nooutputmsg"
           , Ascii "sh: no output\n"
           , Label "missingmsg"
           , Ascii "sh: missing command\n"
           , Label "ambigmsg"
           , Ascii "sh: ambiguous redirect\n"
           , Label "manyargsmsg"
           , Ascii "sh: too many args\n"
           , Label "toolongmsg"
           , Ascii "sh: line too long\n"
           , Label "pipelongmsg"
           , Ascii "sh: pipeline too long\n"
           , Label "brokenmsg"
           , Ascii "sh: broken pipe\n"
           , Label "okexitmsg"
           , Ascii "ok exit "
           , Label "helpmsg"
           , Ascii "exit help echo\n"
           , Label "exitname"
           , Ascii "exit\0"
           , Label "helpname"
           , Ascii "help\0"
           , Label "echoname"
           , Ascii "echo\0"
           , Label "binprefix"
           , Ascii "/bin/\0"
           , Label "loginmsg"
           , Ascii "house login: "
           , Label "loginprefix"
           , Ascii "login "
           , Blank
           , DataSection
           , Align 3
           , Label "buf"
           , Space 1024
           , Label "linebuf"
           , Space 4096
           , Label "linespare"
           , Space 16
           , Label "argvtab"
           , Space 1024
           , Label "argc_tab"
           , Space 8
           , Label "in_tab"
           , Space 64
           , Label "out_tab"
           , Space 64
           , Label "stage_pids"
           , Space 64
           , Label "pipefds"
           , Space 16
           , Label "wfd_slot"
           , Space 8
           , Label "saved_argv0"
           , Space 8
           , Label "saved_hasextras"
           , Space 8
           , Label "argptrs"
           , Space 136
           , Label "binbuf"
           , Space 264
           , Label "numbuf"
           , Space 8
           , Label "emitcell"
           , Space 8
           , Label "loginbuf"
           , Space 33
           ]

-- | Rendered @sh.s@ text.
shText :: String
shText = render shInstrs
