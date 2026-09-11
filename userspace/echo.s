// EL0 echo for /bin/echo (pid1 slice, plans/pid1-init-shell.md step 4).
// Prints argv[1..] joined with single spaces plus a trailing newline via
// svc WRITE (one call per word), exits 0. Bare `echo` prints just `\n`.
// String scans are capped at 2048 (kernel argv strings are <=1024 by the
// setupArgStack contract, so the cap only fires on a hostile stack).
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x19, [sp]               // argc
    cmp     x19, #2
    b.lo    newline                 // 0-1 args: just newline
    add     x20, sp, #16            // &argv[1]
    mov     x21, #1                 // index
word_loop:
    cmp     x21, x19
    b.hs    newline
    ldr     x1, [x20]               // argv[i]
    bl      putstr
    add     x21, x21, #1
    add     x20, x20, #8
    cmp     x21, x19
    b.hs    newline
    mov     w0, #' '
    bl      putc
    b       word_loop
newline:
    mov     w0, #10
    bl      putc
    mov     x0, #0
    svc     #0x02                   // EXIT(0)

// putstr(x1): WRITE(1, x1, strlen_cap(x1, 2048)). Clobbers x0-x4.
putstr:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    stp     x1, x2, [sp, #-16]!
    mov     x2, x1
    mov     x0, #0
1:  cmp     x0, #2048
    b.hs    2f
    ldrb    w3, [x2, x0]
    cbz     w3, 2f
    add     x0, x0, #1
    b       1b
2:  mov     x2, x0                  // len
    ldp     x1, x4, [sp], #16       // x1 = ptr (x4 scratch)
    mov     x0, #1
    cbz     x2, 3f
    svc     #0x01
3:  ldp     x29, x30, [sp], #16
    ret

// putc(w0): WRITE(1, &byte, 1) via stack scratch (SP stays 16-byte
// aligned throughout). Clobbers x0-x2.
putc:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     sp, sp, #16
    strb    w0, [sp, #15]
    add     x1, sp, #15
    mov     x2, #1
    mov     x0, #1
    svc     #0x01
    add     sp, sp, #16
    ldp     x29, x30, [sp], #16
    ret

    .data
    .align 3
scratch:
    .quad   0
