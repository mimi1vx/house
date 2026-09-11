// EL0 mkdir for /bin/mkdir (pid1 slice, plans/pid1-init-shell.md steps 3-4).
// Creates one directory via MKDIR 0x0C (x0 = path VA, resumes 0).
// Needs argv[1]; prints `mkdir ok` + exit 0, else `mkdir fail` + exit 1.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #2
    b.lo    fail                    // need prog + path
    ldr     x0, [sp, #16]           // argv[1]
    svc     #0x0C                   // MKDIR -> x0 = 0
    cbnz    x0, fail
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #9
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "mkdir ok\n", 9)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #11
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "mkdir fail\n", 11)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
okmsg:
    .ascii  "mkdir ok\n"
failmsg:
    .ascii  "mkdir fail\n"

    .data
    .align 3
scratch:
    .quad   0
