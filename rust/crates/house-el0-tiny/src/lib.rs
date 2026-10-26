#![cfg_attr(not(test), no_std)] // hosted tests link std
#![allow(
    unsafe_op_in_unsafe_fn,
    reason = "transliteration has explicit unsafe blocks throughout; inner-block audit as follow-up"
)]
#![allow(
    static_mut_refs,
    reason = "transliterated C globals use raw statics; guarded by HAL spinlocks"
)]
#![allow(
    unused_variables,
    reason = "transliteration keeps C parameter names for ABI parity"
)]

//! Tiny EL0 libc for Haskell-EDSL userspace tools, plus the B1 shared
//! flavour GHC rebuilds against (`cdylib`, ET_DYN).
//!
//! EL0-link only: `ld -T userspace.ld prog.o libhouse_el0_tiny.a
//! --gc-sections`. Never in the kernel link (the kernel links
//! `house-libc`, the single workspace `#[panic_handler]` owner for EL1).
//!
//! Exports the string/memory helpers the EDSL and a non-threaded GHC
//! closure need (`strlen`, `strncmp`, `memcpy`, `memset`, plus `memmove`,
//! `memcmp`, `memchr`, `strnlen`, `strcmp`, `strcpy`, `strncpy`, `strcat`,
//! `strchr`, `strrchr`, `strcasecmp`), link-only `printf`-family and
//! locale stubs (return 0/null/static, mirroring `house-libc` `stdio.rs`
//! and `compat.rs`), a static `__errno_location`, and EL0 `svc #0x02`
//! `exit`/`abort`. No allocator: `malloc` family stays out until B2's link
//! measurement names it (EL0 `brk` bump, not EL1 `house_vm_mmap`).
//! Panics exit the EL0 process via `svc #0x02` with code 1 — never the
//! kernel's `wfi` halt, which would hang the whole guest.

use core::ffi::c_void;
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

/// Overlapping-safe copy.
///
/// # Safety
///
/// Caller guarantees `dst` and `src` valid for `n` bytes; overlap handled
/// by direction choice per C.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memmove(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    if ptr::eq(dst, src as *mut u8) || n == 0 {
        return dst;
    }
    if (dst as usize) < (src as usize) {
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
    } else {
        let mut d = unsafe { dst.add(n) };
        let mut s = unsafe { src.add(n) };
        let mut remaining = n;
        while remaining > 0 {
            unsafe {
                d = d.sub(1);
                s = s.sub(1);
                ptr::write(d, ptr::read(s));
            }
            remaining -= 1;
        }
    }
    dst
}

/// Bounded byte comparison.
///
/// # Safety
///
/// Caller guarantees `a` and `b` valid for `n` bytes.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    let mut i = 0;
    while i < n {
        let av = unsafe { ptr::read(a.add(i)) };
        let bv = unsafe { ptr::read(b.add(i)) };
        if av != bv {
            return av as i32 - bv as i32;
        }
        i += 1;
    }
    0
}

/// Bounded byte search.
///
/// # Safety
///
/// Caller guarantees `s` valid for `n` bytes.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memchr(s: *const u8, c: i32, n: usize) -> *mut u8 {
    let target = c as u8;
    let mut i = 0;
    while i < n {
        let v = unsafe { ptr::read(s.add(i)) };
        if v == target {
            return s.add(i) as *mut u8;
        }
        i += 1;
    }
    core::ptr::null_mut()
}

/// Bounded string length.
///
/// # Safety
///
/// Caller guarantees `s` valid for `max` bytes.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strnlen(s: *const u8, max: usize) -> usize {
    let mut p = s;
    let mut remaining = max;
    unsafe {
        while remaining > 0 && ptr::read(p) != 0 {
            p = p.add(1);
            remaining -= 1;
        }
        p.offset_from(s) as usize
    }
}

/// NUL-terminated comparison.
///
/// # Safety
///
/// Caller guarantees NUL-termination (EDSL passes string literals and
/// capped scans only).
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strcmp(a: *const u8, b: *const u8) -> i32 {
    let mut pa = a;
    let mut pb = b;
    loop {
        let ca = unsafe { ptr::read(pa) };
        let cb = unsafe { ptr::read(pb) };
        if ca != cb || ca == 0 {
            return ca as i32 - cb as i32;
        }
        unsafe {
            pa = pa.add(1);
            pb = pb.add(1);
        }
    }
}

