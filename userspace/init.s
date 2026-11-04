// EL0 pid1 for /sbin/init (pid1 slice).
// v3: forks and execs /bin/sh, reaps it with wait, announces, and exits
// with the child's status. The kernel logs `init pid N` at spawn and
// `init exit CODE` at reap (Kernel.Init). One-shot: no respawn loop, so
// a missing console fails closed once (`sh: ENOENT`, exit 1) instead of
// spamming the UART.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x1, upmsg
    add     x1, x1, :lo12:upmsg
    mov     x2, #8
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "init up\n", 8)
    svc     #0x08                   // FORK -> x0 = 0 (child) | pid (parent)
    cbz     x0, child
    cmp     x0, #0
    b.lt    initfail                // negative errno: fork refused
    mov     x19, x0                 // child pid
    mov     x0, x19
    svc     #0x09                   // WAIT(child) -> x0 = exit code
    mov     x19, x0                 // save code across WRITE
    adrp    x1, donemsg
    add     x1, x1, :lo12:donemsg
    mov     x2, #10
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "init done\n", 10)
    mov     x0, x19
    svc     #0x02                   // EXIT(child code)
child:
    adrp    x0, shpath
    add     x0, x0, :lo12:shpath
    svc     #0x0B                   // EXEC("/bin/sh") -> no return on success
    b       initfail                // exec miss: fail closed like sh
initfail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #10
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "init fail\n", 10)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
upmsg:
    .ascii  "init up\n"
donemsg:
    .ascii  "init done\n"
failmsg:
    .ascii  "init fail\n"
shpath:
    .ascii  "/bin/sh\0"

    .data
    .align 3
scratch:
    .quad   0
