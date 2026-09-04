#![no_std]
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(unused_variables)]
#![allow(dead_code)]
#![allow(clippy::all)]
#![allow(clippy::pedantic)]
#![allow(clippy::nursery)]

//! Phase 5: aarch64 HAL — transliteration of `platform/aarch64/*.c`.
//! Single panic handler owner is `house-libc` (this crate declares `extern` guard).
//!
//! `AArch64Hal` implements `house-hal::Hal*` traits via `#[inline(always)]`
//! adapters to `#[no_mangle] extern "C"` free functions (no vtable, ISR parity).
//! Free functions remain the `ld` symbols per `rust/c-abi.md`.

pub mod buddy;
pub mod detect;
pub mod dtb;
pub mod gic;
pub mod ipc;
pub mod irq;
pub mod mm;
pub mod mmio;
pub mod mmu;
pub mod probe;
pub mod psci;
pub mod smp;
pub mod spinlock;
pub mod svc;
pub mod timer;
pub mod uart;
pub mod userspace;
pub mod virtio_blk;
pub mod virtio_net;
pub mod virtio_probe;
pub mod virtio_transport;

use house_hal::{HalGic, HalMmu, HalPsci, HalTimer, HalUart};

/// Marker for `aarch64` HAL — monomorphized, not `dyn Hal`.
pub struct AArch64Hal;

// SAFETY: `AArch64Hal` is stateless; all ops are unsafe per trait.
unsafe impl HalGic for AArch64Hal {
    #[inline(always)]
    unsafe fn init() {
        // SAFETY: GIC base `0x08000000`/`0x080A0000` identity-mapped, EL1 only.
        unsafe { crate::gic::house_gic_init() }
    }
    #[inline(always)]
    unsafe fn init_secondary(core: u32) {
        // SAFETY: core < 32, GICR per-core valid.
        unsafe { crate::gic::house_gic_init_secondary(core) }
    }
    #[inline(always)]
    unsafe fn enable_int(intid: u32) {
        unsafe { crate::gic::house_gic_enable_int(intid) }
    }
    #[inline(always)]
    unsafe fn disable_int(intid: u32) {
        unsafe { crate::gic::house_gic_disable_int(intid) }
    }
    #[inline(always)]
    unsafe fn send_sgi(id: u32, mask: u32) {
        unsafe { crate::gic::house_gic_send_sgi(id, mask) }
    }
    #[inline(always)]
    unsafe fn send_sgi_to_core(id: u32, core: u32) {
        // SAFETY: `ICC_SGI1R_EL1` encoding correct per `gic.rs`.
        unsafe { crate::gic::house_gic_send_sgi_to_core(id, core) }
    }
    #[inline(always)]
    unsafe fn enable_sgi(id: u32) {
        unsafe { crate::gic::house_gic_enable_sgi(id) }
    }
    #[inline(always)]
    unsafe fn eoi(iar: u32) {
        unsafe { crate::gic::house_gic_eoi(iar) }
    }
    #[inline(always)]
    unsafe fn irq_enable() {
        unsafe { crate::gic::house_irq_enable() }
    }
    #[inline(always)]
    unsafe fn irq_disable() {
        unsafe { crate::gic::house_irq_disable() }
    }
}

