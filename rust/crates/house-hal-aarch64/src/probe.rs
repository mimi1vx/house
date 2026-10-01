#![allow(unused_assignments)]
//! Fault-trapped RAM probe — `house_probe.c` transliteration.
//!
//! Open-ended: double from 128M until the first fault, bounded only by TCR
//! PA capacity (256G contiguous from RAM_BASE). Read-only LDR as before;
//! never a store-test. The DTB path normally skips this entirely — it runs
//! only on DTB-missing boots. Only the flat `.bin` Linux-path boot (x0=DTB)
//! is supported; without a DTB, hvf reads past RAM can succeed and the probe
//! may over-claim by design.

const HOUSE_RAM_BASE: u64 = 0x40000000;
/// TCR/L1 capacity bound matching `detect.rs`/`mmu.rs` (256 1G blocks).
const PROBE_MAX: u64 = 256 << 30;

#[unsafe(no_mangle)]
pub static mut house_in_probe: i32 = 0;
#[unsafe(no_mangle)]
pub static mut house_probe_recovery: u64 = 0;
#[unsafe(no_mangle)]
pub static mut house_probe_faulted: i32 = 0;
#[unsafe(no_mangle)]
pub static mut house_probe_core: u64 = 0;
#[unsafe(no_mangle)]
pub static mut house_probe_addr: u64 = 0;
static mut PROBE_NEST: u32 = 0;

#[inline(never)]
unsafe fn probe_addr(addr: u64) -> bool {
    // SAFETY: records core + probed address with a nesting count, then LDR
    // that may fault. The handler only swallows a data abort (EC 0x24/0x25)
    // on the probing core with FAR equal to the recorded address.
    unsafe {
        let mut me: u64;
        core::arch::asm!("mrs {0}, mpidr_el1", out(reg) me, options(nostack, preserves_flags));
        house_probe_core = me & 0xFF;
        house_probe_addr = addr;
        PROBE_NEST = PROBE_NEST.saturating_add(1);
        house_in_probe = 1;
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        let after: u64;
        let mut tmp: u64 = 0;
        core::arch::asm!(
            "adr {after}, 2f",
            "str {after}, [{recov}]",
            "ldr {tmp}, [{addr}]",
            "2:",
            "dsb sy; isb",
            after = out(reg) after,
            recov = in(reg) &raw mut house_probe_recovery as *mut u64 as u64,
            addr = in(reg) addr,
            tmp = inout(reg) tmp,
            options(nostack),
        );
        PROBE_NEST = PROBE_NEST.saturating_sub(1);
        if PROBE_NEST == 0 {
            house_in_probe = 0;
        }
        let f = house_probe_faulted;
        house_probe_faulted = 0;
        if f != 0 {
            false
        } else {
            let _ = tmp;
            true
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_ram_probe() -> u64 {
    // SAFETY: called early, single core, fault handler watches house_in_probe.
    unsafe {
        let mut size: u64 = 128 << 20;
        let mut last_ok: u64 = 0;
        while size <= PROBE_MAX {
            let Some(addr) = HOUSE_RAM_BASE
                .checked_add(size)
                .and_then(|e| e.checked_sub(8))
            else {
                break;
            };
            if probe_addr(addr) {
                last_ok = size;
                let Some(next) = size.checked_mul(2) else {
                    break;
                };
                // Progress guarantee: checked_mul on nonzero never returns same.
                size = next;
            } else {
                break;
            }
        }
        last_ok
    }
}
