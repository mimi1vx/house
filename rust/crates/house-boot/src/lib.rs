#![no_std]

//! Boot entry/vectors crate — Phase 2 `global_asm!` port of `platform/aarch64/start.S`.
//! Single panic handler owner is `house-libc` (SOTA Rust 03).
// Safety: every `global_asm!` block has `// SAFETY:` discharging VBAR/sp/DAIF invariants.

pub mod entry;
pub mod exception;
