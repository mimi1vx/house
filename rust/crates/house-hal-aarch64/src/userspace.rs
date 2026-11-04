//! Userspace EL0 ASID pager — `userspace.c` transliteration.

use crate::mm::vm::VM_LOCK;
use crate::spinlock::RawSpinLock;
use core::sync::atomic::{AtomicU32, Ordering};

const PAGE_SIZE: usize = 4096;
const PAGE_POOL_N: usize = 512;
#[repr(align(4096))]
struct PagePool([u8; PAGE_POOL_N * PAGE_SIZE]);
static mut PAGE_POOL: PagePool = PagePool([0; PAGE_POOL_N * PAGE_SIZE]);

#[unsafe(no_mangle)]
pub static mut min_user_addr: *mut u8 = core::ptr::null_mut();
#[unsafe(no_mangle)]
pub static mut max_user_addr: *mut u8 = core::ptr::null_mut();

// Trap-time identity: one recorded root per core. A single global races when
// two cores trap at once: the second core's resume/park overwrites the first
// core's table mid-validation, so the first core validates user pointers
// against the wrong tables and fails a healthy call with a spurious EFAULT.
// Every trap/IRQ-context reader runs on the trapping core, and every
// resume/enter sets the slot on the core EL0 is about to run on, so indexing
// by this core's MPIDR slot keeps each core on its own table. Host unit
// tests have no MPIDR and always use slot 0.
static mut RECORDED_PDIRS: [*mut u8; 32] = [core::ptr::null_mut(); 32];

#[cfg(test)]
#[inline]
fn recorded_idx() -> usize {
    0
}

#[cfg(not(test))]
#[inline]
fn recorded_idx() -> usize {
    let me: u64;
    // SAFETY: mrs mpidr_el1 is always readable at EL1 (trap/IRQ context only).
    unsafe {
        core::arch::asm!("mrs {0}, mpidr_el1", out(reg) me, options(nostack, preserves_flags))
    };
    core_slot(me)
}
static ASID_LOCK: RawSpinLock = RawSpinLock::new();
static mut NEXT_ASID: u16 = 1;
const ASID_MAP_CAP: usize = 64;
static mut ASID_MAP: [(*mut u8, u16); 64] = [(core::ptr::null_mut(), 0); 64];
/// Live `(pdir -> ASID)` bindings. Exported so the shell's leak check can read
/// it out of guest memory and prove a reaped process gave its slot back.
#[unsafe(no_mangle)]
pub static mut ASID_MAP_LEN: usize = 0;

unsafe extern "C" {
    static ttbr0_l0: [u64; 512];
    fn buddy_alloc_page() -> *mut u8;
    fn buddy_free_page(p: *mut u8);
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
    fn house_mmu_set_ttbr0(pdir: *mut u8, asid: u64);
}

/// Record the boot TTBR0 and init the user page-pool bounds.
///
/// # Safety
///
/// Call once at EL1 during early boot on a single core.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_userspace_init() {
    unsafe {
        if RECORDED_PDIRS[recorded_idx()].is_null() {
            RECORDED_PDIRS[recorded_idx()] = ttbr0_l0.as_ptr() as *mut u8;
        }
        if min_user_addr.is_null() {
            min_user_addr = PAGE_POOL.0.as_mut_ptr();
            max_user_addr = PAGE_POOL.0.as_mut_ptr().add(PAGE_POOL_N * PAGE_SIZE);
        }
    }
}

unsafe fn asid_for_pdir(pdir: *mut u8) -> u16 {
    unsafe {
        ASID_LOCK.lock();
        for i in 0..ASID_MAP_LEN {
            if ASID_MAP[i].0 == pdir {
                let a = ASID_MAP[i].1;
                ASID_LOCK.unlock();
                return a;
            }
        }
        let mut a = NEXT_ASID;
        NEXT_ASID = NEXT_ASID.wrapping_add(1);
        let mut wrapped = false;
        if NEXT_ASID == 0 || NEXT_ASID > 250 {
            NEXT_ASID = 1;
            wrapped = true;
        }
        if a == 0 {
            a = NEXT_ASID;
            NEXT_ASID = NEXT_ASID.wrapping_add(1);
            if NEXT_ASID > 250 {
                NEXT_ASID = 1;
                wrapped = true;
            }
        }
        if ASID_MAP_LEN == ASID_MAP_CAP {
            // Every live root already holds a slot, so none may keep its ASID
            // while the map is rebuilt. A rebuild drops every cached binding
            // without the ASID counter ever wrapping, so it needs the same
            // all-ASID flush the wrap does: otherwise a still-running process
            // is handed a fresh ASID for the same (TTBR0, ...) pair and nothing
            // separates the two.
            ASID_MAP = [(core::ptr::null_mut(), 0); ASID_MAP_CAP];
            ASID_MAP_LEN = 0;
            wrapped = true;
        }
        ASID_MAP[ASID_MAP_LEN] = (pdir, a);
        ASID_MAP_LEN += 1;
        if wrapped {
            // SAFETY: flush all ASIDs before reuse.
            core::arch::asm!(
                "dsb ishst; tlbi vmalle1is; dsb ish; isb",
                options(nostack, preserves_flags)
            );
        }
        ASID_LOCK.unlock();
        a
    }
}

/// Make code the EL1 data path just wrote visible to the instruction side.
///
/// # Safety
///
/// `page` must be a page the caller has just filled with instructions, and
/// the caller must not execute them until this returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_flush_code_page(page: *mut u8) {
    const CACHE_LINE: usize = 64;
    if page.is_null() {
        return;
    }
    // SAFETY: the caller owns `page` and holds it mapped for the duration;
    // the cache operations touch nothing but that page's own lines.
    unsafe {
        // Clean every line to the point of unification first: the stores
        // above went through the data cache, and an instruction fetch that
        // overtakes them would see stale bytes.
        for offset in (0..PAGE_SIZE).step_by(CACHE_LINE) {
            core::arch::asm!(
                "dc cvau, {addr}",
                addr = in(reg) page.add(offset),
                options(nostack, preserves_flags)
            );
        }
        core::arch::asm!("dsb ish", options(nostack, preserves_flags));
        for offset in (0..PAGE_SIZE).step_by(CACHE_LINE) {
            core::arch::asm!(
                "ic ivau, {addr}",
                addr = in(reg) page.add(offset),
                options(nostack, preserves_flags)
            );
        }
        // The per-line `ic ivau` loop above already invalidated every line of
        // this page, so a whole-PE `ic ialluis` here would only re-do that work
        // for every inner-shareable PE, once per constructor phase.
        core::arch::asm!("dsb ish; isb", options(nostack, preserves_flags));
    }
}

