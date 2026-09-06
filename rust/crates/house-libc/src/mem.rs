#![allow(clippy::all)]
//! mem.rs — tinylibc/mem.c transliteration (167 SLoC).

use core::ptr;

// 8-byte fast path mirrors C: while n>=8 && aligned d && aligned s, copy 8.

// SAFETY: caller guarantees dst and src valid for n bytes, n <= isize::MAX,
// dst/src not overlapping for memcpy (for memmove overlap direction is handled).
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memcpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    // Byte-wise copy to avoid unaligned 8-byte accesses that may fault on some QEMU/hvf configs
    // (previously used read_unaligned/write_unaligned for 8-byte fast path, but that triggered
    // EC 0 faults at 0x405cbcc0 under pure Rust; use simple loop for correctness).
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

#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memmove(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    if dst == src as *mut u8 || n == 0 {
        return dst;
    }
    // SAFETY: copy semantics with overlap; direction chosen per C.
    if (dst as usize) < (src as usize) {
        // forward
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
        // backward
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

#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memcmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    for i in 0..n {
        // SAFETY: caller guarantees a,b valid for n.
        let av = unsafe { ptr::read(a.add(i)) };
        let bv = unsafe { ptr::read(b.add(i)) };
        if av != bv {
            return av as i32 - bv as i32;
        }
    }
    0
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn memchr(s: *const u8, c: i32, n: usize) -> *mut u8 {
    let target = c as u8;
    for i in 0..n {
        // SAFETY: caller valid for n.
        let v = unsafe { ptr::read(s.add(i)) };
        if v == target {
            return s.add(i) as *mut u8;
        }
    }
    core::ptr::null_mut()
}

