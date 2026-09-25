.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x19, [sp]
    cmp     x19, #2
    b.lo    fail
    ldr     x1, [sp, #16]
    ldrb    w2, [x1]
    cmp     w2, #'o'
    b.eq    run_ok
    cmp     w2, #'m'
    b.eq    run_missing
    b       fail

run_ok:
    adrp    x0, ok_path
    add     x0, x0, :lo12:ok_path
    svc     #0x0B
    b       fail

run_missing:
    adrp    x0, missing_path
    add     x0, x0, :lo12:missing_path
    svc     #0x0B
    mov     x3, #-2
    cmp     x0, x3
    b.ne    fail
    adrp    x1, preserved_msg
    add     x1, x1, :lo12:preserved_msg
    mov     x2, #23
    mov     x0, #1
    svc     #0x01
    mov     x0, #0
    svc     #0x02

fail:
    adrp    x1, fail_msg
    add     x1, x1, :lo12:fail_msg
    mov     x2, #14
    mov     x0, #1
    svc     #0x01
    mov     x0, #1
    svc     #0x02

.section .rodata
ok_path:
    .asciz "/bin/hello-dyn"
missing_path:
    .asciz "/bin/hello-dyn-missing"
preserved_msg:
    .ascii "exec missing preserved\n"
fail_msg:
    .ascii "exec dyn fail\n"

.data
.align 3
scratch:
    .quad 0