/// Drop a cached `(pdir -> ASID)` binding. The allocator hands the same root
/// back to the next image, so a surviving entry would alias two processes on
/// one `(TTBR0, ASID)` pair; the flush drops every entry tagged with that pair
/// before the recycled root is populated with a different image.
///
/// Returns 1 when a binding was actually held, which is the only case that can
/// need the flush.
///
/// # Safety
///
/// The caller must be about to return `pdir` to the buddy allocator.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_asid_forget_pdir(pdir: *mut u8) -> i32 {
    if pdir.is_null() {
        return 0;
    }
    unsafe {
        if evict_asid(pdir) {
            // SAFETY: the root is recycled by the caller straight after this
            // returns, so no entry may keep the pair this pdir was tagged with.
            core::arch::asm!(
                "dsb ishst; tlbi vmalle1is; dsb ish; isb",
                options(nostack, preserves_flags)
            );
            1
        } else {
            // A root that was never cached — every pre-`house_el0_register`
            // error path — cannot need a flush, and paying for one would hide
            // the reason the eviction path has one at all.
            0
        }
    }
}

/// Release a page directory the loader is finished with, and report whether
/// the hardware was still running on it.
///
/// The answer comes from `TTBR0_EL1`, not from the software record:
/// `svc_exit_trampoline` restores the kernel root before the session returns,
/// so by the time any caller reaches this the live root is the kernel L0 and
/// the record is only a leftover. Putting the kernel root back in the record
/// also stops the same stale answer from re-arming on the next reap, which is
/// what made the most recently entered process leak its tables and its ASID
/// entry.
///
/// Returns 1 when `TTBR0_EL1` still names `pdir`, i.e. an EL0 session is live
/// on it and the caller must not free the pages under it.
///
/// # Safety
///
/// The caller must have ended every EL0 session on `pdir` and must return
/// `pdir` to the buddy allocator immediately after this returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_release_pdir(pdir: *mut u8) -> i32 {
    if pdir.is_null() {
        return 1;
    }
    unsafe {
        // SAFETY: mrs ttbr0_el1 is always readable at EL1.
        let ttbr0: u64;
        core::arch::asm!("mrs {0}, ttbr0_el1", out(reg) ttbr0, options(nostack, preserves_flags));
        let live = ((ttbr0 & 0x0000_FFFF_FFFF_F000) as *mut u8) == pdir;
        for slot in RECORDED_PDIRS.iter_mut() {
            if *slot == pdir {
                *slot = ttbr0_l0.as_ptr() as *mut u8;
            }
        }
        // S2 (house-oz9.11): retract the fault-domain enrollment with the
        // root (single choke point — Haskell teardown needs no extra call).
        // A stale mark would refuse a recycled root; an early unmark only
        // fails closed (kill instead of page).
        crate::mm::vm::driver_unmark(pdir);
        let _ = evict_asid(pdir);
        budget_remove(pdir as u64);
        SVC_MASK_LOCK.lock();
        svc_mask_remove(pdir as u64);
        SVC_MASK_LOCK.unlock();
        // Unconditional, unlike `house_asid_forget_pdir`: this is the point of
        // no return for the root, so whatever the map held, a recycled root
        // must not inherit the old image's translations.
        core::arch::asm!(
            "dsb ishst; tlbi vmalle1is; dsb ish; isb",
            options(nostack, preserves_flags)
        );
        live as i32
    }
}

/// Remove `pdir` from the ASID cache, reporting whether it was there.
fn evict_asid(pdir: *mut u8) -> bool {
    unsafe {
        ASID_LOCK.lock();
        let mut removed = false;
        let mut i = 0;
        while i < ASID_MAP_LEN {
            if ASID_MAP[i].0 == pdir {
                let last = ASID_MAP_LEN - 1;
                ASID_MAP[i] = ASID_MAP[last];
                ASID_MAP[last] = (core::ptr::null_mut(), 0);
                ASID_MAP_LEN = last;
                removed = true;
                break;
            }
            i += 1;
        }
        ASID_LOCK.unlock();
        removed
    }
}

/// Install a page directory as this core's TTBR0 with its ASID.
///
/// # Safety
///
/// EL1 only; null or misaligned `pdir` is a no-op. `pdir` must be a live
/// root that outlives use (Haskell owns reaping).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn init_page_dir(pdir: *mut u8) {
    if pdir.is_null() || (pdir as usize & 4095) != 0 {
        return;
    }
    unsafe {
        let asid = asid_for_pdir(pdir) as u64;
        RECORDED_PDIRS[recorded_idx()] = pdir;
        house_mmu_set_ttbr0(pdir, asid);
        uart_puts(b"[userspace] init_page_dir done\n\0".as_ptr());
    }
}

#[cfg(test)]
pub(crate) unsafe fn userspace_set_recorded_for_test(pdir: *mut u8) {
    unsafe {
        house_set_recorded_pdir(pdir);
    }
}

/// This core's recorded TTBR0 root (null before init).
///
/// # Safety
///
/// Call at EL1; the returned root is valid only while registered.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn current_pdir() -> *mut u8 {
    unsafe { RECORDED_PDIRS[recorded_idx()] }
}

/// Set this core's recorded root (resume path).
///
/// # Safety
///
/// EL1 only; `pdir` must be a live root, or null to clear.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_set_recorded_pdir(pdir: *mut u8) {
    unsafe {
        RECORDED_PDIRS[recorded_idx()] = pdir;
    }
}

/// ASID binding for a page directory (0 for null).
///
/// # Safety
///
/// EL1 only; takes the ASID lock (never in trap context with it held).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_asid_for_pdir(pdir: *mut u8) -> u64 {
    if pdir.is_null() {
        return 0;
    }
    unsafe { asid_for_pdir(pdir) as u64 }
}

