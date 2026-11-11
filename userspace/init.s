// EL0 pid1 for /sbin/init (pid1 slice).
// v4: minimal getty supervisor: WRITE "init up" once, then respawn forever:
// FORK, child EXEC /bin/sh, parent WAIT + WRITE "init done", YIELD-paced
// re-loop with a bounded YIELD budget (2048 parks) so an instantly-exiting
// child cannot starve the shell. Exec miss fails closed per iteration (`init fail` +
// EXIT 1 in the child); the exit code stays visible via `init exit`
// from Kernel.Init's reaper thread only when init itself exits.
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
respawn:
    svc     #0x08                   // FORK -> x0 = 0 (child) | pid (parent)
    cbz     x0, child
    cmp     x0, #0
    b.lt    initfail                // negative errno: fork refused
    mov     x19, x0                 // child pid
    mov     x0, x19
    svc     #0x09                   // WAIT(child) -> x0 = exit code
    adrp    x1, donemsg
    add     x1, x1, :lo12:donemsg
    mov     x2, #10
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "init done\n", 10)
    mov     x20, #2048              // pace budget: 2048 YIELD parks, not a sleep
pace:
    svc     #0x00                   // YIELD: park so a fast-exiting child cannot starve the shell
    sub     x20, x20, #1
    cbnz    x20, pace
    b       respawn
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
