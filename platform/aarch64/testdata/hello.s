    .arch armv8-a
    .text
    .global _start
    .align 2
_start:
    mov x0, #1
    adr x1, msg
    mov x2, #15
    svc #0x01
    mov x0, #0
    svc #0x02
1:  b 1b
msg:
    .ascii "Hello from EL0\n"
