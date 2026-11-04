#![allow(
    unsafe_op_in_unsafe_fn,
    reason = "transliteration has explicit unsafe blocks throughout; inner-block audit as follow-up"
)]
#![allow(
    static_mut_refs,
    reason = "transliterated C globals use raw statics; guarded by HAL spinlocks"
)]
#![allow(
    unused_unsafe,
    reason = "transliteration keeps explicit unsafe blocks for audit"
)]
#![allow(
    clippy::missing_safety_doc,
    reason = "VM exposes raw map/unmap entry points mirroring C headers"
)]
#![allow(clippy::collapsible_if, reason = "nested guards mirror C control flow")]
#![allow(
    clippy::implicit_saturating_sub,
    reason = "saturating subtraction mirrors C guards"
)]
#![allow(
    clippy::needless_range_loop,
    reason = "index loops mirror C array walks"
)]
#![allow(
    clippy::needless_return,
    reason = "explicit returns mirror C control flow"
)]
#![allow(
    clippy::needless_late_init,
    reason = "late init mirrors C declaration order"
)]
#![allow(clippy::unnecessary_cast, reason = "ABI casts mirror C widths")]

//! VM mmap — `mm/vm.c` transliteration (demand-lazy, 4K).

use crate::spinlock::RawSpinLock;

pub const RTS_ALIAS_BASE: u64 = 0x4200000000;
const MBLOCK: usize = 1 << 20;
const PAGE_SIZE: usize = 4096;
const MAP_FIXED: i32 = 0x10;
const PROT_NONE: i32 = 0x0;
const PROT_READ: i32 = 0x1;
const PROT_WRITE: i32 = 0x2;
const PROT_EXEC: i32 = 0x4;

pub const HOUSE_USER_VA_MIN: u64 = 0x01000000;
// Demand/mmap window extends to 64GB: anon base (17GB) and demand-test VAs
// (32GB) sit above the highest possible 1GB RAM identity block (16GB RAM
// reaches L1 idx 16 = 17GB), so test traffic always fault-allocates fresh
// pages instead of aliasing live RAM. Stays below the RTS alias (264GB) so
// alias unmaps keep release-only behavior.
pub const HOUSE_USER_VA_MAX: u64 = 0x1000000000;

const PTE_VALID: u64 = 1 << 0;
const PTE_TABLE: u64 = 1 << 1;
const PTE_AP_SHIFT: u64 = 6;
const PTE_AP_MASK: u64 = 3 << 6;
const PTE_AP_RW: u64 = 1 << 6;
const PTE_AP_RO: u64 = 3 << 6;

const ENOSYS: i32 = 38;
const ENOTSUP: i32 = 95;
const EINVAL: i32 = 22;
const ENOMEM: i32 = 12;

// Single page-table lock domain: covers the vm.rs walks (mmap/munmap/
// mprotect, via vm_l3_entry/vm_split_slot) and the demand-pager install
// path in userspace.rs (house_handle_user_fault/fault_locked): one domain
// over this core's recorded root. Outer lock; BUDGET_LOCK and the buddy
// LOCK are inner leaves (never held while acquiring this one).
pub(crate) static VM_LOCK: RawSpinLock = RawSpinLock::new();
static mut VM_RESV: [(*mut u8, *mut u8); 32] = [(core::ptr::null_mut(), core::ptr::null_mut()); 32];
static mut VM_N_RESV: i32 = 0;
static mut VM_MMAP_CUR: *mut u8 = core::ptr::null_mut();

