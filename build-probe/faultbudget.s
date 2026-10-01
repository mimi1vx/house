// EL0 fault-budget probe: touch many pages across the user window so the
// per-process demand budget (10% of buddy, floor 1024) caps the scan. Each
// store faults in Rust (no Haskell park on success); after the cap the pager
// returns -28, parks FAULT, and Haskell reaps with exit 1. A completing run
// (no cap) prints `budget uncapped` + exits 1 (fail); a reaped run never
// returns (waiter sees exit 1, kernel reaches next prompt).
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    movz    x19, #0x0100, lsl #16       // 0x01000000 window base
    mov     x20, #0                     // i = 0
    // Do 150000 stores, 4096 apart (covers ~600 MiB, exceeds the 10% cap at
    // 4 GiB while staying quick under TCG; at 512 MiB the cap trips after
    // ~10k faults). 150000 = 0x249F0.
    movz    x22, #0x49f0
    movk    x22, #0x0002, lsl #16       // x22 = 150000
1:
    str     xzr, [x19]
    add     x19, x19, #4096
    add     x20, x20, #1
    cmp     x20, x22
    b.lo    1b
    // Survived the cap (should not happen): fail loudly with exit 2.
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #16
    mov     x0, #1
    svc     #1
    mov     x0, #2
    svc     #2
failmsg:
    .ascii  "budget uncapped\n"
    .data
    .align 3
scratch:
    .quad   0
.section .note.GNU-stack,"",%progbits
