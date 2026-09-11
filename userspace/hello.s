// EL0 hello for /bin/hello (pid1 slice, plans/pid1-init-shell.md step 4).
// Source twin of the historic helloBytes blob: prints `Hello from EL0`
// via svc WRITE and exits 0. /sbin/init execs this as its v1 child, and
// qemu-userspace/qemu-fork (exec leg) assert this exact line.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x1, msg
    add     x1, x1, :lo12:msg
    mov     x2, #15
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "Hello from EL0\n", 15)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
msg:
    .ascii  "Hello from EL0\n"

    .data
    .align 3
scratch:
    .quad   0
