#![allow(
    clippy::missing_safety_doc,
    reason = "timer entry point mirrors C provenance"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_uptime_ns() -> u64 {
    let c: u64;
    unsafe { core::arch::asm!("mrs {0}, cntpct_el0", out(reg) c, options(nomem, nostack)) };
    // cntfrq
    let f: u64;
    unsafe { core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) f, options(nomem, nostack)) };
    let freq = if f == 0 { 62500000 } else { f };
    // u64-only: cntfrq is architecturally 32-bit so (c % freq) * 1e9 cannot overflow.
    (c / freq) * 1000000000 + (c % freq) * 1000000000 / freq
}
