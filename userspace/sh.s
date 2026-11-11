// EL0 sh for /bin/sh (dx7.2 + house-1mo.2 + house-1mo.5 + house-1mo.6 + house-1mo.7).
// Line discipline over the fd ring: OPEN 0x04 /dev/console
// (dx7.1 reserved path, no new svc), login prompt then `sh$ `, then accumulate
// READ 0x05 chunks into a 4 KiB line buffer until `\n`. Per-byte:
// `\n` echoes + reprompts, BS/DEL drops one byte (echo `\b \b`),
// Ctrl-U drops the line, Ctrl-C drops + reprompts. Overflow flushes
// as-is (bytes already echoed per-byte, so reset, no wrap). Empty
// read (console idle poll) is tolerated a few times (~5s each) so a
// fragmented line still completes; only consecutive empties CLOSE +
// EXIT 0. `sh: ENOENT` and
// `sh fail` stay byte-identical, all exit 1. Chunk is 1024, line
// cap is 4096 (both well under the 64K svc buffer cap).
// house-1mo.6: startup binds fd 0 to the console and ensures fd 1
// via a zero-length WRITE_FD probe (no bytes escape on a bound fd;
// EBADF means unbound, so OPEN /dev/console O_WRONLY + DUP2(c, 1)).
// Each line parses into stage [args] [</>] [>|>>] [| ...]: words
// split on space/tab (16 args, 256 B each); consumed gaps are NULed,
// so both skip loops skip NUL as well as space/tab; `|`, `>`, `>>`, `<` are
// standalone fields only, so `echo a|b` stays one word. Executor:
// N-1 PIPEs, per-stage FORK, child DUP2 wiring (stdin: console or
// `<` file or pipe; stdout: probe-bound default or `>`/`>>` file or
// pipe), child closes ALL pipe fds, parent closes its copies at once
// (else EOF never arrives) then WAITs left-to-right, reporting
// `ok exit <last>`. Builtins (exit/help/echo) run in a forked child
// with the same wiring instead of EXEC. `>>` is OPEN + SEEK_END +
// write (no O_APPEND in the fd layer; single-user TOCTOU accepted).
// EXEC carries argv extras in x1 (pointer array, 0 when none); a
// miss on both /bin/<argv0> and <argv0> prints `sh: not found`.
// house-1mo.7: login: after console bind print `house login: `, read one
// line into loginbuf (33 B, silent truncate at 32, empty => root), log
// `login <name>` to fd 1, then prompt. Ctrl-C reprints login (no exit).
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x19, conpath
    add     x19, x19, :lo12:conpath
    mov     x0, x19
    mov     x1, #0                  // O_RDONLY
    svc     #0x04                   // OPEN -> x0 = fd
    cmp     x0, #34
    b.hi    fail
    mov     x19, x0                 // fd
    adrp    x24, buf
    add     x24, x24, :lo12:buf
    adrp    x26, linebuf
    add     x26, x26, :lo12:linebuf
    mov     x20, #0                 // len = 0
    mov     x27, #0                 // empties = 0
    mov     x0, x19                 // confd
    mov     x1, #0
    svc     #0x1A                   // DUP2(confd, 0)
    cmp     x0, #0
    b.lt    fail                    // negative errno
    mov     x0, #1
    mov     x1, x24
    mov     x2, #0
    svc     #0x06                   // WRITE_FD(1, buf, 0) probe: silent when bound
    cmp     x0, #0
    b.lt    bind1                   // EBADF: fd 1 unbound
    b       login
bind1:
    adrp    x9, conpath
    add     x9, x9, :lo12:conpath
    mov     x0, x9
    mov     x1, #1                  // O_WRONLY
    svc     #0x04                   // OPEN -> x0 = fd
    cmp     x0, #34
    b.hi    nofd1
    mov     x25, x0                 // stash across DUP2
    mov     x0, x25
    mov     x1, #1
    svc     #0x1A                   // DUP2(c, 1)
    mov     x0, x25
    svc     #0x07                   // CLOSE(c)
nofd1:
login:
    adrp    x1, loginmsg
    add     x1, x1, :lo12:loginmsg
    mov     x2, #13
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "house login: ", 13)
    adrp    x26, loginbuf
    add     x26, x26, :lo12:loginbuf
    mov     x20, #0                 // login len = 0
    mov     x27, #0                 // login empties = 0
login_read_chunk:
    mov     x1, x24                 // buf
    mov     x2, #1024
    mov     x0, x19
    svc     #0x05                   // READ -> x0 = n
    cmp     x0, #1024
    b.hi    fail                    // negative errno or over-cap
    cbnz    x0, login_got_data
    add     x27, x27, #1            // empties++
    cmp     x27, #6
    b.hs    eof                     // 6 consecutive empties: EOF
    b       login_read_chunk
login_got_data:
    mov     x27, #0                 // empties = 0
    mov     x21, x0                 // n
    mov     x22, #0                 // i = 0
