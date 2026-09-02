#![no_std]

//! Phase 1: aarch64 HAL implementation crate.
//!
//! Owns future `buddy`/`mmu`/`gic`/`timer`/`psci` modules. Depends on
//! `house-hal` for arch-agnostic traits. Single panic handler owner is
//! `house-libc` (Phase 1 removed the per-crate duplicate).
