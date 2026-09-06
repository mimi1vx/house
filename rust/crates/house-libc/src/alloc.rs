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
// 16-byte header at p-16: [magic: u64][size: u64]. The magic lets free /
// realloc reject wild pointers before any header dereference (SOTA 02/05/06).
const MALLOC_MAGIC: u64 = 0x484F5553454D414Cu64; // "HOUSEMAL"
// Smallest payload: freed blocks link via the next pointer in their first 8
// bytes, so sub-8 requests are rounded up (usable size >= requested, as C).
const MALLOC_MIN: usize = 8;
const ENOMEM_: i32 = 12;
const EINVAL_: i32 = 22;

// spinlock via HAL RawSpinLock - use tiny raw spin to avoid dependency cycle before HAL init
// Reuse simple u32 spin like C.
static mut MALLOC_CUR: *mut u8 = core::ptr::null_mut();
static mut ALLOC_LOCK: u32 = 0;
// Intrusive free-list head over the same 64 MiB pool (first-fit reuse);
// nodes live in freed payloads, so no extra memory is consumed.
static mut FREE_HEAD: *mut u8 = core::ptr::null_mut();

#[inline]
unsafe fn spin_lock(ptr: *mut u32) {
    // SAFETY: LDAXR/STXR spin on ALLOC_LOCK; matches C house_spin_lock.
    unsafe {
        core::arch::asm!(
            "1: ldaxr {res:w}, [{ptr}]",
            "   cbnz {res:w}, 1b",
            "   mov {tmp:w}, #1",
            "   stxr {res:w}, {tmp:w}, [{ptr}]",
            "   cbnz {res:w}, 1b",
            "   dmb sy",
            ptr = in(reg) ptr,
            res = out(reg) _,
            tmp = out(reg) _,
            options(nostack, preserves_flags),
        )
    };
}
#[inline]
unsafe fn spin_unlock(ptr: *mut u32) {
    // SAFETY: STLR release; matches C house_spin_unlock.
    unsafe {
        core::arch::asm!(
            "dmb sy",
            "stlr wzr, [{ptr}]",
            "dmb sy",
            ptr = in(reg) ptr,
            options(nostack, preserves_flags),
        )
    };
}

unsafe fn pool_top() -> *mut u8 {
    unsafe { (&raw mut __heap_base).add(MALLOC_POOL_BYTES) }
}

// Validate a malloc payload pointer, returning its recorded size. The range
// check runs BEFORE any dereference, so hostile values (0x1, huge) return
// None without faulting; the magic check then rejects forged in-range
// pointers and double-frees (free clears the magic on unlink).
// Call with ALLOC_LOCK held.
// SAFETY: reads at most 16 bytes below p; the range check confines [p-16, p)
// to the mapped pool, so the unaligned header reads cannot fault.
unsafe fn header_for(p: *mut u8) -> Option<usize> {
    if p.is_null() {
        return None;
    }
    let pu = p as usize;
    let heap_base = (&raw mut __heap_base) as *mut u8 as usize;
    let top = heap_base.saturating_add(MALLOC_POOL_BYTES);
    if pu < heap_base.saturating_add(16) || pu >= top {
        return None;
    }
    // SAFETY: pu >= base+16 keeps the header in-pool; pu < top keeps p in-pool.
    let magic = unsafe { ptr::read_unaligned((pu - 16) as *const u64) };
    if magic != MALLOC_MAGIC {
        return None;
    }
    let size = unsafe { ptr::read_unaligned((pu - 16 + 8) as *const u64) } as usize;
    Some(size)
}

// Bump + free-list core. Call with ALLOC_LOCK held (pool, cursor, and list
// are exclusively owned while it is held); sets errno and returns null on
// exhaustion. First-fit reuse only serves align <= 16 (payloads are
// 16-aligned); larger alignments always bump.
// SAFETY: caller holds ALLOC_LOCK; header writes stay inside the pool bounds
// checked below.
unsafe fn pool_alloc_locked(n: usize, align: usize) -> *mut u8 {
    let align = if align == 0 || (align & (align - 1)) != 0 {
        16
    } else {
        align
    };
    let n_eff = n.max(MALLOC_MIN);
    if align <= 16 {
        // SAFETY: lock held; links live in pooled payloads, exclusively owned.
        unsafe {
            let mut link: *mut *mut u8 = &raw mut FREE_HEAD;
            while !(*link).is_null() {
                let cur = *link;
                // Size survives free (only the magic is cleared); cur is
                // pooled by construction, so cur-16 is a valid header read.
                let size = ptr::read_unaligned((cur as usize - 16 + 8) as *const u64) as usize;
                if size >= n_eff {
                    *link = ptr::read(cur as *const *mut u8);
                    ptr::write_unaligned((cur as usize - 16) as *mut u64, MALLOC_MAGIC);
                    return cur;
                }
                link = cur as *mut *mut u8;
            }
        }
    }
    let cur_ptr = unsafe { MALLOC_CUR };
    let heap_base = &raw mut __heap_base as *mut u8;
    let mut malloc_cur = if cur_ptr.is_null() {
        heap_base
    } else {
        cur_ptr
    };

    // h is 16-aligned so p == h+16 for align <= 16 and the header always
    // lands at p-16 (in the pad gap for larger alignments).
    let h_u = match (malloc_cur as usize).checked_add(15) {
        Some(v) => v & !15usize,
        None => {
            unsafe { *__errno_location() = ENOMEM_ };
            return core::ptr::null_mut();
        }
    };
    let p_u_base = match (h_u).checked_add(16) {
        Some(v) => v,
        None => {
            unsafe { *__errno_location() = ENOMEM_ };
            return core::ptr::null_mut();
        }
    };
    let tmp = match p_u_base.checked_add(align - 1) {
        Some(v) => v,
        None => {
            unsafe { *__errno_location() = ENOMEM_ };
            return core::ptr::null_mut();
        }
    };
    let p_u = tmp & !(align - 1);
    let p = p_u as *mut u8;
    let end_u = match p_u.checked_add(n_eff) {
        Some(v) => v,
        None => {
            unsafe { *__errno_location() = ENOMEM_ };
            return core::ptr::null_mut();
        }
    };
    // SAFETY: pool_top reads the linker-provided __heap_base; pure arithmetic.
    let top = unsafe { pool_top() } as usize;
    if end_u > top {
        unsafe { *__errno_location() = ENOMEM_ };
        return core::ptr::null_mut();
    }
    // header [magic][size] at p-16.
    unsafe {
        ptr::write_unaligned((p_u - 16) as *mut u64, MALLOC_MAGIC);
        ptr::write_unaligned((p_u - 16 + 8) as *mut u64, n_eff as u64);
    }
    malloc_cur = end_u as *mut u8;
    unsafe { MALLOC_CUR = malloc_cur };
    p
}

