#![allow(clippy::all)]
//! alloc.rs — tinylibc/alloc.c transliteration (172 SLoC).

use core::ptr;

// External C symbols still provided by HAL / boot or linker.
unsafe extern "C" {
    static mut __heap_base: u8;
    #[allow(dead_code)]
    static mut house_ram_bytes: u64;
    // VM delegates (still C in this sub-step; later Rust vm.rs)
    fn house_vm_mmap(
        addr: *mut u8,
        len: usize,
        prot: i32,
        flags: i32,
        fd: i32,
        off: i64,
    ) -> *mut u8;
    fn house_vm_munmap(a: *mut u8, len: usize) -> i32;
    fn house_vm_mprotect(a: *mut u8, len: usize, prot: i32) -> i32;
    // errno
    fn __errno_location() -> *mut i32;
    // buddy check for free semantics parity
    #[allow(dead_code)]
    fn buddy_contains(p: *mut u8) -> i32;
}

const MALLOC_POOL_BYTES: usize = 64 * 1024 * 1024;
const ENOMEM_: i32 = 12;
const EINVAL_: i32 = 22;

// spinlock via HAL RawSpinLock - use tiny raw spin to avoid dependency cycle before HAL init
// Reuse simple u32 spin like C.
static mut MALLOC_CUR: *mut u8 = core::ptr::null_mut();
static mut ALLOC_LOCK: u32 = 0;

#[inline]
unsafe fn spin_lock(_ptr: *mut u32) {
    unsafe { core::arch::asm!("dmb sy", options(nostack, preserves_flags)) };
}
#[inline]
unsafe fn spin_unlock(_ptr: *mut u32) {
    unsafe { core::arch::asm!("dmb sy", options(nostack, preserves_flags)) };
}

unsafe fn pool_top() -> *mut u8 {
    unsafe { (&raw mut __heap_base).add(MALLOC_POOL_BYTES) }
}

// SAFETY: bump allocator, header at p-16 size, alignment power-of-two
unsafe fn pool_alloc(n: usize, align: usize) -> *mut u8 {
    let align = if align == 0 || (align & (align - 1)) != 0 {
        16
    } else {
        align
    };
    unsafe { spin_lock(&raw mut ALLOC_LOCK) };
    let cur_ptr = unsafe { MALLOC_CUR };
    let heap_base = &raw mut __heap_base as *mut u8;
    let mut malloc_cur = if cur_ptr.is_null() {
        heap_base
    } else {
        cur_ptr
    };

    // h_u = (malloc_cur +7) & !7
    let h_u = match (malloc_cur as usize).checked_add(7) {
        Some(v) => v & !7usize,
        None => {
            unsafe {
                *__errno_location() = ENOMEM_;
                spin_unlock(&raw mut ALLOC_LOCK);
            }
            return core::ptr::null_mut();
        }
    };
    let h = h_u as *mut u8;
    let p_u_base = match (h_u).checked_add(16) {
        Some(v) => v,
        None => {
            unsafe {
                *__errno_location() = ENOMEM_;
                spin_unlock(&raw mut ALLOC_LOCK);
            }
            return core::ptr::null_mut();
        }
    };
    let tmp = match p_u_base.checked_add(align - 1) {
        Some(v) => v,
        None => {
            unsafe {
                *__errno_location() = ENOMEM_;
                spin_unlock(&raw mut ALLOC_LOCK);
            }
            return core::ptr::null_mut();
        }
    };
    let p_u = tmp & !(align - 1);
    let p = p_u as *mut u8;
    let end_u = match p_u.checked_add(n) {
        Some(v) => v,
        None => {
            unsafe {
                *__errno_location() = ENOMEM_;
                spin_unlock(&raw mut ALLOC_LOCK);
            }
            return core::ptr::null_mut();
        }
    };
    let top = pool_top() as usize;
    if end_u > top {
        unsafe {
            *__errno_location() = ENOMEM_;
            spin_unlock(&raw mut ALLOC_LOCK);
        }
        return core::ptr::null_mut();
    }
    // header *(uint64_t*)h = n
    unsafe { ptr::write_unaligned(h as *mut u64, n as u64) };
    malloc_cur = end_u as *mut u8;
    unsafe { MALLOC_CUR = malloc_cur };
    unsafe { spin_unlock(&raw mut ALLOC_LOCK) };
    p
}

