#![allow(dead_code)]
#![allow(clippy::missing_safety_doc)]

//! Arch-agnostic HAL traits — extension point for `house-hal-riscv64`.
//!
//! Traits are `unsafe` because implementations touch MMIO/MSR/cache/TLBI.
//! Each `unsafe` method documents its `// SAFETY:` precondition at the call site.

/// Physical address newtype (identity-mapped RAM or MMIO).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct PhysAddr(pub u64);

/// Virtual address newtype (`TTBR0` user window or `TTBR1` kernel).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct VirtAddr(pub u64);

/// Page frame (4 KiB buddy page).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Page(pub *mut u8);

// SAFETY: Page is a raw pointer wrapper; Send/Sync follow caller guarantees.
unsafe impl Send for Page {}
unsafe impl Sync for Page {}

/// GIC abstraction — `gic.c` / `gic.rs`.
pub unsafe trait HalGic {
    /// Initialize distributor + primary redistributor.
    unsafe fn init();
    /// Initialize secondary redistributor for `core`.
    unsafe fn init_secondary(core: u32);
    /// Enable interrupt `intid`.
    unsafe fn enable_int(intid: u32);
    /// Disable interrupt `intid`.
    unsafe fn disable_int(intid: u32);
    /// Send SGI `id` to affinity mask.
    unsafe fn send_sgi(id: u32, mask: u32);
    /// Send SGI `id` to single `core` (via `ICC_SGI1R_EL1`).
    unsafe fn send_sgi_to_core(id: u32, core: u32);
    /// Enable SGI `id`.
    unsafe fn enable_sgi(id: u32);
    /// End-of-interrupt for `iar`.
    unsafe fn eoi(iar: u32);
    /// Global IRQ enable (`daif` clear).
    unsafe fn irq_enable();
    /// Global IRQ disable (`daif` set).
    unsafe fn irq_disable();
}

/// MMU abstraction — `mmu.c` / `mmu.rs` (TTBR0/TTBR1 `T1SZ=16` 4K).
pub unsafe trait HalMmu {
    /// Early TTBR1/TTBR0 init (identity-maps RAM blocks, RTS alias `0x4200000000`).
    unsafe fn early();
    /// Enable MMU on secondary core (shared tables).
    unsafe fn enable_secondary();
    /// Load `TTBR0_EL1` with `pdir` + `asid` (`TLBI VMALLE1IS` ordering preserved).
    unsafe fn set_ttbr0(pdir: *mut u8, asid: u64);
    /// Clone kernel L1 entries into `new_l1`.
    unsafe fn clone_kernel_l1(new_l1: *mut u64);
    /// Clone kernel L2 device mappings into `new_l2`.
    unsafe fn clone_kernel_l2(new_l2: *mut u64);
    /// Rebuild RTS alias after `house_ram_probe`.
    unsafe fn update_alias();
    /// Read `TTBR0_EL1`/`TTBR1_EL1`/`TCR_EL1`.
    unsafe fn get_ttbrs(ttbr0: *mut u64, ttbr1: *mut u64, tcr: *mut u64);
    /// Invalidate TLB entry for `vaddr` (`TLBI VAE1IS` + `SGI1` shootdown).
    unsafe fn tlb_shootdown(_vaddr: u64) {}
    /// Handle user translation fault (`DFSC 0x04..0x07`, buddy + `VAE1IS`).
    unsafe fn handle_user_fault(_far: u64) -> i32 {
        -1
    }
}

/// Timer abstraction — `timer.c` / `timer.rs` (generic timer PPI 27/30).
pub unsafe trait HalTimer {
    /// Init generic timer for primary.
    unsafe fn init();
    /// Init generic timer for secondary `core`.
    unsafe fn init_secondary(core: u32);
    /// Rearm virtual timer.
    unsafe fn rearm_virt();
    /// Rearm physical timer.
    unsafe fn rearm_phys();
    /// Seconds since boot (`CNTVCT_EL0`).
    unsafe fn uptime_secs() -> u64;
    /// Nanoseconds since boot.
    unsafe fn uptime_ns() -> u64;
}

/// PSCI abstraction — `psci.c` / `psci.rs` (`hvc #0` / `smc #0`).
pub unsafe trait HalPsci {
    /// `CPU_ON` `mpidr` → `entry` with `ctx`.
    unsafe fn cpu_on(mpidr: u64, entry: u64, ctx: u64) -> i64;
    /// `AFFINITY_INFO`.
    unsafe fn affinity_info(mpidr: u64, lowest: u64) -> i64;
    /// `SYSTEM_OFF` (never returns).
    unsafe fn system_off() -> !;
    /// `SYSTEM_RESET` (never returns).
    unsafe fn system_reset() -> !;
    /// `CPU_OFF`.
    unsafe fn cpu_off() -> i64;
}

/// UART abstraction — `uart.c` / `uart.rs` (PL011 `0x09000000`).
pub unsafe trait HalUart {
    /// Initialize PL011.
    unsafe fn init();
    /// Blocking putc (polls `FR_TXFF`, handles `\n` → `\r\n`).
    unsafe fn putc(c: u8);
    /// Put NUL-terminated string (capped 4K).
    unsafe fn puts(s: *const u8);
    /// Blocking getc (polls `FR_RXFE`).
    unsafe fn getc_blocking() -> i32;
    /// Non-blocking getc (`-1` if `RXFE`).
    unsafe fn getc_nonblock() -> i32;
}

/// Unified HAL — arch-agnostic extension point.
///
/// `#[non_exhaustive]` allows future `riscv64` methods without breaking `aarch64`.
/// No vtable: impls are `#[inline(always)]` adapters to `#[no_mangle] extern "C"`
/// free functions (SOTA Security `dsb sy`/`dc cvac` parity preserved).
#[allow(clippy::missing_safety_doc)]
pub unsafe trait Hal: HalGic + HalMmu + HalTimer + HalPsci + HalUart {}

// Blanket impl helper marker — concrete `AArch64Hal`/`Riscv64Hal` implement each subtrait.
