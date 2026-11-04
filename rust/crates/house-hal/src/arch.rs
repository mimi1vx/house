#![allow(
    dead_code,
    reason = "transliterated C surface keeps entries for ABI parity"
)]
//! Arch-agnostic HAL traits — extension point for `house-hal-riscv64`.
//!
//! Traits are `unsafe` because implementations touch MMIO/MSR/cache/TLBI.
//! Each `unsafe` item carries a `# Safety` section stating what implementors
//! and callers must uphold; call sites repeat the discharged obligation in
//! a `// SAFETY:` comment.

/// Physical address newtype (identity-mapped RAM or MMIO).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct PhysAddr(pub u64);

/// Virtual address newtype (`TTBR0` user window or `TTBR1` kernel).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct VirtAddr(pub u64);

/// Page frame (4 KiB buddy page).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Page(pub *mut u8);

// SAFETY: `Page` is an owned 4 KiB buddy frame; the frame allocator hands
// each frame to a single owner, so transferring or sharing the handle is
// sound as long as the caller upholds that exclusive-ownership contract
// (no live aliases across free, no double free). The `*mut u8` itself
// carries no thread-local state.
unsafe impl Send for Page {}
unsafe impl Sync for Page {}

/// GIC abstraction — `gic.c` / `gic.rs`.
///
/// # Safety
///
/// Implementations touch GIC distributor/redistributor MMIO and `ICC_*`
/// system registers: only implement for EL1 with the GIC windows
/// identity-mapped, and call `init`/`init_secondary` before the rest.
pub unsafe trait HalGic {
    /// Initialize distributor + primary redistributor.
    ///
    /// # Safety
    ///
    /// Call once on the primary core at EL1 before any other GIC method.
    unsafe fn init();
    /// Initialize secondary redistributor for `core`.
    ///
    /// # Safety
    ///
    /// Call once per secondary core at EL1; `core` is that core's own id.
    unsafe fn init_secondary(core: u32);
    /// Enable interrupt `intid`.
    ///
    /// # Safety
    ///
    /// `intid` must be a valid interrupt ID for this GIC.
    unsafe fn enable_int(intid: u32);
    /// Disable interrupt `intid`.
    ///
    /// # Safety
    ///
    /// `intid` must be a valid interrupt ID for this GIC.
    unsafe fn disable_int(intid: u32);
    /// Send SGI `id` to affinity mask.
    ///
    /// # Safety
    ///
    /// `id` must be a valid SGI number (0-15); `mask` must target online cores.
    unsafe fn send_sgi(id: u32, mask: u32);
    /// Send SGI `id` to single `core` (via `ICC_SGI1R_EL1`).
    ///
    /// # Safety
    ///
    /// `id` must be a valid SGI number (0-15); `core` must be online.
    unsafe fn send_sgi_to_core(id: u32, core: u32);
    /// Enable SGI `id`.
    ///
    /// # Safety
    ///
    /// `id` must be a valid SGI number (0-15).
    unsafe fn enable_sgi(id: u32);
    /// End-of-interrupt for `iar`.
    ///
    /// # Safety
    ///
    /// `iar` must be a value read from `ICC_IAR1_EL1` for an interrupt this
    /// core activated and has not yet ended.
    unsafe fn eoi(iar: u32);
    /// Global IRQ enable (`daif` clear).
    ///
    /// # Safety
    ///
    /// Call at EL1.
    unsafe fn irq_enable();
    /// Global IRQ disable (`daif` set).
    ///
    /// # Safety
    ///
    /// Call at EL1.
    unsafe fn irq_disable();
}

/// MMU abstraction — `mmu.c` / `mmu.rs` (TTBR0/TTBR1 `T1SZ=16` 4K).
///
/// # Safety
///
/// Implementations publish translation tables and issue `TLBI`/`DSB`/`ISB`:
/// only implement for EL1 with exclusive ownership of the tables written;
/// callers must not alias a table while it is active.
pub unsafe trait HalMmu {
    /// Early TTBR1/TTBR0 init (identity-maps RAM blocks, RTS alias `0x4200000000`).
    ///
    /// # Safety
    ///
    /// Call once on the primary core at EL1 before enabling the MMU.
    unsafe fn early();
    /// Enable MMU on secondary core (shared tables).
    ///
    /// # Safety
    ///
    /// Call once per secondary core at EL1 before that core enables the MMU.
    unsafe fn enable_secondary();
    /// Load `TTBR0_EL1` with `pdir` + `asid` (`TLBI VMALLE1IS` ordering preserved).
    ///
    /// # Safety
    ///
    /// `pdir` must be a 4 KiB-aligned L0 table base, exclusively owned until replaced.
    unsafe fn set_ttbr0(pdir: *mut u8, asid: u64);
    /// Clone kernel L1 entries into `new_l1`.
    ///
    /// # Safety
    ///
    /// `new_l1` must be a writable, 4 KiB-aligned 512-entry buffer with no live aliases.
    unsafe fn clone_kernel_l1(new_l1: *mut u64);
    /// Clone kernel L2 device mappings into `new_l2`.
    ///
    /// # Safety
    ///
    /// `new_l2` must be a writable, 4 KiB-aligned 512-entry buffer with no live aliases.
    unsafe fn clone_kernel_l2(new_l2: *mut u64);
    /// Rebuild RTS alias after `house_ram_probe`.
    ///
    /// # Safety
    ///
    /// Call at EL1 after RAM detection and before the RTS uses the alias.
    unsafe fn update_alias();
    /// Read `TTBR0_EL1`/`TTBR1_EL1`/`TCR_EL1`.
    ///
    /// # Safety
    ///
    /// Each pointer must be writable for one `u64` and unaliased for the call.
    unsafe fn get_ttbrs(ttbr0: *mut u64, ttbr1: *mut u64, tcr: *mut u64);
    /// Invalidate TLB entry for `vaddr` (`TLBI VAE1IS` + `SGI1` shootdown).
    ///
    /// # Safety
    ///
    /// Call at EL1 after changing the entry for `_vaddr`.
    unsafe fn tlb_shootdown(_vaddr: u64) {}
    /// Handle user translation fault (`DFSC 0x04..0x07`, buddy + `VAE1IS`).
    ///
    /// # Safety
    ///
    /// Call at EL1 with `_far` holding the faulting VA.
    unsafe fn handle_user_fault(_far: u64) -> i32 {
        -1
    }
}

