#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(unused_unsafe)]
#![allow(clippy::all)]

//! VM mmap — `mm/vm.c` transliteration (demand-lazy, 4K).

use crate::spinlock::RawSpinLock;

const RTS_ALIAS_BASE: u64 = 0x4200000000;
const MBLOCK: usize = 1 << 20;
const PAGE_SIZE: usize = 4096;
const MAP_FIXED: i32 = 0x10;
const PROT_NONE: i32 = 0x0;
const PROT_READ: i32 = 0x1;
const PROT_WRITE: i32 = 0x2;
const PROT_EXEC: i32 = 0x4;

const HOUSE_USER_VA_MIN: u64 = 0x01000000;
// Demand/mmap window extends to 64GB: anon base (17GB) and demand-test VAs
// (32GB) sit above the highest possible 1GB RAM identity block (16GB RAM
// reaches L1 idx 16 = 17GB), so test traffic always fault-allocates fresh
// pages instead of aliasing live RAM. Stays below the RTS alias (264GB) so
// alias unmaps keep release-only behavior.
const HOUSE_USER_VA_MAX: u64 = 0x1000000000;

const PTE_VALID: u64 = 1 << 0;
const PTE_TABLE: u64 = 1 << 1;
const PTE_AP_SHIFT: u64 = 6;
const PTE_AP_MASK: u64 = 3 << 6;
const PTE_AP_RW: u64 = 1 << 6;
const PTE_AP_RO: u64 = 3 << 6;

const ENOSYS: i32 = 38;
const EINVAL: i32 = 22;
const ENOMEM: i32 = 12;

static VM_LOCK: RawSpinLock = RawSpinLock::new();
static mut VM_RESV: [(*mut u8, *mut u8); 32] = [(core::ptr::null_mut(), core::ptr::null_mut()); 32];
static mut VM_N_RESV: i32 = 0;
static mut VM_MMAP_CUR: *mut u8 = core::ptr::null_mut();

extern "C" {
    static mut __heap_base: u8;
    static mut house_ram_bytes: u64;
    static mut house_smp_n: i32;
    fn __errno_location() -> *mut i32;
    fn buddy_alloc_page() -> *mut u8;
    fn buddy_free_page(p: *mut u8);
    fn current_pdir() -> *mut u8;
    fn house_tlb_shootdown(vaddr: u64);
    fn uart_puts(s: *const u8);
}

#[inline]
unsafe fn runtime_ram_bytes() -> u64 {
    let v = unsafe { core::ptr::read_volatile(&raw const house_ram_bytes) };
    if v != 0 {
        v
    } else {
        512 << 20
    }
}

#[inline]
fn vm_ram_limit() -> u64 {
    // SAFETY: runtime_ram_bytes reads volatile.
    let ram = unsafe { runtime_ram_bytes() };
    0x40000000 + ram
}

unsafe fn vm_in_ram(lo: *mut u8, n: usize) -> bool {
    let heap = unsafe { &raw mut __heap_base as *mut u8 as usize } as u64;
    let lo_u = lo as usize as u64;
    if (lo as usize) < heap as usize {
        return false;
    }
    let lim = vm_ram_limit();
    let lo64 = lo_u;
    // checked: n > lim - lo_u
    if let Some(diff) = lim.checked_sub(lo64) {
        (n as u64) <= diff
    } else {
        false
    }
}

unsafe fn vm_in_user_window(lo: *mut u8, n: usize) -> bool {
    let lo_u = lo as usize as u64;
    if lo_u < HOUSE_USER_VA_MIN {
        return false;
    }
    // n > MAX - lo +1
    let max_plus_one = HOUSE_USER_VA_MAX.wrapping_add(1);
    if (n as u64) > max_plus_one.wrapping_sub(lo_u) {
        return false;
    }
    let hi = lo_u.wrapping_add(n as u64);
    if hi < lo_u {
        return false;
    }
    if hi > max_plus_one {
        return false;
    }
    true
}