/// NUL-terminated copy.
///
/// # Safety
///
/// Caller guarantees `src` NUL-terminated and `dst` sized.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strcpy(dst: *mut u8, src: *const u8) -> *mut u8 {
    let mut d = dst;
    let mut s = src;
    loop {
        let v = unsafe { ptr::read(s) };
        unsafe { ptr::write(d, v) };
        if v == 0 {
            break;
        }
        unsafe {
            d = d.add(1);
            s = s.add(1);
        }
    }
    dst
}

/// Bounded copy with NUL padding.
///
/// # Safety
///
/// Caller guarantees `dst` valid for `n` bytes and `src` valid for the
/// read range.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strncpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let mut d = dst;
    let mut s = src;
    let mut remaining = n;
    while remaining > 0 {
        let v = unsafe { ptr::read(s) };
        unsafe { ptr::write(d, v) };
        if v == 0 {
            remaining -= 1;
            d = unsafe { d.add(1) };
            while remaining > 0 {
                unsafe {
                    ptr::write(d, 0);
                    d = d.add(1);
                }
                remaining -= 1;
            }
            break;
        }
        unsafe {
            d = d.add(1);
            s = s.add(1);
        }
        remaining -= 1;
    }
    dst
}

/// NUL-terminated concatenation.
///
/// # Safety
///
/// Caller guarantees both inputs NUL-terminated and `dst` sized.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strcat(dst: *mut u8, src: *const u8) -> *mut u8 {
    let len = unsafe { strlen(dst) };
    unsafe { strcpy(dst.add(len), src) };
    dst
}

/// First occurrence search.
///
/// # Safety
///
/// Caller guarantees `s` NUL-terminated.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strchr(s: *const u8, c: i32) -> *mut u8 {
    let target = c as u8;
    let mut p = s;
    loop {
        let v = unsafe { ptr::read(p) };
        if v == target {
            return p as *mut u8;
        }
        if v == 0 {
            return core::ptr::null_mut();
        }
        p = unsafe { p.add(1) };
    }
}

/// Last occurrence search.
///
/// # Safety
///
/// Caller guarantees `s` NUL-terminated.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn strrchr(s: *const u8, c: i32) -> *mut u8 {
    let target = c as u8;
    let mut last: *mut u8 = core::ptr::null_mut();
    let mut p = s;
    loop {
        let v = unsafe { ptr::read(p) };
        if v == target {
            last = p as *mut u8;
        }
        if v == 0 {
            break;
        }
        p = unsafe { p.add(1) };
    }
    last
}

/// Case-insensitive comparison.
///
/// # Safety
///
/// Caller guarantees both inputs NUL-terminated.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
#[allow(
    clippy::manual_range_contains,
    reason = "range checks mirror C comparisons"
)]
#[allow(
    clippy::manual_is_ascii_check,
    reason = "explicit ranges keep the object free of iterator generics"
)]
pub unsafe extern "C" fn strcasecmp(a: *const u8, b: *const u8) -> i32 {
    let mut pa = a;
    let mut pb = b;
    loop {
        let ca = unsafe { ptr::read(pa) };
        let cb = unsafe { ptr::read(pb) };
        if ca == 0 && cb == 0 {
            return 0;
        }
        let ca_low = if (b'a' <= ca && ca <= b'z') || (b'A' <= ca && ca <= b'Z') {
            ca | 0x20
        } else {
            ca
        };
        let cb_low = if (b'a' <= cb && cb <= b'z') || (b'A' <= cb && cb <= b'Z') {
            cb | 0x20
        } else {
            cb
        };
        if ca_low != cb_low {
            return ca as i32 - cb as i32;
        }
        if ca == 0 || cb == 0 {
            return ca as i32 - cb as i32;
        }
        unsafe {
            pa = pa.add(1);
            pb = pb.add(1);
        }
    }
}

