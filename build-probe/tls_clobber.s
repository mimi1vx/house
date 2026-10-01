// EL0 TLS clobber probe: writes garbage TPIDR_EL0, then parks via `svc #0`
// (YIELD). The kernel must preserve its own TLS across the EL0 session:
// after resume the process prints `tls ok` and exits 0, and the shell
// prompt returns (a kernel using the clobbered value crashes instead).
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    mov     x0, #0xbeef
    movk    x0, #0xdead, lsl #16
    movk    x0, #0xbeef, lsl #32
    movk    x0, #0xdead, lsl #48     // x0 = 0xdeadbeefdeadbeef
    msr     tpidr_el0, x0            // clobber TLS
    svc     #0                      // YIELD: park, resume with x0 = 0
    adrp    x1, tmsg
    add     x1, x1, :lo12:tmsg
    mov     x2, #7
    mov     x0, #1
    svc     #1                      // WRITE(1, "tls-ok\n", 7)
    mov     x0, #0
    svc     #2                      // EXIT(0)
tmsg:
    .ascii  "tls-ok\n"

    // Scratch data word: keeps the linker's data PT_LOAD non-empty so
    // repack.py sees the hello-style (R+E text + RW data) shape.
    .data
    .align 3
scratch:
    .quad   0