/// Whether the VA's descriptor is read-only in the recorded pdir.
///
/// # Safety
///
/// Call at EL1; page-table reads only, unmapped VAs report 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_is_ro_page(va: u64) -> i32 {
    let va = va & !4095;
    unsafe {
        let pdir = current_pdir();
        if pdir.is_null() || (pdir as usize & 4095) != 0 {
            return 0;
        }
        let l0 = pdir as *mut u64;
        let d0 = *l0.add(((va >> 39) & 0x1FF) as usize);
        if d0 & 1 == 0 {
            return 0;
        }
        let l1 = (d0 & !0xFFF) as *mut u64;
        let d1 = *l1.add(((va >> 30) & 0x1FF) as usize);
        if d1 & 1 == 0 {
            return 0;
        }
        // 1GB block: no deeper walk; AP applies to the whole block.
        if d1 & 2 == 0 {
            return (((d1 >> 6) & 0x3) == 0x3) as i32;
        }
        let l2 = (d1 & !0xFFF) as *mut u64;
        let d2 = *l2.add(((va >> 21) & 0x1FF) as usize);
        if d2 & 1 == 0 {
            return 0;
        }
        // 2MB block: same, AP applies to the whole block.
        if d2 & 2 == 0 {
            return (((d2 >> 6) & 0x3) == 0x3) as i32;
        }
        let l3 = (d2 & !0xFFF) as *mut u64;
        let d3 = *l3.add(((va >> 12) & 0x1FF) as usize);
        if d3 & 1 == 0 {
            return 0;
        }
        let ap = (d3 >> 6) & 0x3;
        if ap == 0x3 { 1 } else { 0 }
    }
}

/// Whether the VA names a copy-on-write page (RO plus SW mark, bit 57).
///
/// # Safety
///
/// EL1 fault context; page-table reads against the recorded pdir only.
/// Unmapped, writable, or plain-RO pages report 0; block descriptors never
/// carry COW.
// SAFETY: EL1 fault context (RO perm guard in `c_handle_sync`); page-table
// reads against the recorded pdir only, no locks. Reports whether the L3
// page descriptor carries RO permission plus the SW COW mark (bit 57, set
// by the Haskell fork-share path). Block descriptors never carry COW.
// Returns 1 COW, 0 otherwise (unmapped, writable, or plain RO).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_is_cow_page(va: u64) -> i32 {
    let va = va & !4095;
    unsafe {
        let pdir = current_pdir();
        if pdir.is_null() || (pdir as usize & 4095) != 0 {
            return 0;
        }
        let l0 = pdir as *mut u64;
        let d0 = *l0.add(((va >> 39) & 0x1FF) as usize);
        if d0 & 1 == 0 {
            return 0;
        }
        let l1 = (d0 & !0xFFF) as *mut u64;
        let d1 = *l1.add(((va >> 30) & 0x1FF) as usize);
        if d1 & 1 == 0 {
            return 0;
        }
        // 1GB block: no deeper walk; blocks never carry COW.
        if d1 & 2 == 0 {
            return 0;
        }
        let l2 = (d1 & !0xFFF) as *mut u64;
        let d2 = *l2.add(((va >> 21) & 0x1FF) as usize);
        if d2 & 1 == 0 {
            return 0;
        }
        // 2MB block: same, never COW.
        if d2 & 2 == 0 {
            return 0;
        }
        let l3 = (d2 & !0xFFF) as *mut u64;
        let d3 = *l3.add(((va >> 12) & 0x1FF) as usize);
        if d3 & 1 == 0 {
            return 0;
        }
        let ap = (d3 >> 6) & 0x3;
        if ap == 0x3 && (d3 >> 57) & 1 == 1 {
            1
        } else {
            0
        }
    }
}

/// Invalidate one page's local TLB entry.
///
/// # Safety
///
/// Call at EL1; any page VA (ASID-scoped `vae1is` plus barriers).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn invalidate_page(vaddr: u64) {
    unsafe {
        let va = vaddr >> 12;
        core::arch::asm!("tlbi vae1is, {0}; dsb ish; isb", in(reg) va, options(nostack, preserves_flags));
    }
}

// The page-table walk in `house_handle_user_fault` allocates and links levels.
// Two cores can reach it for one root, and with no lock both take the "entry
// invalid" path, both allocate, and one table is orphaned or clobbered. One
// lock, not one per pdir: a pdir page is 512 descriptors wide with no room for
// a lock word, the critical section is three page allocations and their
// zeroing, and faults are rare, so a side table keyed by root would buy no
// throughput and one more thing to keep in step with the allocator.
// Unification (house-oz9.1): the pager shares VM_LOCK (crate::mm::vm) with
// the vm.rs walks (mmap/munmap/mprotect): one domain over the recorded root.
// Outer lock; BUDGET_LOCK and the buddy LOCK are inner leaves.

// Per-pdir demand-page budget: one process cannot drain the buddy for
// everyone. Counts data pages installed by `fault_locked` per root; tables
// are uncounted overhead (a 64 GiB scan needs 16 M data pages but only ~32 k
// tables, so capping data still stops the scan). Cap is 10% of total pages
// with a 1024-page floor, mirroring the RamFs 10% quota idiom, so it scales
// with RAM instead of being a constant. Counts reset on register/release
// (Haskell also resets on exec, which reuses the same root).
static BUDGET_LOCK: RawSpinLock = RawSpinLock::new();
static mut BUDGET_TAB: [(u64, u32); 64] = [(0, 0); 64];
static mut BUDGET_N: usize = 0;

unsafe extern "C" {
    fn buddy_total_count() -> i32;
}

fn budget_cap() -> u32 {
    let total = unsafe { buddy_total_count() } as u32;
    core::cmp::max(total / 10, 1024)
}

fn budget_count(pdir: u64) -> u32 {
    unsafe {
        for i in 0..BUDGET_N {
            if BUDGET_TAB[i].0 == pdir {
                return BUDGET_TAB[i].1;
            }
        }
        0
    }
}

fn budget_inc(pdir: u64) {
    unsafe {
        for i in 0..BUDGET_N {
            if BUDGET_TAB[i].0 == pdir {
                BUDGET_TAB[i].1 = BUDGET_TAB[i].1.saturating_add(1);
                return;
            }
        }
        if BUDGET_N < 64 {
            BUDGET_TAB[BUDGET_N] = (pdir, 1);
            BUDGET_N += 1;
        }
    }
}

fn budget_over(pdir: u64) -> bool {
    BUDGET_LOCK.lock();
    let over = budget_count(pdir) >= budget_cap();
    BUDGET_LOCK.unlock();
    over
}

