// EL0 sh for /bin/sh (dx7.2).
// Minimal prompt-and-echo shell over the fd ring: OPEN 0x04 /dev/console
// (dx7.1 reserved path, no new svc), print `sh$ `, then echo each READ 0x05
// chunk until an empty read (console idle poll), CLOSE 0x07 and exit 0. An
// open miss prints `sh: ENOENT`, any other mismatch `sh fail`, all exit 1.
// Read chunk is 1024 (well under the 64K svc buffer cap).
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    adrp    x19, conpath
    add     x19, x19, :lo12:conpath
    mov     x0, x19
    mov     x1, #0                  // O_RDONLY
    svc     #0x04                   // OPEN -> x0 = fd
    cmp     x0, #34
    b.hi    fail
    mov     x19, x0                 // fd
prompt:
    adrp    x1, promptmsg
    add     x1, x1, :lo12:promptmsg
    mov     x2, #4
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "sh$ ", 4)
read_loop:
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, #1024
    mov     x0, x19
    svc     #0x05                   // READ -> x0 = n
    cmp     x0, #1024
    b.hi    fail                    // negative errno or over-cap
    cbz     x0, eof
    mov     x20, x0                 // n
    adrp    x1, buf
    add     x1, x1, :lo12:buf
    mov     x2, x20
    mov     x0, #1
    svc     #0x01                   // WRITE(1, buf, n)
    b       prompt
eof:
    mov     x0, x19
    svc     #0x07                   // CLOSE(fd)
    cbnz    x0, fail
    mov     x0, #0
    svc     #0x02                   // EXIT(0)
fail:
    mov     x1, #-2
    cmp     x0, x1
    b.eq    enoent                  // x0 is the resumed errno here
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #8
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "sh fail\n", 8)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
enoent:
    adrp    x1, enoentmsg
    add     x1, x1, :lo12:enoentmsg
    mov     x2, #11
    mov     x0, #1
    svc     #0x01                   // WRITE(1, "sh: ENOENT\n", 11)
    mov     x0, #1
    svc     #0x02                   // EXIT(1)
conpath:
    .ascii  "/dev/console\0"
promptmsg:
    .ascii  "sh$ "
failmsg:
    .ascii  "sh fail\n"
enoentmsg:
    .ascii  "sh: ENOENT\n"

    .data
    .align 3
buf:
    .space  1024
