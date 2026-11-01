// EL0 RO-store kill probe: store to our own text (mapped RO, non-COW) so the
// permission fault must park KILL and Haskell reaps exit 1, never elr+4.
// A surviving run distinguishes the two broken modes by read-back: stale
// data means the store was skipped (pre-fix semantics, exit 2), while the
// stored value means the text mapping is writable in HW (loader bug, exit 3).
// Either way the harness's `wait` ("ok exit 1") goes red instead of passing
// vacuously. See house-oz9.2 and rust/crates/house-boot/src/c_start.rs.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x1, _start
    add     x1, x1, :lo12:_start
    mov     x0, #0x1
    str     x0, [x1]                // RO store -> must kill, never skip
    ldr     x2, [x1]                // survived: ask why via read-back
    cmp     x2, x0
    b.eq    writable
    adrp    x1, skipmsg
    add     x1, x1, :lo12:skipmsg
    mov     x2, #17
    mov     x0, #1
    svc     #1
    mov     x0, #2
    svc     #2
writable:
    adrp    x1, writemsg
    add     x1, x1, :lo12:writemsg
    mov     x2, #17
    mov     x0, #1
    svc     #1
    mov     x0, #3
    svc     #2
skipmsg:
    .ascii  "rostore survived\n"
writemsg:
    .ascii  "rostore writable\n"
    .data
    .align 3
scratch:
    .quad   0
.section .note.GNU-stack,"",%progbits
