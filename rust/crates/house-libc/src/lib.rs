#![no_std]

//! Phase 1: tinylibc replacement crate — single owner of `panic handler`
//! and `__stack_chk_guard`/`__stack_chk_fail` (SOTA Rust 03). Also future
//! home of `alloc`/`mem`/`sys`/`threads`/`tls`/`stdio` modules.

pub mod panic;