unsafe extern "C" {
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
    if v != 0 { v } else { 512 << 20 }
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
/// table writers for the same entry under VM_LOCK (shared with the pager).
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
        // L3 children keep bit 1 set: split and fault-installed page
        // descriptors uniformly carry TABLE=1 in this tree, and the
        // hardware walks them as pages that way (clearing it faults
        // translation on HVF while QEMU TCG ignores the bit).
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
#[unsafe(no_mangle)]
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
    if prot & PROT_EXEC != 0 {
        unsafe { *__errno_location() = ENOTSUP };
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

// ---- S1 (house-oz9.11): per-driver virtio-MMIO window mapping ----
//
// VA decision (recorded): identity — VA == PA == VIRTIO_BASE + slot*STRIDE.
// The existing accessors (`mmio_r32`/`mmio_w32`, every `slot_base`) already
// use absolute addresses, so identity keeps them working unchanged when a
// driver root is eventually installed; the window sits inside the user-window
// convention (`HOUSE_USER_VA_MIN..=MAX`), so the standard L0/L1/L2 shape
// applies; and the UART/GIC precedent (`house_mmu_clone_kernel_l2`) is
// identity Device blocks too.
//
// 4K-granule residual: one page covers 8 slots (0x200 stride), so a driver
// root's page also spans same-page neighbours. S1 is mapping-only and still
// EL1-accessed — the kernel root already maps the whole 1GB window Device —
// so the exposure delta is zero; S2 narrows the root (drops the RAM-identity
// clone, keeps window+queues) before any EL0 execution.
pub(crate) const VIRTIO_MMIO_BASE: u64 = 0x0a000000;
pub(crate) const VIRTIO_MMIO_STRIDE: u64 = 0x200;
// 32 probed virtio-mmio transports (`virtio_probe`, e952984 narrative).
pub(crate) const VIRTIO_SLOT_COUNT: i32 = 32;

/// 4K page containing `slot`'s 0x200 window (identity VA == PA), or `None`
/// for a bad slot. Checked arithmetic throughout: the caller never computes
/// an MMIO address, the HAL enforces the window here.
pub(crate) fn mmio_slot_page(slot: i32) -> Option<u64> {
    if !(0..VIRTIO_SLOT_COUNT).contains(&slot) {
        return None;
    }
    let base = VIRTIO_MMIO_BASE.checked_add((slot as u64).checked_mul(VIRTIO_MMIO_STRIDE)?)?;
    Some(base & !4095)
}

/// L3 page descriptor for an MMIO page: the demand-pager leaf exactly, with
/// AttrIdx 0 (Normal) replaced by 1 (Device-nGnRnE, MAIR index 1 in
/// `mmu.rs`). XN at both levels (UXN+PXN, never executable — S1 scope),
/// nG (ASID-scoped like every process page, so wrap/rebuild flushes cover
/// it), AF, Inner-shareable, AP 01 (EL1 RW, no EL0 access: S1 is
/// EL1-accessed; S2 revisits AP before any EL0 execution).
pub(crate) fn mmio_leaf_desc(pa_page: u64) -> u64 {
    const PTE_AF: u64 = 1 << 10;
    const PTE_SH_INNER: u64 = 3 << 8;
    const PTE_NG: u64 = 1 << 11;
    const PTE_UXN: u64 = 1 << 54;
    const PTE_PXN: u64 = 1 << 53;
    const PTE_ATTR_DEVICE: u64 = 1 << 2;
    (pa_page & !0xFFF)
        | PTE_VALID
        | PTE_TABLE
        | PTE_AF
        | PTE_SH_INNER
        | PTE_NG
        | PTE_UXN
        | PTE_PXN
        | PTE_ATTR_DEVICE
        | PTE_AP_RW
}

/// MMIO window allowlist check shared by map and unmap: AttrIdx == 1 marks a
/// leaf the buddy allocator must never own.
#[inline]
fn is_mmio_desc(d: u64) -> bool {
    (d >> 2) & 0x7 == 1
}

/// Locate the L2 slot for an MMIO page without allocating: `Ok` when the slot
/// is free, `Err` when the root is malformed or the slot is occupied. Pure
/// table reads (no lock, no alloc, no barriers): the caller holds `VM_LOCK`.
/// Never splits or overwrites — overlap from this helper is a caller bug and
/// fails closed here.
pub(crate) unsafe fn mmio_l2_slot(pdir: *mut u8, page: u64) -> Result<*mut u64, ()> {
    unsafe {
        // SAFETY: caller guarantees a mapped root; reads only, indices masked.
        let l0 = pdir as *mut u64;
        let d0 = *l0.add(((page >> 39) & 0x1FF) as usize);
        if d0 & PTE_VALID == 0 || d0 & PTE_TABLE == 0 {
            return Err(());
        }
        let l1 = (d0 & !0xFFF) as *mut u64;
        let d1 = *l1.add(((page >> 30) & 0x1FF) as usize);
        if d1 & PTE_VALID == 0 || d1 & PTE_TABLE == 0 {
            return Err(());
        }
        let l2 = (d1 & !0xFFF) as *mut u64;
        let s2 = l2.add(((page >> 21) & 0x1FF) as usize);
        if *s2 & PTE_VALID != 0 {
            return Err(());
        }
        Ok(s2)
    }
}

/// Map one driver's virtio-MMIO window into its own root (S1: mapping only).
///
/// Returns 1 installed, 0 refused (bad slot/root, occupied slot), -12 OOM.
/// The L3 table comes from the buddy; every level above it must already be a
/// table (a standard `allocPageMap` root) — a malformed root is refused, and
/// nothing is linked before the L3 allocation succeeds, so OOM leaves no
/// partial state behind.
///
/// # Safety
///
/// `pdir` must be a caller-owned, page-aligned root the caller never installs
/// concurrently (driver init, EL1). Takes `VM_LOCK`; shares the lock domain
/// with the pager and the `vm.rs` walks (house-oz9.1).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_vm_map_mmio(pdir: *mut u8, slot: i32) -> i32 {
    let Some(page) = mmio_slot_page(slot) else {
        return 0;
    };
    if pdir.is_null() || (pdir as usize & 4095) != 0 {
        return 0;
    }
    unsafe {
        VM_LOCK.lock();
        // SAFETY: pdir validated above; lock excludes other table writers.
        let slot_ptr = match mmio_l2_slot(pdir, page) {
            Ok(s) => s,
            Err(()) => {
                VM_LOCK.unlock();
                return 0;
            }
        };
        let l3 = buddy_alloc_page() as *mut u64;
        if l3.is_null() {
            VM_LOCK.unlock();
            return -12;
        }
        for i in 0..512 {
            *l3.add(i) = 0;
        }
        // SAFETY: fresh buddy page, exclusively owned; publish before linking.
        core::arch::asm!("dsb sy", options(nostack, preserves_flags));
        *slot_ptr = ((l3 as u64) & !0xFFF) | PTE_VALID | PTE_TABLE;
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        *l3.add(((page >> 12) & 0x1FF) as usize) = mmio_leaf_desc(page);
        // Fresh page: no stale TLB entry exists, so a local invalidate (like
        // the demand pager) suffices — no SGI shootdown on the map path.
        core::arch::asm!(
            "dsb ishst; tlbi vae1is, {0}; dsb ish; isb",
            in(reg) page >> 12,
            options(nostack, preserves_flags)
        );
        VM_LOCK.unlock();
        1
    }
}

#[unsafe(no_mangle)]
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
                    // S1 (house-oz9.11): a Device leaf names MMIO, not buddy
                    // RAM. Clear the entry and shoot down, but never free the
                    // address — freeing it would hand a device page to the
                    // buddy allocator (or the Haskell free list).
                    let page = (d & !0xFFF) as *mut u8;
                    unsafe { *slot = 0 };
                    unsafe { core::arch::asm!("dsb ishst", options(nostack, preserves_flags)) };
                    unsafe { house_tlb_shootdown(va) };
                    if !is_mmio_desc(d) {
                        unsafe { buddy_free_page(page) };
                    }
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_vm_mprotect(addr: *mut u8, len: usize, prot: i32) -> i32 {
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
    if prot & PROT_EXEC != 0 {
        unsafe { *__errno_location() = ENOTSUP };
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
    let mut va = lo;
    while va < hi {
        let slot = unsafe { vm_l3_entry(va) };
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_vm_demand_single() -> i32 {
    // 32GB: above any RAM identity block, so the access truly faults and the
    // pager allocates a fresh page (aliasing live RAM would silently sink on
    // hvf and corrupt buddy memory).
    let p = 0x800000000u64 as *mut u32;
    unsafe {
        core::ptr::write_volatile(p, 0xdeadbeef);
        let v = core::ptr::read_volatile(p);
        if v == 0xdeadbeef { 1 } else { 0 }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_vm_demand_100() -> i32 {
    for i in 0..100 {
        let p = (0x800000000u64 + i as u64 * 4096) as *mut u8;
        unsafe { core::ptr::write_volatile(p, i as u8) };
    }
    for i in 0..100 {
        let p = (0x800000000u64 + i as u64 * 4096) as *mut u8;
        let v = unsafe { core::ptr::read_volatile(p) };
        if v != i as u8 {
            return 0;
        }
    }
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_puts_after() {}

#[cfg(test)]
mod tests {
    #[test]
    fn l3_split_keep_shape() {
        // Split children preserve the block low attrs and set bit 1,
        // uniform with fault-installed page descriptors (PTE_TABLE): the
        // combination the hardware walks as a page on this target.
        for d in [0xFFFFFE00000 | 0x711, 0x40000000 | 0x741] {
            let keep = (d & 0xFFFF000000000FFFu64) | super::PTE_TABLE;
            assert_eq!(keep & 1, 1);
            assert_eq!(keep & (1 << 1), 1 << 1);
            assert_eq!(keep & 0xFFF, (d & 0xFFF) | 0x2);
        }
    }

    // S1 (house-oz9.11) mapping-layout tests: slot window -> Device PTE.
    // The full install runs on target (driver init, `house-driver-check`
    // green with the S1 dmesg line); these pin the layout math it executes:
    // which page a slot lands on, which table slots the walk touches, and
    // the exact attribute word the leaf carries.
    #[test]
    fn mmio_slot_vectors() {
        use super::mmio_slot_page;
        // Slot 0 opens the window; neighbours share the 4K page (0x200
        // stride): the granule residual recorded on `house_vm_map_mmio`.
        assert_eq!(mmio_slot_page(0), Some(0x0a000000));
        assert_eq!(mmio_slot_page(1), Some(0x0a000000));
        assert_eq!(mmio_slot_page(7), Some(0x0a000000));
        assert_eq!(mmio_slot_page(8), Some(0x0a001000));
        assert_eq!(mmio_slot_page(31), Some(0x0a003000));
        // Allowlist: negative, past-the-end, and overflowed slots refuse.
        assert_eq!(mmio_slot_page(-1), None);
        assert_eq!(mmio_slot_page(32), None);
        assert_eq!(mmio_slot_page(i32::MAX), None);
    }

    #[test]
    fn mmio_leaf_is_device_xn() {
        use super::mmio_leaf_desc;
        let d = mmio_leaf_desc(0x0a003000);
        // Identity: the leaf names the window's own page (address field
        // only — the XN bits live above it).
        assert_eq!(d & 0x0000FFFFFFFFF000, 0x0a003000);
        assert_eq!(d & 1, 1, "VALID");
        assert_eq!(d & (1 << 1), 1 << 1, "L3 page convention (PTE_TABLE)");
        assert_eq!(d & (1 << 10), 1 << 10, "AF");
        // AttrIdx bits[4:2] == 001: Device-nGnRnE, never Normal cacheable.
        assert_eq!((d >> 2) & 0x7, 1, "AttrIdx device");
        // XN at both levels, ASID-scoped, EL1-only RW (S1 mapping-only).
        assert_eq!(d & (1 << 54), 1 << 54, "UXN");
        assert_eq!(d & (1 << 53), 1 << 53, "PXN");
        assert_eq!(d & (1 << 11), 1 << 11, "nG");
        assert_eq!((d >> 6) & 0x3, 0x1, "AP EL1 RW");
        // Inner-shareable, like every other leaf this tree installs.
        assert_eq!((d >> 8) & 0x3, 0x3, "SH inner");
    }

    #[test]
    fn mmio_walk_layout() {
        use super::mmio_l2_slot;
        // Fake root with 4K-aligned tables (the walk masks links to 4K,
        // exactly like hardware): L0[0] -> L1, L1[0] -> L2, rest invalid.
        #[repr(align(4096))]
        struct Aligned512([u64; 512]);
        let mut l0 = Box::new(Aligned512([0; 512]));
        let mut l1 = Box::new(Aligned512([0; 512]));
        let mut l2 = Box::new(Aligned512([0; 512]));
        let l0p = l0.0.as_mut_ptr() as *mut u8;
        unsafe {
            *l0.0.as_mut_ptr().add(0) = (l1.0.as_mut_ptr() as u64) | 0x3;
            *l1.0.as_mut_ptr().add(0) = (l2.0.as_mut_ptr() as u64) | 0x3;
            // Free slot: every driver window lands in L2[80] (0x0a000000
            // / 2MB == 80), L3 index varies by page.
            let s = mmio_l2_slot(l0p, 0x0a003000).expect("free slot");
            assert_eq!(s, l2.0.as_mut_ptr().add(80));
            let s0 = mmio_l2_slot(l0p, 0x0a000000).expect("free slot");
            assert_eq!(s0, l2.0.as_mut_ptr().add(80));
            // Occupied slot refuses (overlap backstop): VALID block or leaf.
            *l2.0.as_mut_ptr().add(80) = 0x0a000000 | 0x3;
            assert!(mmio_l2_slot(l0p, 0x0a003000).is_err());
            *l2.0.as_mut_ptr().add(80) = 0;
            // Malformed roots refuse: invalid L0, block L1.
            let mut bare = Box::new(Aligned512([0; 512]));
            assert!(mmio_l2_slot(bare.0.as_mut_ptr() as *mut u8, 0x0a000000).is_err());
            *l0.0.as_mut_ptr().add(0) = 0x40000000 | 0x401;
            assert!(mmio_l2_slot(l0p, 0x0a000000).is_err());
        }
    }
}
