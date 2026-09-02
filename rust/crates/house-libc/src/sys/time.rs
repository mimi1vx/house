#![allow(clippy::all)]
#[no_mangle]
pub unsafe extern "C" fn house_uptime_ns() -> u64 {
    let c: u64;
    unsafe { core::arch::asm!("mrs {0}, cntpct_el0", out(reg) c, options(nomem, nostack)) };
    // cntfrq
    let f: u64;
    unsafe { core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) f, options(nomem, nostack)) };
    let freq = if f == 0 { 62500000 } else { f };
    ((c as u128 * 1000000000u128) / freq as u128) as u64
}
