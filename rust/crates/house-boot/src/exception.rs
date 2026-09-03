//! Exception vectors — `global_asm!` port of `platform/aarch64/start.S:203-434`.
//!
//! Provides `vectors` (VBAR_EL1), `vec_sync`/`vec_irq`/`vec_fatal`,
//! `house_enter_el0`, and `svc_exit_trampoline` with identical frame layout
//  (`896 B`: `x0-x30` + `SP` + `q0-q31`) and `TLBI` ordering to C.

// SAFETY: Exception handling is the most delicate boot path per `plans/rust-port.md`.
// Each `global_asm!` block discharged:
// - `vectors` is `.align 11` (2048 B), 16×128 B slots with `.rept 4` + `.space 124`
//   padding; `VBAR_EL1` requires 2 KiB alignment — `msr vbar_el1` in `entry.rs`
//   installs it before MMU; `TLBI vmalle1is; dsb ish; isb` ordering matches
//   `mmu.c:house_mmu_set_ttbr0` and `start.S:house_enter_el0`.
// - `vec_sync`/`vec_irq` save/restore `x0-x30`, `sp` (`x17` scratch), `q0-q31` in
//   same offsets (`0..240`, `248`, `256..736`) and call `c_handle_sync`/`c_handle_irq`
//   with identical args (`esr/far/elr/gpr/fpi`); `eret` restores `elr_el1` from handler.
// - `house_enter_el0` sets `TTBR0|ASID<<48` (`bfi #48,#16`), `dsb ish; tlbi vmalle1is;
//   dsb ish; isb` before `eret` to EL0t (`spsr 0`, `sp_el0`, `elr_el1=entry`); `ASID 0`
//   reserved, 8-bit ASID.
// - `svc_exit_trampoline` restores kernel `ttbr0_l0` (ASID 0), same barriers, returns
//   to `house_enter_el0` caller via `ret`; `ldr x9, =ttbr0_l0` pseudo-instruction
//   expanded by `aarch64-unknown-none` assembler correctly.
// - `vec_fatal` masks `DAIF` and loops on `wfi` after `fatal_exception`.
// - `c_handle_sync`, `c_handle_irq`, `fatal_exception`, `uart_puts`, `ttbr0_l0`
//   remain `extern` C symbols until Phase 3; `global_asm!` `ldr =symbol` refs
//   resolve at `ld -T build/aarch64.ld`.
core::arch::global_asm!(
    r#"
    .section .text.vectors, "ax"
    .global vectors
    .type vectors, %object
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

    /* EL0 entry trampoline: sets TTBR0+ASID, spsr 0, elr entry, sp_el0, erets.
       On svc EXIT, c_handle_sync sets ELR to svc_exit_trampoline and SPSR EL1h,
       which restores kernel TTBR0 and returns to house_enter_el0 caller. */
    .global house_enter_el0
    .type house_enter_el0, %function
house_enter_el0:
    // x0=entry, x1=sp, x2=pdir, x3=asid
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    // set TTBR0 = pdir | (asid << 48)
    mov     x9, x2
    bfi     x9, x3, #48, #16
    msr     ttbr0_el1, x9
    dsb     ish
    tlbi    vmalle1is
    dsb     ish
    isb
    // debug
    stp     x0, x1, [sp, #-16]!
    stp     x2, x3, [sp, #-16]!
    adrp    x0, enter_msg
    add     x0, x0, :lo12:enter_msg
    bl      uart_puts
    ldp     x2, x3, [sp], #16
    ldp     x0, x1, [sp], #16
    msr     elr_el1, x0
    mov     x0, #0
    msr     spsr_el1, x0
    msr     sp_el0, x1
    eret
    .align 2
enter_msg:
    .asciz "[enter] eret to EL0\n"
    .align 2
    // EL1 trampoline that SVC EXIT returns to — restores kernel TTBR0 and returns.
    .global svc_exit_trampoline
    .type svc_exit_trampoline, %function
svc_exit_trampoline:
    // restore kernel TTBR0 (ttbr0_l0 with asid 0)
    ldr     x9, =ttbr0_l0
    msr     ttbr0_el1, x9
    dsb     ish
    tlbi    vmalle1is
    dsb     ish
    isb
    // debug
    stp     x0, x1, [sp, #-16]!
    adrp    x0, exit_msg
    add     x0, x0, :lo12:exit_msg
    bl      uart_puts
    ldp     x0, x1, [sp], #16
    ldp     x29, x30, [sp], #16
    ret
    .align 2
exit_msg:
    .asciz "[enter] exit trampoline EL1\n"
    .align 2

vec_fatal:
    msr     daifset, #0xf
    stp     x29, x30, [sp, #-16]!
    bl      fatal_exception
7:  wfi
    b       7b
    "#
);
