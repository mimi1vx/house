#![no_std]

//! Phase 0 stub: architecture-agnostic HAL traits (no code yet).
//!
//! Phase 5 will introduce `trait HalGic/HalTimer/HalMmu/HalPsci/HalUart`
//! and `Mmio` helpers. This crate is the arch-agnostic extension point
//! for future `house-hal-riscv64` etc.

/// Placeholder for future SpinLock abstraction.
// FIXME Phase 5: replace with proper Hal spinlock trait.
pub mod spinlock {}
