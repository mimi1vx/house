// EL0 rm for /bin/rm (pid1 slice, plans/pid1-init-shell.md steps 3-4).
// Removes a file or empty dir via UNLINK 0x0D (x0 = path VA, resumes 0).
// Needs argv[1]; prints `rm ok` + exit 0, else `rm fail` + exit 1.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #2
    b.lo    fail                    // need prog + path
    ldr     x0, [sp, #16]           // argv[1]
    svc     #0x0D                   // UNLINK -> x0 = 0
    cbnz    x0, fail
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #6
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "rm ok\n", 6)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #8
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "rm fail\n", 8)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
okmsg:
    .ascii  "rm ok\n"
failmsg:
    .ascii  "rm fail\n"

    .data
    .align 3
scratch:
    .quad   0
