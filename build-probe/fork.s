// EL0 fork/wait probe (plans/multiprocess.md step 9) + COW divergence
// (step 10). Scratch is zeroed pre-fork so the share walk maps it shared;
// after fork each side stores a distinct halfword and reads it back. A
// skipped store (plain-RO fault, no COW break) reads back stale data and
// fails, so success proves share-then-diverge on both the copy path
// (child, while the parent still maps the page) and the sole-mapper path
// (parent, after the child was reaped).
// Forks via `svc #0x08`; the child resumes at the post-svc pc with x0 = 0,
// the parent with x0 = child pid. The child prints `fork child` and exits
// 0; the parent prints `fork parent`, waits via `svc #0x09` (x0 = child
// pid, resumes the reaped exit code), prints `fork wait ok` and exits 0.
// Any mismatch prints `fork fail` and exits 1.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x1, scratch
    add     x1, x1, :lo12:scratch
    str     xzr, [x1]                 // map scratch pre-fork (present at share)
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
    adrp    x1, scratch
    add     x1, x1, :lo12:scratch
    mov     x0, #0x111
    str     x0, [x1]                // COW fault (sole mapper) -> break -> retry
    ldr     x0, [x1]
    cmp     x0, #0x111
    b.ne    fail                    // stale read means the store was skipped
    adrp    x1, wmsg
    add     x1, x1, :lo12:wmsg
    mov     x2, #13
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "fork wait ok\n", 13)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
child:
    adrp    x1, scratch
    add     x1, x1, :lo12:scratch
    mov     x0, #0x222
    str     x0, [x1]                // COW fault (shared) -> copy -> retry
    ldr     x0, [x1]
    cmp     x0, #0x222
    b.ne    fail                    // peer value means no divergence
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
    // repack.py sees the hello-style (R+E text + RW data) shape, and gives
    // the COW check a shared data page to diverge on.
    .data
    .align 3
scratch:
    .quad   0
