// Both constructor phases print their own line, so a phase the loader never
// reaches is visible in the boot log instead of silent.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x0, init_ran
    add     x0, x0, :lo12:init_ran
    ldrb    w1, [x0]
    cbz     w1, 1f
    adrp    x0, init_ok
    add     x0, x0, :lo12:init_ok
    bl      print
    b       2f
1:  adrp    x0, init_missing
    add     x0, x0, :lo12:init_missing
    bl      print
2:  mov     x0, #0
    svc     #0x02

// print writes the NUL-terminated string named by x0 to fd 1. It calls, so it
// must save the link register the bl to strlen overwrites.
.type print, %function
print:
    stp     x29, x30, [sp, #-16]!
    mov     x1, x0
    bl      strlen
    mov     x2, x0
    mov     x0, #1
    svc     #0x01
    ldp     x29, x30, [sp], #16
    ret

// The init constructor only records that it ran; _start picks the line, so a
// missing array shows up as init array MISSING.
.type ctor, %function
ctor:
    adrp    x0, init_ran
    add     x0, x0, :lo12:init_ran
    mov     w1, #1
    strb    w1, [x0]
    ret

// Two fini entries on purpose: the first sets the flag and the second reports
// it, so the exit phase also proves the array was expanded in order.
.type fctor_set, %function
fctor_set:
    adrp    x0, fini_ran
    add     x0, x0, :lo12:fini_ran
    mov     w1, #1
    strb    w1, [x0]
    ret

// Called from the trampoline by address, so x30 is the return into the stub
// and the bl to print overwrites it: the frame has to carry it across.
.type fctor_report, %function
fctor_report:
    stp     x29, x30, [sp, #-16]!
    adrp    x0, fini_ran
    add     x0, x0, :lo12:fini_ran
    ldrb    w1, [x0]
    cbz     w1, 1f
    adrp    x0, fini_ok
    add     x0, x0, :lo12:fini_ok
    bl      print
    b       2f
1:  adrp    x0, fini_missing
    add     x0, x0, :lo12:fini_missing
    bl      print
2:  ldp     x29, x30, [sp], #16
    ret

.section .init_array,"aw",%init_array
.align 3
.quad   ctor

.section .fini_array,"aw",%fini_array
.align 3
.quad   fctor_set
.quad   fctor_report

.section .rodata
init_ok:
    .asciz "init array ok\n"
init_missing:
    .asciz "init array MISSING\n"
fini_ok:
    .asciz "fini array ok\n"
fini_missing:
    .asciz "fini array MISSING\n"

// Zero in the file, not .bss: the flags are written from a constructor, and
// the mapping zeroes that tail anyway.
.data
.align 3
init_ran:
    .byte   0
fini_ran:
    .byte   0
.section .note.GNU-stack,"",%progbits