// Debug-build bound for the trust-boundary probes below: every unbounded
// NUL scanner asserts a NUL within this many bytes. Matches uart_puts' 4K
// cap. Release keeps zero cost (debug_assert compiled out under panic=abort).
const CSTR_DEBUG_CAP: usize = 4096;

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strlen(s: *const u8) -> usize {
    // Trust boundary (rust/c-abi.md): caller guarantees NUL-termination —
    // Haskell withCString upholds it; device/EL0 bytes must be
    // strnlen-pre-bound before reaching here. The probe trips in debug builds
    // on a violated contract instead of wandering unmapped memory.
    debug_assert!(unsafe { strnlen(s, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
    let mut p = s;
    // SAFETY: s is NUL-terminated per C contract (see trust boundary above).
    unsafe {
        while ptr::read(p) != 0 {
            p = p.add(1);
        }
        p.offset_from(s) as usize
    }
}

#[cfg_attr(not(test), unsafe(no_mangle))]
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

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strcmp(a: *const u8, b: *const u8) -> i32 {
    // Trust boundary (rust/c-abi.md): both inputs NUL-terminated by the
    // caller; device/EL0 bytes must be strnlen-pre-bound before reaching here.
    debug_assert!(unsafe { strnlen(a, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
    debug_assert!(unsafe { strnlen(b, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
    let mut pa = a;
    let mut pb = b;
    loop {
        // SAFETY: NUL-terminated strings per contract.
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

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strncmp(a: *const u8, b: *const u8, n: usize) -> i32 {
    for i in 0..n {
        let ca = unsafe { ptr::read(a.add(i)) };
        let cb = unsafe { ptr::read(b.add(i)) };
        if ca != cb {
            return ca as i32 - cb as i32;
        }
        if ca == 0 {
            break;
        }
    }
    0
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strcpy(dst: *mut u8, src: *const u8) -> *mut u8 {
    // Trust boundary (rust/c-abi.md): src NUL-terminated and dst sized by the
    // caller; device/EL0 bytes must be strnlen-pre-bound before reaching here.
    debug_assert!(unsafe { strnlen(src, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
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

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strncpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    let mut d = dst;
    let mut s = src;
    let mut remaining = n;
    while remaining > 0 {
        let v = unsafe { ptr::read(s) };
        unsafe { ptr::write(d, v) };
        if v == 0 {
            // pad with zeros
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
    // C strncpy pads remaining with NULs already handled; if src longer, no NUL termination.
    // Ensure tail zero fill if loop exited via n exhaustion without hitting NUL.
    // Already handled by while condition: if we consumed n without NUL, no pad needed.
    // But if we broke early due to NUL, tail already padded. So nothing extra.
    dst
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strcat(dst: *mut u8, src: *const u8) -> *mut u8 {
    // Trust boundary (rust/c-abi.md): both inputs NUL-terminated and dst
    // sized by the caller (strlen/strcpy below re-probe). Device/EL0 bytes
    // must be strnlen-pre-bound before reaching here.
    debug_assert!(unsafe { strnlen(dst, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
    debug_assert!(unsafe { strnlen(src, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
    // dst + strlen(dst)
    let len = strlen(dst);
    strcpy(dst.add(len), src);
    dst
}

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strchr(s: *const u8, c: i32) -> *mut u8 {
    // Trust boundary (rust/c-abi.md): s NUL-terminated by the caller;
    // device/EL0 bytes must be strnlen-pre-bound before reaching here.
    debug_assert!(unsafe { strnlen(s, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
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

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strrchr(s: *const u8, c: i32) -> *mut u8 {
    // Trust boundary (rust/c-abi.md): s NUL-terminated by the caller;
    // device/EL0 bytes must be strnlen-pre-bound before reaching here.
    debug_assert!(unsafe { strnlen(s, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
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

#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strcasecmp(a: *const u8, b: *const u8) -> i32 {
    // Trust boundary (rust/c-abi.md): both inputs NUL-terminated by the
    // caller; device/EL0 bytes must be strnlen-pre-bound before reaching here.
    debug_assert!(unsafe { strnlen(a, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
    debug_assert!(unsafe { strnlen(b, CSTR_DEBUG_CAP) } < CSTR_DEBUG_CAP);
    let mut pa = a;
    let mut pb = b;
    loop {
        let ca = unsafe { ptr::read(pa) };
        let cb = unsafe { ptr::read(pb) };
        if ca == 0 && cb == 0 {
            return 0;
        }
        // tolower-ish: |0x20 but only for A-Z; preserve C bug parity
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
        // C original has odd condition with ((a|b) >= 'A' && <= 'Z') ; we simplify but keep behavior
        if ca == 0 || cb == 0 {
            return ca as i32 - cb as i32;
        }
        unsafe {
            pa = pa.add(1);
            pb = pb.add(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // SAFETY on every call below: all pointers come from live stack buffers
    // sized for the access; contracts from rust/c-abi.md hold.

    #[test]
    fn memcpy_round_trip_returns_dst() {
        let src = [1u8, 2, 3, 4, 5, 6, 7, 8];
        let mut dst = [0u8; 8];
        let r = unsafe { memcpy(dst.as_mut_ptr(), src.as_ptr(), 8) };
        assert_eq!(r, dst.as_mut_ptr());
        assert_eq!(dst, src);
    }

    #[test]
    fn memcpy_zero_len_leaves_dst() {
        let src = [9u8; 4];
        let mut dst = [0u8; 4];
        unsafe { memcpy(dst.as_mut_ptr(), src.as_ptr(), 0) };
        assert_eq!(dst, [0u8; 4]);
    }

    #[test]
    fn memmove_overlapping_forward() {
        let mut buf = [1u8, 2, 3, 4, 5, 6, 7, 8];
        unsafe {
            let p = buf.as_mut_ptr();
            memmove(p, p.add(2), 4);
        }
        assert_eq!(buf, [3, 4, 5, 6, 5, 6, 7, 8]);
    }

    #[test]
    fn memmove_overlapping_backward() {
        let mut buf = [1u8, 2, 3, 4, 5, 6, 7, 8];
        unsafe {
            let p = buf.as_mut_ptr();
            memmove(p.add(2), p, 4);
        }
        assert_eq!(buf, [1, 2, 1, 2, 3, 4, 7, 8]);
    }

    #[test]
    fn memset_fills_and_returns_dst() {
        let mut dst = [0u8; 8];
        let r = unsafe { memset(dst.as_mut_ptr(), 0xAB, 8) };
        assert_eq!(r, dst.as_mut_ptr());
        assert_eq!(dst, [0xABu8; 8]);
    }

    #[test]
    fn memcmp_equal_prefix_and_sign() {
        let a = *b"abcdef\0\0";
        let b = *b"abcdeg\0\0";
        assert_eq!(unsafe { memcmp(a.as_ptr(), a.as_ptr(), 8) }, 0);
        assert!(unsafe { memcmp(a.as_ptr(), b.as_ptr(), 8) } < 0);
        assert!(unsafe { memcmp(b.as_ptr(), a.as_ptr(), 8) } > 0);
        assert_eq!(unsafe { memcmp(a.as_ptr(), b.as_ptr(), 5) }, 0);
    }

    #[test]
    fn memchr_found_and_missed() {
        let s = *b"hello world\0\0\0\0";
        let hit = unsafe { memchr(s.as_ptr(), b'w' as i32, 11) };
        assert_eq!(hit, unsafe { s.as_ptr().add(6) } as *mut u8);
        assert!(unsafe { memchr(s.as_ptr(), b'z' as i32, 11) }.is_null());
    }

    #[test]
    fn strlen_and_strnlen() {
        let s = b"hello\0";
        assert_eq!(unsafe { strlen(s.as_ptr()) }, 5);
        assert_eq!(unsafe { strnlen(s.as_ptr(), 3) }, 3);
        assert_eq!(unsafe { strnlen(s.as_ptr(), 99) }, 5);
    }

    #[test]
    fn strcmp_orders_and_equals() {
        let a = b"abc\0";
        let b = b"abd\0";
        assert_eq!(unsafe { strcmp(a.as_ptr(), a.as_ptr()) }, 0);
        assert!(unsafe { strcmp(a.as_ptr(), b.as_ptr()) } < 0);
        assert!(unsafe { strcmp(b.as_ptr(), a.as_ptr()) } > 0);
        assert_eq!(unsafe { strncmp(a.as_ptr(), b.as_ptr(), 2) }, 0);
        assert!(unsafe { strncmp(a.as_ptr(), b.as_ptr(), 3) } < 0);
    }

    #[test]
    fn strcpy_copies_nul() {
        let mut dst = [0xFFu8; 8];
        let src = b"hi\0";
        let r = unsafe { strcpy(dst.as_mut_ptr(), src.as_ptr()) };
        assert_eq!(r, dst.as_mut_ptr());
        assert_eq!(&dst[..4], b"hi\0\xFF");
    }

    #[test]
    fn strncpy_pads_short_src() {
        let mut dst = [0xFFu8; 8];
        let src = b"hi\0";
        unsafe { strncpy(dst.as_mut_ptr(), src.as_ptr(), 6) };
        assert_eq!(&dst[..7], b"hi\0\0\0\0\xFF");
    }

    #[test]
    fn strncpy_truncates_without_nul() {
        let mut dst = [0u8; 4];
        let src = b"abcdef\0";
        unsafe { strncpy(dst.as_mut_ptr(), src.as_ptr(), 4) };
        assert_eq!(dst, *b"abcd");
    }

    #[test]
    fn strcat_appends() {
        let mut dst = [0u8; 12];
        unsafe {
            strcpy(dst.as_mut_ptr(), b"foo\0".as_ptr());
            strcat(dst.as_mut_ptr(), b"bar\0".as_ptr());
        }
        assert_eq!(&dst[..7], b"foobar\0");
    }

    #[test]
    fn strchr_and_strrchr() {
        let s = b"abca\0";
        let first = unsafe { strchr(s.as_ptr(), b'a' as i32) };
        let last = unsafe { strrchr(s.as_ptr(), b'a' as i32) };
        assert_eq!(first, s.as_ptr() as *mut u8);
        assert_eq!(last, unsafe { s.as_ptr().add(3) } as *mut u8);
        assert!(unsafe { strchr(s.as_ptr(), b'z' as i32) }.is_null());
        assert!(unsafe { strrchr(s.as_ptr(), b'z' as i32) }.is_null());
    }

    #[test]
    fn strcasecmp_folds_ascii() {
        let a = b"Hello\0";
        let b = b"hELLO\0";
        let c = b"help\0";
        assert_eq!(unsafe { strcasecmp(a.as_ptr(), b.as_ptr()) }, 0);
        assert!(unsafe { strcasecmp(a.as_ptr(), c.as_ptr()) } < 0);
    }
}