login_byte_loop:
    cmp     x22, x21
    b.hs    login_read_chunk        // i >= n: next chunk
    ldrb    w23, [x24, x22]
    add     x22, x22, #1            // i++
    cmp     w23, #10
    b.eq    login_nl                // newline
    cmp     w23, #127
    b.eq    login_bs                // DEL
    cmp     w23, #8
    b.eq    login_bs                // BS
    cmp     w23, #21
    b.eq    login_cu                // Ctrl-U
    cmp     w23, #3
    b.eq    login_cc                // Ctrl-C
    cmp     x20, #32
    b.hs    login_byte_loop         // len >= 32: silent truncate, ignore
    add     x1, x26, x20
    strb    w23, [x1, #0]
    add     x20, x20, #1            // len++
    mov     x2, #1
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, byte, 1)
    b       login_byte_loop
login_bs:
    cbz     x20, login_byte_loop
    sub     x20, x20, #1            // len--
    adrp    x1, bsmsg
    add     x1, x1, :lo12:bsmsg
    mov     x2, #3
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "\b \b", 3)
    b       login_byte_loop
login_cu:
    mov     x20, #0                 // drop line
    b       login_byte_loop
login_cc:
    mov     x20, #0                 // drop line
    adrp    x1, loginmsg
    add     x1, x1, :lo12:loginmsg
    mov     x2, #13
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "house login: ", 13)
    b       login_byte_loop
login_nl:
    adrp    x1, nlmsg
    add     x1, x1, :lo12:nlmsg
    mov     x2, #1
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "\n", 1)
    add     x1, x26, x20
    mov     w0, #0
    strb    w0, [x1, #0]            // NUL-terminate (loginbuf has 33 B)
    cbz     x20, login_empty
    b       login_print
login_empty:
    mov     x9, x26                 // dest = loginbuf
    mov     w10, #'r'
    strb    w10, [x9], #1
    mov     w10, #'o'
    strb    w10, [x9], #1
    mov     w10, #'o'
    strb    w10, [x9], #1
    mov     w10, #'t'
    strb    w10, [x9], #1
    mov     x20, #4                 // empty => root
login_print:
    adrp    x1, loginprefix
    add     x1, x1, :lo12:loginprefix
    mov     x2, #6
    bl      printm
    mov     x1, x26                 // loginbuf
    mov     x2, x20                 // len
    bl      printm
    adrp    x1, nlmsg
    add     x1, x1, :lo12:nlmsg
    mov     x2, #1
    bl      printm
    adrp    x26, linebuf
    add     x26, x26, :lo12:linebuf
    mov     x20, #0                 // len = 0
    mov     x27, #0                 // empties = 0
prompt:
    adrp    x1, promptmsg
    add     x1, x1, :lo12:promptmsg
    mov     x2, #4
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "sh$ ", 4)
read_chunk:
    mov     x1, x24                 // buf
    mov     x2, #1024
    mov     x0, x19
    svc     #0x05                   // READ -> x0 = n
    cmp     x0, #1024
    b.hi    fail                    // negative errno or over-cap
    cbnz    x0, got_data
    add     x27, x27, #1            // empties++
    cmp     x27, #6
    b.hs    eof                     // 6 consecutive empties: EOF
    b       read_chunk
got_data:
    mov     x27, #0                 // empties = 0
    mov     x21, x0                 // n
    mov     x22, #0                 // i = 0
byte_loop:
    cmp     x22, x21
    b.hs    read_chunk              // i >= n: next chunk
    ldrb    w23, [x24, x22]
    add     x22, x22, #1            // i++
    cmp     w23, #10
    b.eq    handle_nl               // newline
    cmp     w23, #127
    b.eq    handle_bs               // DEL
    cmp     w23, #8
    b.eq    handle_bs               // BS
    cmp     w23, #21
    b.eq    handle_cu               // Ctrl-U
    cmp     w23, #3
    b.eq    handle_cc               // Ctrl-C
    cmp     x20, #4096
    b.lo    store                   // len < 4096
    mov     x20, #0                 // overflow: flush-as-is, reset
store:
    add     x1, x26, x20
    strb    w23, [x1, #0]
    add     x20, x20, #1            // len++
    mov     x2, #1
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, byte, 1)
    b       byte_loop
handle_nl:
    adrp    x1, nlmsg
    add     x1, x1, :lo12:nlmsg
    mov     x2, #1
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "\n", 1)
    add     x1, x26, x20
    mov     w0, #0
    strb    w0, [x1, #0]            // NUL-terminate (linespare guards len == 4096)
    bl      runline
    mov     x20, #0                 // len = 0
    mov     x27, #0                 // empties = 0 (runline clobbers x27)
    adrp    x1, promptmsg
    add     x1, x1, :lo12:promptmsg
    mov     x2, #4
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "sh$ ", 4)
    b       byte_loop
handle_bs:
    cbz     x20, byte_loop
    sub     x20, x20, #1            // len--
    adrp    x1, bsmsg
    add     x1, x1, :lo12:bsmsg
    mov     x2, #3
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "\b \b", 3)
    b       byte_loop
handle_cu:
    mov     x20, #0                 // drop line
    b       byte_loop
handle_cc:
    mov     x20, #0                 // drop line
    adrp    x1, promptmsg
    add     x1, x1, :lo12:promptmsg
    mov     x2, #4
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "sh$ ", 4)
    b       byte_loop