/// Timer abstraction — `timer.c` / `timer.rs` (generic timer PPI 27/30).
///
/// # Safety
///
/// Implementations program the generic timer and read `CNTVCT_EL0`: only
/// implement where the counter is enabled at the calling exception level.
pub unsafe trait HalTimer {
    /// Init generic timer for primary.
    ///
    /// # Safety
    ///
    /// Call once on the primary core before rearming.
    unsafe fn init();
    /// Init generic timer for secondary `core`.
    ///
    /// # Safety
    ///
    /// Call once per secondary core; `core` is that core's own id.
    unsafe fn init_secondary(core: u32);
    /// Rearm virtual timer.
    ///
    /// # Safety
    ///
    /// Call after `init`/`init_secondary` on this core.
    unsafe fn rearm_virt();
    /// Rearm physical timer.
    ///
    /// # Safety
    ///
    /// Call after `init`/`init_secondary` on this core.
    unsafe fn rearm_phys();
    /// Seconds since boot (`CNTVCT_EL0`).
    ///
    /// # Safety
    ///
    /// No requirements beyond the trait contract.
    unsafe fn uptime_secs() -> u64;
    /// Nanoseconds since boot.
    ///
    /// # Safety
    ///
    /// No requirements beyond the trait contract.
    unsafe fn uptime_ns() -> u64;
}

/// PSCI abstraction — `psci.c` / `psci.rs` (`hvc #0` / `smc #0`).
///
/// # Safety
///
/// Implementations issue `HVC`/`SMC` with PSCI function IDs: only implement
/// where firmware handles PSCI, and call at EL1.
pub unsafe trait HalPsci {
    /// `CPU_ON` `mpidr` → `entry` with `ctx`.
    ///
    /// # Safety
    ///
    /// `mpidr` must address a present core; `entry` must be a valid physical
    /// entry point for it.
    unsafe fn cpu_on(mpidr: u64, entry: u64, ctx: u64) -> i64;
    /// `AFFINITY_INFO`.
    ///
    /// # Safety
    ///
    /// No requirements beyond the trait contract (unknown cores report an error).
    unsafe fn affinity_info(mpidr: u64, lowest: u64) -> i64;
    /// `SYSTEM_OFF` (never returns).
    ///
    /// # Safety
    ///
    /// Never returns; call only to power the machine off.
    unsafe fn system_off() -> !;
    /// `SYSTEM_RESET` (never returns).
    ///
    /// # Safety
    ///
    /// Never returns; call only to reset the machine.
    unsafe fn system_reset() -> !;
    /// `CPU_OFF`.
    ///
    /// # Safety
    ///
    /// The calling core stops and may never resume; call only with this
    /// core's state saved and no more work for it.
    unsafe fn cpu_off() -> i64;
}

/// UART abstraction — `uart.c` / `uart.rs` (PL011 `0x09000000`).
///
/// # Safety
///
/// Implementations drive the PL011 registers: only implement with the UART
/// window mapped, and call `init` before the other methods.
pub unsafe trait HalUart {
    /// Initialize PL011.
    ///
    /// # Safety
    ///
    /// Call once before any other UART method.
    unsafe fn init();
    /// Blocking putc (polls `FR_TXFF`, handles `\n` → `\r\n`).
    ///
    /// # Safety
    ///
    /// The UART must be initialized; may spin until TX is ready.
    unsafe fn putc(c: u8);
    /// Put NUL-terminated string (capped 4K).
    ///
    /// # Safety
    ///
    /// `s` must point to a NUL-terminated string in memory readable at EL1.
    unsafe fn puts(s: *const u8);
    /// Blocking getc (polls `FR_RXFE`).
    ///
    /// # Safety
    ///
    /// The UART must be initialized; spins until a byte arrives.
    unsafe fn getc_blocking() -> i32;
    /// Non-blocking getc (`-1` if `RXFE`).
    ///
    /// # Safety
    ///
    /// The UART must be initialized.
    unsafe fn getc_nonblock() -> i32;
}

/// Unified HAL — arch-agnostic extension point.
///
/// `#[non_exhaustive]` allows future `riscv64` methods without breaking `aarch64`.
/// No vtable: impls are `#[inline(always)]` adapters to `#[no_mangle] extern "C"`
/// free functions (SOTA Security `dsb sy`/`dc cvac` parity preserved).
///
/// # Safety
///
/// Implementors must uphold the `# Safety` contracts of all five subtraits.
pub unsafe trait Hal: HalGic + HalMmu + HalTimer + HalPsci + HalUart {}

// Blanket impl helper marker — concrete `AArch64Hal`/`Riscv64Hal` implement each subtrait.
