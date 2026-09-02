//! Buddy allocator — `buddy.c` transliteration (intrusive free-list+bump).
//!
//! Over `__heap_base+64M .. house_boot_stack_top-16*16K` whole RAM window.

use crate::spinlock::RawSpinLock;

const PAGE_SIZE: usize = 4096;

#[repr(C)]
struct FreeBlock {
    next: *mut FreeBlock,
}

static mut BUDDY_START: u64 = 0;
static mut BUDDY_END: u64 = 0;
static mut BUDDY_CUR: u64 = 0;
static LOCK: RawSpinLock = RawSpinLock::new();
static mut TOTAL_PAGES: i32 = 0;
static mut FREE_PAGES: i32 = 0;
static mut FREE_HEAD: *mut FreeBlock = core::ptr::null_mut();

/// void buddy_init(uint64_t start, uint64_t end)
#[no_mangle]
pub unsafe extern "C" fn buddy_init(start: u64, end: u64) {
    let mut s = start;
    let mut e = end;
    // Align start up, end down to 4K — checked_add handled via wrapping then mask.
    // SAFETY: arithmetic on u64 is wrapping-free; alignment math uses checked_add for SOTA 06.
    s = (s.checked_add(4095).unwrap_or(u64::MAX)) & !4095u64;
    e &= !4095u64;
    if e <= s {
        return;
    }
    LOCK.lock();
    // SAFETY: BUDDY_START/END protected by LOCK; re-init guard.
    unsafe {
        if BUDDY_START != 0 && BUDDY_END != 0 {
            LOCK.unlock();
            return;
        }
        BUDDY_START = s;
        BUDDY_END = e;
        BUDDY_CUR = s;
        // pages = (e - s) >>12 ; e>s checked above.
        let pages = ((e - s) >> 12) as i32;
        TOTAL_PAGES = pages;
        FREE_PAGES = pages;
        FREE_HEAD = core::ptr::null_mut();
    }
    LOCK.unlock();
}

/// void *buddy_alloc_page(void)
#[no_mangle]
pub unsafe extern "C" fn buddy_alloc_page() -> *mut u8 {
    let mut p: *mut u8 = core::ptr::null_mut();
    LOCK.lock();
    // SAFETY: FREE_HEAD/CUR protected by LOCK.
    unsafe {
        if !FREE_HEAD.is_null() {
            let hb = FREE_HEAD;
            p = hb as *mut u8;
            FREE_HEAD = (*hb).next;
            if FREE_PAGES > 0 {
                FREE_PAGES -= 1;
            }
        } else if BUDDY_CUR.checked_add(PAGE_SIZE as u64).unwrap_or(u64::MAX) <= BUDDY_END {
            p = BUDDY_CUR as *mut u8;
            BUDDY_CUR += PAGE_SIZE as u64;
            if FREE_PAGES > 0 {
                FREE_PAGES -= 1;
            }
        }
    }
    LOCK.unlock();
    if !p.is_null() {
        // SAFETY: p is 4K page from buddy region, valid for writes, 8-byte aligned.
        // Manual zero-fill to avoid `write_bytes` precondition panic (core checks).
        unsafe {
            let p64 = p as *mut u64;
            for off in 0..(PAGE_SIZE / 8) {
                *p64.wrapping_add(off) = 0;
            }
        }
    }
    p
}

/// void buddy_free_page(void *p)
#[no_mangle]
pub unsafe extern "C" fn buddy_free_page(p: *mut u8) {
    if p.is_null() {
        return;
    }
    let v = p as usize as u64;
    // SAFETY: reads of BUDDY_START/END are racy but start/end stable after init; copy locally.
    let (s, e) = unsafe { (BUDDY_START, BUDDY_END) };
    if v < s || v >= e {
        return;
    }
    if (v & 4095) != 0 {
        return;
    }
    LOCK.lock();
    // SAFETY: FREE_HEAD protected by LOCK.
    unsafe {
        let fb = p as *mut FreeBlock;
        (*fb).next = FREE_HEAD;
        FREE_HEAD = fb;
        if FREE_PAGES < TOTAL_PAGES {
            FREE_PAGES += 1;
        }
    }
    LOCK.unlock();
}

/// int buddy_free_count(void)
#[no_mangle]
pub unsafe extern "C" fn buddy_free_count() -> i32 {
    // SAFETY: reading FREE_PAGES is racy but single word; no lock needed for count query (C does same).
    unsafe { FREE_PAGES }
}

/// int buddy_total_count(void)
#[no_mangle]
pub unsafe extern "C" fn buddy_total_count() -> i32 {
    unsafe { TOTAL_PAGES }
}

/// void house_mem_stats(uint64_t *total, uint64_t *free_pages_out)
#[no_mangle]
pub unsafe extern "C" fn house_mem_stats(total: *mut u64, free_out: *mut u64) {
    let (tp, fp): (i32, i32);
    LOCK.lock();
    unsafe {
        tp = TOTAL_PAGES;
        fp = FREE_PAGES;
    }
    LOCK.unlock();
    // SAFETY: caller guarantees total/free_out are valid or null.
    unsafe {
        if !total.is_null() {
            *total = tp as u64;
        }
        if !free_out.is_null() {
            *free_out = fp as u64;
        }
    }
}

/// int buddy_contains(void *p)
#[no_mangle]
pub unsafe extern "C" fn buddy_contains(p: *mut u8) -> i32 {
    if p.is_null() {
        return 0;
    }
    let v = p as usize as u64;
    if (v & 4095) != 0 {
        return 0;
    }
    let (s, e) = unsafe { (BUDDY_START, BUDDY_END) };
    if v >= s && v < e {
        1
    } else {
        0
    }
}
