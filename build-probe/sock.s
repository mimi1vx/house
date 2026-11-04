// EL0 socket probe for the S2 delegation ring (single in-flight S1 transport).
// Usage: run /bin/sock <ip dotted> <port> <text>
// OPEN 0x15 (packed IPv4, port) -> SEND 0x16 (text bytes) -> RECV 0x17
// (echo, EAGAIN retried 8x like ipc_pp: under TCG the echo can lag the
// 1.5s server wait) -> CLOSE 0x18. The echo must byte-match the sent text.
// Prints `sock ok` + exits 0; any mismatch, errno, or exhausted budget
// prints `sock fail` + exits 1, so a wedged transport fails honestly.
// x19-x28 hold state across svcs (the kernel preserves them); x0-x18 are
// scratch and reloaded after every svc.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #4
    b.lt    fail
    add     x9, sp, #8
    ldr     x9, [x9, #8]            // argv[1] ip string
    ldr     x10, [sp, #24]          // argv[2] port string (sp+8+16)
    ldr     x11, [sp, #32]          // argv[3] text (sp+8+24)
// Dotted IPv4 -> x19 (network order). Octets accumulate in w15 (<=255),
// shifted into x19; exactly 4 octets then NUL, else fail.
    mov     x19, #0
    mov     x12, #0                 // octet index
octet:
    mov     w15, #0                 // octet value (x11 holds argv[3])
digit:
    ldrb    w13, [x9], #1
    cbz     w13, octet_end
    cmp     w13, #'.'
    b.eq    octet_end
    sub     w13, w13, #48           // '0'
    cmp     w13, #9
    b.hi    fail
    lsl     w14, w15, #3            // val * 10 + d
    add     w15, w14, w15, lsl #1
    add     w15, w15, w13
    cmp     w15, #255
    b.hi    fail
    b       digit
octet_end:
    lsl     x19, x19, #8
    orr     x19, x19, x15
    add     x12, x12, #1
    cmp     x12, #4
    b.eq    ip_done
    cbnz    w13, octet              // '.' continues, NUL this early fails
    b       fail
ip_done:
    cbnz    w13, fail               // trailing garbage after 4th octet
// Port atoi -> x20, range 1..65535.
    mov     x20, #0
port_loop:
    ldrb    w13, [x10], #1
    cbz     w13, port_done
    sub     w13, w13, #48
    cmp     w13, #9
    b.hi    fail
    lsl     x14, x20, #3
    add     x20, x14, x20, lsl #1
    add     x20, x20, x13
    cmp     x20, #65536
    b.hs    fail
    b       port_loop
port_done:
    cbz     x20, fail
// strlen(argv[3]) -> x22, cap 512 (the S1 single-segment payload cap).
    mov     x21, x11
    mov     x22, #0
strlen_loop:
    cmp     x22, #512
    b.hi    fail
    ldrb    w13, [x21, x22]
    cbz     w13, strlen_done
    add     x22, x22, #1
    b       strlen_loop
strlen_done:
// OPEN(packed ip, port) -> x0 = 0.
    mov     x0, x19
    mov     x1, x20
    svc     #0x15
    cbnz    x0, fail
// SEND(text, len) -> x0 = len.
    mov     x0, x21
    mov     x1, x22
    svc     #0x16
    cmp     x0, x22
    b.ne    fail
// RECV(buf, 1024) -> x0 = n; EAGAIN retried 8x, EOF(0) fails (echo expected).
    mov     x23, #8
recv_try:
    adrp    x0, buf
    add     x0, x0, :lo12:buf
    mov     x1, #1024
    svc     #0x17
    cbz     x0, fail
    cmn     x0, #11                 // -11 EAGAIN (peer slow, not wedged)?
    b.ne    recv_got
    subs    x23, x23, #1
    b.ne    recv_try
    b       fail
recv_got:
    cmp     x0, #0
    b.lt    fail                    // any other errno fails honestly
    mov     x24, x0
    cmp     x24, x22                 // echo must match the sent length
    b.ne    fail
    mov     x12, #0
cmp_loop:
    cmp     x12, x22
    b.eq    cmp_done
    adrp    x13, buf
    add     x13, x13, :lo12:buf
    ldrb    w14, [x13, x12]
    ldrb    w13, [x21, x12]
    cmp     w14, w13
    b.ne    fail
    add     x12, x12, #1
    b       cmp_loop
cmp_done:
// CLOSE() -> x0 = 0, then report.
    svc     #0x18
    cbnz    x0, fail
    adrp    x1, okmsg
    add     x1, x1, :lo12:okmsg
    mov     x2, #8
    mov     x0, #1
    svc     #1                      // WRITE(1, "sock ok\n", 8)
    mov     x0, #0
    svc     #2                      // EXIT(0)
fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #10
    mov     x0, #1
    svc     #1
    mov     x0, #1
    svc     #2                      // EXIT(1)
okmsg:
    .ascii  "sock ok\n"
failmsg:
    .ascii  "sock fail\n"
    .data
    .align 3
buf:
    .space  1024
