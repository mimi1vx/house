/* House aarch64 boot entry. QEMU -kernel jumps here at EL2 (virtualization
   enabled) or EL1. Drops to EL1 flat/unmapped, applies static-PIC relative
   relocations, clears BSS, hands off to c_start(). */

    .section .text.boot, "ax"
    .global _start
_start:
    msr     daifset, #0xf

    mrs     x0, CurrentEL
    cmp     x0, #0xc
    b.eq    enter_el3
    cmp     x0, #0x8
    b.eq    enter_el2
    b       el1_setup

enter_el3:
    mov     x1, #0x3c9              /* SPSR: EL2h, DAIF masked */
    msr     spsr_el3, x1
    ldr     x1, =enter_el2
    msr     elr_el3, x1
    eret

enter_el2:
    mov     x1, #(1 << 31)          /* HCR_EL2.RW: EL1 is AArch64 */
    msr     hcr_el2, x1
    mrs     x1, cnthctl_el2
    orr     x1, x1, #0x3            /* EL1 may read counters / use events */
    msr     cnthctl_el2, x1
    msr     cntvoff_el2, xzr
    /* GICv3: EL2 must enable ICC_SRE_EL1 sysreg access for EL1. */
    mrs     x1, ICC_SRE_EL2
    orr     x1, x1, #1
    msr     ICC_SRE_EL2, x1
    isb
    mov     x1, #0x3c5              /* SPSR: EL1h, DAIF masked */
    msr     spsr_el2, x1
    ldr     x1, =el1_setup
    msr     elr_el2, x1
    eret

el1_setup:
    mrs     x1, sctlr_el1
    ldr     x2, =(1 << 29) | (1 << 3) | (1 << 1)   /* SA0, SA, A off */
    bic     x1, x1, x2
    msr     sctlr_el1, x1

    /* FP/SIMD (and SVE) are trapped after reset; Haskell code uses them */
    mrs     x1, cpacr_el1
    ldr     x2, =(3 << 20) | (3 << 18)
    orr     x1, x1, x2
    msr     cpacr_el1, x1
    isb

    /* Self-relocation: static link of PIC archives leaves R_AARCH64_RELATIVE
       entries nobody else applies (bias is 0, so entry = final value). */
    ldr     x0, =__rela_start
    ldr     x1, =__rela_end