eof:
    mov     x0, x19
    svc     #0x07                   // CLOSE(fd)
    cbnz    x0, fail
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    mov     x1, #-2
    cmp     x0, x1
    b.eq    enoent                  // x0 is the resumed errno here
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #8
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "sh fail\n", 8)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
enoent:
    adrp    x1, enoentmsg
    add     x1, x1, :lo12:enoentmsg
    mov     x2, #11
    mov     x0, #1
    svc     #0x06                   // WRITE_FD(1, "sh: ENOENT\n", 11)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
runline:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    cbz     x20, rl_exit
    mov     x27, #0                 // stage = 0
    mov     x28, #0                 // argc = 0
    mov     x16, #0                 // have_in = 0
    mov     x17, #0                 // have_out = 0
    mov     x18, #0                 // append = 0
    mov     x8, #0                  // zero index for ldrb [base, x8]
    mov     x25, #0                 // pos = 0
    adrp    x10, argvtab
    add     x10, x10, :lo12:argvtab
    adrp    x11, argc_tab
    add     x11, x11, :lo12:argc_tab
    adrp    x12, in_tab
    add     x12, x12, :lo12:in_tab
    adrp    x13, out_tab
    add     x13, x13, :lo12:out_tab
    mov     x15, #0                 // clear stale redirect tables each line
    mov     x14, #0                 // (in/out ptrs persist across lines)
rl_cleartabs:
    str     x15, [x12, x14]
    str     x15, [x13, x14]
    add     x14, x14, #8            // off += 8
    cmp     x14, #64                // off >= 64: done
    b.lo    rl_cleartabs
    b       rl_skip
rl_skip:
    cmp     x25, x20
    b.hs    rl_endline              // pos >= len
    ldrb    w23, [x26, x25]
    add     x25, x25, #1            // pos++
    cmp     w23, #32
    b.eq    rl_skip
    cmp     w23, #9
    b.eq    rl_skip
    cmp     w23, #0
    b.eq    rl_skip
    sub     x9, x25, #1             // field_start = pos - 1
    mov     x14, x9
rl_scanloop:
    cmp     x14, x20
    b.hs    rl_fend                 // end of line
    ldrb    w23, [x26, x14]
    cmp     w23, #32
    b.eq    rl_fend
    cmp     w23, #9
    b.eq    rl_fend
    add     x14, x14, #1            // end++
    b       rl_scanloop
rl_fend:
    sub     x15, x14, x9            // len = end - start
    cmp     x15, #256
    b.hi    rl_toolong              // field > 256 B
    cmp     x14, x20
    b.hs    rl_class                // at end: NUL already in place
    ldrb    w23, [x26, x14]
    cmp     w23, #32
    b.eq    rl_nul
    cmp     w23, #9
    b.ne    rl_class                // operator abuts: keep the char
