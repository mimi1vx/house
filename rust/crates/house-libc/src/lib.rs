#![no_std]

//! Phase 0 stub: tinylibc replacement crate.
//!
//! Future single owner of `#[panic_handler]` (Phase 1 will keep this and
//! remove duplicates from `house-hal-aarch64`/`house-boot`). Also future
//! home of `alloc`/`mem`/`sys`/`threads`/`tls`/`stdio` modules.

use core::panic::PanicInfo;

#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {
        core::hint::spin_loop();
    }
}
