#![no_std]

//! Phase 0 stub: entry/vectors crate.
//!
//! Future home of `global_asm!` vectors and `#[unsafe(naked)] _start`
//! (ported from `platform/aarch64/start.S`). Depends on
//! `house-hal-aarch64` for HAL primitives.

use core::panic::PanicInfo;

// FIXME Phase 1: remove; `house-libc` will own the single panichandler.
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {
        core::hint::spin_loop();
    }
}
