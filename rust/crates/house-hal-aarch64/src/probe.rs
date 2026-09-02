#![allow(unused_assignments)]
//! Fault-trapped RAM probe — `house_probe.c` transliteration.

const HOUSE_RAM_BASE: u64 = 0x40000000;

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
        // Use raw pointer for recovery address: label after LDR.
        let after: u64;
        // We need to capture address of label `2f` via `adr`.
        // Use explicit assembly with local label.
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
        const SIZES: [u64; 8] = [
            16 << 30,
            8 << 30,
            4 << 30,
            2 << 30,
            1 << 30,
            512 << 20,
            256 << 20,
            128 << 20,
        ];
        for sz in SIZES {
            let addr = HOUSE_RAM_BASE + sz - 8;
            if probe_addr(addr) {
                return sz;
            }
        }
        0
    }
}
