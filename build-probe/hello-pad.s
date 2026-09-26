.arch armv8-a
.text

// house_pad is a DSO export the deep probe calls that touches no GOT slot.
.global house_pad
.type house_pad, %function
house_pad:
    mov     x1, x0
1:  ldrb    w2, [x0]
    cbz     w2, 2f
    add     x0, x0, #1
    b       1b
2:  sub     x0, x0, x1
    ret

// house_len reaches libc through this DSO's own JUMP_SLOT for strlen. It
// calls, so it must save the link register the bl overwrites.
.global house_len
.type house_len, %function
house_len:
    stp     x29, x30, [sp, #-16]!
    bl      strlen
    ldp     x29, x30, [sp], #16
    ret

.section .note.GNU-stack,"",%progbits