/// Reset a root's demand count to zero (new incarnation: register, exec).
///
/// # Safety
///
/// The caller must own `pdir` (freshly registered or just exec-cleared).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_page_budget_reset(pdir: *mut u8) {
    if pdir.is_null() {
        return;
    }
    let key = pdir as u64;
    BUDGET_LOCK.lock();
    unsafe {
        for i in 0..BUDGET_N {
            if BUDGET_TAB[i].0 == key {
                BUDGET_TAB[i].1 = 0;
                BUDGET_LOCK.unlock();
                return;
            }
        }
        if BUDGET_N < 64 {
            BUDGET_TAB[BUDGET_N] = (key, 0);
            BUDGET_N += 1;
        }
    }
    BUDGET_LOCK.unlock();
}

fn budget_remove(pdir: u64) {
    BUDGET_LOCK.lock();
    unsafe {
        let mut i = 0;
        while i < BUDGET_N {
            if BUDGET_TAB[i].0 == pdir {
                let last = BUDGET_N - 1;
                BUDGET_TAB[i] = BUDGET_TAB[last];
                BUDGET_TAB[last] = (0, 0);
                BUDGET_N = last;
                break;
            }
            i += 1;
        }
    }
    BUDGET_LOCK.unlock();
}

/// Try to charge `n` pages to a root's budget: `1` allowed and counted,
/// `0` denied (at cap). Shared by the Haskell brk/COW paths so demand (Rust)
/// and eager (Haskell) allocations draw from one cap.
///
/// # Safety
///
/// The caller must own `pdir` (a live EL0 root).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_page_budget_try_acquire(pdir: *mut u8, n: u32) -> i32 {
    if pdir.is_null() {
        return -22;
    }
    let key = pdir as u64;
    BUDGET_LOCK.lock();
    let allowed = unsafe {
        let cur = budget_count(key);
        let cap = budget_cap();
        match cur.checked_add(n) {
            Some(next) if next <= cap => {
                for i in 0..BUDGET_N {
                    if BUDGET_TAB[i].0 == key {
                        BUDGET_TAB[i].1 = next;
                        break;
                    }
                }
                if (0..BUDGET_N).all(|i| BUDGET_TAB[i].0 != key) && BUDGET_N < 64 {
                    BUDGET_TAB[BUDGET_N] = (key, next);
                    BUDGET_N += 1;
                }
                true
            }
            _ => false,
        }
    };
    BUDGET_LOCK.unlock();
    if allowed { 1 } else { 0 }
}

// Per-pdir syscall mask: 25 bits cover 0x00..0x18. Same shape and lock
// discipline as BUDGET_TAB, so one place knows things owned by a pdir.
// Full mask (all 25 used bits) is the boot default; narrowing is explicit
// via the shell verb. Unknown imm (>0x18) denies.
static SVC_MASK_LOCK: RawSpinLock = RawSpinLock::new();
static mut SVC_MASK_TAB: [(u64, u32); 64] = [(0, 0); 64];
static mut SVC_MASK_N: usize = 0;

const SVC_MASK_FULL: u32 = 0x1FFFFFF;

fn svc_mask_get_locked(pdir: u64) -> u32 {
    unsafe {
        for i in 0..SVC_MASK_N {
            if SVC_MASK_TAB[i].0 == pdir {
                return SVC_MASK_TAB[i].1;
            }
        }
        SVC_MASK_FULL
    }
}

fn svc_mask_set_locked(pdir: u64, mask: u32) {
    unsafe {
        for i in 0..SVC_MASK_N {
            if SVC_MASK_TAB[i].0 == pdir {
                SVC_MASK_TAB[i].1 = mask;
                return;
            }
        }
        if SVC_MASK_N < 64 {
            SVC_MASK_TAB[SVC_MASK_N] = (pdir, mask);
            SVC_MASK_N += 1;
        }
    }
}

fn svc_mask_remove(pdir: u64) {
    unsafe {
        let mut i = 0;
        while i < SVC_MASK_N {
            if SVC_MASK_TAB[i].0 == pdir {
                let last = SVC_MASK_N - 1;
                SVC_MASK_TAB[i] = SVC_MASK_TAB[last];
                SVC_MASK_TAB[last] = (0, 0);
                SVC_MASK_N = last;
                break;
            }
            i += 1;
        }
    }
}

/// Reset a root mask to full (spawn, pid0/init).
///
/// # Safety
///
/// Caller must own `pdir`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_svc_mask_reset(pdir: *mut u8) {
    if pdir.is_null() {
        return;
    }
    let key = pdir as u64;
    SVC_MASK_LOCK.lock();
    svc_mask_set_locked(key, SVC_MASK_FULL);
    SVC_MASK_LOCK.unlock();
}

/// Narrow a live root mask (shell verb). Bits beyond 0x18 are ignored.
///
/// # Safety
///
/// Caller must own `pdir`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_svc_mask_set(pdir: *mut u8, mask: u32) {
    if pdir.is_null() {
        return;
    }
    let key = pdir as u64;
    SVC_MASK_LOCK.lock();
    svc_mask_set_locked(key, mask & SVC_MASK_FULL);
    SVC_MASK_LOCK.unlock();
}

/// Read a root mask (full when never set).
///
/// # Safety
///
/// Caller must own `pdir`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_svc_mask_get(pdir: *mut u8) -> u32 {
    if pdir.is_null() {
        return 0;
    }
    let key = pdir as u64;
    SVC_MASK_LOCK.lock();
    let mask = svc_mask_get_locked(key);
    SVC_MASK_LOCK.unlock();
    mask
}

/// Query whether `imm` is allowed for `pdir`: 1 allowed, 0 denied.
///
/// # Safety
///
/// `pdir` may be null (denies).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_svc_allowed(pdir: *mut u8, imm: u32) -> i32 {
    if pdir.is_null() {
        return 0;
    }
    if imm > 0x18 {
        return 0;
    }
    let key = pdir as u64;
    SVC_MASK_LOCK.lock();
    let mask = svc_mask_get_locked(key);
    SVC_MASK_LOCK.unlock();
    if (mask & (1u32 << imm)) != 0 { 1 } else { 0 }
}

// TLB shootdown acknowledgements: `house_tlb_shootdown` stamps a generation,
// sends SGI 1 to every peer, and waits for each peer's ack to reach it.
static TLB_SD_SEQ: AtomicU32 = AtomicU32::new(0);
static TLB_SD_ACK: [AtomicU32; 32] = [const { AtomicU32::new(0) }; 32];

#[inline]
fn core_slot(mpidr: u64) -> usize {
    ((mpidr & 0xFF) as usize) & 31
}

