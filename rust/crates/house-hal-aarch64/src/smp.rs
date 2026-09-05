//! SMP hotplug — `house_smp_up/down/online` over PSCI + SGI handshake.
//!
//! Owner of the OFF-request flags and per-core epoch. The online mask itself
//! (`house_smp_online_mask`) stays single-owned by `house-boot` (`c_start.rs`);
//! this module accesses it via `extern` volatile reads and atomic RMW only.
//! Threaded-RTS seam: `+RTS -N<smp_n>` is synthesized in
//! house-boot `c_start` from detected cores (Max(DTB,PSCI,GICR)<=32);
//! affinity follows the live mask (offline target -> first online).

#![allow(static_mut_refs)]

use core::sync::atomic::Ordering;

pub const HOUSE_MAX_SMP: usize = 32;
const SGI_OFF: u32 = 7;

static mut OFF_REQ: [u32; 32] = [0; 32];
static mut EPOCH: [u32; 32] = [0; 32];

extern "C" {
    static mut house_smp_online_mask: u32;
    static mut house_smp_n: i32;
    fn secondary_entry();
    fn house_threads_on_core_down(core: u32);
}

fn cntvct() -> u64 {
    let v: u64;
    // SAFETY: CNTVCT_EL0 read is always safe at EL1.
    unsafe {
        core::arch::asm!("mrs {0}, cntvct_el0", out(reg) v, options(nostack, preserves_flags))
    };
    v
}

fn cntfrq() -> u64 {
    let f: u64;
    // SAFETY: CNTFRQ_EL0 read is always safe.
    unsafe {
        core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) f, options(nostack, preserves_flags))
    };
    f
}

/// Live online mask (volatile read).
///
/// # Safety
/// EL1 only; single 32-bit volatile read.
#[no_mangle]
pub unsafe extern "C" fn house_smp_online() -> u32 {
    // SAFETY: mask is u32 single-def in house-boot, volatile read is race-safe.
    unsafe { core::ptr::read_volatile(&raw const house_smp_online_mask) }
}

/// 1 when `core` has a pending OFF request (polled by the target's SGI handler).
///
/// # Safety
/// `core` is bounds-checked; out-of-range returns 0.
#[no_mangle]
pub unsafe extern "C" fn house_smp_should_off(core: u32) -> i32 {
    if (core as usize) >= HOUSE_MAX_SMP {
        return 0;
    }
    // SAFETY: OFF_REQ indexed in range, single-word read.
    unsafe {
        core::arch::asm!("dmb ishld", options(nostack, preserves_flags));
        OFF_REQ[core as usize] as i32
    }
}

/// Bring `core` online via `psci_cpu_on` + timed mask wait.
///
/// Returns 0 on success, -22 (`EINVAL`) when out of range, -16 (`EBUSY`)
/// when already online, -110 (`ETIMEDOUT`) when the core never sets its bit.
///
/// # Safety
/// EL1 only, `secondary_entry` valid, `core` is the PSCI MPIDR (0..32).
#[no_mangle]
pub unsafe extern "C" fn house_smp_up(core: u32) -> i32 {
    if (core as usize) >= HOUSE_MAX_SMP {
        return -22;
    }
    if core == 0 {
        return -16;
    }
    let bit = match 1u32.checked_shl(core) {
        Some(b) => b,
        None => return -22,
    };
    // SAFETY: volatile mask read.
    let cur = unsafe { core::ptr::read_volatile(&raw const house_smp_online_mask) };
    if cur & bit != 0 {
        return -16;
    }
    let entry = secondary_entry as *const () as u64;
    // SAFETY: HVC PSCI call with valid entry/context.
    let r = unsafe { crate::psci::psci_cpu_on(core as u64, entry, core as u64) };
    if r != 0 {
        return -5;
    }
    let freq = cntfrq();
    let t0 = cntvct();
    let limit = if freq == 0 { u64::MAX } else { freq * 5 };
    loop {
        // SAFETY: volatile mask poll.
        let m = unsafe { core::ptr::read_volatile(&raw const house_smp_online_mask) };
        if m & bit != 0 {
            // SAFETY: epoch bump, single writer (up path serialised by shell).
            unsafe { EPOCH[core as usize] = EPOCH[core as usize].wrapping_add(1) };
            return 0;
        }
        unsafe { core::arch::asm!("wfe", options(nostack, preserves_flags)) };
        if cntvct().wrapping_sub(t0) > limit {
            return -110;
        }
    }
}

/// Take `core` offline: SGI remote-off handshake then mask clear.
///
/// Refuses core 0 and offline cores, never forced. Returns 0, -22
/// (`EINVAL`), -16 (`EBUSY`, already offline), -110 (`ETIMEDOUT`).
///
/// # Safety
/// EL1 only; the target must be parked in `c_start_secondary`'s
/// `wfe`/`house_sched_yield` loop with IRQs enabled so SGI 7 lands.
#[no_mangle]
pub unsafe extern "C" fn house_smp_down(core: u32) -> i32 {
    if (core as usize) >= HOUSE_MAX_SMP {
        return -22;
    }
    if core == 0 {
        return -22;
    }
    let bit = match 1u32.checked_shl(core) {
        Some(b) => b,
        None => return -22,
    };
    // SAFETY: volatile mask read.
    let cur = unsafe { core::ptr::read_volatile(&raw const house_smp_online_mask) };
    if cur & bit == 0 {
        return -16;
    }
    // SAFETY: flag store + broadcast barrier before the SGI.
    unsafe {
        OFF_REQ[core as usize] = 1;
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        crate::gic::house_gic_send_sgi_to_core(SGI_OFF, core);
        core::arch::asm!("dsb sy; sev; isb", options(nostack, preserves_flags));
    }
    let freq = cntfrq();
    let t0 = cntvct();
    let limit = if freq == 0 { u64::MAX } else { freq * 2 };
    loop {
        // SAFETY: PSCI AFFINITY_INFO probe; 1 == OFF.
        let st = unsafe { crate::psci::psci_affinity_info(core as u64, 0) };
        if st == 1 {
            break;
        }
        if cntvct().wrapping_sub(t0) > limit {
            unsafe { OFF_REQ[core as usize] = 0 };
            return -110;
        }
        unsafe { core::arch::asm!("wfe", options(nostack, preserves_flags)) };
    }
    // SAFETY: atomic mask clear + migrate the parked run queue to core 0.
    unsafe {
        let ptr = &raw mut house_smp_online_mask as *mut core::sync::atomic::AtomicU32;
        (*ptr).fetch_and(!bit, Ordering::SeqCst);
        core::arch::asm!("dmb sy; dsb sy", options(nostack, preserves_flags));
        OFF_REQ[core as usize] = 0;
        EPOCH[core as usize] = EPOCH[core as usize].wrapping_add(1);
        house_threads_on_core_down(core);
        core::arch::asm!("dsb sy; sev", options(nostack, preserves_flags));
    }
    0
}
