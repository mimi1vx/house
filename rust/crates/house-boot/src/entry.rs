//! Boot entry — `global_asm!` port of `platform/aarch64/start.S:8-201`.
//!
//! Provides `_start`, `secondary_entry`, `secondary_spin`, and `__boot_dtb`
//! with byte-identical semantics to the C boot. HAL (`mmu`/`c_start`) stays C
//! in Phase 2; this crate only owns the assembly shape.

// SAFETY: Every `global_asm!` block is freestanding EL3→EL2→EL1 entry. Preconditions
// discharged by hardware/QEMU contract and by the assembly itself:
// - `DAIF` masked (`daifset #0xf`) before touching `SPSR_EL3/EL2`, `VBAR_EL1`, or
//   `sp` — no interrupt window before `VBAR` install (SOTA Security: keep DAIF masked).
// - `CurrentEL` check covers all entry ELs; `eret` to EL1 only after `HCR_EL2.RW=1`,
//   `CNTHCTL_EL2`, `CNTVOFF_EL2`, `ICC_SRE_EL2`, `SPSR_EL2=0x3c5`/`SPSR_EL3=0x3c9`.
// - `sp` per-core `house_boot_stack_top - core*16K` (or `__early_stacks_top` fallback)
//   is valid per `aarch64.ld` `HOUSE_MAX_SMP*16K` reservation; `TLBI VMALLE1IS` not
//   needed until later `TTBR0` switch (done in `exception.rs`).
// - `R_AARCH64_RELATIVE` loop processes host `.rela.dyn` entries with `cmp x5,#1027`
//   exactly as C `start.S:73-85`; primary only (secondary skips relocs/BSS).
// - `__rela_start/end`, `__bss_start/end`, `__early_stacks_top`, `house_boot_stack_top`,
//   `vectors`, `house_mmu_early`, `house_mmu_enable_secondary`, `c_start`,
//   `c_start_secondary` are `extern` C/ld symbols resolved at `ld -T build/aarch64.ld`.
core::arch::global_asm!(
    r#"
    .section .data
    .align 3
    .global __boot_dtb
__boot_dtb:
    .quad 0

    .section .text.boot, "ax"
    .global _start
_start:
    msr     daifset, #0xf
    mov     x20, x0                /* preserve DTB/x0 before clobber */

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

    /* SMP: check core id; non-zero cores that land on _start (not PSCI)
       spin on wfe — real secondaries arrive via secondary_entry. */
    mrs     x19, MPIDR_EL1
    and     x19, x19, #0xff
    cbnz    x19, secondary_spin

    /* Primary (core 0) — Self-relocation: static link of PIC archives leaves
       R_AARCH64_RELATIVE entries nobody else applies (bias is 0). */
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
    /* Per-core SP: house_boot_stack_top - core*16K if set else early stacks.
       Early boot uses low __early_stacks_top (after BSS) which is safe
       for both 512M and 4G QEMU; c_start rebases to runtime top after
       detect (so same ELF works at 512M/4G without stack fault). */
    ldr     x1, =house_boot_stack_top
    ldr     x1, [x1]
    cbnz    x1, 10f
    ldr     x1, =__early_stacks_top
10: mov     x2, #16384
    mul     x3, x19, x2
    sub     x1, x1, x3
    mov     sp, x1

    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
4:  cmp     x0, x1
    b.hs    5f
    stp     xzr, xzr, [x0], #16
    b       4b
5:
    /* Persist boot DTB before any C code clobbers it. */
    ldr     x1, =__boot_dtb
    str     x20, [x1]

    /* Vectors live identity-mapped; installing them before the MMU comes
       up means any fault in house_mmu_early reports instead of vanishing
       through an unset VBAR. */
    ldr     x1, =vectors
    msr     vbar_el1, x1
    isb

    /* Identity map RAM as Normal WB (see mmu.c) before RTS code. */
    bl      house_mmu_early

    bl      c_start
6:  wfi
    b       6b

secondary_spin:
    wfe
    b       secondary_spin

    /* PSCI entry for secondaries: x0 = ctx = core_id (from primary's
       psci_cpu_on). 4K-aligned as required by some PSCI impls. */
    .align 12
    .global secondary_entry
secondary_entry:
    mov     x19, x0                 /* save core_id */
    msr     daifset, #0xf

    /* Handle EL2/EL3 if firmware entered secondary at higher EL. */
    mrs     x0, CurrentEL
    cmp     x0, #0xc
    b.eq    sec_enter_el3
    cmp     x0, #0x8
    b.eq    sec_enter_el2
    b       sec_el1

sec_enter_el3:
    mov     x1, #0x3c9
    msr     spsr_el3, x1
    ldr     x1, =sec_enter_el2
    msr     elr_el3, x1
    eret

sec_enter_el2:
    mov     x1, #(1 << 31)
    msr     hcr_el2, x1
    mrs     x1, cnthctl_el2
    orr     x1, x1, #0x3
    msr     cnthctl_el2, x1
    msr     cntvoff_el2, xzr
    mrs     x1, ICC_SRE_EL2
    orr     x1, x1, #1
    msr     ICC_SRE_EL2, x1
    isb
    mov     x1, #0x3c5
    msr     spsr_el2, x1
    ldr     x1, =sec_el1
    msr     elr_el2, x1
    eret

sec_el1:
    /* SRE for sysreg GIC access, FP enable per core. */
    mrs     x1, ICC_SRE_EL1
    orr     x1, x1, #1
    msr     ICC_SRE_EL1, x1
    isb
    mrs     x1, cpacr_el1
    ldr     x2, =(3 << 20) | (3 << 18)
    orr     x1, x1, x2
    msr     cpacr_el1, x1
    isb

    /* Per-core SP: runtime top if already set by primary (else early). */
    ldr     x1, =house_boot_stack_top
    ldr     x1, [x1]
    cbnz    x1, 11f
    ldr     x1, =__early_stacks_top
11: mov     x2, #16384
    mul     x3, x19, x2
    sub     x1, x1, x3
    mov     sp, x1

    ldr     x1, =vectors
    msr     vbar_el1, x1
    isb

    bl      house_mmu_enable_secondary

    mov     x0, x19
    bl      c_start_secondary
7:  wfi
    b       7b
    "#
);
