// EL0 fork/wait probe (plans/multiprocess.md step 9). Forks via `svc #0x08`;
// the child resumes at the post-svc pc with x0 = 0, the parent with
// x0 = child pid. The child prints `fork child` and exits 0; the parent
// prints `fork parent`, waits via `svc #0x09` (x0 = child pid, resumes the
// reaped exit code), prints `fork wait ok` and exits 0. Any mismatch prints
// `fork fail` and exits 1.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    svc     #0x08                   // FORK -> x0 = 0 (child) | pid (parent)
    cbz     x0, child
    mov     x19, x0                 // child pid
    adrp    x1, pmsg
    add     x1, x1, :lo12:pmsg
    mov     x2, #12
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "fork parent\n", 12)
    mov     x0, x19
    svc     #0x09                   // WAIT(child) -> x0 = exit code
    cbnz    x0, fail                // child must exit 0
    adrp    x1, wmsg
    add     x1, x1, :lo12:wmsg
    mov     x2, #13
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "fork wait ok\n", 13)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
child:
    adrp    x1, cmsg
    add     x1, x1, :lo12:cmsg
    mov     x2, #11
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "fork child\n", 11)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    adrp    x1, fmsg
    add     x1, x1, :lo12:fmsg
    mov     x2, #10
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "fork fail\n", 10)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
pmsg:
    .ascii  "fork parent\n"
cmsg:
    .ascii  "fork child\n"
wmsg:
    .ascii  "fork wait ok\n"
fmsg:
    .ascii  "fork fail\n"

    // Scratch data word: keeps the linker's data PT_LOAD non-empty so
    // repack.py sees the hello-style (R+E text + RW data) shape.
    .data
    .align 3
scratch:
    .quad   0