#[inline]
fn ack_satisfies(ack: u32, seq: u32) -> bool {
    ack.wrapping_sub(seq) < 0x80000000
}

/// Invalidate a VA cluster-wide (local flush plus SGI + ack protocol).
///
/// # Safety
///
/// Call at EL1 with the SMP online mask and GIC up; waits for online peers
/// (cores that go offline are dropped, never hung on).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_tlb_shootdown(vaddr: u64) {
    unsafe extern "C" {
        static mut house_smp_online_mask: u32;
        fn house_gic_send_sgi_to_core(sgi: u32, core: u32);
    }
    unsafe {
        let va = vaddr >> 12;
        core::arch::asm!("dsb ishst; tlbi vae1is, {0}; dsb ish; isb", in(reg) va, options(nostack, preserves_flags));
        // Broadcast SGI 1 to online cores except self; offline cores are
        // skipped so a down core never takes a shootdown IPI.
        let mut me_raw: u64;
        core::arch::asm!("mrs {0}, mpidr_el1", out(reg) me_raw, options(nostack, preserves_flags));
        let me = core_slot(me_raw) as u32;
        let mask = core::ptr::read_volatile(&raw const house_smp_online_mask);
        let seq = TLB_SD_SEQ.fetch_add(1, Ordering::AcqRel).wrapping_add(1);
        let mut pending: u32 = 0;
        for core in 0..32u32 {
            if core == me {
                continue;
            }
            let Some(bit) = 1u32.checked_shl(core) else {
                continue;
            };
            if mask & bit != 0 {
                house_gic_send_sgi_to_core(1, core);
                pending |= bit;
            }
        }
        // A peer that has not reported may still be running the translation this
        // call invalidated, so the caller must not go on to reuse the VA. Peers
        // echo `sev` after acking, so this sleeps rather than spins.
        while pending != 0 {
            for core in 0..32u32 {
                let Some(bit) = 1u32.checked_shl(core) else {
                    continue;
                };
                if pending & bit != 0
                    && ack_satisfies(TLB_SD_ACK[core as usize].load(Ordering::Acquire), seq)
                {
                    pending &= !bit;
                }
            }
            if pending == 0 {
                break;
            }
            // A core that goes offline cannot ack; drop it rather than hang.
            pending &= core::ptr::read_volatile(&raw const house_smp_online_mask);
            if pending != 0 {
                core::arch::asm!("wfe", options(nostack, preserves_flags));
            }
        }
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
}

/// The shootdown generation a handler acknowledges: the newest flush any
///
/// # Safety
///
/// Safe to call anytime (single atomic load).
/// requester has asked for.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_tlb_shootdown_seq() -> u32 {
    TLB_SD_SEQ.load(Ordering::Acquire)
}

/// Report that this core has completed a shootdown covering `seq`.
///
/// # Safety
///
/// Call from this core's shootdown handler once its own flush is visible.
///
/// A shootdown handler calls this once its own flush is visible, so a requester
/// that sees the ack knows the peer is past the invalidation it waited for.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_tlb_shootdown_ack(seq: u32) {
    unsafe {
        let mut me: u64;
        core::arch::asm!("mrs {0}, mpidr_el1", out(reg) me, options(nostack, preserves_flags));
        TLB_SD_ACK[core_slot(me)].store(seq, Ordering::Release);
    }
}

/// Demand-pager marker (planted by `H.VirtualMemory`, consumed here and by
/// the svc.rs park gates): an L3 descriptor with Valid clear, magic `0xDE`
/// in bits[63:56], and bit1 carrying the final writable bit the supervisor
/// serve applies. Hardware ignores invalid descriptors outright, and the
/// `(valid, table-shape, buddy-owned)` checks in `userTable`/`getPage`
/// treat markers as unmapped — only the fault and validator paths below
/// interpret them.
pub(crate) const DEMAND_MAGIC: u64 = 0xDE << 56;
const DEMAND_MAGIC_MASK: u64 = 0xFF00_0000_0000_0000;
pub(crate) const DEMAND_WRITABLE: u64 = 1 << 1;

#[inline]
pub(crate) fn is_demand_desc(d3: u64) -> bool {
    d3 & 1 == 0 && (d3 & DEMAND_MAGIC_MASK) == DEMAND_MAGIC
}

/// Trap-side validator hook for the svc.rs park gates: `1` when `va` names
/// a demand-registered but unfaulted page in the recorded pdir, else `0`.
/// Markers are loader-committed future pages, so the gates park (the
/// supervisor serves the page, then re-validates exactly) instead of
/// refusing with a spurious `EFAULT`.
///
/// # Safety
///
/// Reads this core's recorded pdir; caller must guarantee EL1.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_is_demand_va(va: u64) -> i32 {
    let vap = va & !4095;
    unsafe {
        let slot = core::ptr::addr_of!(RECORDED_PDIRS[recorded_idx()]);
        let pdir = core::ptr::read_volatile(slot);
        if pdir.is_null() || (pdir as usize & 4095) != 0 {
            return 0;
        }
        let l0 = pdir as *mut u64;
        let d0 = *l0.add(((vap >> 39) & 0x1FF) as usize);
        if d0 & 1 == 0 {
            return 0;
        }
        let l1 = (d0 & !0xFFF) as *mut u64;
        let d1 = *l1.add(((vap >> 30) & 0x1FF) as usize);
        if d1 & 1 == 0 {
            return 0;
        }
        let l2 = (d1 & !0xFFF) as *mut u64;
        let d2 = *l2.add(((vap >> 21) & 0x1FF) as usize);
        if d2 & 1 == 0 {
            return 0;
        }
        let l3 = (d2 & !0xFFF) as *mut u64;
        let d3 = *l3.add(((vap >> 12) & 0x1FF) as usize);
        if is_demand_desc(d3) { 1 } else { 0 }
    }
}

