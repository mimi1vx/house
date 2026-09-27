// EL0 demand-pager race probe: grow the break one page at a time and store to
// the new page, so every iteration makes the kernel allocate a page-table level
// or a data page on the fault path. Two of these run at once under -smp 2, so
// two cores enter house_handle_user_fault together; a walk with no lock lets
// both allocate and link the same missing level.
//
// Syscall: BRK 0x03 (x0=newBrk -> x0=break), WRITE 0x01, YIELD 0x00, EXIT 0x02.
.arch armv8-a
.equ ROUNDS, 64
.text
.global _start
.type _start, %function
_start:
    mov     x0, #0
    svc     #0x03                   // BRK(0) -> x0 = current break
    mov     x19, x0                 // x19 = brk cursor
    mov     x20, #0                 // x20 = round
1:
    add     x21, x19, #4096
    mov     x0, x21
    svc     #0x03                   // BRK(new)
    cmp     x0, x21
    b.ne    fail
    // Store to the freshly grown page: the fault the pager has to service.
    mov     x22, x20
    str     x22, [x19]
    ldr     x23, [x19]
    cmp     x22, x23
    b.ne    fail
    add     x19, x19, #4096
    add     x20, x20, #1
    cmp     x20, #ROUNDS
    b.lo    1b
    // Yield every round so the scheduler interleaves the two processes on
    // different cores instead of running one to completion.
    mov     x0, #0
    svc     #0x00
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #13
    mov     x0, #1
    svc     #0x01
    mov     x0, #0
    svc     #0x02
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #16
    mov     x0, #1
    svc     #0x01
    mov     x0, #1
    svc     #0x02
okmsg:
    .ascii  "faultrace ok\n"
failmsg:
    .ascii  "faultrace FAIL\n"

    // Scratch data word: keeps the linker's data PT_LOAD non-empty so
    // repack.py sees the hello-style (R+E text + RW data) shape.
.data
.align 3
scratch:
    .quad   0
.section .note.GNU-stack,"",%progbits
