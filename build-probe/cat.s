// EL0 cat probe for the fd delegation ring (plans/multiprocess.md step 7).
// Opens /probe.txt read-only, reads up to 64 bytes, echoes via svc WRITE,
// closes, prints `cat ok` and exits 0. Any mismatch prints `cat fail` and
// exits 1. Syscalls: OPEN 0x04 (x0=path, x1=flags), READ 0x05 (x0=fd,
// x1=buf, x2=len), CLOSE 0x07 (x0=fd), WRITE 0x01, EXIT 0x02.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x0, path
    add     x0, x0, :lo12:path
    mov     x1, #0                  // O_RDONLY
    svc     #0x04                   // OPEN -> x0 = fd
    cmp     x0, #34
    b.hi    fail                    // negative errno or out of range
    mov     x19, x0                 // fd
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, #64
    mov     x0, x19
    svc     #0x05                   // READ -> x0 = n
    cmp     x0, #0
    b.le    fail                    // need >= 1 byte
    mov     x20, x0                 // n
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, x20
    mov     x0, #1
    svc     #0x01                   // WRITE(1, buf, n)
    mov     x0, x19
    svc     #0x07                   // CLOSE(fd)
    cbnz    x0, fail
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #7
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "cat ok\n", 7)
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #9
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "cat fail\n", 9)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
path:
    .ascii  "/probe.txt\0"
okmsg:
    .ascii  "cat ok\n"
failmsg:
    .ascii  "cat fail\n"

    .data
    .align 3
buf:
    .space  64
