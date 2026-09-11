// EL0 write for /bin/write (pid1 slice, plans/pid1-init-shell.md step 4).
// Writes argv[2..] joined with spaces to the file at argv[1] via the fd
// ring: OPEN 0x04 (O_WRONLY|O_CREAT|O_TRUNC), WRITE_FD 0x06, CLOSE 0x07.
// Needs prog + path + text; payload capped at 1024 (one WRITE_FD, under
// the 64K svc buffer cap). Prints `write ok` + exit 0, else `write fail`.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #3
    b.lo    fail                    // need prog + path + text
    ldr     x19, [sp, #16]          // path = argv[1]
    // Join argv[2..] with spaces into buf (x20 = cursor, x21 = index).
    adrp    x20, buf
    add     x20, x20, :lo12:buf
    add     x22, sp, #24            // &argv[2]
    mov     x21, #2
    ldr     x23, [sp]               // argc
join_loop:
    cmp     x21, x23
    b.hs    join_done
    cmp     x21, #2
    b.eq    no_sep
    mov     x0, #1024
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    sub     x0, x20, x1
    cmp     x0, #1024
    b.hs    fail                    // payload cap
    mov     w0, #' '
    strb    w0, [x20], #1
no_sep:
    ldr     x1, [x22]               // argv[i]
    bl      copy_capped
    cbnz    x0, fail
    add     x21, x21, #1
    add     x22, x22, #8
    b       join_loop
join_done:
    mov     x0, #1024
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    sub     x24, x20, x1            // len
    // OPEN(path, O_WRONLY|O_CREAT|O_TRUNC = 0x241).
    mov     x0, x19
    mov     x1, #0x241
    svc     #0x04                   // OPEN -> x0 = fd
    cmp     x0, #34
    b.hi    fail
    mov     x19, x0                 // fd
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, x24
    mov     x0, x19
    svc     #0x06                   // WRITE_FD -> x0 = n
    cmp     x0, x24
    b.ne    fail_close
    mov     x0, x19
    svc     #0x07                   // CLOSE(fd)
    cbnz    x0, fail
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #9
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "write ok\n", 9)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail_close:
    mov     x20, x0
    mov     x0, x19
    svc     #0x07                   // CLOSE(fd) before failing
    mov     x0, x20
    cbnz    x0, fail
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #11
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "write fail\n", 11)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)

// copy_capped(x1 = src NUL-terminated, x20 = cursor): appends to buf,
// capped at buf+1024. Returns x0 = 0 ok, 1 over-cap. Clobbers x0-x4.
copy_capped:
    mov     x2, #0
1:  cmp     x2, #1024
    b.hs    3f                      // src over-cap without NUL
    ldrb    w3, [x1, x2]
    cbz     w3, 2f
    add     x2, x2, #1
    b       1b
2:  adrp    x4, buf
    add     x4, x4, :lo12:buf
    sub     x4, x20, x4             // used
    add     x4, x4, x2              // used + srclen
    cmp     x4, #1024
    b.hi    3f
    mov     x4, #0
4:  cmp     x4, x2
    b.hs    5f
    ldrb    w3, [x1, x4]
    strb    w3, [x20], #1
    add     x4, x4, #1
    b       4b
5:  mov     x0, #0
    ret
3:  mov     x0, #1
    ret
okmsg:
    .ascii  "write ok\n"
failmsg:
    .ascii  "write fail\n"

    .data
    .align 3
buf:
    .space  1024
