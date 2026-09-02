#![no_std]

//! Phase 0 stub: aarch64 HAL implementation crate.
//!
//! Owns future `buddy`/`mmu`/`gic`/`timer`/`psci` modules. Depends on
//! `house-hal` for arch-agnostic traits. Phase 1 will centralize
//! `#[panic_handler]` ownership in `house-libc` to avoid duplicate
//! `staticlib` symbols; Phase 0 provides per-crate handlers to satisfy
//! `cargo build` for freestanding `staticlib` (FIXME Phase 1).

use core::panic::PanicInfo;

// FIXME Phase 1: remove; `house-libc` will own the single panichandler.
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {
        core::hint::spin_loop();
    }
}
