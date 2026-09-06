//! Buddy allocator — `buddy.c` transliteration (intrusive free-list+bump).
//!
//! Over `__heap_base+64M .. stack_top-N*64K` (N = detected cores).

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
// 64-bit counters (6G ≈ 1.5M pages; TCR window far beyond i32 only at TB
// scale). The `buddy_*_count` C ABI stays i32: saturated compat shims.
static mut TOTAL_PAGES: u64 = 0;
static mut FREE_PAGES: u64 = 0;
static mut FREE_HEAD: *mut FreeBlock = core::ptr::null_mut();

/// void buddy_init(uint64_t start, uint64_t end)
#[unsafe(no_mangle)]
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
        let pages = (e - s) >> 12;
        TOTAL_PAGES = pages;
        FREE_PAGES = pages;
        FREE_HEAD = core::ptr::null_mut();
    }
    LOCK.unlock();
}

/// void *buddy_alloc_page(void)
#[unsafe(no_mangle)]
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
#[unsafe(no_mangle)]
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

/// int buddy_free_count(void) — compat shim, saturates at INT_MAX.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn buddy_free_count() -> i32 {
    // SAFETY: reading FREE_PAGES is racy but single word; no lock needed for count query (C does same).
    unsafe { FREE_PAGES.min(i32::MAX as u64) as i32 }
}

/// int buddy_total_count(void) — compat shim, saturates at INT_MAX.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn buddy_total_count() -> i32 {
    unsafe { TOTAL_PAGES.min(i32::MAX as u64) as i32 }
}

/// void house_mem_stats(uint64_t *total, uint64_t *free_pages_out)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_mem_stats(total: *mut u64, free_out: *mut u64) {
    let (tp, fp): (u64, u64);
    LOCK.lock();
    unsafe {
        tp = TOTAL_PAGES;
        fp = FREE_PAGES;
    }
    LOCK.unlock();
    // SAFETY: caller guarantees total/free_out are valid or null.
    unsafe {
        if !total.is_null() {
            *total = tp;
        }
        if !free_out.is_null() {
            *free_out = fp;
        }
    }
}

/// int buddy_contains(void *p)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn buddy_contains(p: *mut u8) -> i32 {
    if p.is_null() {
        return 0;
    }
    let v = p as usize as u64;
    if (v & 4095) != 0 {
        return 0;
    }
    let (s, e) = unsafe { (BUDDY_START, BUDDY_END) };
    if v >= s && v < e { 1 } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 16-page Miri-owned backing store: buddy_init aligns start up / end
    // down to 4K, so the usable count is derived in-test, never assumed.
    // Single lifecycle test: the allocator globals are process-wide, so
    // parallel tests would race (Miri flags data races); one ordered
    // sequence keeps the state machine deterministic.
    static mut BACKING: [u8; 65536] = [0xA5; 65536];

    #[test]
    fn buddy_page_lifecycle() {
        let (start, end) = unsafe {
            let base = BACKING.as_mut_ptr() as u64;
            buddy_init(base, base + 65536);
            let s = (base.checked_add(4095).unwrap_or(u64::MAX)) & !4095u64;
            let e = (base + 65536) & !4095u64;
            (s, e)
        };
        let pages = ((end - start) >> 12) as i32;
        assert!(pages >= 14);
        // SAFETY: init ran once above; queries read stable counters.
        unsafe {
            assert_eq!(buddy_total_count(), pages);
            assert_eq!(buddy_free_count(), pages);

            // Alloc: distinct, 4K-aligned, zero-filled pages.
            let p0 = buddy_alloc_page();
            let p1 = buddy_alloc_page();
            assert!(!p0.is_null() && !p1.is_null());
            assert_ne!(p0, p1);
            assert_eq!(p0 as usize & 4095, 0);
            assert_eq!(p1 as usize & 4095, 0);
            assert_eq!(buddy_free_count(), pages - 2);
            for i in 0..4096 {
                assert_eq!(*p0.add(i), 0);
            }
            assert_eq!(buddy_contains(p0), 1);
            assert_eq!(buddy_contains(core::ptr::null_mut()), 0);
            assert_eq!(buddy_contains(p0.wrapping_add(1)), 0);

            // Free returns the page to the head (LIFO reuse).
            buddy_free_page(p0);
            assert_eq!(buddy_free_count(), pages - 1);
            let p2 = buddy_alloc_page();
            assert_eq!(p2, p0);
            assert_eq!(buddy_free_count(), pages - 2);

            // Out-of-range, misaligned, and null frees are ignored.
            buddy_free_page(core::ptr::null_mut());
            buddy_free_page(0x1000 as *mut u8);
            buddy_free_page(p1.wrapping_add(7));
            assert_eq!(buddy_free_count(), pages - 2);

            // Drain: exactly the remaining pages, then null.
            let mut got = 0;
            loop {
                let p = buddy_alloc_page();
                if p.is_null() {
                    break;
                }
                got += 1;
            }
            assert_eq!(got, pages - 2);
            assert_eq!(buddy_free_count(), 0);
            assert!(buddy_alloc_page().is_null());

            // Stats with null outputs must not fault.
            let mut total = 0u64;
            let mut free = 0u64;
            house_mem_stats(&mut total, &mut free);
            assert_eq!(total as i32, pages);
            assert_eq!(free, 0);
            house_mem_stats(core::ptr::null_mut(), core::ptr::null_mut());

            // Return the two held pages; free-list head count recovers.
            buddy_free_page(p1);
            buddy_free_page(p2);
            assert_eq!(buddy_free_count(), 2);
        }
    }
}
