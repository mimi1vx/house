//! Userspace EL0 ASID pager — `userspace.c` transliteration.

use crate::spinlock::RawSpinLock;

const PAGE_SIZE: usize = 4096;
const PAGE_POOL_N: usize = 512;
#[repr(align(4096))]
struct PagePool([u8; PAGE_POOL_N * PAGE_SIZE]);
static mut PAGE_POOL: PagePool = PagePool([0; PAGE_POOL_N * PAGE_SIZE]);

#[no_mangle]
pub static mut min_user_addr: *mut u8 = core::ptr::null_mut();
#[no_mangle]
pub static mut max_user_addr: *mut u8 = core::ptr::null_mut();

static mut RECORDED_PDIR: *mut u8 = core::ptr::null_mut();
static ASID_LOCK: RawSpinLock = RawSpinLock::new();
static mut NEXT_ASID: u16 = 1;
const ASID_MAP_CAP: usize = 64;
static mut ASID_MAP: [(*mut u8, u16); 64] = [(core::ptr::null_mut(), 0); 64];
static mut ASID_MAP_LEN: usize = 0;

extern "C" {
    static ttbr0_l0: [u64; 512];
    fn buddy_alloc_page() -> *mut u8;
    fn buddy_free_page(p: *mut u8);
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
    fn house_mmu_set_ttbr0(pdir: *mut u8, asid: u64);
}

#[no_mangle]
pub unsafe extern "C" fn house_userspace_init() {
    unsafe {
        if RECORDED_PDIR.is_null() {
            RECORDED_PDIR = ttbr0_l0.as_ptr() as *mut u8;
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
        if wrapped {
            // SAFETY: flush all ASIDs before reuse.
            core::arch::asm!(
                "dsb ishst; tlbi vmalle1is; dsb ish; isb",
                options(nostack, preserves_flags)
            );
        }
        if ASID_MAP_LEN < ASID_MAP_CAP {
            ASID_MAP[ASID_MAP_LEN] = (pdir, a);
            ASID_MAP_LEN += 1;
        }
        ASID_LOCK.unlock();
        a
    }
}

#[no_mangle]
pub unsafe extern "C" fn init_page_dir(pdir: *mut u8) {
    if pdir.is_null() || (pdir as usize & 4095) != 0 {
        return;
    }
    unsafe {
        let asid = asid_for_pdir(pdir) as u64;
        RECORDED_PDIR = pdir;
        house_mmu_set_ttbr0(pdir, asid);
        uart_puts(b"[userspace] init_page_dir done\n\0".as_ptr());
    }
}

#[no_mangle]
pub unsafe extern "C" fn current_pdir() -> *mut u8 {
    unsafe { RECORDED_PDIR }
}

#[no_mangle]
pub unsafe extern "C" fn house_set_recorded_pdir(pdir: *mut u8) {
    unsafe {
        RECORDED_PDIR = pdir;
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_asid_for_pdir(pdir: *mut u8) -> u64 {
    if pdir.is_null() {
        return 0;
    }
    unsafe { asid_for_pdir(pdir) as u64 }
}

#[no_mangle]
pub unsafe extern "C" fn house_is_ro_page(va: u64) -> i32 {
    let va = va & !4095;
    unsafe {
        let pdir = RECORDED_PDIR;
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
        if ap == 0x3 {
            1
        } else {
            0
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn invalidate_page(vaddr: u64) {
    unsafe {
        let va = vaddr >> 12;
        core::arch::asm!("tlbi vae1is, {0}; dsb ish; isb", in(reg) va, options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_tlb_shootdown(vaddr: u64) {
    unsafe {
        let va = vaddr >> 12;
        core::arch::asm!("dsb ishst; tlbi vae1is, {0}; dsb ish; isb", in(reg) va, options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_handle_user_fault(far: u64) -> i32 {
    const MIN_V: u64 = 0x01000000;
    // Matches mm/vm.rs HOUSE_USER_VA_MAX: demand window covers anon base
    // (17GB) and demand-test VAs (32GB), still below the RTS alias (264GB).
    const MAX_V: u64 = 0x1000000000;
    const PTE_VALID: u64 = 1 << 0;
    const PTE_TABLE: u64 = 1 << 1;
    const PTE_AF: u64 = 1 << 10;
    const PTE_SH_INNER: u64 = 3 << 8;
    const PTE_NG: u64 = 1 << 11;
    const PTE_UXN: u64 = 1 << 54;
    const PTE_PXN: u64 = 1 << 53;
    const PTE_AP_RW: u64 = 1 << 6;
    // Don't handle kernel buddy region
    if far >= 0x46000000 && far < 0x60000000 {
        return 0;
    }
    if far < MIN_V || far > MAX_V {
        return 0;
    }
    let va = far & !4095;
    unsafe {
        let pdir = RECORDED_PDIR;
        if pdir.is_null() || (pdir as usize & 4095) != 0 {
            return 0;
        }
        let page = buddy_alloc_page();
        if page.is_null() {
            return 0;
        }
        let l0 = pdir as *mut u64;
        let i0 = ((va >> 39) & 0x1FF) as usize;
        let mut d0 = *l0.add(i0);
        if d0 & PTE_VALID == 0 {
            let nl1 = buddy_alloc_page() as *mut u64;
            if nl1.is_null() {
                buddy_free_page(page);
                return 0;
            }
            for i in 0..512 {
                *nl1.add(i) = 0;
            }
            core::arch::asm!("dsb sy", options(nostack, preserves_flags));
            *l0.add(i0) = ((nl1 as u64) & !0xFFF) | PTE_VALID | PTE_TABLE;
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
                return 0;
            }
            for i in 0..512 {
                *nl2.add(i) = 0;
            }
            core::arch::asm!("dsb sy", options(nostack, preserves_flags));
            *s1 = ((nl2 as u64) & !0xFFF) | PTE_VALID | PTE_TABLE;
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
            d1 = *s1;
            l2 = (d1 & !0xFFF) as *mut u64;
        } else if d1 & PTE_TABLE == 0 {
            // 1GB block (early-boot identity RAM map): split, preserving the
            // mapping, instead of overwriting it.
            if !crate::mm::vm::vm_split_slot(s1, 1) {
                buddy_free_page(page);
                return 0;
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
                return 0;
            }
            for i in 0..512 {
                *nl3.add(i) = 0;
            }
            core::arch::asm!("dsb sy", options(nostack, preserves_flags));
            *s2 = ((nl3 as u64) & !0xFFF) | PTE_VALID | PTE_TABLE;
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
            d2 = *s2;
            l3 = (d2 & !0xFFF) as *mut u64;
        } else if d2 & PTE_TABLE == 0 {
            // 2MB block: split, preserving the mapping.
            if !crate::mm::vm::vm_split_slot(s2, 2) {
                buddy_free_page(page);
                return 0;
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
        core::arch::asm!("dsb ishst; tlbi vae1is, {0}; dsb ish; isb", in(reg) va >> 12, options(nostack, preserves_flags));
        1
    }
}
