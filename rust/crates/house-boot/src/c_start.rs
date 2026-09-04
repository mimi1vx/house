#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(clippy::manual_c_str_literals)]
#![allow(clippy::missing_safety_doc)]
#![allow(clippy::collapsible_if)]
#![allow(clippy::unnecessary_cast)]
#![allow(clippy::too_many_lines)]
#![allow(clippy::manual_saturating_arithmetic)]
#![allow(unused_variables)]
#![allow(dead_code)]

//! `c_start` + exception ownership — `platform/aarch64/c_start.c:50-357` transliteration.
//!
//! Owns `house_smp_n` / `house_smp_online_mask` single-def (SOTA Rust 03).
//! All helpers are `extern "C"` resolved by `ld -T build/aarch64.ld`; when `RUST=1`
//! this crate supplies `c_start` symbols and `build/c_start.o` is not linked.

use core::sync::atomic::Ordering;

core::arch::global_asm!(
    r#"
    .weak house_main
    .weak house_irqcheck_main
    .weak house_spike_main
    .global check_house_main
    .type check_house_main, %function
check_house_main:
    adrp x0, :got:house_main
    ldr x0, [x0, :got_lo12:house_main]
    ret
    .global check_house_irqcheck_main
    .type check_house_irqcheck_main, %function
check_house_irqcheck_main:
    adrp x0, :got:house_irqcheck_main
    ldr x0, [x0, :got_lo12:house_irqcheck_main]
    ret
    .global check_house_spike_main
    .type check_house_spike_main, %function
check_house_spike_main:
    adrp x0, :got:house_spike_main
    ldr x0, [x0, :got_lo12:house_spike_main]
    ret
    "#
);

const HOUSE_MAX_SMP: usize = 32;

// Single definition — other crates declare `extern "C" static mut house_smp_n`.
#[no_mangle]
pub static mut house_smp_n: i32 = 2;

#[no_mangle]
pub static mut house_smp_online_mask: u32 = 1;

extern "C" {
    static mut house_ram_bytes: u64;
    static mut house_boot_stack_top: u64;
    static mut house_smp: i32;
    static mut house_ram_source: *const u8;
    static __boot_dtb: u64;
    static mut __heap_base: u8;
    static mut ttbr0_l0: [u64; 512];
    fn svc_exit_trampoline();
    fn secondary_entry();
    static mut house_in_probe: i32;
    static mut house_probe_recovery: u64;
    static mut house_probe_faulted: i32;
    fn uart_init();
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
    fn house_detect_early();
    fn house_detect_late();
    fn house_mmu_update_alias();
    fn house_irq_init();
    fn buddy_init(start: u64, end: u64);
    fn house_mem_stats(total: *mut u64, free_pages: *mut u64);
    fn house_userspace_init();
    static mut min_user_addr: *mut u8;
    static mut max_user_addr: *mut u8;
    fn house_gic_init_secondary(core: u32);
    fn house_timer_init_secondary(core: u32);
    fn house_threads_init_secondary(core: u32);
    fn house_thread_init_main();
    fn house_irq_enable();
    fn house_irq_push(intid: u32);
    fn house_sched_ipi_handler();
    fn house_sched_maybe_preempt_from_isr();
    fn house_sched_yield();
    fn psci_cpu_on(mpidr: u64, entry: u64, ctx: u64) -> i64;
    fn psci_affinity_info(mpidr: u64, lowest: u64) -> i64;
    fn psci_cpu_off() -> i64;
    fn house_smp_should_off(core: u32) -> i32;
    fn house_handle_user_fault(far: u64) -> i32;
    fn house_is_ro_page(va: u64) -> i32;
    fn house_svc_dispatch(imm: u32, x0: u64, x1: u64, x2: u64, x3: u64, gpr: *mut u64) -> i64;
    fn house_set_recorded_pdir(pdir: *mut u8);
    fn hs_init(argc: *mut i32, argv: *mut *mut *mut u8);
    fn getenv(name: *const u8) -> *mut u8;
    fn check_house_main() -> usize;
    fn check_house_irqcheck_main() -> usize;
    fn check_house_spike_main() -> usize;
}

