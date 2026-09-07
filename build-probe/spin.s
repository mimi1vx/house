// EL0 preemption probe (plans/multiprocess.md step 11): argv[1][0] is the
// dot char, argv[2] the decimal iteration total. Burns the total in a tight
// register loop (no yield svc anywhere), printing ".<char>" every total/20
// iterations, then `spin done` + exit 0. Two concurrent spins must
// interleave on -smp 1 (dots alternate A/B/A), both complete exit 0, and
// the shell stays responsive throughout. Any mismatch prints `spin fail`
// and exits 1. Loop counters live in x19-x24 (callee-saved across svc per
// the register contract); the stack is never touched.
.arch armv8-a
.text
.global _start
.type _start, %function
_start:
    ldr     x0, [sp]                  // argc
    cmp     x0, #3
    b.lo    fail                      // need prog + char + count
    ldr     x1, [sp, #16]             // argv[1]
    ldrb    w19, [x1]                 // dot char
    ldr     x1, [sp, #24]             // argv[2]
    mov     x20, #0                   // total
parse:
    ldrb    w2, [x1], #1
    cbz     w2, parsed
    sub     w2, w2, #48               // '0'
    cmp     w2, #9
    b.hi    fail                      // non-digit
    mov     x3, #10
    mul     x20, x20, x3
    add     x20, x20, x2
    b       parse
parsed:
    cbz     x20, fail
    mov     x21, #20
    udiv    x21, x20, x21             // step = total/20
    cbnz    x21, run
    mov     x21, #1                   // tiny totals: dot every iteration
run:
    mov     x22, #0                   // done
    mov     x23, x21                  // next_dot
    mov     x24, #0                   // dots printed
spin:
    add     x22, x22, #1
    cmp     x22, x23
    b.lo    cont
    add     x23, x23, x21
    cmp     x24, #20
    b.hs    cont                      // 20 dots already: silent burn
    mov     x0, #1
    adrp    x1, dotmark
    add     x1, x1, :lo12:dotmark
    mov     x2, #1
    svc     #0x01                     // WRITE(1, ".", 1)
    mov     x0, #1
    ldr     x1, [sp, #16]             // argv[1] (dot char)
    mov     x2, #1
    svc     #0x01                     // WRITE(1, "<char>", 1)
    add     x24, x24, #1
cont:
    cmp     x22, x20
    b.lo    spin
    mov     x0, #1
    adrp    x1, donemsg
    add     x1, x1, :lo12:donemsg
    mov     x2, #10
    svc     #0x01                     // WRITE(1, "spin done\n", 10)
    mov     x0, #0
    svc     #0x02                     // EXIT(0)
fail:
    mov     x0, #1
    adrp    x1, failmsg
    add     x1, x1, :lo12:failmsg
    mov     x2, #10
    svc     #0x01                     // WRITE(1, "spin fail\n", 10)
    mov     x0, #1
    svc     #0x02                     // EXIT(1)
dotmark:
    .ascii  "."
donemsg:
    .ascii  "spin done\n"
failmsg:
    .ascii  "spin fail\n"

    // Scratch data word: keeps the linker's data PT_LOAD non-empty so
    // repack.py sees the hello-style (R+E text + RW data) shape.
    .data
    .align 3
scratch:
    .quad   0
