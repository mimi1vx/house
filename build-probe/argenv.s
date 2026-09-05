// EL0 argv/env probe for House (`run /bin/argenv [args...]`).
// Entry: sp -> argc, argv[argc+1], envp[], strings; x0 is zeroed by eret.
// Buffers the whole report (argc, argv lines, ENV, env lines, <=2000B) into
// .data and emits ONE svc #1 write + svc #2 exit, like /bin/hello's two
// supervisor roundtrips.
// Registers: x19=argc, x23=argv/env cursor, x20=buf cursor, x21=buf base.
// Helpers use x0-x6 only and preserve x19-x24.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x19, [sp]           // argc
    adrp    x21, outbuf
    add     x21, x21, :lo12:outbuf
    mov     x20, x21            // cursor = base
    adrp    x1, s_argc
    add     x1, x1, :lo12:s_argc
    bl      buf_puts
    mov     x0, x19
    bl      buf_u64
    mov     w0, #10
    bl      buf_putc
    add     x23, sp, #8         // &argv[0]
    mov     x24, #0
argv_loop:
    cmp     x24, x19
    b.hs    argv_done
    ldr     x1, [x23], #8
    bl      buf_puts
    mov     w0, #10
    bl      buf_putc
    add     x24, x24, #1
    b       argv_loop
argv_done:
    add     x23, x23, #8        // skip argv NULL -> envp[0]
    adrp    x1, s_env
    add     x1, x1, :lo12:s_env
    bl      buf_puts
    mov     w0, #10
    bl      buf_putc
env_loop:
    ldr     x1, [x23], #8
    cbz     x1, flush
    bl      buf_puts
    mov     w0, #10
    bl      buf_putc
    b       env_loop
flush:
    sub     x2, x20, x21        // len
    mov     x1, x21             // ptr
    mov     x0, #1
    svc     #1                  // WRITE(1, buf, len)
    movz    x0, #0
    svc     #2                  // EXIT(0)

// buf_putc(w0): append byte unless 2000B cap reached. Clobbers x5-x7.
buf_putc:
    sub     x7, x20, x21
    cmp     x7, #2000
    b.hs    1f
    strb    w0, [x20], #1
1:  ret

// buf_puts(x1): append NUL-terminated string (cap 2048 scanned). Clobbers x1-x4.
buf_puts:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     x2, #0
1:  cmp     x2, #2048
    b.hs    2f
    ldrb    w3, [x1, x2]
    cbz     w3, 2f
    add     x2, x2, #1
    b       1b
2:  mov     x4, #0
3:  cmp     x4, x2
    b.hs    4f
    ldrb    w0, [x1, x4]
    stp     x1, x2, [sp, #-16]!
    stp     x3, x4, [sp, #-16]!
    bl      buf_putc
    ldp     x3, x4, [sp], #16
    ldp     x1, x2, [sp], #16
    add     x4, x4, #1
    b       3b
4:  ldp     x29, x30, [sp], #16
    ret

// buf_u64(x0): decimal, no leading zeros. Clobbers x0-x5.
buf_u64:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    sub     x3, sp, #64         // digit scratch (inside mapped stack page)
    mov     x4, x3
    mov     x1, #10
    cmp     x0, #0
    b.ne    1f
    mov     w2, #'0'
    strb    w2, [x3, #-1]!
    b       2f
1:  udiv    x2, x0, x1
    msub    x5, x2, x1, x0
    add     x5, x5, #'0'
    strb    w5, [x3, #-1]!
    mov     x0, x2
    cbnz    x0, 1b
2:  mov     w0, #0
3:  cmp     x3, x4
    b.hs    4f
    ldrb    w0, [x3], #1
    stp     x1, x3, [sp, #-16]!
    stp     x4, x5, [sp, #-16]!
    bl      buf_putc
    ldp     x4, x5, [sp], #16
    ldp     x1, x3, [sp], #16
    b       3b
4:  ldp     x29, x30, [sp], #16
    ret

.section .rodata
s_argc: .asciz "argc="
s_env:  .asciz "ENV"

.section .data
.align 3
outbuf: .space 2048