extern "C" {
    // Access timer globals by name as C defines them (owned by house-hal-aarch64::timer)
    #[link_name = "house_isr_active"]
    static mut __c_house_isr_active: i32;
    #[link_name = "house_isr_pending"]
    static mut __c_house_isr_pending: [u64; 32];
    #[link_name = "house_timer_interval"]
    static mut __c_house_timer_interval: u32;
}

#[inline(always)]
unsafe fn cpu_id() -> u32 {
    let mpidr: u64;
    // SAFETY: mrs mpidr_el1 is always valid at EL1.
    unsafe {
        core::arch::asm!("mrs {0}, mpidr_el1", out(reg) mpidr, options(nostack, preserves_flags))
    };
    (mpidr & 0xFF) as u32
}

unsafe fn puthex(v: u64) {
    // SAFETY: uart_putc valid after uart_init.
    unsafe {
        uart_puts(b"0x\0".as_ptr());
        for i in (0..16).rev() {
            let n = ((v >> (i * 4)) & 0xF) as usize;
            let ch = b"0123456789abcdef"[n];
            uart_putc(ch);
        }
    }
}

// SAFETY: EL1 fault handler, gpr points to 896B frame saved in exception.rs vec_sync (x0-x30 @0, SP @248).
#[no_mangle]
pub unsafe extern "C" fn c_handle_sync(
    esr: u64,
    far: u64,
    elr: u64,
    gpr: *mut u64,
    _fpi: *mut u8,
) -> u64 {
    // probe guard: house_in_probe && (ec 0x24/0x25) → skip 4B
    // SAFETY: house_in_probe is i32 single-def in probe.rs, reads volatile-safe (single writer).
    let in_probe = unsafe { core::ptr::read_volatile(&raw const house_in_probe) } != 0;
    let ec = ((esr >> 26) & 0x3f) as u32;
    if in_probe && (ec == 0x24 || ec == 0x25) {
        unsafe {
            core::ptr::write_volatile(&raw mut house_probe_faulted, 1);
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        }
        return elr.wrapping_add(4);
    }
    // demand pager: EL1 faults on TTBR0 user VA (see mm/vm.rs HOUSE_USER_VA_MAX)
    {
        let is_data_abort = ec == 0x24 || ec == 0x25;
        let is_insn_abort = ec == 0x20 || ec == 0x21;
        if (is_data_abort || is_insn_abort) && (0x01000000u64..=0x1000000000u64).contains(&far) {
            // SAFETY: house_handle_user_fault allocates via buddy, sets PTE, uses dsb/isb.
            let handled = unsafe { house_handle_user_fault(far) };
            if handled != 0 {
                unsafe { core::arch::asm!("dsb ish; isb", options(nostack, preserves_flags)) };
                return elr;
            }
        }
    }
    // RO perm guard: DFSC 0x0C..0x0F, WnR=1, far in user window, AP_RO
    {
        let dfsc = esr & 0x3f;
        let is_data_abort = ec == 0x24 || ec == 0x25;
        let is_insn_abort = ec == 0x20 || ec == 0x21;
        let is_permission = (0x0C..=0x0F).contains(&dfsc);
        let wnr = ((esr >> 6) & 1) != 0;
        if (is_data_abort || is_insn_abort) && is_permission && wnr {
            if (0x01000000u64..=0x1000000000u64).contains(&far) {
                // SAFETY: checks PTE AP bits.
                let is_ro = unsafe { house_is_ro_page(far) } != 0;
                if is_ro {
                    unsafe {
                        uart_puts(b"[demand] perm fault RO far=\0".as_ptr());
                        puthex(far);
                        uart_puts(b" DFSC=\0".as_ptr());
                        puthex(dfsc);
                        uart_puts(b" ESR=\0".as_ptr());
                        puthex(esr);
                        uart_puts(b"\n\0".as_ptr());
                        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
                    }
                    return elr.wrapping_add(4);
                } else {
                    unsafe {
                        uart_puts(b"[demand] perm fault far=\0".as_ptr());
                        puthex(far);
                        uart_puts(b" DFSC=\0".as_ptr());
                        puthex(dfsc);
                        uart_puts(b"\n\0".as_ptr());
                    }
                }
            }
        }
    }
    // SVC EC 0x15 dispatch — EL0 svc #imm after probe+pager
    if ec == 0x15 {
        let spsr: u64;
        // SAFETY: mrs spsr_el1 at handler (EL1).
        unsafe {
            core::arch::asm!("mrs {0}, spsr_el1", out(reg) spsr, options(nostack, preserves_flags))
        };
        let is_el0 = (spsr & 0xF) == 0;
        if is_el0 {
            let svc_imm = (esr & 0xFFFF) as u32;
            // SAFETY: gpr valid 32*8, house_svc_dispatch reads x0..x3 and may write gpr[0].
            let _r = unsafe {
                let x0 = if gpr.is_null() { 0 } else { *gpr.add(0) };
                let x1 = if gpr.is_null() { 0 } else { *gpr.add(1) };
                let x2 = if gpr.is_null() { 0 } else { *gpr.add(2) };
                let x3 = if gpr.is_null() { 0 } else { *gpr.add(3) };
                house_svc_dispatch(svc_imm, x0, x1, x2, x3, gpr)
            };
            if svc_imm == 0x02 {
                // EXIT: restore kernel TTBR0 and return to EL1 trampoline
                // SAFETY: ttbr0_l0 is kernel L0, EL1 only.
                unsafe {
                    house_set_recorded_pdir(ttbr0_l0.as_mut_ptr() as *mut u8);
                    core::arch::asm!("msr ttbr0_el1, {0}", in(reg) ttbr0_l0.as_ptr() as u64, options(nostack, preserves_flags));
                    core::arch::asm!(
                        "dsb ish; tlbi vmalle1is; dsb ish; isb",
                        options(nostack, preserves_flags)
                    );
                    core::arch::asm!("msr spsr_el1, {0}", in(reg) 0x3c5u64, options(nostack, preserves_flags));
                }
                return svc_exit_trampoline as *const () as u64;
            }
            return elr;
        }
        unsafe {
            uart_puts(b"[svc] EL1 SVC unexpected imm=\0".as_ptr());
            puthex(esr & 0xFFFF);
            uart_puts(b"\n\0".as_ptr());
        }
    }
    unsafe {
        uart_puts(b"[probe] in_probe=\0".as_ptr());
        uart_putc(if in_probe { b'1' } else { b'0' });
        uart_puts(b" ec=\0".as_ptr());
        puthex(esr);
        uart_puts(b" far=\0".as_ptr());
        puthex(far);
        uart_puts(b" elr=\0".as_ptr());
        puthex(elr);
        uart_puts(b" rec=\0".as_ptr());
        puthex(core::ptr::read_volatile(&raw const house_probe_recovery));
        uart_puts(b"\n\0".as_ptr());
        uart_puts(b"\n[house] fatal sync exception ESR=\0".as_ptr());
        puthex(esr);
        uart_puts(b" FAR=\0".as_ptr());
        puthex(far);
        uart_puts(b" ELR=\0".as_ptr());
        puthex(elr);
        if ec == 0x25 {
            let insn = core::ptr::read_volatile(elr as *const u32) as u64;
            uart_puts(b" INSN=\0".as_ptr());
            puthex(insn);
            for q in 0..=30 {
                let c = if q < 10 {
                    b'0' + q as u8
                } else {
                    b'a' + q as u8 - 10
                };
                uart_puts(b" x\0".as_ptr());
                uart_putc(c);
                uart_putc(b'=');
                let v = if gpr.is_null() { 0 } else { *gpr.add(q) };
                for k in (0..16).rev() {
                    uart_putc(b"0123456789abcdef"[((v >> (k * 4)) & 0xF) as usize]);
                }
            }
        }
        uart_puts(b"\n\0".as_ptr());
        loop {
            core::arch::asm!("wfi", options(nostack, preserves_flags))
        }
    }
}

