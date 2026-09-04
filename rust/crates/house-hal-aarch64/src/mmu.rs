//! MMU TTBR0/TTBR1 split — `mmu.c` transliteration (panic-free).

const RAM_BASE: u64 = 0x40000000;

const PTE_VALID: u64 = 1 << 0;
const PTE_TABLE: u64 = 1 << 1;
const PTE_BLOCK_AF: u64 = 1 << 10;
const PTE_SH_INNER: u64 = 3 << 8;

const ATTR_NORMAL: u64 = 0;
const ATTR_DEVICE: u64 = 1;

#[repr(align(4096))]
struct Aligned512([u64; 512]);

static mut TTBR1_L0: Aligned512 = Aligned512([0; 512]);
#[no_mangle]
pub static mut ttbr0_l0: [u64; 512] = [0; 512];

static mut L1_LOW: Aligned512 = Aligned512([0; 512]);
static mut L1_RTS: Aligned512 = Aligned512([0; 512]);
static mut L2_RTS: [[u64; 512]; 8] = [[0; 512]; 8];

extern "C" {
    static house_ram_bytes: u64;
    static house_smp_n: i32;
}

#[inline]
fn tcr_value() -> u64 {
    (16u64)
        | (1u64 << 8)
        | (1u64 << 10)
        | (3u64 << 12)
        | (0u64 << 14)
        | (16u64 << 16)
        | (0u64 << 22)
        | (0u64 << 23)
        | (1u64 << 24)
        | (1u64 << 26)
        | (3u64 << 28)
        | (2u64 << 30)
        | (2u64 << 32)
}

#[inline]
fn pte_attr(n: u64) -> u64 {
    n << 2
}

unsafe fn map_block(idx: usize, attr: u64) {
    // SAFETY: idx <512 per caller, L1_LOW valid.
    unsafe {
        let p = L1_LOW.0.as_mut_ptr().wrapping_add(idx);
        *p = PTE_VALID | PTE_BLOCK_AF | PTE_SH_INNER | pte_attr(attr) | ((idx as u64) << 30);
    }
}

unsafe fn build_rts_alias(span: u64) {
    unsafe {
        // SAFETY: house_smp_n is volatile but stable after detect; read via volatile.
        let smp_n: u64 = core::ptr::read_volatile(&raw const house_smp_n) as u64;
        let smp_n = if smp_n == 0 { 2 } else { smp_n };
        let stack_reserve: u64 = 0x200000 + smp_n * 65536;
        let half = span >> 1;
        let usable_half = if half > stack_reserve {
            half - stack_reserve
        } else {
            0
        };
        let vspan64 = if usable_half > (8u64 << 30) {
            8u64 << 30
        } else {
            usable_half
        };
        let mut n_l2 = ((vspan64 + (1u64 << 30) - 1) >> 30) as usize;
        if n_l2 > 8 {
            n_l2 = 8;
        }
        let pa = RAM_BASE + half;
        let l1_low_ptr = L1_LOW.0.as_mut_ptr();
        let l1_rts_ptr = L1_RTS.0.as_mut_ptr();
        // Clear previous alias entries via raw pointers to avoid bounds checks.
        for i in 0..8 {
            let l2_ptr = L2_RTS[i].as_mut_ptr();
            for e in 0..512 {
                *l2_ptr.wrapping_add(e) = 0;
            }
            *l1_rts_ptr.wrapping_add(i) = 0;
            *l1_low_ptr.wrapping_add(264 + i) = 0;
        }
        for i in 0..n_l2 {
            let l2_addr = L2_RTS[i].as_ptr() as u64;
            *l1_rts_ptr.wrapping_add(i) = PTE_VALID | PTE_TABLE | l2_addr;
            *l1_low_ptr.wrapping_add(264 + i) = *l1_rts_ptr.wrapping_add(i);
        }
        let mut off: u64 = 0;
        while off < vspan64 {
            let t = (off >> 30) as usize;
            let e = ((off >> 21) & 511) as usize;
            let l2_ptr = L2_RTS[t].as_mut_ptr();
            *l2_ptr.wrapping_add(e) =
                PTE_VALID | PTE_BLOCK_AF | PTE_SH_INNER | pte_attr(ATTR_NORMAL) | (pa + off);
            off += 1u64 << 21;
        }
        core::arch::asm!(
            "dsb sy; tlbi vmalle1; dsb sy; isb",
            options(nostack, preserves_flags)
        );
    }
}

