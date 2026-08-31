    .text
    .global house_thread_switch
    .type house_thread_switch, %function
// void house_thread_switch(house_thread_t *old, house_thread_t *new)
// old in x0, new in x1
house_thread_switch:
    // save callee-saved regs onto current stack
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    stp x29, x30, [sp, #-16]!
    stp d8, d9, [sp, #-16]!
    stp d10, d11, [sp, #-16]!
    stp d12, d13, [sp, #-16]!
    stp d14, d15, [sp, #-16]!
    // save sp and tpidr to old
    mov x2, sp
    str x2, [x0]              // old->sp at offset 0
    mrs x2, tpidr_el0
    str x2, [x0, #8]           // old->tpidr at offset 8
    // load new sp and tpidr
    ldr x2, [x1]
    mov sp, x2
    ldr x2, [x1, #8]
    msr tpidr_el0, x2
    isb
    // restore regs
    ldp d14, d15, [sp], #16
    ldp d12, d13, [sp], #16
    ldp d10, d11, [sp], #16
    ldp d8, d9, [sp], #16
    ldp x29, x30, [sp], #16
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ret
    .size house_thread_switch, .-house_thread_switch
