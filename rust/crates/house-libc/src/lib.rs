#![no_std]
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(unused_variables)]

//! Phase 1: tinylibc replacement crate — single owner of `panic handler`
//! and `__stack_chk_guard`/`__stack_chk_fail` (SOTA Rust 03). Also future
//! home of `alloc`/`mem`/`sys`/`threads`/`tls`/`stdio` modules.

pub mod alloc;
pub mod c_print;
pub mod compat;
pub mod getopt;
pub mod mathmin;
pub mod mem;
pub mod panic;
pub mod stdio;
pub mod sys;
pub mod threads;
