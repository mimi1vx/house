//! EL1 virtual/physical timer — `timer.c` transliteration.

const HOUSE_MAX_SMP: usize = 16;

#[no_mangle]
pub static mut house_isr_active: i32 = 0;

#[no_mangle]
pub static mut house_isr_pending: [u64; 16] = [0; 16];

#[no_mangle]
pub static mut house_timer_interval: u32 = 0;

static mut HOUSE_BOOT_TICKS: [u64; 16] = [0; 16];

unsafe fn cntfrq() -> u64 {
    let f: u64;
    unsafe {
        core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) f, options(nostack, preserves_flags))
    }
    if f == 0 {
        62500000
    } else {
        f
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_uptime_secs() -> u64 {
    let now: u64;
    unsafe {
        core::arch::asm!("mrs {0}, cntvct_el0", out(reg) now, options(nostack, preserves_flags))
    }
    let freq = unsafe { cntfrq() };
    if freq == 0 {
        return 0;
    }
    let boot = unsafe {
        let mut mpidr: u64;
        core::arch::asm!("mrs {0}, mpidr_el1", out(reg) mpidr, options(nostack, preserves_flags));
        let core = (mpidr & 0xFF) as usize;
        if core < HOUSE_MAX_SMP && HOUSE_BOOT_TICKS[core] != 0 {
            HOUSE_BOOT_TICKS[core]
        } else {
            HOUSE_BOOT_TICKS[0]
        }
    };
    (now - boot) / freq
}

unsafe fn timer_init_for_core(core: u32) {
    if (core as usize) >= HOUSE_MAX_SMP {
        return;
    }
    let now: u64;
    unsafe {
        core::arch::asm!("mrs {0}, cntvct_el0", out(reg) now, options(nostack, preserves_flags))
    }
    unsafe {
        HOUSE_BOOT_TICKS[core as usize] = now;
    }
    let freq = unsafe { cntfrq() };
    let mut interval = unsafe { house_timer_interval };
    if interval == 0 {
        interval = (freq / 100) as u32;
        if interval == 0 {
            interval = (freq / 10) as u32;
        }
        unsafe {
            house_timer_interval = interval;
        }
    }
    unsafe {
        core::arch::asm!("msr CNTV_TVAL_EL0, {0}", in(reg) interval as u64, options(nostack, preserves_flags));
        core::arch::asm!("msr CNTV_CTL_EL0, {0}", in(reg) 1u64, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
        core::arch::asm!("msr CNTP_TVAL_EL0, {0}", in(reg) interval as u64, options(nostack, preserves_flags));
        core::arch::asm!("msr CNTP_CTL_EL0, {0}", in(reg) 1u64, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        house_isr_active = 1;
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_timer_init() {
    unsafe { timer_init_for_core(0) }
}

#[no_mangle]
pub unsafe extern "C" fn house_timer_init_secondary(core: u32) {
    unsafe { timer_init_for_core(core) }
}

#[no_mangle]
pub unsafe extern "C" fn house_timer_rearm_virt() {
    unsafe {
        let iv = house_timer_interval as u64;
        core::arch::asm!("msr CNTV_TVAL_EL0, {0}", in(reg) iv, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_timer_rearm_phys() {
    unsafe {
        let iv = house_timer_interval as u64;
        core::arch::asm!("msr CNTP_TVAL_EL0, {0}", in(reg) iv, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}