// Link-only printf family: a GHC closure references these, but House EL0
// has no FILE* runtime yet. Return 0 like `house-libc` `stdio.rs` so the
// link succeeds; functional output stays on `svc #0x01` in the EDSL tools.

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn vfprintf(_f: *mut c_void, _fmt: *const u8, _ap: *mut c_void) -> i32 {
    0
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn fprintf(_f: *mut c_void, _fmt: *const u8) -> i32 {
    0
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn vprintf(_fmt: *const u8, _ap: *mut c_void) -> i32 {
    0
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn printf(_fmt: *const u8) -> i32 {
    0
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn vsnprintf(_b: *mut u8, _n: usize, _f: *const u8, _a: *mut c_void) -> i32 {
    0
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn snprintf(_b: *mut u8, _n: usize, _f: *const u8) -> i32 {
    0
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn sprintf(_b: *mut u8, _f: *const u8) -> i32 {
    0
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn puts(_s: *const u8) -> i32 {
    0
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn fputs(_s: *const u8, _f: *mut c_void) -> i32 {
    0
}

/// Link-only stub echoing its arg.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn putchar(_c: i32) -> i32 {
    _c
}

/// Link-only stub echoing its arg.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn fputc(_c: i32, _f: *mut c_void) -> i32 {
    _c
}

/// Link-only stub echoing its count.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn fwrite(_p: *const u8, _s: usize, _c: usize, _f: *mut c_void) -> usize {
    _c
}

/// Link-only stub returning 0.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn fflush(_f: *mut c_void) -> i32 {
    0
}

// Link-only locale stubs mirroring `house-libc` `compat.rs`. The C locale
// is the only locale; `setlocale`/`nl_langinfo` return static UTF-8 tags.

/// Link-only stub returning its base pointer.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn newlocale(_m: i32, _n: *const u8, _b: *mut c_void) -> *mut c_void {
    _b
}

/// Link-only stub doing nothing.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn freelocale(_l: *mut c_void) {}

/// Link-only stub returning null.
///
/// # Safety
///
/// Always safe: ignores all args.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn uselocale(_l: *mut c_void) -> *mut c_void {
    core::ptr::null_mut()
}

/// Link-only stub returning a static tag.
///
/// # Safety
///
/// Always safe: returns a static address.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn setlocale(_c: i32, _n: *const u8) -> *mut u8 {
    c"C.UTF-8".as_ptr() as *mut u8
}

/// Link-only stub returning a static tag.
///
/// # Safety
///
/// Always safe: returns a static address.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn nl_langinfo(_i: i32) -> *mut u8 {
    c"UTF-8".as_ptr() as *mut u8
}

static mut STATIC_ERRNO: i32 = 0;

/// EL0 errno cell. Single static (no thread pointer at EL0 yet).
///
/// # Safety
///
/// Always safe: returns a valid static address.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn __errno_location() -> *mut i32 {
    &raw mut STATIC_ERRNO
}

// EL0 process enders via `svc #0x02`. The `target_arch` gate keeps hosted
// `cargo test` (x86_64) compiling: only aarch64 emits `svc`.

/// Exit with code via `svc #0x02`.
///
/// # Safety
///
/// Always safe: never returns.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn exit(code: i32) -> ! {
    #[cfg(target_arch = "aarch64")]
    unsafe {
        core::arch::asm!("svc #0x02", in("x0") code as u64, options(noreturn));
    }
    #[cfg(not(target_arch = "aarch64"))]
    loop {
        core::hint::spin_loop();
    }
}

/// Exit with code via `svc #0x02`.
///
/// # Safety
///
/// Always safe: never returns.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn _exit(code: i32) -> ! {
    #[cfg(target_arch = "aarch64")]
    unsafe {
        core::arch::asm!("svc #0x02", in("x0") code as u64, options(noreturn));
    }
    #[cfg(not(target_arch = "aarch64"))]
    loop {
        core::hint::spin_loop();
    }
}

/// Exit with code via `svc #0x02`.
///
/// # Safety
///
/// Always safe: never returns.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
#[allow(non_snake_case)]
pub unsafe extern "C" fn _Exit(code: i32) -> ! {
    #[cfg(target_arch = "aarch64")]
    unsafe {
        core::arch::asm!("svc #0x02", in("x0") code as u64, options(noreturn));
    }
    #[cfg(not(target_arch = "aarch64"))]
    loop {
        core::hint::spin_loop();
    }
}

/// Abort via `svc #0x02` with code 1.
///
/// # Safety
///
/// Always safe: never returns.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn abort() -> ! {
    #[cfg(target_arch = "aarch64")]
    unsafe {
        core::arch::asm!("mov x0, #1", "svc #0x02", options(noreturn));
    }
    #[cfg(not(target_arch = "aarch64"))]
    loop {
        core::hint::spin_loop();
    }
}