unsafe fn vm_committable(lo: *mut u8, n: usize) -> bool {
    if unsafe { vm_in_user_window(lo, n) } {
        return true;
    }
    if unsafe { vm_in_ram(lo, n) } {
        return true;
    }
    let lo_u = lo as usize as u64;
    let alias_base = RTS_ALIAS_BASE;
    let smp_n = unsafe { core::ptr::read_volatile(&raw const house_smp_n) } as u64;
    let smp_n = if smp_n == 0 { 2 } else { smp_n };
    let stack_reserve: u64 = 0x200000 + smp_n * 65536;
    let ram = unsafe { runtime_ram_bytes() };
    let half = ram >> 1;
    let mut span = if half > stack_reserve {
        half - stack_reserve
    } else {
        0
    };
    if span > (8u64 << 30) {
        span = 8u64 << 30;
    }
    if lo_u < alias_base {
        return false;
    }
    if (n as u64) > span {
        return false;
    }
    let hi = lo_u.wrapping_add(n as u64);
    if hi < lo_u {
        return false;
    }
    if hi > alias_base + span {
        return false;
    }
    true
}

unsafe fn vm_overlap(lo: *mut u8, hi: *mut u8) -> bool {
    let n = unsafe { VM_N_RESV };
    for i in 0..n as usize {
        let (rlo, rhi) = unsafe { VM_RESV[i] };
        if (lo as usize) < rhi as usize && (rlo as usize) < hi as usize {
            return true;
        }
    }
    false
}

unsafe fn vm_record(lo: *mut u8, hi: *mut u8) {
    let n = unsafe { VM_N_RESV };
    if (n as usize) < 32 {
        unsafe {
            VM_RESV[n as usize] = (lo, hi);
            VM_N_RESV = n + 1;
        }
    }
}

unsafe fn vm_release(lo: *mut u8, hi: *mut u8) {
    let mut i = 0;
    while i < unsafe { VM_N_RESV } as usize {
        let (rlo, rhi) = unsafe { VM_RESV[i] };
        if (rlo as usize) >= lo as usize && (rhi as usize) <= hi as usize {
            let n = unsafe { VM_N_RESV } as usize;
            unsafe {
                VM_RESV[i] = VM_RESV[n - 1];
                VM_N_RESV = (n - 1) as i32;
            }
            if i > 0 {
                i -= 1;
            }
        }
        i += 1;
        if i >= unsafe { VM_N_RESV } as usize {
            break;
        }
    }
}

unsafe fn vm_l3_entry(va: u64) -> *mut u64 {
    let pdir = unsafe { current_pdir() };
    if pdir.is_null() {
        return core::ptr::null_mut();
    }
    if (pdir as usize & 4095) != 0 {
        return core::ptr::null_mut();
    }
    let l0 = pdir as *mut u64;
    let d0 = unsafe { *l0.add(((va >> 39) & 0x1FF) as usize) };
    if d0 & PTE_VALID == 0 {
        return core::ptr::null_mut();
    }
    let l1 = (d0 & !0xFFF) as *mut u64;
    if l1.is_null() {
        return core::ptr::null_mut();
    }
    let s1 = unsafe { l1.add(((va >> 30) & 0x1FF) as usize) };
    let d1 = unsafe { *s1 };
    if d1 & PTE_VALID == 0 {
        return core::ptr::null_mut();
    }
    if d1 & PTE_TABLE == 0 {
        if !unsafe { vm_split_slot(s1, 1) } {
            return core::ptr::null_mut();
        }
    }
    let d1 = unsafe { *s1 };
    let l2 = (d1 & !0xFFF) as *mut u64;
    if l2.is_null() {
        return core::ptr::null_mut();
    }
    let s2 = unsafe { l2.add(((va >> 21) & 0x1FF) as usize) };
    let d2 = unsafe { *s2 };
    if d2 & PTE_VALID == 0 {
        return core::ptr::null_mut();
    }
    if d2 & PTE_TABLE == 0 {
        if !unsafe { vm_split_slot(s2, 2) } {
            return core::ptr::null_mut();
        }
    }
    let d2 = unsafe { *s2 };
    let l3 = (d2 & !0xFFF) as *mut u64;
    if l3.is_null() {
        return core::ptr::null_mut();
    }
    unsafe { l3.add(((va >> 12) & 0x1FF) as usize) }
}

