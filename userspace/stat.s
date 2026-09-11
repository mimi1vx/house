// EL0 stat for /bin/stat (pid1 slice, plans/pid1-init-shell.md steps 3-4).
// Stats a path via STAT 0x0E (x0 = path VA, x1 = buf VA, x2 = buflen):
// the kernel renders one text line (`dir ...` / `file ...`), resumes its
// length, and this echoes it. Needs argv[1]; exits 0, else `stat fail` + 1.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #2
    b.lo    fail                    // need prog + path
    ldr     x0, [sp, #16]           // argv[1]
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, #128
    svc     #0x0E                   // STAT -> x0 = n
    cmp     x0, #128
    b.hi    fail                    // negative errno or over-cap
    cbz     x0, done                // zero-length render: nothing to print
    mov     x20, x0
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, x20
    mov     x0, #1
    svc     #0x01                   // WRITE(1, buf, n)
done:
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #10
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "stat fail\n", 10)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
failmsg:
    .ascii  "stat fail\n"

    .data
    .align 3
buf:
    .space  128