// SAFETY: IRQ handler, reads ICC_IAR1_EL1, may push to irq ring or rearm timer.
#[no_mangle]
pub unsafe extern "C" fn c_handle_irq(_gpr: *mut u64, _fpi: *mut u8) {
    let iar: u64;
    // SAFETY: EL1 GIC SRE enabled, ICC_IAR1_EL1 valid.
    unsafe {
        core::arch::asm!("mrs {0}, ICC_IAR1_EL1", out(reg) iar, options(nostack, preserves_flags))
    };
    let intid = (iar & 0xFFFFFF) as u32;
    if intid == 1023 {
        return;
    }
    if intid == 0 {
        // SGI IPI 0: scheduler kick
        unsafe {
            house_sched_ipi_handler();
            core::arch::asm!("msr ICC_EOIR1_EL1, {0}", in(reg) iar, options(nostack, preserves_flags));
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        }
        return;
    }
    if intid == 1 {
        // SGI 1: TLB shootdown
        unsafe {
            core::arch::asm!(
                "dsb ish; tlbi vmalle1is; dsb ish; isb",
                options(nostack, preserves_flags)
            );
            core::arch::asm!("msr ICC_EOIR1_EL1, {0}", in(reg) iar, options(nostack, preserves_flags));
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        }
        return;
    }
    if intid == 7 {
        // SGI 7: SMP-OFF remote handshake — self-off when flagged.
        let me = unsafe { cpu_id() };
        let want = unsafe { house_smp_should_off(me) };
        unsafe {
            core::arch::asm!("msr ICC_EOIR1_EL1, {0}", in(reg) iar, options(nostack, preserves_flags));
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        }
        if want != 0 {
            unsafe {
                core::arch::asm!(
                    "dsb sy; tlbi vmalle1is; dsb sy; isb",
                    options(nostack, preserves_flags)
                );
                let _ = psci_cpu_off();
                // If CPU_OFF returns (refused), park until re-kicked.
                loop {
                    core::arch::asm!("wfe", options(nostack, preserves_flags));
                }
            }
        }
        return;
    }
    if intid == 27 {
        // SAFETY: rearm virtual timer, tick via house_isr_pending
        unsafe {
            let iv = core::ptr::read_volatile(&raw const __c_house_timer_interval) as u64;
            core::arch::asm!("msr CNTV_TVAL_EL0, {0}", in(reg) iv, options(nostack, preserves_flags));
            core::arch::asm!("isb", options(nostack, preserves_flags));
            let core_id = cpu_id() as usize;
            if core::ptr::read_volatile(&raw const __c_house_isr_active) != 0
                && core_id < HOUSE_MAX_SMP
            {
                let p = &raw mut __c_house_isr_pending as *mut [u64; 32] as *mut u64;
                let slot = p.add(core_id);
                // Use atomic fetch_add equivalent
                let atomic = &*(slot as *const core::sync::atomic::AtomicU64);
                atomic.fetch_add(1, Ordering::SeqCst);
            }
            house_sched_maybe_preempt_from_isr();
        }
    } else if intid == 29 || intid == 30 {
        unsafe {
            let iv = core::ptr::read_volatile(&raw const __c_house_timer_interval) as u64;
            core::arch::asm!("msr CNTP_TVAL_EL0, {0}", in(reg) iv, options(nostack, preserves_flags));
            core::arch::asm!("isb", options(nostack, preserves_flags));
        }
    } else {
        unsafe { house_irq_push(intid) };
    }
    unsafe {
        core::arch::asm!("msr ICC_EOIR1_EL1, {0}", in(reg) iar, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn fatal_exception() {
    let esr: u64;
    let far: u64;
    let elr: u64;
    unsafe {
        core::arch::asm!("mrs {0}, esr_el1", out(reg) esr, options(nostack, preserves_flags));
        core::arch::asm!("mrs {0}, far_el1", out(reg) far, options(nostack, preserves_flags));
        core::arch::asm!("mrs {0}, elr_el1", out(reg) elr, options(nostack, preserves_flags));
        uart_puts(b"\n[house] fatal exception ESR=\0".as_ptr());
        puthex(esr);
        uart_puts(b" FAR=\0".as_ptr());
        puthex(far);
        uart_puts(b" ELR=\0".as_ptr());
        puthex(elr);
        uart_puts(b"\n\0".as_ptr());
        loop {
            core::arch::asm!("wfi", options(nostack, preserves_flags))
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn c_start_secondary(core_id: u64) {
    let core = core_id as u32;
    // SAFETY: early secondary, DAIF masked, per-core init.
    unsafe {
        let mpidr: u64;
        core::arch::asm!("mrs {0}, mpidr_el1", out(reg) mpidr, options(nostack, preserves_flags));
        uart_puts(b"[house] c_start_secondary core=\0".as_ptr());
        uart_putc(b'0' + (core / 10) as u8);
        uart_putc(b'0' + (core % 10) as u8);
        uart_puts(b" mpidr=\0".as_ptr());
        puthex(mpidr);
        uart_puts(b"\n\0".as_ptr());
        // Epoch guard for PSCI OFF->ON re-entry: stale TLB entries from the
        // OFF window must die before re-init.
        core::arch::asm!(
            "dsb ishst; tlbi vmalle1is; dsb ish; isb",
            options(nostack, preserves_flags)
        );
        house_gic_init_secondary(core);
        house_timer_init_secondary(core);
        house_threads_init_secondary(core);
        // Atomic OR online mask
        {
            let ptr = &raw mut house_smp_online_mask as *mut core::sync::atomic::AtomicU32;
            (*ptr).fetch_or(1u32 << core, Ordering::SeqCst);
            core::arch::asm!("dmb sy; dsb sy; sev", options(nostack, preserves_flags));
        }
        uart_puts(b"[house] secondary core=\0".as_ptr());
        uart_putc(b'0' + (core / 10) as u8);
        uart_putc(b'0' + (core % 10) as u8);
        uart_puts(b" online mask=\0".as_ptr());
        puthex(core::ptr::read_volatile(&raw const house_smp_online_mask) as u64);
        uart_puts(b"\n\0".as_ptr());
        house_irq_enable();
        loop {
            core::arch::asm!("wfe", options(nostack, preserves_flags));
            house_sched_yield();
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn c_start() {
    // SAFETY: primary entry after entry.rs _start, single core, BSS clear, VBAR set, MMU early done.
    unsafe {
        uart_init();
        house_detect_early();
        {
            uart_puts(b"[house] detect early: ram=\0".as_ptr());
            puthex(core::ptr::read_volatile(&raw const house_ram_bytes));
            uart_puts(b" smp=\0".as_ptr());
            let _smp_e = core::ptr::read_volatile(&raw const house_smp);
            uart_putc(b'0' + ((_smp_e / 10) & 0xF) as u8);
            uart_putc(b'0' + ((_smp_e % 10) & 0xF) as u8);
            uart_puts(b" src=\0".as_ptr());
            uart_puts(core::ptr::read_volatile(&raw const house_ram_source));
            uart_puts(b" stack_top=\0".as_ptr());
            puthex(core::ptr::read_volatile(&raw const house_boot_stack_top));
            uart_puts(b" dtb=\0".as_ptr());
            puthex(__boot_dtb);
            uart_puts(b"\n\0".as_ptr());
        }
        {
            // Map detected RAM before rebasing sp: stack_top can sit above
            // the early 4G window (e.g. ~7G at 6G RAM); the first push after
            // rebase would fault on the unmapped window.
            house_mmu_update_alias();
            uart_puts(b"[house] mmu alias updated for ram \0".as_ptr());
            puthex(core::ptr::read_volatile(&raw const house_ram_bytes));
            uart_puts(b"\n\0".as_ptr());
        }
        {
            let core = cpu_id() as u64;
            // Per-core 64 KiB stacks: measured primary depth ~18.5K during
            // RTS bringup exceeds the old 16K and corrupts the neighbor core.
            let new_sp = core::ptr::read_volatile(&raw const house_boot_stack_top)
                .wrapping_sub(core * 65536);
            core::arch::asm!("mov sp, {0}", in(reg) new_sp, options(nostack, preserves_flags));
        }
        uart_puts(b"[house] c_start: irq_init\n\0".as_ptr());
        house_irq_init();
        {
            let pool_top = (&raw mut __heap_base as *mut u8 as u64).wrapping_add(64 << 20);
            let b_start = (pool_top.checked_add(4095).unwrap_or(u64::MAX)) & !4095u64;
            let mut b_end = core::ptr::read_volatile(&raw const house_boot_stack_top);
            // Reserve per-core 64K stacks for the detected core count (HW bound 32).
            let detected_n = core::ptr::read_volatile(&raw const house_smp) as u64;
            let detected_n = detected_n.clamp(1, HOUSE_MAX_SMP as u64);
            if let Some(reserve) = detected_n.checked_mul(65536) {
                if let Some(end) = b_end.checked_sub(reserve) {
                    b_end = end;
                }
            }
            b_end &= !4095u64;
            if b_end > b_start {
                buddy_init(b_start, b_end);
                uart_puts(b"[house] buddy: \0".as_ptr());
                puthex(b_start);
                uart_puts(b"..\0".as_ptr());
                puthex(b_end);
                uart_puts(b" pages=\0".as_ptr());
                let mut tp: u64 = 0;
                let mut fp: u64 = 0;
                house_mem_stats(&raw mut tp, &raw mut fp);
                puthex(tp);
                uart_puts(b"/\0".as_ptr());
                puthex(fp);
                uart_puts(b"\n\0".as_ptr());
                house_userspace_init();
                uart_puts(b"[house] userspace: \0".as_ptr());
                puthex(core::ptr::read_volatile(&raw const min_user_addr) as u64);
                uart_puts(b"..\0".as_ptr());
                puthex(core::ptr::read_volatile(&raw const max_user_addr) as u64);
                uart_puts(b"\n\0".as_ptr());
            }
        }
        house_detect_late();
        {
            let n = core::ptr::read_volatile(&raw const house_smp_n);
            uart_puts(b"[house] c_start: house_smp_n=\0".as_ptr());
            uart_putc(b'0' + ((n / 10) & 0xF) as u8);
            uart_putc(b'0' + ((n % 10) & 0xF) as u8);
            uart_puts(b"\n\0".as_ptr());
        }
        house_thread_init_main();
        let smp_n = core::ptr::read_volatile(&raw const house_smp_n);
        if smp_n > 1 {
            uart_puts(b"[house] smp: bringing up \0".as_ptr());
            uart_putc(b'0' + (smp_n / 10) as u8);
            uart_putc(b'0' + (smp_n % 10) as u8);
            uart_puts(b" cores\n\0".as_ptr());
            let mut boot_freq: u64 = 0;
            core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) boot_freq, options(nostack, preserves_flags));
            for i in 1..smp_n {
                let aff = psci_affinity_info(i as u64, 0);
                uart_puts(b"[house] psci aff core=\0".as_ptr());
                uart_putc(b'0' + ((i / 10) & 0xF) as u8);
                uart_putc(b'0' + ((i % 10) & 0xF) as u8);
                uart_puts(b" state=\0".as_ptr());
                puthex(aff as u64);
                uart_puts(b"\n\0".as_ptr());
                let entry = secondary_entry as *const () as u64;
                let r = psci_cpu_on(i as u64, entry, i as u64);
                uart_puts(b"[house] psci_cpu_on \0".as_ptr());
                uart_putc(b'0' + ((i / 10) & 0xF) as u8);
                uart_putc(b'0' + ((i % 10) & 0xF) as u8);
                uart_puts(b" -> \0".as_ptr());
                puthex(r as u64);
                uart_puts(b"\n\0".as_ptr());
                // Serialize ON with settle delay: hvf loses wakeups on
                // back-to-back CPU_ON at N=8; 20ms between cores.
                if boot_freq != 0 {
                    let t0: u64;
                    core::arch::asm!("mrs {0}, cntvct_el0", out(reg) t0, options(nostack, preserves_flags));
                    loop {
                        let now: u64;
                        core::arch::asm!("mrs {0}, cntvct_el0", out(reg) now, options(nostack, preserves_flags));
                        if now.wrapping_sub(t0) > boot_freq / 50 {
                            break;
                        }
                        core::arch::asm!("yield", options(nostack, preserves_flags));
                    }
                }
            }
            let mut start_ns: u64 = 0;
            let mut freq: u64 = 0;
            core::arch::asm!("mrs {0}, cntvct_el0", out(reg) start_ns, options(nostack, preserves_flags));
            core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) freq, options(nostack, preserves_flags));
            let want: u32 = if smp_n >= 32 {
                0xFFFFFFFF
            } else {
                (1u32 << smp_n) - 1
            };
            loop {
                // read mask
                let cur = core::ptr::read_volatile(&raw const house_smp_online_mask);
                if (cur & want) == want {
                    break;
                }
                core::arch::asm!("wfe", options(nostack, preserves_flags));
                let now: u64;
                core::arch::asm!("mrs {0}, cntvct_el0", out(reg) now, options(nostack, preserves_flags));
                if freq != 0 && now.wrapping_sub(start_ns) > freq * 5 {
                    break;
                }
            }
            uart_puts(b"[house] smp: \0".as_ptr());
            puthex(core::ptr::read_volatile(&raw const house_smp_online_mask) as u64);
            uart_puts(b" online mask (want \0".as_ptr());
            puthex(want as u64);
            uart_puts(b")\n\0".as_ptr());
            let cur = core::ptr::read_volatile(&raw const house_smp_online_mask);
            let mut online = 0;
            for i in 0..32 {
                if cur & (1u32 << i) != 0 {
                    online += 1;
                }
            }
            uart_puts(b"[house] smp: \0".as_ptr());
            uart_putc(b'0' + (online & 0xF) as u8);
            uart_puts(b" cores online\n\0".as_ptr());
        }
        if smp_n > 1 {
            let mut has_n = 0;
            // check existing argv for -N ( argc stored in stack var below)
            // We use same logic as C: scan argv and GHCRTS
            // Keep minimal port: only inject if not has_N
            // argc/argv are statics inside this function per C; replicate logically
            // Instead use Rust statics block
            // For now declare has_n via env check stub — if no env, inject
            // Use getenv to test GHCRTS
            let ghcrts = getenv(b"GHCRTS\0".as_ptr());
            if !ghcrts.is_null() {
                let mut p = ghcrts;
                while *p != 0 {
                    if *p == b'-' && *p.add(1) == b'N' {
                        has_n = 1;
                        break;
                    }
                    p = p.add(1);
                }
            }
            if has_n == 0 {
                // C would also scan argv; our argv is static "house" only, so injection needed
                // we will do injection below via hs_init arg tweaking
            }
            // defer actual injection to after creating nargv (handled below)
            let _ = has_n;
        }
        // RTS -N injection and hs_init
        {
            // Replicate C static argc/argv handling
            static mut ARGC: i32 = 1;
            static mut ARGV_VALS: [*mut u8; 2] =
                [b"house\0".as_ptr() as *mut u8, core::ptr::null_mut()];
            static mut ARGV_PTR: *mut *mut u8 = core::ptr::null_mut();
            static mut NB: [u8; 8] = [0; 8];
            static mut NARGV: [*mut u8; 5] = [core::ptr::null_mut(); 5];

            // initialize ARGV_PTR if null
            if core::ptr::read_volatile(&raw const ARGV_PTR).is_null() {
                core::ptr::write_volatile(&raw mut ARGV_PTR, ARGV_VALS.as_mut_ptr());
            }
            let mut argc_val = core::ptr::read_volatile(&raw const ARGC);
            let mut argv_val = core::ptr::read_volatile(&raw const ARGV_PTR);
            // scan existing argv for -N
            let mut has_n = 0;
            for i in 0..argc_val as usize {
                let arg = *argv_val.add(i);
                if !arg.is_null() && *arg == b'-' && *arg.add(1) == b'N' {
                    has_n = 1;
                }
            }
            let ghcrts = getenv(b"GHCRTS\0".as_ptr());
            if !ghcrts.is_null() {
                let mut p = ghcrts;
                while *p != 0 {
                    if *p == b'-' && *p.add(1) == b'N' {
                        has_n = 1;
                        break;
                    }
                    p = p.add(1);
                }
            }
            if smp_n > 1 && has_n == 0 {
                NB[0] = b'-';
                NB[1] = b'N';
                let mut pos = 2usize;
                let n = smp_n as i32;
                if n >= 100 {
                    NB[pos] = b'0' + ((n / 100) % 10) as u8;
                    pos += 1;
                }
                if n >= 10 {
                    NB[pos] = b'0' + ((n / 10) % 10) as u8;
                    pos += 1;
                }
                NB[pos] = b'0' + (n % 10) as u8;
                pos += 1;
                NB[pos] = 0;
                NARGV[0] = b"house\0".as_ptr() as *mut u8;
                NARGV[1] = b"+RTS\0".as_ptr() as *mut u8;
                NARGV[2] = NB.as_mut_ptr();
                NARGV[3] = b"-RTS\0".as_ptr() as *mut u8;
                NARGV[4] = core::ptr::null_mut();
                argc_val = 4;
                argv_val = NARGV.as_mut_ptr();
                core::ptr::write_volatile(&raw mut ARGC, argc_val);
                core::ptr::write_volatile(&raw mut ARGV_PTR, argv_val);
                uart_puts(b"[house] RTS \0".as_ptr());
                uart_puts(NB.as_ptr());
                uart_puts(b" injected\n\0".as_ptr());
            }
            uart_puts(b"[house] c_start: hs_init smp_n=\0".as_ptr());
            uart_putc(b'0' + ((smp_n / 10) & 0xF) as u8);
            uart_putc(b'0' + ((smp_n % 10) & 0xF) as u8);
            uart_puts(b" mask=\0".as_ptr());
            puthex(core::ptr::read_volatile(&raw const house_smp_online_mask) as u64);
            uart_puts(b"\n\0".as_ptr());
            hs_init(&raw mut ARGC, &raw mut ARGV_PTR);
            // weak dispatch — helpers return 0 if not linked
            let spike_addr = check_house_spike_main();
            let irq_addr = check_house_irqcheck_main();
            let house_addr = check_house_main();
            let has_house = house_addr != 0;
            let has_irq = irq_addr != 0;
            let has_spike = spike_addr != 0;
            // debug weak addrs
            uart_puts(b"[house] weak addrs house=\0".as_ptr());
            puthex(house_addr as u64);
            uart_puts(b" irq=\0".as_ptr());
            puthex(irq_addr as u64);
            uart_puts(b" spike=\0".as_ptr());
            puthex(spike_addr as u64);
            uart_puts(b"\n\0".as_ptr());
            if has_house {
                let f: extern "C" fn() = core::mem::transmute(house_addr as *const ());
                f();
            } else if has_irq {
                let f: extern "C" fn() = core::mem::transmute(irq_addr as *const ());
                f();
            } else if has_spike {
                let f: extern "C" fn() = core::mem::transmute(spike_addr as *const ());
                f();
            } else {
                uart_puts(b"[house] no main\n\0".as_ptr());
            }
        }
        uart_puts(b"[house] c_start: returned, halting\n\0".as_ptr());
        loop {
            core::arch::asm!("wfi", options(nostack, preserves_flags))
        }
    }
}
