// EL0 ls for /bin/ls (pid1 slice, plans/pid1-init-shell.md steps 3-4).
// Lists a directory via GETDENTS 0x0C..0x0F slice: svc #0x0F
// (x0 = path VA, x1 = buf VA, x2 = buflen) resumes the newline-separated
// listing length, which is echoed with one WRITE. Path is argv[1],
// defaulting to `/`. Prints `ls fail` and exits 1 on any error.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #2
    b.hs    have_arg
    adrp    x19, defpath
    add     x19, x19, :lo12:defpath
    b       do_list
have_arg:
    ldr     x19, [sp, #16]          // argv[1]
do_list:
    mov     x0, x19
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, #4096
    svc     #0x0F                   // GETDENTS -> x0 = n
    cmp     x0, #4096
    b.hi    fail                    // negative errno or over-cap
    cbz     x0, done                // empty dir: nothing to print
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
    mov     x2, #8
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "ls fail\n", 8)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
defpath:
    .ascii  "/\0"
failmsg:
    .ascii  "ls fail\n"

    .data
    .align 3
buf:
    .space  4096
