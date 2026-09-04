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

#[no_mangle]
pub static mut house_in_probe: i32 = 0;
#[no_mangle]
pub static mut house_probe_recovery: u64 = 0;
#[no_mangle]
pub static mut house_probe_faulted: i32 = 0;

#[inline(never)]
unsafe fn probe_addr(addr: u64) -> bool {
    // SAFETY: sets house_in_probe and recovery, then LDR that may fault. c_handle_sync checks house_in_probe and DFSC 0x04..0x07.
    unsafe {
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
        house_in_probe = 0;
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

#[no_mangle]
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