/// Demand-page/CoW fault handler: 1 handled, 0 fall through to kill.
///
/// # Safety
///
/// EL1 fault context; refuses buddy-heap, out-of-window, demand-unmarked,
/// and driver-root VAs before taking `VM_LOCK`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_handle_user_fault(far: u64) -> i32 {
    use crate::mm::vm::{HOUSE_USER_VA_MAX, HOUSE_USER_VA_MIN};
    if crate::buddy::buddy_in_heap(far & !4095) {
        return 0;
    }
    if far < HOUSE_USER_VA_MIN || far > HOUSE_USER_VA_MAX {
        return 0;
    }
    let pdir = unsafe {
        let slot = core::ptr::addr_of!(RECORDED_PDIRS[recorded_idx()]);
        core::ptr::read_volatile(slot)
    };
    if pdir.is_null() || (pdir as usize & 4095) != 0 {
        return 0;
    }
    // S2 (house-oz9.11): a narrowed driver root is not pageable. Refuse here
    // (before the lock) so an EL0 fault under a driver TTBR0 context falls
    // through to the generic fault-kill park instead of silently zero-mapping
    // a RAM page into the driver's allowlist window.
    if crate::mm::vm::is_driver_root(pdir) {
        return 0;
    }
    VM_LOCK.lock();
    // SAFETY: the lock excludes a second walker; the walk only allocates from
    // the buddy and writes the levels it just allocated.
    let handled = unsafe { fault_locked(pdir, far) };
    VM_LOCK.unlock();
    handled
}

