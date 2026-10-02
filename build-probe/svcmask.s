// EL0 svcmask probe: wait until WRITE is revoked, then prove ENOSYS.
// The shell narrows this pid via `svcmask <pid> 1` after spawn. This probe
// loops attempting WRITE(1, "x", 1): success returns 1, revoked returns
// -38 (ENOSYS). On ENOSYS it prints `svcmask ok` and exits 0; after 500
// yields without ENOSYS it prints `svcmask fail` and exits 1.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    mov     x19, #0                 // attempt count
try_loop:
    adrp    x1, xmsg
    add     x1, x1, :lo12:xmsg
    mov     x2, #1
    mov     x0, #1
    svc     #1                      // WRITE
    cmn     x0, #38                 // x0 == -38 ?
    b.eq    denied
    // success: yield and retry
    svc     #0                      // YIELD
    add     x19, x19, #1
    cmp     x19, #500
    b.lt    try_loop
    b       fail
denied:
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #11
    mov     x0, #1
    svc     #1                      // WRITE may also be denied; best effort
    mov     x0, #0
    svc     #2                      // EXIT 0
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #13
    mov     x0, #1
    svc     #1
    mov     x0, #1
    svc     #2                      // EXIT 1
okmsg:
    .ascii  "svcmask ok\n"
failmsg:
    .ascii  "svcmask fail\n"
xmsg:
    .ascii  "x"
    .data
    .align 3
scratch:
    .quad   0
.section .note.GNU-stack,"",%progbits