1:  cmp     x0, x1
    b.hs    2f
    ldr     x2, [x0]                /* r_offset */
    ldr     x3, [x0, #8]            /* r_info */
    ldr     x4, [x0, #16]           /* r_addend */
    lsr     x5, x3, #32
    cmp     x5, #1027               /* R_AARCH64_RELATIVE */
    b.ne    3f
    str     x4, [x2]
3:  add     x0, x0, #24
    b       1b
2:
    ldr     x1, =BOOT_STACK_TOP
    mov     sp, x1

    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
4:  cmp     x0, x1
    b.hs    5f
    stp     xzr, xzr, [x0], #16
    b       4b
5:
    /* Vectors live identity-mapped; installing them before the MMU comes
       up means any fault in house_mmu_early reports instead of vanishing
       through an unset VBAR. */
    ldr     x1, =vectors
    msr     vbar_el1, x1
    isb

    /* Identity map RAM as Normal (see mmu.c) before anything executes RTS
       code; exclusives/unaligned pairs abort on Device memory. */
    bl      house_mmu_early

    bl      c_start
6:  wfi
    b       6b


    .align 11
vectors:
    /* 16 x 128-byte slots: [sync irq fiq serr] x
       (cur SP0, cur SPx, lower A64, lower A32) */
    .rept 4
    b       vec_sync
    .space 124
    b       vec_irq
    .space 124
    b       vec_fatal
    .space 124
    b       vec_fatal
    .space 124
    .endr

/* Full-context save: x0-x30 @0..240, SP @248, q0-q31 @256..767. */
vec_sync:
    sub     sp, sp, #896
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30, [sp, #240]
    add     x17, sp, #896           /* original SP -> gpr[31] slot */
    str     x17, [sp, #248]
    stp     q0, q1, [sp, #256]
    stp     q2, q3, [sp, #288]
    stp     q4, q5, [sp, #320]
    stp     q6, q7, [sp, #352]
    stp     q8, q9, [sp, #384]
    stp     q10, q11, [sp, #416]
    stp     q12, q13, [sp, #448]
    stp     q14, q15, [sp, #480]
    stp     q16, q17, [sp, #512]
    stp     q18, q19, [sp, #544]
    stp     q20, q21, [sp, #576]
    stp     q22, q23, [sp, #608]
    stp     q24, q25, [sp, #640]
    stp     q26, q27, [sp, #672]
    stp     q28, q29, [sp, #704]
    stp     q30, q31, [sp, #736]
    mrs     x0, esr_el1
    mrs     x1, far_el1
    mrs     x2, elr_el1
    mov     x3, sp                  /* gpr frame */
    add     x4, sp, #256            /* fp image */
    bl      c_handle_sync
    msr     elr_el1, x0
    ldp     q0, q1, [sp, #256]
    ldp     q2, q3, [sp, #288]
    ldp     q4, q5, [sp, #320]
    ldp     q6, q7, [sp, #352]
    ldp     q8, q9, [sp, #384]
    ldp     q10, q11, [sp, #416]
    ldp     q12, q13, [sp, #448]
    ldp     q14, q15, [sp, #480]
    ldp     q16, q17, [sp, #512]
    ldp     q18, q19, [sp, #544]
    ldp     q20, q21, [sp, #576]
    ldp     q22, q23, [sp, #608]
    ldp     q24, q25, [sp, #640]
    ldp     q26, q27, [sp, #672]
    ldp     q28, q29, [sp, #704]
    ldp     q30, q31, [sp, #736]
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30, [sp, #240]
    add     sp, sp, #896
    eret

vec_irq:
    sub     sp, sp, #896
    stp     x0, x1, [sp, #0]
    stp     x2, x3, [sp, #16]
    stp     x4, x5, [sp, #32]
    stp     x6, x7, [sp, #48]
    stp     x8, x9, [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30, [sp, #240]
    add     x17, sp, #896
    str     x17, [sp, #248]
    stp     q0, q1, [sp, #256]
    stp     q2, q3, [sp, #288]
    stp     q4, q5, [sp, #320]
    stp     q6, q7, [sp, #352]
    stp     q8, q9, [sp, #384]
    stp     q10, q11, [sp, #416]
    stp     q12, q13, [sp, #448]
    stp     q14, q15, [sp, #480]
    stp     q16, q17, [sp, #512]
    stp     q18, q19, [sp, #544]
    stp     q20, q21, [sp, #576]
    stp     q22, q23, [sp, #608]
    stp     q24, q25, [sp, #640]
    stp     q26, q27, [sp, #672]
    stp     q28, q29, [sp, #704]
    stp     q30, q31, [sp, #736]
    mov     x0, sp
    add     x1, sp, #256
    bl      c_handle_irq
    ldp     q0, q1, [sp, #256]
    ldp     q2, q3, [sp, #288]
    ldp     q4, q5, [sp, #320]
    ldp     q6, q7, [sp, #352]
    ldp     q8, q9, [sp, #384]
    ldp     q10, q11, [sp, #416]
    ldp     q12, q13, [sp, #448]
    ldp     q14, q15, [sp, #480]
    ldp     q16, q17, [sp, #512]
    ldp     q18, q19, [sp, #544]
    ldp     q20, q21, [sp, #576]
    ldp     q22, q23, [sp, #608]
    ldp     q24, q25, [sp, #640]
    ldp     q26, q27, [sp, #672]
    ldp     q28, q29, [sp, #704]
    ldp     q30, q31, [sp, #736]
    ldp     x0, x1, [sp, #0]
    ldp     x2, x3, [sp, #16]
    ldp     x4, x5, [sp, #32]
    ldp     x6, x7, [sp, #48]
    ldp     x8, x9, [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30, [sp, #240]
    add     sp, sp, #896
    eret

vec_fatal:
    msr     daifset, #0xf
    stp     x29, x30, [sp, #-16]!
    bl      fatal_exception
7:  wfi
    b       7b
