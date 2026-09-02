#![allow(clippy::all)]
//! mem.rs — tinylibc/mem.c transliteration (167 SLoC).

use core::ptr;

// 8-byte fast path mirrors C: while n>=8 && aligned d && aligned s, copy 8.

// SAFETY: caller guarantees dst and src valid for n bytes, n <= isize::MAX,
// dst/src not overlapping for memcpy (for memmove overlap direction is handled).
#[no_mangle]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memcpy(dst: *mut u8, src: *const u8, n: usize) -> *mut u8 {
    // Fast 8-byte unaligned copy when n>=8, then byte tail. Avoids alignment check that
    // previously generated ldrb/and sequence and avoids recursive lowering via copy_nonoverlapping.
    let mut d = dst;
    let mut s = src;
    let mut remaining = n;
    while remaining >= 8 {
        unsafe {
            ptr::write_unaligned(d as *mut u64, ptr::read_unaligned(s as *const u64));
            d = d.add(8);
            s = s.add(8);
        }
        remaining -= 8;
    }
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

#[no_mangle]
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

#[no_mangle]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn memset(dst: *mut u8, c: i32, n: usize) -> *mut u8 {
    let val = c as u8;
    let word = (val as u64) * 0x0101010101010101u64;
    let mut d = dst;
    let mut remaining = n;
    while remaining >= 8 {
        unsafe {
            ptr::write_unaligned(d as *mut u64, word);
            d = d.add(8);
        }
        remaining -= 8;
    }
    while remaining > 0 {
        unsafe {
            ptr::write(d, val);
            d = d.add(1);
        }
        remaining -= 1;
    }
    dst
}

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
pub unsafe extern "C" fn strlen(s: *const u8) -> usize {
    let mut p = s;
    // SAFETY: s is NUL-terminated per C contract.
    unsafe {
        while ptr::read(p) != 0 {
            p = p.add(1);
        }
        p.offset_from(s) as usize
    }
}

#[no_mangle]
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

#[no_mangle]
pub unsafe extern "C" fn strcmp(a: *const u8, b: *const u8) -> i32 {
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
pub unsafe extern "C" fn strcat(dst: *mut u8, src: *const u8) -> *mut u8 {
    // dst + strlen(dst)
    let len = strlen(dst);
    strcpy(dst.add(len), src);
    dst
}

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
pub unsafe extern "C" fn strcasecmp(a: *const u8, b: *const u8) -> i32 {
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
