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
2:  adrp    x0, clobber_ran
    add     x0, x0, :lo12:clobber_ran
    ldrb    w1, [x0]
    cbz     w1, 3f
    adrp    x0, clobber_ok
    add     x0, x0, :lo12:clobber_ok
    bl      print
    b       4f
3:  adrp    x0, clobber_missing
    add     x0, x0, :lo12:clobber_missing
    bl      print
4:  adrp    x0, stub_ro
    add     x0, x0, :lo12:stub_ro
    ldrb    w1, [x0]
    cbz     w1, 5f
    adrp    x0, stub_ro_ok
    add     x0, x0, :lo12:stub_ro_ok
    bl      print
    b       6f
5:  adrp    x0, stub_ro_bad
    add     x0, x0, :lo12:stub_ro_bad
    bl      print
6:  mov     x0, #0
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

// A constructor shaped like a compiler-generated frame: it keeps a
// callee-saved register live across a nested call and hands the nested call a
// pointer in x1. AAPCS64 lets every callee destroy x0-x18, so a loader stub
// that parks its own loop state there is calling into code that may take it
// away. If the loop did not survive, this entry never runs.
.type ctor_clobber, %function
ctor_clobber:
    stp     x29, x30, [sp, #-32]!
    str     x28, [sp, #16]
    adrp    x28, clobber_ran
    add     x28, x28, :lo12:clobber_ran
    mov     w9, #1
    strb    w9, [x28]
    mov     x1, x28
    bl      clobber_caller_saved
    ldr     x28, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// A leaf that leaves the caller-saved set full of scratch, which is what any
// real libc constructor with a frame does before its own calls.
.type clobber_caller_saved, %function
clobber_caller_saved:
    mov     x4, xzr
    mov     x5, xzr
    mov     x6, xzr
    mov     x7, xzr
    mov     x8, #0x40
    mov     x9, #0x50
    mov     x10, #0x60
    mov     x11, #0x70
    mov     x12, #0x80
    mov     x13, #0x90
    mov     x14, #0xa0
    mov     x15, #0xb0
    mov     x16, #0xc0
    mov     x17, #0xd0
    mov     x18, #0xe0
    ret

// The loader's stub page must be read-only while a constructor is running on
// it: x30 is the return into the stub, so [x30, #-4] is an instruction word
// the loop is about to re-enter. The store is expected to be refused, and the
// word is put back either way so a wrong answer cannot wedge the loop.
.type ctor_stub_ro, %function
ctor_stub_ro:
    stp     x29, x30, [sp, #-32]!
    ldr     x9, [x30, #-4]
    mov     x10, #0x5a5a
    str     x10, [x30, #-4]
    ldr     x11, [x30, #-4]
    str     x9, [x30, #-4]
    adrp    x0, stub_ro
    add     x0, x0, :lo12:stub_ro
    cmp     x11, x9
    b.eq    1f
    mov     w1, #0
    b       2f
1:  mov     w1, #1
2:  strb    w1, [x0]
    ldp     x29, x30, [sp], #32
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
.quad   ctor_clobber
.quad   ctor_stub_ro

.section .fini_array,"aw",%fini_array
.align 3
.quad   fctor_set
.quad   fctor_report

.section .rodata
init_ok:
    .asciz "init array ok\n"
init_missing:
    .asciz "init array MISSING\n"
clobber_ok:
    .asciz "init clobber ok\n"
clobber_missing:
    .asciz "init clobber MISSING\n"
stub_ro_ok:
    .asciz "stub page read-only\n"
stub_ro_bad:
    .asciz "stub page WRITABLE\n"
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
clobber_ran:
    .byte   0
fini_ran:
    .byte   0
stub_ro:
    .byte   1
.section .note.GNU-stack,"",%progbits