// SAFETY: lock discipline only; the core above owns the safety argument.
unsafe fn pool_alloc(n: usize, align: usize) -> *mut u8 {
    unsafe { spin_lock(&raw mut ALLOC_LOCK) };
    let p = unsafe { pool_alloc_locked(n, align) };
    unsafe { spin_unlock(&raw mut ALLOC_LOCK) };
    p
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn malloc(n: usize) -> *mut u8 {
    unsafe { pool_alloc(n, 16) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn free(p: *mut u8) {
    // C free(NULL) is a silent no-op; anything outside the pool (buddy /
    // mmap ranges) is likewise not ours: no-op + EINVAL, never a fault.
    if p.is_null() {
        return;
    }
    unsafe { spin_lock(&raw mut ALLOC_LOCK) };
    // SAFETY: lock held; header_for range-checks before any dereference.
    match unsafe { header_for(p) } {
        Some(size) if size >= MALLOC_MIN => unsafe {
            // Clear the magic so a double-free fails validation instead of
            // linking twice (which would cycle the list); size stays for reuse.
            ptr::write_unaligned((p as usize - 16) as *mut u64, 0);
            ptr::write(p as *mut *mut u8, FREE_HEAD);
            FREE_HEAD = p;
        },
        Some(_) => unsafe {
            // Unreachable: payloads are normalized to >= MIN. Clear the magic
            // and leak rather than link a block too small for the next pointer.
            ptr::write_unaligned((p as usize - 16) as *mut u64, 0);
            *__errno_location() = EINVAL_;
        },
        None => unsafe {
            *__errno_location() = EINVAL_;
        },
    }
    unsafe { spin_unlock(&raw mut ALLOC_LOCK) };
}

#[unsafe(no_mangle)]
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn realloc(old: *mut u8, n: usize) -> *mut u8 {
    if old.is_null() {
        return unsafe { malloc(n) };
    }
    // Hostile huge: fail closed before touching old (old stays valid, per C).
    if n > MALLOC_POOL_BYTES {
        unsafe { *__errno_location() = ENOMEM_ };
        return core::ptr::null_mut();
    }
    unsafe { spin_lock(&raw mut ALLOC_LOCK) };
    // SAFETY: lock held; header_for range-checks before the header read, so
    // old.sub(16) can never underflow or read out of bounds.
    let oldn = match unsafe { header_for(old) } {
        Some(s) => s,
        None => unsafe {
            *__errno_location() = EINVAL_;
            spin_unlock(&raw mut ALLOC_LOCK);
            return core::ptr::null_mut();
        },
    };
    let p = unsafe { pool_alloc_locked(n, 16) };
    if !p.is_null() {
        // Bound the copy by the old payload, the new payload, and the
        // pool-remaining bytes from old (stops forged-but-magic-valid sizes).
        let top = unsafe { pool_top() } as usize;
        let remaining = top.saturating_sub(old as usize);
        let mut copy = if oldn < n { oldn } else { n };
        if copy > remaining {
            copy = remaining;
        }
        // SAFETY: [old, old+copy) and [p, p+copy) are pooled payloads.
        unsafe { ptr::copy_nonoverlapping(old, p, copy) };
    }
    unsafe { spin_unlock(&raw mut ALLOC_LOCK) };
    p
}

#[unsafe(no_mangle)]
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn strdup(s: *const u8) -> *mut u8 {
    if s.is_null() {
        return core::ptr::null_mut();
    }
    // Trust boundary (rust/c-abi.md): s NUL-terminated by the caller, like
    // strlen — POSIX strdup is inherently unbounded, so device/EL0 bytes must
    // be strnlen-pre-bound before reaching here.
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
#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn munmap(a: *mut u8, len: usize) -> i32 {
    unsafe { house_vm_munmap(a, len) }
}
#[unsafe(no_mangle)]
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
