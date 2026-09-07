// EL0 brk probe for the brk delegation ring (plans/multiprocess.md step 7).
// Queries brk(0), grows by 8192 (2 pages), touches each new page, prints
// `brk ok` and exits 0. Any mismatch prints `brk fail` and exits 1.
// Syscall: BRK 0x03 (x0=newBrk -> x0=break).
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    mov     x0, #0
    svc     #0x03                   // BRK(0) -> x0 = current break
    mov     x19, x0                 // old brk
    add     x20, x19, #8192         // new brk = old + 2 pages
    mov     x0, x20
    svc     #0x03                   // BRK(new) -> x0 = break
    cmp     x0, x20
    b.ne    fail
    str     xzr, [x19]              // touch first grown page
    str     xzr, [x19, #4096]       // touch second grown page
    ldr     x1, [x19]
    cbnz    x1, fail
    ldr     x1, [x19, #4096]
    cbnz    x1, fail
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #7
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "brk ok\n", 7)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #9
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "brk fail\n", 9)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
okmsg:
    .ascii  "brk ok\n"
failmsg:
    .ascii  "brk fail\n"

    // Scratch data word: keeps the linker's data PT_LOAD non-empty so
    // repack.py sees the hello-style (R+E text + RW data) shape.
    .data
    .align 3
scratch:
    .quad   0
