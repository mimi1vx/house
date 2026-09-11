#![cfg_attr(not(test), no_std)] // hosted tests link std
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(unused_variables)]

//! Tiny EL0 libc for Haskell-EDSL userspace tools.
//!
//! EL0-link only: `ld -T userspace.ld prog.o libhouse_el0_tiny.a
//! --gc-sections`. Never in the kernel link (the kernel links
//! `house-libc`, the single workspace `#[panic_handler]` owner for EL1).
//!
//! Exports exactly the helpers the EDSL needs (`strlen`, `strncmp`,
//! `memcpy`, `memset`; `u64dec` arrives with the `stat`/`ls` slice).
//! Panics exit the EL0 process via `svc #0x02` with code 1 — never the
//! kernel's `wfi` halt, which would hang the whole guest.

#[cfg(not(test))]
use core::panic::PanicInfo;
use core::ptr;

/// EL0 panic handler: `EXIT(1)` through the house svc table, then trap.
/// `panic = "abort"` keeps this out of the normal path; `--gc-sections`
/// drops it from binaries that never reference it.
#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    // SAFETY: `svc #0x02` is the house EXIT path (x0 = code); it never
    // returns. No memory accessed. The trailing loop is unreachable.
    unsafe {
        core::arch::asm!("mov x0, #1", "svc #0x02", options(noreturn));
    }
}

// SAFETY on every function below: caller guarantees pointer validity for
// the accessed range, per the C contract in rust/c-abi.md.

/// Byte copy without overlap handling.
///
/// # Safety
///
/// Caller guarantees `dst` and `src` valid for `n` bytes with no overlap.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memcpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let mut d = dst;
    let mut s = src;
    let mut remaining = n;
    while remaining > 0 {
        unsafe {
            ptr::write(d, ptr::read(s));
            d = d.add(1);
            s = s.add(1);
        }
        remaining -= 1;
    }
    dst
}

/// Byte fill.
///
/// # Safety
///
/// Caller guarantees `dst` valid for `n` bytes.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memset(dst: *mut u8, c: i32, n: usize) -> *mut u8 {
    let val = c as u8;
    let mut d = dst;
    let mut remaining = n;
    while remaining > 0 {
        unsafe {
            ptr::write(d, val);
            d = d.add(1);
        }
        remaining -= 1;
    }
    dst
}

/// NUL-terminated string length.
///
/// # Safety
///
/// Caller guarantees NUL-termination (EDSL passes string literals and
/// capped argv scans only); unbounded scans stay out of EL0.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strlen(s: *const u8) -> usize {
    let start = s.addr();
    let mut p = s;
    // SAFETY: s is NUL-terminated per the contract above.
    unsafe {
        while ptr::read(p) != 0 {
            p = p.add(1);
        }
        p.addr() - start
    }
}

/// Bounded string comparison.
///
/// # Safety
///
/// Caller guarantees `a` and `b` valid for `n` bytes.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strncmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    let mut i = 0;
    while i < n {
        let ca = unsafe { ptr::read(a.add(i)) };
        let cb = unsafe { ptr::read(b.add(i)) };
        if ca != cb {
            return ca as i32 - cb as i32;
        }
        if ca == 0 {
            break;
        }
        i += 1;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    // SAFETY on every call below: pointers come from live stack buffers
    // sized for the access.

    #[test]
    fn memcpy_round_trip() {
        let src = [1u8, 2, 3, 4, 5, 6, 7, 8];
        let mut dst = [0u8; 8];
        let r = unsafe { memcpy(dst.as_mut_ptr(), src.as_ptr(), 8) };
        assert_eq!(r, dst.as_mut_ptr());
        assert_eq!(dst, src);
    }

    #[test]
    fn memset_fills() {
        let mut dst = [0u8; 8];
        let r = unsafe { memset(dst.as_mut_ptr(), 0xAB, 8) };
        assert_eq!(r, dst.as_mut_ptr());
        assert_eq!(dst, [0xABu8; 8]);
    }

    #[test]
    fn strlen_counts() {
        let s = b"hello\0";
        assert_eq!(unsafe { strlen(s.as_ptr()) }, 5);
    }

    #[test]
    fn strncmp_orders() {
        let a = b"abc\0";
        let b = b"abd\0";
        assert_eq!(unsafe { strncmp(a.as_ptr(), a.as_ptr(), 3) }, 0);
        assert_eq!(unsafe { strncmp(a.as_ptr(), b.as_ptr(), 2) }, 0);
        assert!(unsafe { strncmp(a.as_ptr(), b.as_ptr(), 3) } < 0);
    }
}