// SAFETY: MMU ops require EL1, correct TCR/TTBR ordering (`dsb sy`/`tlbi` preserved).
unsafe impl HalMmu for AArch64Hal {
    #[inline(always)]
    unsafe fn early() {
        unsafe { crate::mmu::house_mmu_early() }
    }
    #[inline(always)]
    unsafe fn enable_secondary() {
        unsafe { crate::mmu::house_mmu_enable_secondary() }
    }
    #[inline(always)]
    unsafe fn set_ttbr0(pdir: *mut u8, asid: u64) {
        // SAFETY: pdir page-aligned, asid 8-bit, `dsb ish; isb` ordering in `mmu.rs`.
        unsafe { crate::mmu::house_mmu_set_ttbr0(pdir, asid) }
    }
    #[inline(always)]
    unsafe fn clone_kernel_l1(new_l1: *mut u64) {
        unsafe { crate::mmu::house_mmu_clone_kernel_l1(new_l1) }
    }
    #[inline(always)]
    unsafe fn clone_kernel_l2(new_l2: *mut u64) {
        unsafe { crate::mmu::house_mmu_clone_kernel_l2(new_l2) }
    }
    #[inline(always)]
    unsafe fn update_alias() {
        unsafe { crate::mmu::house_mmu_update_alias() }
    }
    #[inline(always)]
    unsafe fn get_ttbrs(ttbr0: *mut u64, ttbr1: *mut u64, tcr: *mut u64) {
        unsafe { crate::mmu::house_get_ttbrs(ttbr0, ttbr1, tcr) }
    }
}

unsafe impl HalTimer for AArch64Hal {
    #[inline(always)]
    unsafe fn init() {
        unsafe { crate::timer::house_timer_init() }
    }
    #[inline(always)]
    unsafe fn init_secondary(core: u32) {
        unsafe { crate::timer::house_timer_init_secondary(core) }
    }
    #[inline(always)]
    unsafe fn rearm_virt() {
        unsafe { crate::timer::house_timer_rearm_virt() }
    }
    #[inline(always)]
    unsafe fn rearm_phys() {
        unsafe { crate::timer::house_timer_rearm_phys() }
    }
    #[inline(always)]
    unsafe fn uptime_secs() -> u64 {
        // SAFETY: `CNTVCT_EL0` read is always safe.
        unsafe { crate::timer::house_uptime_secs() }
    }
    #[inline(always)]
    unsafe fn uptime_ns() -> u64 {
        // SAFETY: `house_uptime_ns` is house-libc (timerfd); for HAL gate use `house_uptime_secs*1e9`.
        unsafe { crate::timer::house_uptime_secs() * 1_000_000_000 }
    }
}

unsafe impl HalPsci for AArch64Hal {
    #[inline(always)]
    unsafe fn cpu_on(mpidr: u64, entry: u64, ctx: u64) -> i64 {
        // SAFETY: `hvc #0` / `smc #0` with `psci` calling convention.
        unsafe { crate::psci::psci_cpu_on(mpidr, entry, ctx) }
    }
    #[inline(always)]
    unsafe fn affinity_info(mpidr: u64, lowest: u64) -> i64 {
        unsafe { crate::psci::psci_affinity_info(mpidr, lowest) }
    }
    #[inline(always)]
    unsafe fn system_off() -> ! {
        unsafe { crate::psci::psci_system_off() }
    }
    #[inline(always)]
    unsafe fn system_reset() -> ! {
        unsafe { crate::psci::psci_system_reset() }
    }
    #[inline(always)]
    unsafe fn cpu_off() -> i64 {
        unsafe { crate::psci::psci_cpu_off() }
    }
}

unsafe impl HalUart for AArch64Hal {
    #[inline(always)]
    unsafe fn init() {
        // SAFETY: PL011 `0x09000000` identity-mapped.
        unsafe { crate::uart::uart_init() }
    }
    #[inline(always)]
    unsafe fn putc(c: u8) {
        unsafe { crate::uart::uart_putc(c) }
    }
    #[inline(always)]
    unsafe fn puts(s: *const u8) {
        unsafe { crate::uart::uart_puts(s) }
    }
    #[inline(always)]
    unsafe fn getc_blocking() -> i32 {
        unsafe { crate::uart::uart_getc_blocking() }
    }
    #[inline(always)]
    unsafe fn getc_nonblock() -> i32 {
        unsafe { crate::uart::uart_getc_nonblock() }
    }
}

// SAFETY: `AArch64Hal` implements all `Hal*` traits.
unsafe impl house_hal::Hal for AArch64Hal {}