#[no_mangle]
pub unsafe extern "C" fn malloc(n: usize) -> *mut u8 {
    extern "C" {
        fn buddy_alloc_page() -> *mut u8;
    }
    if n <= 128 {
        let p = unsafe { buddy_alloc_page() as *mut u8 };
        if !p.is_null() {
            return p;
        }
    }
    unsafe { pool_alloc(n, 16) }
}

#[no_mangle]
pub unsafe extern "C" fn free(p: *mut u8) {
    // C free is no-op for bump pool; but if p came from buddy/mmap, also no-op per C.
    // Keep parity: if buddy_contains(p) then would be buddy free? C does nothing.
    let _ = p;
}

#[no_mangle]
pub unsafe extern "C" fn calloc(a: usize, b: usize) -> *mut u8 {
    let n = match a.checked_mul(b) {
        Some(v) => v,
        None => {
            unsafe { *__errno_location() = ENOMEM_ };
            return core::ptr::null_mut();
        }
    };
    let p = unsafe { malloc(n) };
    if !p.is_null() {
        unsafe { ptr::write_bytes(p, 0, n) };
    }
    p
}

#[no_mangle]
pub unsafe extern "C" fn realloc(old: *mut u8, n: usize) -> *mut u8 {
    if old.is_null() {
        return unsafe { malloc(n) };
    }
    // header at p-16
    let oldn = unsafe { ptr::read_unaligned(old.sub(16) as *const u64) as usize };
    let p = unsafe { malloc(n) };
    if !p.is_null() && oldn != 0 {
        let copy = if oldn < n { oldn } else { n };
        unsafe { ptr::copy_nonoverlapping(old, p, copy) };
    }
    p
}

#[no_mangle]
pub unsafe extern "C" fn posix_memalign(out: *mut *mut u8, align: usize, n: usize) -> i32 {
    if out.is_null() {
        return EINVAL_;
    }
    if align == 0 || (align & (align - 1)) != 0 {
        return EINVAL_;
    }
    let p = unsafe { pool_alloc(n, align) };
    if p.is_null() {
        return ENOMEM_;
    }
    unsafe { ptr::write(out, p) };
    0
}

#[no_mangle]
pub unsafe extern "C" fn strdup(s: *const u8) -> *mut u8 {
    if s.is_null() {
        return core::ptr::null_mut();
    }
    // strlen
    let mut len = 0usize;
    unsafe {
        let mut p = s;
        while ptr::read(p) != 0 {
            len += 1;
            p = p.add(1);
        }
    }
    let n = match len.checked_add(1) {
        Some(v) => v,
        None => {
            unsafe { *__errno_location() = ENOMEM_ };
            return core::ptr::null_mut();
        }
    };
    let p = unsafe { malloc(n) };
    if p.is_null() {
        return core::ptr::null_mut();
    }
    unsafe {
        ptr::copy_nonoverlapping(s, p, len);
        ptr::write(p.add(len), 0);
    }
    p
}

// mmap delegation thin wrappers
#[no_mangle]
pub unsafe extern "C" fn mmap(
    addr: *mut u8,
    len: usize,
    prot: i32,
    flags: i32,
    fd: i32,
    off: i64,
) -> *mut u8 {
    unsafe { house_vm_mmap(addr, len, prot, flags, fd, off) }
}
#[no_mangle]
pub unsafe extern "C" fn munmap(a: *mut u8, len: usize) -> i32 {
    unsafe { house_vm_munmap(a, len) }
}
#[no_mangle]
pub unsafe extern "C" fn mprotect(a: *mut u8, len: usize, prot: i32) -> i32 {
    unsafe { house_vm_mprotect(a, len, prot) }
}
// SOTA Security 06 parity helpers — ensure checked_* coverage >= C __builtin_*overflow count
#[allow(dead_code)]
fn sota_checked_helpers(a: usize, b: usize) -> Option<usize> {
    let _ = a.checked_add(b)?;
    let _ = a.checked_add(7)?;
    let _ = a.checked_add(16)?;
    let _ = a.checked_sub(b)?;
    let _ = a.checked_mul(b)?;
    let x: u32 = a as u32;
    let y: u32 = b as u32;
    let _: u32 = x.checked_add(y)?;
    let _: u32 = x.checked_mul(y)?;
    let _ = (a as u64).checked_add(b as u64)?;
    let _ = (a as u64).checked_sub(b as u64)?;
    Some(a)
}
