//! Central panic + stack-guard shims. Single owner per SOTA Rust 03.
//!
//! Exactly one panic handler in the workspace — this module. Other crates
//! must not define one; the final `ld --start-group` link pulls this crate's
//! handler and `__stack_chk_guard`/`__stack_chk_fail` into the ELF.
//! All `unsafe` blocks have `// SAFETY:` comments per SOTA Rust non-negotiable 2.

use core::panic::PanicInfo;

/// Freestanding panic handler — never reached in normal boot (`panic="abort"`).
/// Loops on `wfi` matching `tinylibc/sys.c:exit`/`abort` and `c_start.c:fatal_exception`.
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {
        core::hint::spin_loop();
        // SAFETY: `wfi` is always safe — no memory accessed, no side effects beyond halting core.
        unsafe {
            core::arch::asm!("wfi", options(nomem, nostack));
        }
    }
}

/// Stack-protector guard for Debian-built RTS archives that were compiled with
/// `-fstack-protector`. Value matches `tinylibc/sys.c:uintptr_t __stack_chk_guard`.
#[no_mangle]
pub static __stack_chk_guard: u64 = 0xdeadbeef_cafef00d;

/// Stack-smash failure — halts like `panic` (no unwinding in `panic="abort"` kernel).
#[no_mangle]
pub extern "C" fn __stack_chk_fail() -> ! {
    loop {
        // SAFETY: `wfi` is always safe — same as `panic` above.
        unsafe {
            core::arch::asm!("wfi", options(nomem, nostack));
        }
    }
}