/// The demand-pager page-table walk, under `VM_LOCK` (shared with vm.rs).
unsafe fn fault_locked(pdir: *mut u8, far: u64) -> i32 {
    const PTE_VALID: u64 = 1 << 0;
    const PTE_TABLE: u64 = 1 << 1;
    const PTE_AF: u64 = 1 << 10;
    const PTE_SH_INNER: u64 = 3 << 8;
    const PTE_NG: u64 = 1 << 11;
    const PTE_UXN: u64 = 1 << 54;
    const PTE_PXN: u64 = 1 << 53;
    const PTE_AP_RW: u64 = 1 << 6;
    let va = far & !4095;
    if budget_over(pdir as u64) {
        return -28;
    }
    unsafe {
        let page = buddy_alloc_page();
        if page.is_null() {
            return -12;
        }
        let l0 = pdir as *mut u64;
        let i0 = ((va >> 39) & 0x1FF) as usize;
        let mut d0 = *l0.add(i0);
        if d0 & PTE_VALID == 0 {
            let nl1 = buddy_alloc_page() as *mut u64;
            if nl1.is_null() {
                buddy_free_page(page);
                return -12;
            }
            for i in 0..512 {
                *nl1.add(i) = 0;
            }
            // Miri cannot execute `asm!`: hosted tests are single-threaded, so
            // the table-clear publish ordering is elided there (logic unaffected).
            #[cfg(not(miri))]
            core::arch::asm!("dsb sy", options(nostack, preserves_flags));
            *l0.add(i0) = ((nl1 as u64) & !0xFFF) | PTE_VALID | PTE_TABLE;
            #[cfg(not(miri))]
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
            d0 = *l0.add(i0);
        }
        let l1 = (d0 & !0xFFF) as *mut u64;
        let i1 = ((va >> 30) & 0x1FF) as usize;
        let s1 = l1.add(i1);
        let mut d1 = *s1;
        let l2: *mut u64;
        if d1 & PTE_VALID == 0 {
            let nl2 = buddy_alloc_page() as *mut u64;
            if nl2.is_null() {
                buddy_free_page(page);
                return -12;
            }
            for i in 0..512 {
                *nl2.add(i) = 0;
            }
            #[cfg(not(miri))]
            core::arch::asm!("dsb sy", options(nostack, preserves_flags));
            *s1 = ((nl2 as u64) & !0xFFF) | PTE_VALID | PTE_TABLE;
            #[cfg(not(miri))]
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
            d1 = *s1;
            l2 = (d1 & !0xFFF) as *mut u64;
        } else if d1 & PTE_TABLE == 0 {
            // 1GB block (early-boot identity RAM map): split, preserving the
            // mapping, instead of overwriting it.
            if !crate::mm::vm::vm_split_slot(s1, 1) {
                buddy_free_page(page);
                return -12;
            }
            d1 = *s1;
            l2 = (d1 & !0xFFF) as *mut u64;
        } else {
            l2 = (d1 & !0xFFF) as *mut u64;
        }
        let i2 = ((va >> 21) & 0x1FF) as usize;
        let s2 = l2.add(i2);
        let mut d2 = *s2;
        let l3: *mut u64;
        if d2 & PTE_VALID == 0 {
            let nl3 = buddy_alloc_page() as *mut u64;
            if nl3.is_null() {
                buddy_free_page(page);
                return -12;
            }
            for i in 0..512 {
                *nl3.add(i) = 0;
            }
            #[cfg(not(miri))]
            core::arch::asm!("dsb sy", options(nostack, preserves_flags));
            *s2 = ((nl3 as u64) & !0xFFF) | PTE_VALID | PTE_TABLE;
            #[cfg(not(miri))]
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
            d2 = *s2;
            l3 = (d2 & !0xFFF) as *mut u64;
        } else if d2 & PTE_TABLE == 0 {
            // 2MB block: split, preserving the mapping.
            if !crate::mm::vm::vm_split_slot(s2, 2) {
                buddy_free_page(page);
                return -12;
            }
            d2 = *s2;
            l3 = (d2 & !0xFFF) as *mut u64;
        } else {
            l3 = (d2 & !0xFFF) as *mut u64;
        }
        let i3 = ((va >> 12) & 0x1FF) as usize;
        let d3 = *l3.add(i3);
        if d3 & PTE_VALID != 0 {
            buddy_free_page(page);
            return 0;
        }
        // Demand-registered but unfaulted: the supervisor materializes file
        // content with final perms (Haskell `demandServe`) and resumes the
        // faulting insn, so EL1 must not zero-map here.
        if is_demand_desc(d3) {
            buddy_free_page(page);
            return 2;
        }
        let desc = ((page as u64) & !0xFFF)
            | PTE_VALID
            | PTE_TABLE
            | PTE_AF
            | PTE_SH_INNER
            | PTE_NG
            | PTE_UXN
            | PTE_PXN
            | (0 << 2)
            | PTE_AP_RW;
        *l3.add(i3) = desc;
        // Host tests run at EL0, where `tlbi` traps (SIGILL under Linux);
        // the guest install path runs EL1 and keeps the invalidate.
        #[cfg(not(test))]
        core::arch::asm!("dsb ishst; tlbi vae1is, {0}; dsb ish; isb", in(reg) va >> 12, options(nostack, preserves_flags));
        #[cfg(all(test, not(miri)))]
        core::arch::asm!("dsb ishst; dsb ish; isb", options(nostack, preserves_flags));
        BUDGET_LOCK.lock();
        budget_inc(pdir as u64);
        BUDGET_LOCK.unlock();
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn demand_desc_recognized() {
        assert!(is_demand_desc(DEMAND_MAGIC));
        assert!(is_demand_desc(DEMAND_MAGIC | DEMAND_WRITABLE));
        assert!(!is_demand_desc(0));
        assert!(!is_demand_desc(1 | (1 << 10) | (3 << 6)));
        assert!(!is_demand_desc(DEMAND_MAGIC | 1));
        assert!(!is_demand_desc(0xDF00_0000_0000_0000));
    }

    // S1 (house-oz9.11): driver roots reuse the process ASID allocator —
    // no separate budget. The map must fit every live driver root: 32 slots
    // against a 64-entry map leaves headroom for live processes, and the
    // wrap/rebuild path is shared (a driver pdir is just a pdir to it).
    #[test]
    fn driver_roots_share_asid_cap() {
        use crate::mm::vm::VIRTIO_SLOT_COUNT;
        assert!((VIRTIO_SLOT_COUNT as usize) * 2 <= ASID_MAP_CAP);
        unsafe {
            // 40 roots stay under the cap, so no wrap flush fires (the host
            // runs EL0 and cannot execute TLBI): distinct ASIDs in the 8-bit
            // range, stable on re-request, accounted in the map length.
            let mut pdirs = [core::ptr::null_mut(); 40];
            for (i, slot) in pdirs.iter_mut().enumerate() {
                *slot = (0x1000 * (i + 1)) as *mut u8;
            }
            let mut seen = [0u64; 40];
            for (i, p) in pdirs.iter().enumerate() {
                let a = asid_for_pdir(*p) as u64;
                assert!((1..=250).contains(&a), "ASID in 8-bit range");
                assert!(!seen[..i].contains(&a), "distinct before the cap");
                seen[i] = a;
            }
            assert_eq!(ASID_MAP_LEN, 40);
            for (i, p) in pdirs.iter().enumerate() {
                assert_eq!(asid_for_pdir(*p) as u64, seen[i], "stable re-request");
            }
        }
    }

    // S2 (house-oz9.11): the demand pager refuses enrolled driver roots, so
    // an EL0 fault under a driver TTBR0 context falls through to the generic
    // fault-kill park instead of zero-mapping RAM into the allowlist window.
    // The `dsb`/`isb` table-publish ordering on the unmarked-root map path
    // is elided under Miri (single-threaded hosted test; logic unaffected).
    #[test]
    fn pager_refuses_driver_root() {
        use crate::mm::vm::{driver_unmark, house_vm_narrow_driver_root};
        #[repr(align(4096))]
        struct A512([u64; 512]);
        unsafe {
            let mut l0 = Box::new(A512([0; 512]));
            let mut l1 = Box::new(A512([0; 512]));
            let mut l2 = Box::new(A512([0; 512]));
            // One retag per table (see mm::vm::tests::mmio_walk_layout): a
            // fresh as_mut_ptr per write would pop the tag the pager and
            // narrow walks read through.
            let l0w = l0.0.as_mut_ptr();
            let l1w = l1.0.as_mut_ptr();
            let l2w = l2.0.as_mut_ptr();
            let l0p = l0w as *mut u8;
            *l0w.add(0) = (l1w as u64) | 0x3;
            *l1w.add(0) = (l2w as u64) | 0x3;
            let prev = current_pdir();
            house_set_recorded_pdir(l0p);
            // Unmarked: the pager owns it (maps or refuses on alloc — either
            // way it does not take the driver-refusal exit).
            let before = house_handle_user_fault(0x01000000);
            assert_ne!(before, 0, "unmarked root is pageable, got refusal");
            // Narrowed + enrolled: refused without touching the allocator.
            assert_eq!(house_vm_narrow_driver_root(l0p), 1);
            assert_eq!(
                house_handle_user_fault(0x01000000),
                0,
                "marked root refused"
            );
            assert_eq!(
                house_handle_user_fault(0x0a000100),
                0,
                "marked root refused off-window-page too"
            );
            driver_unmark(l0p);
            house_set_recorded_pdir(prev);
        }
    }

    #[test]
    fn slot_folds_aff0_onto_32() {
        for mpidr in 0..=0xFFu64 {
            let slot = core_slot(mpidr);
            assert!(slot < 32);
            assert_eq!(slot, ((mpidr & 0xFF) as usize) & 31);
        }
        assert_eq!(core_slot(0), 0);
        assert_eq!(core_slot(31), 31);
        assert_eq!(core_slot(32), 0);
        assert_eq!(core_slot(0xFF), 31);
    }

    #[test]
    fn thread_switch_frame_matches_thread_init() {
        let sw = include_str!("../../house-libc/src/threads/switch.rs");
        let init = include_str!("../../house-libc/src/threads/threads.rs");
        let regs = |line: &str| -> Option<(String, String)> {
            let line = line.trim();
            let (op, rest) = line.split_once(char::is_whitespace)?;
            if op != "stp" && op != "ldp" {
                return None;
            }
            let rest = rest.split(',').collect::<Vec<_>>();
            if rest.len() < 2 {
                return None;
            }
            Some((
                rest[0].trim().to_string(),
                rest[1].split_whitespace().next()?.to_string(),
            ))
        };
        let pushes: Vec<(String, String)> = sw.lines().filter_map(regs).collect();
        // pushes: stp lines come before ldp lines in switch.rs
        let first_ldp = sw
            .lines()
            .position(|l| l.trim_start().starts_with("ldp"))
            .unwrap();
        let mut push_seq = Vec::new();
        let mut pop_seq = Vec::new();
        for (i, line) in sw.lines().enumerate() {
            if let Some(p) = regs(line) {
                if i < first_ldp {
                    push_seq.push(p);
                } else {
                    pop_seq.push(p);
                }
            }
        }
        assert!(!push_seq.is_empty());
        let mut rev = push_seq.clone();
        rev.reverse();
        assert_eq!(pop_seq, rev, "switch frame must pop in reverse push order");
        let frame_bytes = push_seq.len() * 16;
        // x30 link slot: word index of x30 in pop order from sp.
        let mut words = Vec::new();
        for (a, b) in &pop_seq {
            words.push(a.clone());
            words.push(b.clone());
        }
        let link_word = words.iter().position(|r| r == "x30").expect("x30 saved");
        let get_num = |src: &str, key: &str| -> usize {
            let line = src
                .lines()
                .find(|l| l.contains(key))
                .expect("thread init frame constant");
            line.split(|c: char| !c.is_ascii_digit())
                .filter(|t| !t.is_empty())
                .next()
                .unwrap()
                .parse()
                .unwrap()
        };
        let get_tramp_word = || -> usize {
            let line = init
                .lines()
                .find(|l| l.contains("house_thread_trampoline as"))
                .expect("trampoline slot");
            let after_add = line.split("sp.add(").nth(1).unwrap();
            after_add.split(')').next().unwrap().parse().unwrap()
        };
        assert_eq!(get_num(init, "top = top -"), frame_bytes);
        assert_eq!(get_tramp_word(), link_word);
        let top_pos = init.find("top = top -").expect("frame base");
        let zero_line = init[top_pos..]
            .lines()
            .find(|l| l.contains("for i in 0.."))
            .expect("zero loop");
        let zero_end: usize = zero_line
            .split("0..")
            .nth(1)
            .unwrap()
            .split(|c: char| !c.is_ascii_digit())
            .filter(|t| !t.is_empty())
            .next()
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(zero_end, frame_bytes / 8);
    }

    #[test]
    fn thread_switch_saves_full_callee_fp() {
        let src = include_str!("../../house-libc/src/threads/switch.rs");
        let mut seen = std::collections::BTreeSet::new();
        // minimal scan for d<nn> tokens following stp/ldp
        let mut i = 0;
        let b = src.as_bytes();
        while i < b.len() {
            if b[i] == b'd' && i + 1 < b.len() && b[i + 1].is_ascii_digit() {
                let mut j = i + 1;
                while j < b.len() && b[j].is_ascii_digit() {
                    j += 1;
                }
                if let Ok(n) = src[i + 1..j].parse::<u32>() {
                    // only count when line contains stp or ldp
                    let line_start = src[..i].rfind('\n').map(|k| k + 1).unwrap_or(0);
                    let line_end = src[i..].find('\n').map(|k| i + k).unwrap_or(src.len());
                    let line = &src[line_start..line_end];
                    if line.contains("stp") || line.contains("ldp") {
                        seen.insert(n);
                    }
                }
                i = j;
            } else {
                i += 1;
            }
        }
        let expect: std::collections::BTreeSet<u32> = (8..=15).chain(24..=31).collect();
        assert_eq!(seen, expect);
    }

    #[test]
    fn oom_returns_enomem_not_not_mine() {
        // Drain the buddy so the next fault has no page to give.
        let mut drained: Vec<*mut u8> = Vec::new();
        loop {
            let p = unsafe { crate::buddy::buddy_alloc_page() };
            if p.is_null() {
                break;
            }
            drained.push(p);
            if drained.len() > 1 << 24 {
                break;
            }
        }
        let rc = unsafe { fault_locked(core::ptr::null_mut(), 0x01000000) };
        assert_eq!(rc, -12);
        for p in drained {
            unsafe { crate::buddy::buddy_free_page(p) };
        }
    }

    #[test]
    fn oom_propagates_through_handler() {
        let mut drained: Vec<*mut u8> = Vec::new();
        loop {
            let p = unsafe { crate::buddy::buddy_alloc_page() };
            if p.is_null() {
                break;
            }
            drained.push(p);
            if drained.len() > 1 << 24 {
                break;
            }
        }
        let fake = 0x70000000 as *mut u8;
        unsafe { userspace_set_recorded_for_test(fake) };
        let rc = unsafe { house_handle_user_fault(0x01000000) };
        unsafe { userspace_set_recorded_for_test(core::ptr::null_mut()) };
        assert_eq!(rc, -12);
        for p in drained {
            unsafe { crate::buddy::buddy_free_page(p) };
        }
    }

    #[test]
    fn slot_ignores_upper_affinity() {
        assert_eq!(core_slot(0x0000000100000020), 0);
        assert_eq!(core_slot(0x000000FF0000001F), 31);
        assert_eq!(core_slot(u64::MAX), 31);
    }

    #[test]
    fn newer_ack_satisfies_older_seq() {
        assert!(ack_satisfies(2, 1));
        assert!(ack_satisfies(1, 1));
        assert!(!ack_satisfies(1, 2));
        assert!(ack_satisfies(0, u32::MAX));
        assert!(!ack_satisfies(u32::MAX, 0));
    }

    #[test]
    fn budget_cap_has_floor() {
        assert!(budget_cap() >= 1024);
    }

    #[test]
    fn budget_acquire_caps_at_cap() {
        let pdir = 0x71000000 as *mut u8;
        unsafe { house_page_budget_reset(pdir) };
        let cap = budget_cap();
        assert!(cap >= 1024);
        for _ in 0..cap {
            assert_eq!(unsafe { house_page_budget_try_acquire(pdir, 1) }, 1);
        }
        assert_eq!(unsafe { house_page_budget_try_acquire(pdir, 1) }, 0);
        unsafe { house_page_budget_reset(pdir) };
        assert_eq!(unsafe { house_page_budget_try_acquire(pdir, 1) }, 1);
        budget_remove(pdir as u64);
    }

    #[test]
    fn budget_bulk_acquire_fails_over_cap() {
        let pdir = 0x72000000 as *mut u8;
        unsafe { house_page_budget_reset(pdir) };
        let cap = budget_cap();
        assert_eq!(unsafe { house_page_budget_try_acquire(pdir, cap) }, 1);
        assert_eq!(unsafe { house_page_budget_try_acquire(pdir, 1) }, 0);
        budget_remove(pdir as u64);
    }

    #[test]
    fn budget_remove_clears_entry() {
        let pdir = 0x73000000 as *mut u8;
        unsafe { house_page_budget_reset(pdir) };
        assert_eq!(unsafe { house_page_budget_try_acquire(pdir, 5) }, 1);
        budget_remove(pdir as u64);
        assert_eq!(budget_count(pdir as u64), 0);
        assert!(!budget_over(pdir as u64));
        budget_remove(pdir as u64);
    }

    #[test]
    fn budget_over_false_when_empty() {
        let pdir = 0x74000000u64;
        budget_remove(pdir);
        assert!(!budget_over(pdir));
        budget_remove(pdir);
    }

    #[test]
    fn budget_null_pdir_rejected() {
        assert_eq!(
            unsafe { house_page_budget_try_acquire(core::ptr::null_mut(), 1) },
            -22
        );
    }
}
