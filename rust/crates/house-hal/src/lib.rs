#![no_std]

//! Arch-agnostic HAL trait surface — extension point for `house-hal-riscv64`.
//!
//! `house-hal-aarch64` implements these traits via `#[inline(always)]` adapters
//! to `#[no_mangle] extern "C"` free functions (no vtable, ISR parity preserved).

pub mod arch;
pub mod mmio;
pub mod spinlock;

pub use arch::{Hal, HalGic, HalMmu, HalPsci, HalTimer, HalUart, Page, PhysAddr, VirtAddr};
pub use mmio::Mmio;
pub use spinlock::{RawSpinLock, SpinLock, SpinLockGuard};
