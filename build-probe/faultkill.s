// EL0 fault-kill probe: trigger an unhandled abort so the core parks KILL
// (0x1D) and Haskell reaps with exit 1 instead of halting. Role from argv[1]:
// `low` loads from 0x0 (below window), `high` loads from 0x2000000000 (above
// window). A reaped run never returns (waiter sees exit 1); a surviving run
// (no kill) prints `kill survived` + exits 1 (fail).
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #2
    b.lt    fail
    add     x9, sp, #8
    ldr     x10, [x9, #8]           // argv[1] role
    ldrb    w11, [x10]              // first char: 'l' low, 'h' high
    cmp     w11, #104               // 'h'
    b.eq    do_high
    // low: load from 0x0 (xzr cannot be a base, materialise 0 in x1)
    mov     x1, xzr
    ldr     x0, [x1]
    b       fail                    // survived (should not happen)
do_high:
    // 0x2000000000 = 0x20 << 32 (above the 64 GiB window).
    movz    x1, #0x0000
    movk    x1, #0x0000, lsl #16
    movk    x1, #0x0020, lsl #32
    ldr     x0, [x1]
    b       fail
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #14
    mov     x0, #1
    svc     #1
    mov     x0, #1
    svc     #2
failmsg:
    .ascii  "kill survived\n"
    .data
    .align 3
scratch:
    .quad   0
.section .note.GNU-stack,"",%progbits
