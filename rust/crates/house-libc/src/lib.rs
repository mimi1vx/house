#![cfg_attr(not(test), no_std)] // hosted tests link std (Miri gate, step 9)
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(unused_variables)]

//! Phase 1: tinylibc replacement crate — single owner of `panic handler`
//! and `__stack_chk_guard`/`__stack_chk_fail` (SOTA Rust 03). Also future
//! home of `alloc`/`mem`/`sys`/`threads`/`tls`/`stdio` modules.
//!
//! Miri isolation: only pure logic (`mem`, `mathmin`, `getopt`) compiles
//! for hosted tests. The syscall/ABI surface (`alloc`, `c_print`,
//! `compat`, `stdio`, `sys`, `threads`) exports `#[no_mangle]` libc
//! symbols that would interpose (or signature-clash with) std's own
//! runtime in the test binary, so it stays kernel-link-only. The pure
//! modules keep their bodies but drop `#[no_mangle]` under `cfg(test)`
//! for the same reason (Miri routes known symbols like `strlen` through
//! built-in shims and rejects interposed definitions).

#[cfg(not(test))]
pub mod alloc;
#[cfg(not(test))]
pub mod c_print;
#[cfg(not(test))]
pub mod compat;
pub mod getopt;
pub mod mathmin;
pub mod mem;
pub mod panic;
#[cfg(not(test))]
pub mod stdio;
#[cfg(not(test))]
pub mod sys;
#[cfg(not(test))]
pub mod threads;
