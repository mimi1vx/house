// EL0 cat for /bin/cat (pid1 slice, plans/pid1-init-shell.md step 4).
// Streams a file to stdout via the fd ring: OPEN 0x04, READ 0x05 loop,
// CLOSE 0x07. Path is argv[1], defaulting to /probe.txt so the legacy
// `run /bin/cat` probe (qemu-fd-el0.exp) keeps working. Prints `cat ok`
// and exits 0 after the full stream; a missing path prints `cat: ENOENT`
// (keeps the fs-harness ENOENT match), any other mismatch `cat fail`,
// all exit 1. Read chunk is 1024 (well under the 64K svc buffer cap).
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #2
    b.hs    have_arg
    adrp    x19, defpath
    add     x19, x19, :lo12:defpath
    b       do_open
have_arg:
    ldr     x19, [sp, #16]          // argv[1]
do_open:
    mov     x0, x19
    mov     x1, #0                  // O_RDONLY
    svc     #0x04                   // OPEN -> x0 = fd
    cmp     x0, #34
    b.hi    fail
    mov     x19, x0                 // fd
read_loop:
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, #1024
    mov     x0, x19
    svc     #0x05                   // READ -> x0 = n
    cmp     x0, #1024
    b.hi    fail                    // negative errno or over-cap
    cbz     x0, eof
    mov     x20, x0                 // n
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, x20
    mov     x0, #1
    svc     #0x01                   // WRITE(1, buf, n)
    b       read_loop
eof:
    mov     x0, x19
    svc     #0x07                   // CLOSE(fd)
    cbnz    x0, fail
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #7
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "cat ok\n", 7)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    mov     x1, #-2
    cmp     x0, x1
    b.eq    enoent                  // x0 is the resumed errno here
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #9
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "cat fail\n", 9)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
enoent:
    adrp    x1, enoentmsg
    add     x1, x1, :lo12:enoentmsg
    mov     x2, #12
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "cat: ENOENT\n", 12)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
defpath:
    .ascii  "/probe.txt\0"
okmsg:
    .ascii  "cat ok\n"
failmsg:
    .ascii  "cat fail\n"
enoentmsg:
    .ascii  "cat: ENOENT\n"

    .data
    .align 3
buf:
    .space  1024