/// Split a block descriptor in place into a table of smaller mappings.
///
/// `slot` points at an L1 entry (`level` 1, 1GB block → L2 table of 2MB
/// blocks) or an L2 entry (`level` 2, 2MB block → L3 table of 4K pages).
/// Attribute bits (AttrIndx/NS/AP/SH/AF/nG/UXN/PXN) and the output address
/// are preserved per chunk, so the translation is unchanged — only the
/// granularity is refined, giving later walks a real slot to operate on.
/// Already-table or invalid entries are a no-op returning true; OOM false.
/// # Safety
/// `slot` must be a writable table entry; caller serializes against other
/// table writers for the same entry (VM_LOCK, or exception-context for the
/// pager fast path as with the existing lock-free table fills).
pub(crate) unsafe fn vm_split_slot(slot: *mut u64, level: u8) -> bool {
    if slot.is_null() || (level != 1 && level != 2) {
        return false;
    }
    let d = unsafe { *slot };
    if d & PTE_VALID == 0 || d & PTE_TABLE != 0 {
        return true;
    }
    let child = unsafe { buddy_alloc_page() } as *mut u64;
    if child.is_null() {
        return false;
    }
    for i in 0..512 {
        unsafe { *child.add(i) = 0 };
    }
    if level == 1 {
        let base = d & 0xFFFFC0000000u64;
        let keep = d & 0xFFFF000000000FFFu64;
        for i in 0..512 {
            let chunk = base.wrapping_add((i as u64) << 21) & 0xFFFFFE00000u64;
            unsafe { *child.add(i as usize) = keep | chunk };
        }
    } else {
        let base = d & 0xFFFFFE00000u64;
        let keep = (d & 0xFFFF000000000FFFu64) | PTE_TABLE;
        for i in 0..512 {
            let chunk = base.wrapping_add((i as u64) << 12) & 0x0000FFFFFFFFF000u64;
            unsafe { *child.add(i as usize) = keep | chunk };
        }
    }
    unsafe { core::arch::asm!("dsb sy", options(nostack, preserves_flags)) };
    unsafe { *slot = ((child as u64) & !0xFFF) | PTE_VALID | PTE_TABLE };
    unsafe {
        core::arch::asm!(
            "dsb sy; tlbi vmalle1is; dsb sy; isb",
            options(nostack, preserves_flags)
        )
    };
    true
}

