// EL0 YIELD-spin probe: parks repeatedly via `svc #0` for a bounded budget.
// A spin-yielding process must not hold the RTS capability long enough to
// starve the shell, so the harness spawns this, immediately runs `uname`,
// and asserts the shell answers promptly. The probe emits no UART inside the
// loop (the `6e0b314` lesson: no output in a retry loop, or the harness
// pattern-matches its own progress). x19 carries the count across the park,
// which the kernel preserves for the EL0 session. On completion it writes
// `yieldspin ok` and exits 0.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    mov     x19, #0
    mov     x20, #25000             // bounded budget, never an unbounded spin
    movk    x20, #0x2, lsl #16     // 25000 + 2*65536 = 156072 yields
yield_loop:
    svc     #0                      // YIELD: park, resume with x0 = 0
    add     x19, x19, #1
    cmp     x19, x20
    b.lo    yield_loop
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #14
    mov     x0, #1
    svc     #1                      // WRITE(1, "yieldspin ok\n", 14)
    mov     x0, #0
    svc     #2                      // EXIT(0)
okmsg:
    .ascii  "yieldspin ok\n"

    // Scratch data word: keeps the linker's data PT_LOAD non-empty so
    // repack.py sees the hello-style (R+E text + RW data) shape.
    .data
    .align 3
scratch:
    .quad   0
.section .note.GNU-stack,"",%progbits
