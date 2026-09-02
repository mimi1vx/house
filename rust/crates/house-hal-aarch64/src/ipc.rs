//! IPC — `ipc.c` transliteration.

#[no_mangle]
pub unsafe extern "C" fn house_ipc_svc_dispatch(_x0: u64, _x1: u64, _x2: u64, _x3: u64) -> i64 {
    // SAFETY: stub returns ENOSYS (38) until Track 6 wires EL0/TTBR0.
    -38
}

#[no_mangle]
pub unsafe extern "C" fn house_ipc_copy_msg(src: *const u8, dst: *mut u8, len: usize) {
    if src.is_null() || dst.is_null() {
        return;
    }
    // SAFETY: src/dst valid for len, no overlap needed for copy_nonoverlapping; use manual copy to avoid panic.
    unsafe {
        core::arch::asm!("dmb ish", options(nostack, preserves_flags));
        // manual byte copy to avoid `copy_nonoverlapping` precondition on null
        for i in 0..len {
            *dst.add(i) = *src.add(i);
        }
        core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    }
}