// # Safety: caller must ensure addr/len valid, fd/off checked.
#[no_mangle]
pub unsafe extern "C" fn house_vm_mmap(
    addr: *mut u8,
    len: usize,
    prot: i32,
    flags: i32,
    fd: i32,
    off: i64,
) -> *mut u8 {
    if fd != -1 {
        unsafe { *__errno_location() = ENOSYS };
        return usize::MAX as *mut u8;
    }
    if off != 0 {
        unsafe { *__errno_location() = EINVAL };
        return usize::MAX as *mut u8;
    }
    if prot & !(PROT_READ | PROT_WRITE | PROT_EXEC) != 0 {
        unsafe { *__errno_location() = EINVAL };
        return usize::MAX as *mut u8;
    }
    VM_LOCK.lock();
    if len == 0 {
        unsafe { *__errno_location() = EINVAL };
        VM_LOCK.unlock();
        return usize::MAX as *mut u8;
    }
    let rounded: usize;
    {
        let Some(tmp) = len.checked_add(MBLOCK - 1) else {
            unsafe { *__errno_location() = EINVAL };
            VM_LOCK.unlock();
            return usize::MAX as *mut u8;
        };
        rounded = tmp & !(MBLOCK - 1);
    }
    let lo = addr;
    let hi: *mut u8;
    if !lo.is_null() {
        let Some(hi_u) = (lo as usize).checked_add(rounded) else {
            unsafe { *__errno_location() = EINVAL };
            VM_LOCK.unlock();
            return usize::MAX as *mut u8;
        };
        hi = hi_u as *mut u8;
    } else {
        hi = core::ptr::null_mut();
    }

    if (flags & MAP_FIXED) != 0 && !lo.is_null() {
        if unsafe { vm_committable(lo, len) } {
            VM_LOCK.unlock();
            return addr;
        }
        unsafe { *__errno_location() = ENOMEM };
        VM_LOCK.unlock();
        return usize::MAX as *mut u8;
    }
    if !lo.is_null() {
        let hi_val = hi as usize;
        if hi_val <= 0x1000000000000usize && unsafe { !vm_overlap(lo, hi) } {
            unsafe { vm_record(lo, hi) };
            VM_LOCK.unlock();
            return addr;
        }
        unsafe { *__errno_location() = ENOMEM };
        VM_LOCK.unlock();
        return usize::MAX as *mut u8;
    }
    // anonymous: bump through 0x44000000 (17GB, above any RAM identity block)
    {
        let anon_base = 0x44000000usize as *mut u8;
        let cur = unsafe { VM_MMAP_CUR };
        let p = if !cur.is_null() {
            let cur_u = cur as usize;
            let aligned = (cur_u + MBLOCK - 1) & !(MBLOCK - 1);
            aligned as *mut u8
        } else {
            anon_base
        };
        let Some(p_end_u) = (p as usize).checked_add(rounded) else {
            unsafe { *__errno_location() = ENOMEM };
            VM_LOCK.unlock();
            return usize::MAX as *mut u8;
        };
        if p_end_u > (HOUSE_USER_VA_MAX as usize + 1)
            || unsafe { vm_overlap(p, p_end_u as *mut u8) }
        {
            unsafe { *__errno_location() = ENOMEM };
            VM_LOCK.unlock();
            return usize::MAX as *mut u8;
        }
        unsafe { VM_MMAP_CUR = p_end_u as *mut u8 };
        unsafe { vm_record(p, p_end_u as *mut u8) };
        VM_LOCK.unlock();
        return p;
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_vm_munmap(addr: *mut u8, len: usize) -> i32 {
    if addr.is_null() {
        return 0;
    }
    if len == 0 {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    }
    let rounded: usize;
    {
        let Some(tmp) = len.checked_add(PAGE_SIZE - 1) else {
            unsafe { *__errno_location() = EINVAL };
            return -1;
        };
        rounded = tmp & !(PAGE_SIZE - 1);
    }
    let lo = addr as usize as u64;
    let Some(hi) = (addr as usize).checked_add(rounded).map(|v| v as u64) else {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    };
    if lo >= HOUSE_USER_VA_MIN && hi <= HOUSE_USER_VA_MAX.wrapping_add(1) {
        VM_LOCK.lock();
        let mut va = lo;
        while va < hi {
            let slot = unsafe { vm_l3_entry(va) };
            if !slot.is_null() {
                let d = unsafe { *slot };
                if d & PTE_VALID != 0 {
                    let page = (d & !0xFFF) as *mut u8;
                    unsafe { *slot = 0 };
                    unsafe { core::arch::asm!("dsb ishst", options(nostack, preserves_flags)) };
                    unsafe { buddy_free_page(page) };
                    unsafe { house_tlb_shootdown(va) };
                }
            }
            va = va.wrapping_add(PAGE_SIZE as u64);
        }
        unsafe { vm_release(addr, hi as usize as *mut u8) };
        VM_LOCK.unlock();
        return 0;
    }
    VM_LOCK.lock();
    {
        let Some(tmp2) = len.checked_add(MBLOCK - 1) else {
            VM_LOCK.unlock();
            return 0;
        };
        let rnd2 = tmp2 & !(MBLOCK - 1);
        let Some(hi2) = (addr as usize).checked_add(rnd2) else {
            VM_LOCK.unlock();
            return 0;
        };
        unsafe { vm_release(addr, hi2 as *mut u8) };
    }
    VM_LOCK.unlock();
    0
}

#[no_mangle]
pub unsafe extern "C" fn house_vm_mprotect(addr: *mut u8, len: usize, prot: i32) -> i32 {
    unsafe { uart_puts(b"[mprotect] start\n\0".as_ptr()) };
    if addr.is_null() {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    }
    if len == 0 {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    }
    if prot & !(PROT_READ | PROT_WRITE | PROT_EXEC) != 0 {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    }
    let want_rw = (prot & PROT_WRITE) != 0;
    let rounded: usize;
    {
        let Some(tmp) = len.checked_add(PAGE_SIZE - 1) else {
            unsafe { *__errno_location() = EINVAL };
            return -1;
        };
        rounded = tmp & !(PAGE_SIZE - 1);
    }
    if (addr as usize & (PAGE_SIZE - 1)) != 0 {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    }
    let lo = addr as usize as u64;
    let Some(hi) = lo.checked_add(rounded as u64) else {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    };
    if hi < lo {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    }
    if lo < HOUSE_USER_VA_MIN || hi > HOUSE_USER_VA_MAX.wrapping_add(1) {
        unsafe { *__errno_location() = ENOMEM };
        return -1;
    }
    VM_LOCK.lock();
    unsafe { uart_puts(b"[mprotect] lock done\n\0".as_ptr()) };
    let mut va = lo;
    while va < hi {
        unsafe { uart_puts(b"[mprotect] loop va\n\0".as_ptr()) };
        let slot = unsafe { vm_l3_entry(va) };
        unsafe { uart_puts(b"[mprotect] slot done\n\0".as_ptr()) };
        if slot.is_null() {
            VM_LOCK.unlock();
            unsafe { *__errno_location() = EINVAL };
            return -1;
        }
        let d = unsafe { *slot };
        if d & PTE_VALID == 0 {
            VM_LOCK.unlock();
            unsafe { *__errno_location() = EINVAL };
            return -1;
        }
        let ap = if want_rw { PTE_AP_RW } else { PTE_AP_RO };
        let new_d = (d & !PTE_AP_MASK) | ap;
        unsafe { *slot = new_d };
        unsafe { core::arch::asm!("dsb ishst", options(nostack, preserves_flags)) };
        unsafe { house_tlb_shootdown(va) };
        va = va.wrapping_add(PAGE_SIZE as u64);
    }
    VM_LOCK.unlock();
    0
}

#[no_mangle]
pub unsafe extern "C" fn house_vm_demand_single() -> i32 {
    unsafe { uart_puts(b"[vm] demand single start\n\0".as_ptr()) };
    // 32GB: above any RAM identity block, so the access truly faults and the
    // pager allocates a fresh page (aliasing live RAM would silently sink on
    // hvf and corrupt buddy memory).
    let p = 0x800000000u64 as *mut u32;
    unsafe {
        core::ptr::write_volatile(p, 0xdeadbeef);
        uart_puts(b"[vm] demand single store done\n\0".as_ptr());
        let v = core::ptr::read_volatile(p);
        uart_puts(b"[vm] demand single load done\n\0".as_ptr());
        if v == 0xdeadbeef {
            1
        } else {
            0
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_vm_demand_100() -> i32 {
    unsafe { uart_puts(b"[vm] demand 100 start\n\0".as_ptr()) };
    for i in 0..100 {
        let p = (0x800000000u64 + i as u64 * 4096) as *mut u8;
        unsafe { core::ptr::write_volatile(p, i as u8) };
    }
    unsafe { uart_puts(b"[vm] demand 100 store done\n\0".as_ptr()) };
    for i in 0..100 {
        let p = (0x800000000u64 + i as u64 * 4096) as *mut u8;
        let v = unsafe { core::ptr::read_volatile(p) };
        if v != i as u8 {
            return 0;
        }
    }
    unsafe { uart_puts(b"[vm] demand 100 load done\n\0".as_ptr()) };
    1
}

#[no_mangle]
pub unsafe extern "C" fn house_puts_after() {
    unsafe { uart_puts(b"[vm] after alloc\n\0".as_ptr()) };
}