#[inline]
unsafe fn get_ram_bytes() -> u64 {
    unsafe { core::ptr::read_volatile(&raw const house_ram_bytes) }
}

/// void house_mmu_early(void)
#[no_mangle]
pub unsafe extern "C" fn house_mmu_early() {
    unsafe {
        let mut span = get_ram_bytes();
        if span == 0 {
            span = 4u64 << 30;
        }
        map_block(0, ATTR_DEVICE);
        let blocks = ((span + (1u64 << 30) - 1) >> 30) as usize;
        let mut i = 1usize;
        while i <= blocks && i < 256 {
            map_block(i, ATTR_NORMAL);
            i += 1;
        }
        build_rts_alias(span);
        let ttbr0_ptr = ttbr0_l0.as_mut_ptr();
        for idx in 0..512 {
            *ttbr0_ptr.wrapping_add(idx) = 0;
        }
        let ttbr1_ptr = TTBR1_L0.0.as_mut_ptr();
        for idx in 0..512 {
            *ttbr1_ptr.wrapping_add(idx) = 0;
        }
        let l1_low_addr = L1_LOW.0.as_ptr() as u64;
        *ttbr1_ptr.wrapping_add(0) = PTE_VALID | PTE_TABLE | l1_low_addr;
        *ttbr0_ptr.wrapping_add(0) = PTE_VALID | PTE_TABLE | l1_low_addr;
        let mair: u64 = 0xFF | (0x04u64 << 8);
        // SAFETY: EL1 only, MAIR/TCR/TTBR valid.
        core::arch::asm!("msr mair_el1, {0}", in(reg) mair, options(nostack, preserves_flags));
        core::arch::asm!("msr tcr_el1, {0}", in(reg) tcr_value(), options(nostack, preserves_flags));
        // SAFETY: TTBR0/TTBR1 separate: TTBR1 is kernel, TTBR0 is user (both l1_low initially, per mmu.c).
        core::arch::asm!("msr ttbr0_el1, {0}", in(reg) ttbr0_l0.as_ptr() as u64, options(nostack, preserves_flags));
        core::arch::asm!("msr ttbr1_el1, {0}", in(reg) TTBR1_L0.0.as_ptr() as u64, options(nostack, preserves_flags));
        core::arch::asm!("dsb sy", options(nostack, preserves_flags));
        core::arch::asm!("tlbi vmalle1", options(nostack, preserves_flags));
        core::arch::asm!("ic iallu", options(nostack, preserves_flags));
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        core::arch::asm!("dsb sy", options(nostack, preserves_flags));
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        let mut sctlr: u64;
        core::arch::asm!("mrs {0}, sctlr_el1", out(reg) sctlr, options(nostack, preserves_flags));
        core::arch::asm!("msr sctlr_el1, {0}", in(reg) sctlr | (1u64<<0) | (1u64<<2) | (1u64<<12), options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}

/// void house_mmu_enable_secondary(void)
#[no_mangle]
pub unsafe extern "C" fn house_mmu_enable_secondary() {
    unsafe {
        let mair: u64 = 0xFF | (0x04u64 << 8);
        core::arch::asm!("msr mair_el1, {0}", in(reg) mair, options(nostack, preserves_flags));
        core::arch::asm!("msr tcr_el1, {0}", in(reg) tcr_value(), options(nostack, preserves_flags));
        core::arch::asm!("msr ttbr0_el1, {0}", in(reg) ttbr0_l0.as_ptr() as u64, options(nostack, preserves_flags));
        core::arch::asm!("msr ttbr1_el1, {0}", in(reg) TTBR1_L0.0.as_ptr() as u64, options(nostack, preserves_flags));
        core::arch::asm!(
            "dsb sy; tlbi vmalle1; ic iallu; dsb sy; isb",
            options(nostack, preserves_flags)
        );
        let mut sctlr: u64;
        core::arch::asm!("mrs {0}, sctlr_el1", out(reg) sctlr, options(nostack, preserves_flags));
        core::arch::asm!("msr sctlr_el1, {0}", in(reg) sctlr | (1u64<<0) | (1u64<<2) | (1u64<<12), options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}

/// void house_mmu_set_ttbr0(void *pdir, uint64_t asid) — TTBR0 update with TLBI ordering.
#[no_mangle]
pub unsafe extern "C" fn house_mmu_set_ttbr0(pdir: *mut u8, asid: u64) {
    // SAFETY: pdir is page-aligned, asid 8-bit (0 reserved), EL1 only. Ordering per mmu.c.
    let v = ((pdir as u64) & !0xFFFu64) | ((asid & 0xFF) << 48);
    unsafe {
        core::arch::asm!("msr ttbr0_el1, {0}", in(reg) v, options(nostack, preserves_flags));
        // DSB ISH to ensure TTBR write completes, then ISB for pipeline.
        core::arch::asm!("dsb ish; isb", options(nostack, preserves_flags));
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
}

/// void house_mmu_clone_kernel_l1(void *new_l1)
#[no_mangle]
pub unsafe extern "C" fn house_mmu_clone_kernel_l1(new_l1: *mut u64) {
    if new_l1.is_null() {
        return;
    }
    unsafe {
        let l1_ptr = L1_LOW.0.as_ptr();
        for idx in 0..512 {
            let d = *l1_ptr.wrapping_add(idx);
            if d == 0 {
                continue;
            }
            if idx == 0 {
                continue;
            }
            *new_l1.wrapping_add(idx) = d;
        }
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
}

/// void house_mmu_clone_kernel_l2(void *new_l2)
#[no_mangle]
pub unsafe extern "C" fn house_mmu_clone_kernel_l2(new_l2: *mut u64) {
    if new_l2.is_null() {
        return;
    }
    unsafe {
        let dev080: u64 = 0x08000000 | (1 << 0) | (1 << 10) | (3 << 8) | (1 << 2);
        let dev090: u64 = 0x09000000 | (1 << 0) | (1 << 10) | (3 << 8) | (1 << 2);
        *new_l2.wrapping_add(64) = dev080;
        *new_l2.wrapping_add(72) = dev090;
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
}

/// Clear stale early-boot 1GB RAM blocks beyond detected RAM.
///
/// `house_mmu_early` runs before RAM is known and maps up to 4GB of 1GB
/// identity blocks. After detect, entries past detected RAM alias physical
/// addresses that do not exist; on hvf such accesses silently sink (reads 0)
/// instead of faulting, which breaks the demand pager and `mprotect` walks.
/// Only block descriptors are cleared — table entries (user-window root at
/// idx 0, RTS alias at 264+) are preserved.
/// # Safety
/// Single core (secondaries not up yet), EL1, `L1_LOW` live. `dsb`/`tlbi`/`isb`
/// ordered; idx 0 and table entries never touched.
unsafe fn trim_ram_blocks() {
    unsafe {
        let mut span = get_ram_bytes();
        if span == 0 {
            span = 4u64 << 30;
        }
        let blocks = ((span + (1u64 << 30) - 1) >> 30) as usize;
        let l1_low_ptr = L1_LOW.0.as_mut_ptr();
        for idx in (blocks + 1)..256 {
            let d = *l1_low_ptr.wrapping_add(idx);
            if d & PTE_VALID != 0 && d & PTE_TABLE == 0 {
                *l1_low_ptr.wrapping_add(idx) = 0;
            }
        }
        core::arch::asm!(
            "dsb sy; tlbi vmalle1is; dsb sy; isb",
            options(nostack, preserves_flags)
        );
    }
}

/// void house_mmu_update_alias(void)
#[no_mangle]
pub unsafe extern "C" fn house_mmu_update_alias() {
    unsafe {
        trim_ram_blocks();
        let span = get_ram_bytes();
        build_rts_alias(span);
    }
}

/// void house_mmu_map_kernel(uint64_t pa, uint64_t va, uint64_t size, uint64_t attr) — stub.
#[no_mangle]
pub unsafe extern "C" fn house_mmu_map_kernel(_pa: u64, _va: u64, _size: u64, _attr: u64) {}

/// void house_get_ttbrs(uint64_t *ttbr0, uint64_t *ttbr1, uint64_t *tcr)
#[no_mangle]
pub unsafe extern "C" fn house_get_ttbrs(ttbr0: *mut u64, ttbr1: *mut u64, tcr: *mut u64) {
    let mut a: u64;
    let mut b: u64;
    let mut c: u64;
    unsafe {
        core::arch::asm!("mrs {0}, ttbr0_el1", out(reg) a, options(nostack, preserves_flags));
        core::arch::asm!("mrs {0}, ttbr1_el1", out(reg) b, options(nostack, preserves_flags));
        core::arch::asm!("mrs {0}, tcr_el1", out(reg) c, options(nostack, preserves_flags));
        if !ttbr0.is_null() {
            *ttbr0 = a;
        }
        if !ttbr1.is_null() {
            *ttbr1 = b;
        }
        if !tcr.is_null() {
            *tcr = c;
        }
    }
}