/// Assertion failure via `svc #0x02` with code 1.
///
/// # Safety
///
/// Always safe: never returns.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn __assert_fail(_a: *const u8, _f: *const u8, _l: u32, _fn: *const u8) -> ! {
    #[cfg(target_arch = "aarch64")]
    unsafe {
        core::arch::asm!("mov x0, #1", "svc #0x02", options(noreturn));
    }
    #[cfg(not(target_arch = "aarch64"))]
    loop {
        core::hint::spin_loop();
    }
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

    #[test]
    fn memmove_overlapping() {
        let mut buf = [1u8, 2, 3, 4, 5, 6, 7, 8];
        unsafe {
            let p = buf.as_mut_ptr();
            memmove(p, p.add(2), 4);
        }
        assert_eq!(buf, [3, 4, 5, 6, 5, 6, 7, 8]);
        let mut buf = [1u8, 2, 3, 4, 5, 6, 7, 8];
        unsafe {
            let p = buf.as_mut_ptr();
            memmove(p.add(2), p, 4);
        }
        assert_eq!(buf, [1, 2, 1, 2, 3, 4, 7, 8]);
    }

    #[test]
    fn memcmp_sign() {
        let a = *b"abcdef\0\0";
        let b = *b"abcdeg\0\0";
        assert_eq!(unsafe { memcmp(a.as_ptr(), a.as_ptr(), 8) }, 0);
        assert!(unsafe { memcmp(a.as_ptr(), b.as_ptr(), 8) } < 0);
        assert_eq!(unsafe { memcmp(a.as_ptr(), b.as_ptr(), 5) }, 0);
    }

    #[test]
    fn memchr_hit_miss() {
        let s = *b"hello world\0\0\0\0";
        assert_eq!(
            unsafe { memchr(s.as_ptr(), b'w' as i32, 11) },
            unsafe { s.as_ptr().add(6) } as *mut u8
        );
        assert!(unsafe { memchr(s.as_ptr(), b'z' as i32, 11) }.is_null());
    }

    #[test]
    fn strnlen_caps() {
        let s = b"hello\0";
        assert_eq!(unsafe { strnlen(s.as_ptr(), 3) }, 3);
        assert_eq!(unsafe { strnlen(s.as_ptr(), 99) }, 5);
    }

    #[test]
    fn strcmp_orders() {
        let a = b"abc\0";
        let b = b"abd\0";
        assert_eq!(unsafe { strcmp(a.as_ptr(), a.as_ptr()) }, 0);
        assert!(unsafe { strcmp(a.as_ptr(), b.as_ptr()) } < 0);
    }

    #[test]
    fn strcpy_strncpy_strcat() {
        let mut dst = [0xFFu8; 8];
        let src = b"hi\0";
        assert_eq!(
            unsafe { strcpy(dst.as_mut_ptr(), src.as_ptr()) },
            dst.as_mut_ptr()
        );
        assert_eq!(&dst[..4], b"hi\0\xFF");
        let mut dst = [0xFFu8; 8];
        unsafe { strncpy(dst.as_mut_ptr(), src.as_ptr(), 6) };
        assert_eq!(&dst[..7], b"hi\0\0\0\0\xFF");
        let mut dst = [0u8; 12];
        unsafe {
            strcpy(dst.as_mut_ptr(), b"foo\0".as_ptr());
            strcat(dst.as_mut_ptr(), b"bar\0".as_ptr());
        }
        assert_eq!(&dst[..7], b"foobar\0");
    }

    #[test]
    fn strchr_strrchr() {
        let s = b"abca\0";
        assert_eq!(
            unsafe { strchr(s.as_ptr(), b'a' as i32) },
            s.as_ptr() as *mut u8
        );
        assert_eq!(
            unsafe { strrchr(s.as_ptr(), b'a' as i32) },
            unsafe { s.as_ptr().add(3) } as *mut u8
        );
        assert!(unsafe { strchr(s.as_ptr(), b'z' as i32) }.is_null());
    }

    #[test]
    fn strcasecmp_folds() {
        let a = b"Hello\0";
        let b = b"hELLO\0";
        assert_eq!(unsafe { strcasecmp(a.as_ptr(), b.as_ptr()) }, 0);
    }

    #[test]
    fn stdio_stubs_zero() {
        assert_eq!(unsafe { printf(b"%d\0".as_ptr()) }, 0);
        assert_eq!(
            unsafe { snprintf(core::ptr::null_mut(), 0, b"x\0".as_ptr()) },
            0
        );
        assert_eq!(
            unsafe {
                vsnprintf(
                    core::ptr::null_mut(),
                    0,
                    b"x\0".as_ptr(),
                    core::ptr::null_mut(),
                )
            },
            0
        );
        assert_eq!(unsafe { puts(b"x\0".as_ptr()) }, 0);
        assert_eq!(unsafe { putchar(65) }, 65);
        assert_eq!(unsafe { fflush(core::ptr::null_mut()) }, 0);
    }

    #[test]
    fn locale_stubs_static() {
        assert!(!unsafe { setlocale(0, core::ptr::null()) }.is_null());
        assert!(!unsafe { nl_langinfo(0) }.is_null());
        assert!(unsafe { uselocale(core::ptr::null_mut()) }.is_null());
        assert_eq!(unsafe { __errno_location() }.is_null(), false);
    }
}
