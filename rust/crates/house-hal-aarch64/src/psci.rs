//! PSCI via HVC/SMC — `psci.c` transliteration.

unsafe fn psci_call3(fid: u64, a1: u64, a2: u64, a3: u64, use_smc: bool) -> i64 {
    let mut x0 = fid;
    let x1 = a1;
    let x2 = a2;
    let x3 = a3;
    unsafe {
        if use_smc {
            core::arch::asm!("smc #0", inout("x0") x0, in("x1") x1, in("x2") x2, in("x3") x3, options(nostack));
        } else {
            core::arch::asm!("hvc #0", inout("x0") x0, in("x1") x1, in("x2") x2, in("x3") x3, options(nostack));
        }
    }
    x0 as i64
}

#[no_mangle]
pub unsafe extern "C" fn psci_system_off() -> ! {
    unsafe {
        psci_call3(0x84000008, 0, 0, 0, false);
    }
    loop {
        unsafe { core::arch::asm!("wfi", options(nostack)) }
    }
}

#[no_mangle]
pub unsafe extern "C" fn psci_system_reset() -> ! {
    unsafe {
        psci_call3(0x84000009, 0, 0, 0, false);
    }
    loop {
        unsafe { core::arch::asm!("wfi", options(nostack)) }
    }
}

#[no_mangle]
pub unsafe extern "C" fn psci_cpu_on(mpidr: u64, entry: u64, ctx: u64) -> i64 {
    let r = unsafe { psci_call3(0xC4000003, mpidr, entry, ctx, false) };
    if r == -1 {
        // PSCI_NOT_SUPPORTED = -1
        unsafe { psci_call3(0xC4000003, mpidr, entry, ctx, true) }
    } else {
        r
    }
}

#[no_mangle]
pub unsafe extern "C" fn psci_cpu_off() -> i64 {
    let r = unsafe { psci_call3(0x84000002, 0, 0, 0, false) };
    if r == -1 {
        unsafe { psci_call3(0x84000002, 0, 0, 0, true) }
    } else {
        r
    }
}

#[no_mangle]
pub unsafe extern "C" fn psci_affinity_info(mpidr: u64, lowest: u64) -> i64 {
    let r = unsafe { psci_call3(0xC4000004, mpidr, lowest, 0, false) };
    if r == -1 {
        unsafe { psci_call3(0xC4000004, mpidr, lowest, 0, true) }
    } else {
        r
    }
}
