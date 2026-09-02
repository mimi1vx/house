//! GICv3 driver — `gic.c` transliteration.

use crate::mmio::{mmio_r32, mmio_w32};

const GICD_BASE: u64 = 0x08000000;
const GICR_BASE: u64 = 0x080A0000;
const GICR_STRIDE: u64 = 0x20000;
const GICR_WAKER_OFF: u64 = 0x14;
const GICR_SGI_OFF: u64 = 0x10000;
const GICR_IGROUPR0: u64 = GICR_SGI_OFF + 0x80;
const GICR_ISENABLER0: u64 = GICR_SGI_OFF + 0x100;
const GICR_ICENABLER0: u64 = GICR_SGI_OFF + 0x180;

// SGI for scheduler IPI — same as irq.h SGI_IPI (0)
const SGI_IPI: u32 = 0;

#[inline]
fn gicr_base(core: u32) -> u64 {
    GICR_BASE + core as u64 * GICR_STRIDE
}

unsafe fn gic_enable_sre() {
    unsafe {
        let mut s: u64;
        core::arch::asm!("mrs {0}, ICC_SRE_EL1", out(reg) s, options(nostack, preserves_flags));
        s |= 1;
        core::arch::asm!("msr ICC_SRE_EL1, {0}", in(reg) s, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
        s = 0xff;
        core::arch::asm!("msr ICC_PMR_EL1, {0}", in(reg) s, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
        s = 1;
        core::arch::asm!("msr ICC_IGRPEN1_EL1, {0}", in(reg) s, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
        s = 0;
        core::arch::asm!("msr ICC_BPR1_EL1, {0}", in(reg) s, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_gic_init() {
    unsafe {
        gic_enable_sre();
        let waker = gicr_base(0) + GICR_WAKER_OFF;
        let mut w = mmio_r32(waker);
        w &= !(1u32 << 1);
        mmio_w32(waker, w);
        for _ in 0..1000000 {
            w = mmio_r32(waker);
            if w & (1u32 << 2) == 0 {
                break;
            }
        }
        let igr = gicr_base(0) + GICR_IGROUPR0;
        let mut gr = mmio_r32(igr);
        gr |= (1u32 << 27) | (1u32 << 29) | (1u32 << 30) | (1u32 << SGI_IPI) | (1u32 << 1);
        mmio_w32(igr, gr);
        let ctlr = mmio_r32(GICD_BASE);
        mmio_w32(GICD_BASE, ctlr | 0x02);
        let isen = gicr_base(0) + GICR_ISENABLER0;
        mmio_w32(
            isen,
            (1u32 << 27) | (1u32 << 29) | (1u32 << 30) | (1u32 << SGI_IPI) | (1u32 << 1),
        );
        core::arch::asm!("mrs {0}, ICC_SRE_EL1", out(reg) _ , options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_gic_init_secondary(core: u32) {
    unsafe {
        let waker = gicr_base(core) + GICR_WAKER_OFF;
        let mut w = mmio_r32(waker);
        w &= !(1u32 << 1);
        mmio_w32(waker, w);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        for _ in 0..1000000 {
            w = mmio_r32(waker);
            if w & (1u32 << 2) == 0 {
                break;
            }
        }
        let igr = gicr_base(core) + GICR_IGROUPR0;
        let mut gr = mmio_r32(igr);
        gr |= (1u32 << 27) | (1u32 << 29) | (1u32 << 30) | (1u32 << SGI_IPI) | (1u32 << 1);
        mmio_w32(igr, gr);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        let isen = gicr_base(core) + GICR_ISENABLER0;
        mmio_w32(
            isen,
            (1u32 << 27) | (1u32 << 29) | (1u32 << 30) | (1u32 << SGI_IPI) | (1u32 << 1),
        );
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        gic_enable_sre();
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_gic_enable_int(intid: u32) {
    unsafe {
        if intid < 32 {
            let mut mpidr: u64;
            core::arch::asm!("mrs {0}, mpidr_el1", out(reg) mpidr, options(nostack, preserves_flags));
            let core = (mpidr & 0xFF) as u32;
            mmio_w32(gicr_base(core) + GICR_ISENABLER0, 1u32 << intid);
        } else {
            let off = 0x100u64 + (intid / 32) as u64 * 4;
            mmio_w32(GICD_BASE + off, 1u32 << (intid % 32));
            let igr = GICD_BASE + 0x80 + (intid / 32) as u64 * 4;
            let mut v = mmio_r32(igr);
            v |= 1u32 << (intid % 32);
            mmio_w32(igr, v);
        }
        core::arch::asm!("isb; dsb sy", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_gic_disable_int(intid: u32) {
    unsafe {
        if intid < 32 {
            let mut mpidr: u64;
            core::arch::asm!("mrs {0}, mpidr_el1", out(reg) mpidr, options(nostack, preserves_flags));
            let core = (mpidr & 0xFF) as u32;
            mmio_w32(gicr_base(core) + GICR_ICENABLER0, 1u32 << intid);
        } else {
            let off = 0x180u64 + (intid / 32) as u64 * 4;
            mmio_w32(GICD_BASE + off, 1u32 << (intid % 32));
        }
        core::arch::asm!("isb; dsb sy", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_gic_send_sgi_to_core(sgi_id: u32, core: u32) {
    let aff3 = (core >> 24) & 0xff;
    let aff2 = (core >> 16) & 0xff;
    let aff1 = (core >> 8) & 0xff;
    let rs = (core >> 4) & 0xf;
    let bit = 1u64 << (core & 0xf);
    let v = (aff3 as u64) << 48
        | (rs as u64) << 44
        | (aff2 as u64) << 32
        | ((sgi_id & 0xf) as u64) << 24
        | (aff1 as u64) << 16
        | bit;
    unsafe {
        core::arch::asm!("msr ICC_SGI1R_EL1, {0}", in(reg) v, options(nostack, preserves_flags));
        core::arch::asm!("isb; dsb sy", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_gic_send_sgi(sgi_id: u32, aff0_mask: u32) {
    if aff0_mask == 0 {
        return;
    }
    for core in 0..16 {
        if aff0_mask & (1u32 << core) != 0 {
            unsafe { house_gic_send_sgi_to_core(sgi_id, core as u32) };
        }
    }
    for core in 16..32 {
        if aff0_mask & (1u32 << core) != 0 {
            unsafe { house_gic_send_sgi_to_core(sgi_id, core as u32) };
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_gic_enable_sgi(id: u32) {
    unsafe { house_gic_enable_int(id) }
}

#[no_mangle]
pub unsafe extern "C" fn house_gic_eoi(iar: u32) {
    unsafe {
        core::arch::asm!("msr ICC_EOIR1_EL1, {0}", in(reg) iar as u64, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_irq_enable() {
    unsafe {
        core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_irq_disable() {
    unsafe {
        core::arch::asm!("msr daifset, #2", options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}
