// EL0 exec probe (plans/multiprocess.md step 9). Execs /bin/hello via
// `svc #0x0B` (x0 = path VA); on success the image is replaced and this
// code never runs again (hello prints + exits 0). A return means failure:
// print `exec fail` and exit 1.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x0, path
    add     x0, x0, :lo12:path
    svc     #0x0B                   // EXEC("/bin/hello") -> 0 on success
    adrp    x1, fmsg
    add     x1, x1, :lo12:fmsg
    mov     x2, #10
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "exec fail\n", 10)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
path:
    .ascii  "/bin/hello\0"
fmsg:
    .ascii  "exec fail\n"

    .data
    .align 3
scratch:
    .quad   0
