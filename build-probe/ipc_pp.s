// EL0 IPC ping-pong probe for the park/resume delegation ring
// (plans/multiprocess.md step 6). One binary, role from argv[1]:
// `server` does RECV (0x11) then REPLY (0x13); `client` does CALL (0x12).
// Endpoint id (decimal) comes from argv[2]. Payload is verified both ways:
// client sends [0x22221111, 0x44443333] tag 0x70, server checks them and
// replies [0x5a5abeee] tag 0x71, client checks the reply word.
// Success: server prints `served ok` + exits 0, client prints `pong ok` +
// exits 0. Any mismatch prints `pp fail` + exits 1.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                // argc
    cmp     x0, #3
    b.lt    fail
    add     x9, sp, #8
    ldr     x10, [x9, #8]           // argv[1] role
    ldr     x11, [x9, #16]          // argv[2] endpoint id
    ldrb    w12, [x10]              // role first char
    mov     x19, #0                 // ep = atoi(argv[2])
atoi_loop:
    ldrb    w13, [x11], #1
    cbz     w13, atoi_done
    sub     w13, w13, #48           // '0'
    cmp     w13, #9
    b.hi    fail
    lsl     x14, x19, #3            // x19 * 8
    add     x19, x14, x19, lsl #1   // + x19 * 2 = x19 * 10
    add     x19, x19, x13
    b       atoi_loop
atoi_done:
    cmp     w12, #99                // 'c' -> client
    b.eq    client
    b       server

client:
    adrp    x1, msgbuf
    add     x1, x1, :lo12:msgbuf
    mov     x2, #0x1111
    movk    x2, #0x2222, lsl #16
    str     x2, [x1]
    mov     x2, #0x3333
    movk    x2, #0x4444, lsl #16
    str     x2, [x1, #8]
    mov     x0, x19                 // ep
    mov     x2, #2                  // nwords
    mov     x3, #0x70               // tag
    svc     #0x12                   // CALL -> x0 = 0, reply words in buf
    cbnz    x0, fail
    ldr     x2, [x1]                // reply word0 must be 0x5a5abeee
    mov     x3, #0xbeee
    movk    x3, #0x5a5a, lsl #16
    cmp     x2, x3
    b.ne    fail
    adrp    x1, pongmsg
    add     x1, x1, :lo12:pongmsg
    mov     x2, #8
    mov     x0, #1
    svc     #1                      // WRITE(1, "pong ok\n", 8)
    mov     x0, #0
    svc     #2                      // EXIT(0)

server:
    adrp    x1, msgbuf
    add     x1, x1, :lo12:msgbuf
    mov     x0, x19                 // ep
    mov     x2, #8                  // nwords
    mov     x3, #0
    svc     #0x11                   // RECV -> x0 = sender tag
    cmp     x0, #0x70
    b.ne    fail
    ldr     x2, [x1]                // word0 must be 0x22221111
    mov     x3, #0x1111
    movk    x3, #0x2222, lsl #16
    cmp     x2, x3
    b.ne    fail
    ldr     x2, [x1, #8]            // word1 must be 0x44443333
    mov     x3, #0x3333
    movk    x3, #0x4444, lsl #16
    cmp     x2, x3
    b.ne    fail
    mov     x2, #0xbeee
    movk    x2, #0x5a5a, lsl #16
    str     x2, [x1]                // reply word0
    mov     x0, x19                 // ep
    mov     x2, #1                  // nwords
    mov     x3, #0x71               // tag
    svc     #0x13                   // REPLY -> x0 = 0
    cbnz    x0, fail
    adrp    x1, servmsg
    add     x1, x1, :lo12:servmsg
    mov     x2, #10
    mov     x0, #1
    svc     #1                      // WRITE(1, "served ok\n", 10)
    mov     x0, #0
    svc     #2                      // EXIT(0)

fail:
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #8
    mov     x0, #1
    svc     #1                      // WRITE(1, "pp fail\n", 8)
    mov     x0, #1
    svc     #2                      // EXIT(1)

pongmsg:
    .ascii  "pong ok\n"
servmsg:
    .ascii  "served ok\n"
failmsg:
    .ascii  "pp fail\n"

    // Scratch message buffer: explicit quads keep the data PT_LOAD
    // file-backed so repack.py sees the hello-style (R+E text + RW data)
    // shape.
    .data
    .align 3
msgbuf:
    .quad   0
    .quad   0
    .quad   0
    .quad   0
    .quad   0
    .quad   0
    .quad   0
    .quad   0
