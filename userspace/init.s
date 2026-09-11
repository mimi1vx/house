// EL0 pid1 for /sbin/init (pid1 slice, plans/pid1-init-shell.md step 5).
// v2: runs no children. Announces, exits 0; the kernel logs
// `init pid N` at spawn and `init exit CODE` at reap
// (Kernel.Init), which qemu-initramfs/qemu-pid1 assert. Spawning demo
// children at boot is gone: the shell waits for the user instead.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x1, upmsg
    add     x1, x1, :lo12:upmsg
    mov     x2, #8
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "init up\n", 8)
    adrp    x1, donemsg
    add     x1, x1, :lo12:donemsg
    mov     x2, #10
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "init done\n", 10)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
upmsg:
    .ascii  "init up\n"
donemsg:
    .ascii  "init done\n"

    .data
    .align 3
scratch:
    .quad   0
