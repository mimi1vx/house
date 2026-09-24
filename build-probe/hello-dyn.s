.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x1, msg
    add     x1, x1, :lo12:msg
    mov     x0, x1
    bl      strlen
    mov     x2, x0
    mov     x0, #1
    svc     #0x01
    mov     x0, #0
    svc     #0x02
msg:
    .ascii  "Hello from dynamic EL0\n"