rl_nul:
    add     x0, x26, x14
    mov     w23, #0
    strb    w23, [x0, #0]
rl_class:
    ldrb    w23, [x26, x9]
    cmp     x15, #1
    b.ne    rl_maybeappend          // len != 1
    cmp     w23, #124
    b.eq    rl_pipe
    cmp     w23, #62
    b.eq    rl_redirout
    cmp     w23, #60
    b.eq    rl_redirin
    b       rl_word
rl_maybeappend:
    cmp     x15, #2
    b.ne    rl_word                 // len != 2
    add     x0, x26, x9
    ldrb    w1, [x0, x8]
    cmp     w1, #62
    b.ne    rl_word                 // second char is not >
    cmp     w23, #62
    b.ne    rl_word                 // first char is not >
    b       rl_redirappend
rl_word:
    cmp     x28, #16
    b.hs    rl_manyargs             // argc >= 16
    add     x0, x26, x9
    str     x0, [x10]
    add     x10, x10, #8            // argv ptr += 8
    add     x28, x28, #1            // argc++
    mov     x25, x14
    b       rl_skip
rl_pipe:
    cbz     x28, rl_missing
    strb    w28, [x11, #0]
    cmp     x27, #7
    b.hs    rl_pipelong             // stage 7 piped: a 9th stage
    add     x27, x27, #1            // stage++
    mov     x28, #0
    mov     x16, #0
    mov     x17, #0
    mov     x18, #0
    add     x11, x11, #1            // argc ptr += 1
    add     x12, x12, #8            // in ptr += 8
    add     x13, x13, #8            // out ptr += 8
    adrp    x10, argvtab
    add     x10, x10, :lo12:argvtab
    mov     x15, x27
rl_psloop:
    cbz     x15, rl_pipedone
    add     x10, x10, #128          // argv ptr += 128
    sub     x15, x15, #1            // stage--
    b       rl_psloop
rl_pipedone:
    mov     x25, x14
    b       rl_skip
rl_redirout:
    mov     x0, #1
    b       rl_redir
rl_redirappend:
    mov     x0, #2
    b       rl_redir
rl_redirin:
    mov     x0, #0
rl_redir:
    mov     x25, x14                // pos = end
rl_rskip:
    cmp     x25, x20
    b.hs    rl_missing              // dangling redirect
    ldrb    w23, [x26, x25]
    add     x25, x25, #1            // pos++
    cmp     w23, #32
    b.eq    rl_rskip
    cmp     w23, #9
    b.eq    rl_rskip
    cmp     w23, #0
    b.eq    rl_rskip
    sub     x9, x25, #1             // filename start = pos - 1
    mov     x14, x9
rl_rscan:
    cmp     x14, x20
    b.hs    rl_rfend                // end of line
    ldrb    w23, [x26, x14]
    cmp     w23, #32
    b.eq    rl_rfend
    cmp     w23, #9
    b.eq    rl_rfend
    add     x14, x14, #1            // end++
    b       rl_rscan
rl_rfend:
    sub     x15, x14, x9            // len = end - start
    cmp     x15, #256
    b.hi    rl_toolong              // filename > 256 B
    cmp     x14, x20
    b.hs    rl_rnot1                // at end: NUL already in place
    ldrb    w23, [x26, x14]
    cmp     w23, #32
    b.eq    rl_rnul
    cmp     w23, #9
    b.ne    rl_rnot1                // operator abuts: keep the char
rl_rnul:
    add     x1, x26, x14
    mov     w23, #0
    strb    w23, [x1, #0]
rl_rnot1:
    cmp     x15, #1
    b.ne    rl_rnot2                // len != 1
    ldrb    w23, [x26, x9]
    cmp     w23, #124
    b.eq    rl_missing
    cmp     w23, #62
    b.eq    rl_missing
    cmp     w23, #60
    b.eq    rl_missing
    b       rl_rstore
rl_rnot2:
    cmp     x15, #2
    b.ne    rl_rstore               // len != 2
    ldrb    w23, [x26, x9]
    cmp     w23, #62
    b.ne    rl_rstore               // not >>
    add     x1, x26, x9
    ldrb    w1, [x1, x8]
    cmp     w1, #62
    b.ne    rl_rstore               // not >>
    b       rl_missing
rl_rstore:
    cmp     x0, #0
    b.eq    rl_storein
    cbnz    x17, rl_ambiguous
    add     x1, x26, x9
    str     x1, [x13]
    mov     x17, #1                 // have_out = 1
    cmp     x0, #2
    b.ne    rl_routdone             // truncate, not append
    mov     x18, #1                 // append = 1
rl_routdone:
    mov     x25, x14
    b       rl_skip
rl_storein:
    cbnz    x16, rl_ambiguous
    add     x1, x26, x9
    str     x1, [x12]
    mov     x16, #1                 // have_in = 1
    mov     x25, x14
    b       rl_skip
rl_endline:
    cbnz    x28, rl_exec
    cbnz    x27, rl_missing
    cbnz    x16, rl_missing
    cbnz    x17, rl_missing
    b       rl_exit
rl_missing:
    adrp    x1, missingmsg
    add     x1, x1, :lo12:missingmsg
    mov     x2, #20
    bl      printm
    b       rl_exit
rl_ambiguous:
    adrp    x1, ambigmsg
    add     x1, x1, :lo12:ambigmsg
    mov     x2, #24
    bl      printm
    b       rl_exit
rl_manyargs:
    adrp    x1, manyargsmsg
    add     x1, x1, :lo12:manyargsmsg
    mov     x2, #18
    bl      printm
    b       rl_exit
rl_toolong:
    adrp    x1, toolongmsg
    add     x1, x1, :lo12:toolongmsg
    mov     x2, #19
    bl      printm
    b       rl_exit
rl_pipelong:
    adrp    x1, pipelongmsg
    add     x1, x1, :lo12:pipelongmsg
    mov     x2, #22
    bl      printm
    b       rl_exit
rl_exec:
    strb    w28, [x11, #0]
    add     x22, x27, #1            // nstages = stage + 1
    sub     x27, x22, #1            // pipes = nstages - 1
    cbz     x27, rl_forkinit
    mov     x21, #0                 // i = 0
    adrp    x23, pipefds
    add     x23, x23, :lo12:pipefds
rl_mkpipes:
    cmp     x21, x27
    b.hs    rl_forkinit             // i >= pipes
    mov     x0, #0
    adrp    x1, wfd_slot
    add     x1, x1, :lo12:wfd_slot
    mov     x2, #0
    svc     #0x19                   // PIPE -> x0 = rd, [x1] = wr
    cmp     x0, #34
    b.hi    rl_pipefail             // negative errno or over-cap
    strb    w0, [x23, #0]
    add     x23, x23, #1            // pipefds += 1
    adrp    x9, wfd_slot
    add     x9, x9, :lo12:wfd_slot
    ldr     x9, [x9]
    strb    w9, [x23, #0]
    add     x23, x23, #1            // pipefds += 1
    add     x21, x21, #1            // i++
    b       rl_mkpipes
rl_pipefail:
    mov     x27, x21                // made = i
    add     x27, x27, x27           // made = 2 * made
    mov     x25, #0                 // idx = 0
rl_pfailclose:
    cmp     x25, x27
    b.hs    rl_pfailexit            // all closed
    adrp    x9, pipefds
    add     x9, x9, :lo12:pipefds
    ldrb    w0, [x9, x25]
    svc     #0x07                   // CLOSE(pipefd)
    add     x25, x25, #1            // idx++
    b       rl_pfailclose
rl_pfailexit:
    adrp    x1, brokenmsg
    add     x1, x1, :lo12:brokenmsg
    mov     x2, #16
    bl      printm
    b       rl_exit
rl_forkinit:
    mov     x21, #0                 // stage idx = 0
    adrp    x23, stage_pids
    add     x23, x23, :lo12:stage_pids
rl_forkloop:
    cmp     x21, x22
    b.hs    rl_parentclose          // all stages forked
    svc     #0x08                   // FORK -> x0 = 0 (child) | pid (parent)
    cbz     x0, rl_child
    cmp     x0, #0
    b.lt    rl_forkfail             // negative errno
    str     x0, [x23]
    add     x23, x23, #8            // pids += 8
    add     x21, x21, #1            // stage++
    b       rl_forkloop
rl_forkfail:
    adrp    x1, brokenmsg
    add     x1, x1, :lo12:brokenmsg
    mov     x2, #16
    bl      printm
    sub     x27, x22, #1            // total = nstages - 1
    add     x27, x27, x27           // total = 2 * total
    mov     x25, #0                 // idx = 0
rl_ffclose:
    cmp     x25, x27
    b.hs    rl_ffreap               // all closed
    adrp    x9, pipefds
    add     x9, x9, :lo12:pipefds
    ldrb    w0, [x9, x25]
    svc     #0x07                   // CLOSE(pipefd)
    add     x25, x25, #1            // idx++
    b       rl_ffclose
rl_ffreap:
    adrp    x23, stage_pids
    add     x23, x23, :lo12:stage_pids
    mov     x25, #0                 // idx = 0
rl_ffwait:
    cmp     x25, x21
    b.hs    rl_exit                 // all reaped
    ldr     x0, [x23]
    svc     #0x09                   // WAIT(reaped)
    add     x23, x23, #8            // pids += 8
    add     x25, x25, #1            // idx++
    b       rl_ffwait
rl_parentclose:
    sub     x27, x22, #1            // total = nstages - 1
    add     x27, x27, x27           // total = 2 * total
    mov     x25, #0                 // idx = 0
rl_pclose:
    cmp     x25, x27
    b.hs    rl_waitinit             // all closed: readers see EOF
    adrp    x9, pipefds
    add     x9, x9, :lo12:pipefds
    ldrb    w0, [x9, x25]
    svc     #0x07                   // CLOSE(pipefd)
    add     x25, x25, #1            // idx++
    b       rl_pclose
rl_waitinit:
    mov     x21, #0                 // stage idx = 0
    adrp    x23, stage_pids
    add     x23, x23, :lo12:stage_pids
    mov     x27, #0                 // lastcode = 0
rl_waitloop:
    cmp     x21, x22
    b.hs    rl_report               // all stages reaped
    ldr     x0, [x23]
    svc     #0x09                   // WAIT(stage)
    cmp     x0, #0
    b.lt    rl_waitfail             // negative errno
    mov     x27, x0
    add     x23, x23, #8            // pids += 8
    add     x21, x21, #1            // stage++
    b       rl_waitloop
rl_waitfail:
    adrp    x1, brokenmsg
    add     x1, x1, :lo12:brokenmsg
    mov     x2, #16
    bl      printm
    add     x23, x23, #8            // pids += 8
    add     x21, x21, #1            // stage++
    b       rl_waitloop
rl_report:
    adrp    x1, okexitmsg
    add     x1, x1, :lo12:okexitmsg
    mov     x2, #8
    bl      printm
    mov     x9, #0                  // hundreds = 0
rl_h100:
    cmp     x27, #100
    b.lo    rl_tens                 // code < 100
    sub     x27, x27, #100          // code -= 100
    add     x9, x9, #1              // hundreds++
    b       rl_h100
rl_tens:
    mov     x10, #0                 // tens = 0
rl_t10:
    cmp     x27, #10
    b.lo    rl_digits               // code < 10
    sub     x27, x27, #10           // code -= 10
    add     x10, x10, #1            // tens++
    b       rl_t10
rl_digits:
    adrp    x11, numbuf
    add     x11, x11, :lo12:numbuf
    mov     x12, #0                 // count = 0
    mov     x13, #0                 // printed = 0
    cbz     x9, rl_notens0
    add     x9, x9, #48             // hundreds += '0'
    strb    w9, [x11], #1
    add     x12, x12, #1            // count++
    mov     x13, #1                 // printed = 1
rl_notens0:
    cbnz    x13, rl_dotens
    cbz     x10, rl_ones
rl_dotens:
    add     x10, x10, #48           // tens += '0'
    strb    w10, [x11], #1
    add     x12, x12, #1            // count++
    mov     x13, #1                 // printed = 1
rl_ones:
    add     x27, x27, #48           // ones += '0'
    strb    w27, [x11], #1
    add     x12, x12, #1            // count++
    adrp    x1, numbuf
    add     x1, x1, :lo12:numbuf
    mov     x2, x12
    bl      printm
    adrp    x1, nlmsg
    add     x1, x1, :lo12:nlmsg
    mov     x2, #1
    bl      printm
    b       rl_exit
rl_child:
    cmp     x21, #0
    b.ne    ch_pipein               // stage > 0 reads the pipe
    adrp    x9, in_tab
    add     x9, x9, :lo12:in_tab
    ldr     x9, [x9]
    cbz     x9, ch_outsel
    mov     x0, x9
    mov     x1, #0                  // O_RDONLY
    svc     #0x04                   // OPEN(<file) -> x0 = fd
    cmp     x0, #34
    b.hi    ch_broken               // negative errno or over-cap
    mov     x25, x0                 // stash across DUP2
    mov     x0, x25
    mov     x1, #0
    svc     #0x1A                   // DUP2(f, 0)
    cmp     x0, #0
    b.lt    ch_broken               // negative errno
    mov     x0, x25
    svc     #0x07                   // CLOSE(f)
    b       ch_outsel
ch_pipein:
    sub     x9, x21, #1             // idx = 2 * (i - 1)
    add     x9, x9, x9              // idx = 2 * idx
    adrp    x10, pipefds
    add     x10, x10, :lo12:pipefds
    ldrb    w0, [x10, x9]
    mov     x1, #0
    svc     #0x1A                   // DUP2(pipeR, 0)
    cmp     x0, #0
    b.lt    ch_broken               // negative errno
ch_outsel:
    sub     x9, x22, #1             // last = nstages - 1
    cmp     x21, x9
    b.ne    ch_pipeout              // not the last stage
    adrp    x9, out_tab
    add     x9, x9, :lo12:out_tab
    mov     x15, x21
ch_outwalk:
    cbz     x15, ch_outptr
    add     x9, x9, #8              // out ptr += 8
    sub     x15, x15, #1            // stage--
    b       ch_outwalk
ch_outptr:
    ldr     x9, [x9]
    cbz     x9, ch_probe1
    mov     x0, x9
    cbnz    x18, ch_outapp
    mov     x1, #0x241
    b       ch_outopen
ch_outapp:
    mov     x1, #0x41
ch_outopen:
    svc     #0x04                   // OPEN(>file, 0x241 | >>file, 0x41)
    cmp     x0, #34
    b.hi    ch_broken               // negative errno or over-cap
    mov     x25, x0                 // stash across DUP2
    mov     x0, x25
    mov     x1, #1
    svc     #0x1A                   // DUP2(f, 1)
    cmp     x0, #0
    b.lt    ch_broken               // negative errno
    cbz     x18, ch_outclose
    mov     x0, x25
    mov     x1, #0
    mov     x2, #2
    svc     #0x0A                   // SEEK(fd, 0, END)
    cmp     x0, #0
    b.lt    ch_broken               // negative errno
ch_outclose:
    mov     x0, x25
    svc     #0x07                   // CLOSE(f)
    b       ch_execwire
ch_probe1:
    mov     x0, #1
    mov     x1, x24
    mov     x2, #0
    svc     #0x06                   // WRITE_FD(1, buf, 0) probe: silent when bound
    cmp     x0, #0
    b.lt    ch_bind1                // EBADF: fd 1 unbound
    b       ch_execwire
ch_bind1:
    adrp    x9, conpath
    add     x9, x9, :lo12:conpath
    mov     x0, x9
    mov     x1, #1                  // O_WRONLY
    svc     #0x04                   // OPEN -> x0 = fd
    cmp     x0, #34
    b.hi    ch_nooutput             // no console and fd 1 unbound
    mov     x25, x0                 // stash across DUP2
    mov     x0, x25
    mov     x1, #1
    svc     #0x1A                   // DUP2(c, 1)
    cmp     x0, #0
    b.lt    ch_nooutput             // negative errno
    mov     x0, x25
    svc     #0x07                   // CLOSE(c)
    b       ch_execwire
ch_nooutput:
    adrp    x1, nooutputmsg
    add     x1, x1, :lo12:nooutputmsg
    mov     x2, #14
    bl      printm
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
ch_pipeout:
    add     x9, x21, x21            // idx = 2 * i + 1
    add     x9, x9, #1              // idx += 1
    adrp    x10, pipefds
    add     x10, x10, :lo12:pipefds
    ldrb    w0, [x10, x9]
    mov     x1, #1
    svc     #0x1A                   // DUP2(pipeW, 1)
    cmp     x0, #0
    b.lt    ch_broken               // negative errno
ch_execwire:
    sub     x27, x22, #1            // total = nstages - 1
    add     x27, x27, x27           // total = 2 * total
    mov     x25, #0                 // idx = 0
ch_closeloop:
    cmp     x25, x27
    b.hs    ch_builtin              // all closed
    adrp    x9, pipefds
    add     x9, x9, :lo12:pipefds
    ldrb    w0, [x9, x25]
    svc     #0x07                   // CLOSE(pipefd)
    add     x25, x25, #1            // idx++
    b       ch_closeloop
ch_builtin:
    mov     x8, #0                  // zero index for ldrb [base, x8]
    adrp    x9, argvtab
    add     x9, x9, :lo12:argvtab
    mov     x15, x21
ch_argwalk:
    cbz     x15, ch_argbase
    add     x9, x9, #128            // argv ptr += 128
    sub     x15, x15, #1            // stage--
    b       ch_argwalk
ch_argbase:
    ldr     x10, [x9]
    mov     x25, x10                // argv0 survives until the bare EXEC attempt
    adrp    x11, exitname
    add     x11, x11, :lo12:exitname
    bl      streq
    cbnz    x0, ch_exit
    ldr     x10, [x9]
    adrp    x11, helpname
    add     x11, x11, :lo12:helpname
    bl      streq
    cbnz    x0, ch_help
    ldr     x10, [x9]
    adrp    x11, echoname
    add     x11, x11, :lo12:echoname
    bl      streq
    cbnz    x0, ch_echo
    b       ch_execbin
ch_exit:
    adrp    x9, argc_tab
    add     x9, x9, :lo12:argc_tab
    ldrb    w9, [x9, x21]
    cmp     w9, #2
    b.lo    ch_exit0                // no code arg
    adrp    x9, argvtab
    add     x9, x9, :lo12:argvtab
    mov     x15, x21
ch_argwalkex:
    cbz     x15, ch_argbaseex
    add     x9, x9, #128            // argv ptr += 128
    sub     x15, x15, #1            // stage--
    b       ch_argwalkex
ch_argbaseex:
    add     x9, x9, #8              // skip argv0
    ldr     x11, [x9]
    mov     x9, #0                  // acc = 0
    mov     x12, #0                 // idx = 0
ch_atoiloop:
    ldrb    w0, [x11, x12]
    cbz     w0, ch_atoiexit
    sub     w0, w0, #48             // digit = c - '0'
    cmp     w0, #10
    b.hs    ch_atoiexit             // non-digit stops
    mov     x13, x9
    add     x9, x9, x13             // acc += acc (x2)
    add     x9, x9, x13             // acc += acc (x3)
    add     x9, x9, x13             // acc += acc (x4)
    add     x9, x9, x13             // acc += acc (x5)
    add     x9, x9, x13             // acc += acc (x6)
    add     x9, x9, x13             // acc += acc (x7)
    add     x9, x9, x13             // acc += acc (x8)
    add     x9, x9, x13             // acc += acc (x9)
    add     x9, x9, x13             // acc += acc (x10)
    add     x9, x9, x0              // acc += digit
    add     x12, x12, #1            // idx++
    b       ch_atoiloop
ch_atoiexit:
    mov     x0, x9
    svc     #0x02                   // EXIT(code)
ch_exit0:
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
ch_help:
    adrp    x1, helpmsg
    add     x1, x1, :lo12:helpmsg
    mov     x2, #15
    bl      printm
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
ch_echo:
    adrp    x9, argc_tab
    add     x9, x9, :lo12:argc_tab
    ldrb    w10, [x9, x21]
    adrp    x9, argvtab
    add     x9, x9, :lo12:argvtab
    mov     x15, x21
ch_argwalkec:
    cbz     x15, ch_argbaseec
    add     x9, x9, #128            // argv ptr += 128
    sub     x15, x15, #1            // stage--
    b       ch_argwalkec
ch_argbaseec:
    mov     x27, #1                 // j = 1
ch_echoloop:
    cmp     x27, x10
    b.hs    ch_echodone             // j >= argc
    mov     x11, x9
    mov     x13, x27
ch_echowalk:
    cbz     x13, ch_echoword
    add     x11, x11, #8            // word ptr += 8
    sub     x13, x13, #1            // j--
    b       ch_echowalk
ch_echoword:
    ldr     x1, [x11]
    mov     x2, #0                  // len = 0
ch_strlen:
    ldrb    w12, [x1, x2]
    cbz     w12, ch_printword
    add     x2, x2, #1              // len++
    cmp     x2, #256
    b.lo    ch_strlen               // cap at 256
ch_printword:
    bl      printm
    add     x13, x27, #1            // j + 1
    cmp     x13, x10
    b.hs    ch_echonext             // last word: no space
    mov     w0, #' '
    bl      emitb
ch_echonext:
    add     x27, x27, #1            // j++
    b       ch_echoloop
ch_echodone:
    mov     w0, #10
    bl      emitb
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
ch_execbin:
    mov     x8, #0                  // zero index for ldrb [base, x8]
    adrp    x9, binprefix
    add     x9, x9, :lo12:binprefix
    adrp    x10, binbuf
    add     x10, x10, :lo12:binbuf
ch_copybin:
    ldrb    w0, [x9, x8]
    cbz     w0, ch_copyarg0
    strb    w0, [x10], #1
    add     x9, x9, #1              // prefix++
    b       ch_copybin
ch_copyarg0:
    mov     x12, #0                 // idx = 0
ch_copyarg1:
    ldrb    w0, [x25, x12]
    cbz     w0, ch_copyarg2
    strb    w0, [x10], #1
    add     x12, x12, #1            // idx++
    cmp     x12, #256
    b.lo    ch_copyarg1             // cap at 256
ch_copyarg2:
    mov     w0, #0
    strb    w0, [x10, #0]
    adrp    x9, argc_tab
    add     x9, x9, :lo12:argc_tab
    ldrb    w15, [x9, x21]
    cmp     w15, #2
    b.lo    ch_execbare             // no extras: x1 = 0
    adrp    x9, argvtab
    add     x9, x9, :lo12:argvtab
    mov     x15, x21
ch_argwalkeb:
    cbz     x15, ch_argbaseeb
    add     x9, x9, #128            // argv ptr += 128
    sub     x15, x15, #1            // stage--
    b       ch_argwalkeb
ch_argbaseeb:
    add     x9, x9, #8              // skip argv0
    adrp    x10, argptrs
    add     x10, x10, :lo12:argptrs
    mov     x15, x21
    adrp    x11, argc_tab
    add     x11, x11, :lo12:argc_tab
    ldrb    w11, [x11, x21]
    sub     x11, x11, #1            // extras = argc - 1
ch_argcopy:
    cbz     x11, ch_argnull
    ldr     x0, [x9]
    str     x0, [x10]
    add     x9, x9, #8              // argv += 8
    add     x10, x10, #8            // argptrs += 8
    sub     x11, x11, #1            // extras--
    b       ch_argcopy
ch_argnull:
    mov     x0, #0
    str     x0, [x10]
    adrp    x1, argptrs
    add     x1, x1, :lo12:argptrs
    mov     x27, #1                 // has extras
    b       ch_execgo
ch_execbare:
    mov     x1, #0
    mov     x27, #0                 // no extras
ch_execgo:
    adrp    x9, saved_argv0
    add     x9, x9, :lo12:saved_argv0
    str     x25, [x9]
    adrp    x9, saved_hasextras
    add     x9, x9, :lo12:saved_hasextras
    str     x27, [x9]
    adrp    x0, binbuf
    add     x0, x0, :lo12:binbuf
    svc     #0x0B                   // EXEC(/bin/<argv0>)
    adrp    x9, saved_argv0
    add     x9, x9, :lo12:saved_argv0
    ldr     x25, [x9]
    adrp    x9, saved_hasextras
    add     x9, x9, :lo12:saved_hasextras
    ldr     x27, [x9]
    cbz     x27, ch_execgo0
    adrp    x1, argptrs
    add     x1, x1, :lo12:argptrs
    b       ch_execgo1
ch_execgo0:
    mov     x1, #0
ch_execgo1:
    mov     x0, x25
    svc     #0x0B                   // EXEC(<argv0>)
    adrp    x1, notfoundmsg
    add     x1, x1, :lo12:notfoundmsg
    mov     x2, #15
    bl      printm
    mov     x0, #127
    svc     #0x02                   // EXIT(127)
ch_broken:
    adrp    x1, brokenmsg
    add     x1, x1, :lo12:brokenmsg
    mov     x2, #16
    bl      printm
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
rl_exit:
    ldp     x29, x30, [sp], #16
    ret

// printm(x1 = ptr, x2 = len): WRITE_FD(1, ptr, len). Clobbers x0.
printm:
    mov     x0, #1
    svc     #0x06
    ret

// emitb(w0 = byte): WRITE_FD(1, &cell, 1) via .data. Clobbers x0-x2.
emitb:
    adrp    x1, emitcell
    add     x1, x1, :lo12:emitcell
    strb    w0, [x1, #0]
    mov     x2, #1
    mov     x0, #1
    svc     #0x06
    ret

// streq(x10 = hay, x11 = needle): x0 = 1 when NUL-equal. Clobbers x0-x2/x12.
streq:
    mov     x12, #0
streq_loop:
    ldrb    w0, [x10, x12]
    ldrb    w1, [x11, x12]
    cmp     w0, w1
    b.ne    streq_no                // bytes differ
    cbz     w0, streq_yes
    add     x12, x12, #1            // idx++
    b       streq_loop
streq_yes:
    mov     x0, #1
    ret
streq_no:
    mov     x0, #0
    ret

conpath:
    .ascii  "/dev/console\0"
promptmsg:
    .ascii  "sh$ "
bsmsg:
    .ascii  "\010 \010"
nlmsg:
    .ascii  "\n"
failmsg:
    .ascii  "sh fail\n"
enoentmsg:
    .ascii  "sh: ENOENT\n"
notfoundmsg:
    .ascii  "sh: not found\n"
nooutputmsg:
    .ascii  "sh: no output\n"
missingmsg:
    .ascii  "sh: missing command\n"
ambigmsg:
    .ascii  "sh: ambiguous redirect\n"
manyargsmsg:
    .ascii  "sh: too many args\n"
toolongmsg:
    .ascii  "sh: line too long\n"
pipelongmsg:
    .ascii  "sh: pipeline too long\n"
brokenmsg:
    .ascii  "sh: broken pipe\n"
okexitmsg:
    .ascii  "ok exit "
helpmsg:
    .ascii  "exit help echo\n"
exitname:
    .ascii  "exit\0"
helpname:
    .ascii  "help\0"
echoname:
    .ascii  "echo\0"
binprefix:
    .ascii  "/bin/\0"
loginmsg:
    .ascii  "house login: "
loginprefix:
    .ascii  "login "

    .data
    .align 3
buf:
    .space  1024
linebuf:
    .space  4096
linespare:
    .space  16
argvtab:
    .space  1024
argc_tab:
    .space  8
in_tab:
    .space  64
out_tab:
    .space  64
stage_pids:
    .space  64
pipefds:
    .space  16
wfd_slot:
    .space  8
saved_argv0:
    .space  8
saved_hasextras:
    .space  8
argptrs:
    .space  136
binbuf:
    .space  264
numbuf:
    .space  8
emitcell:
    .space  8
loginbuf:
    .space  33
