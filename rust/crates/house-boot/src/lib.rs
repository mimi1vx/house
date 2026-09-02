#![no_std]

//! Phase 1: entry/vectors crate.
//!
//! Future home of `global_asm!` vectors and `#[unsafe(naked)] _start`
//! (ported from `platform/aarch64/start.S`). Depends on
//! `house-hal-aarch64` for HAL primitives. Single panic handler owner is
//! `house-libc` (per-crate duplicate removed in Phase 1).
