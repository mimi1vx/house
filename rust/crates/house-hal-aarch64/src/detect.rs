//! RAM/SMP auto-detect — `house_detect.c` transliteration.
//!
//! Purely dynamic: DTB `reg` via x0 → fault probe → 512M fallback. No
//! build-time LIMIT vars and no geometry caps — `-m` is the only knob and one
//! `.bin` boots at any geometry. Residual 32-core ceiling is physical, not
//! configurable: `OFF_REQ`/`EPOCH[32]`, `house_smp_online_mask u32`, and
//! `house_isr_pending[32]` tables plus `__early_stacks` reservation are sized
//! for 32 (see `aarch64.ld`), so counts are clamped to that HW bound with a
//! comment, never a `-DHOUSE_*` define. RAM is bounded only by TCR/L1
//! capacity (256G contiguous from `RAM_BASE`); larger DTB sums clamp there.

const RAM_BASE: u64 = 0x40000000;
/// TCR/L1 identity-map capacity: `mmu.rs` maps 1G blocks for L1 idx 1..255.
/// Larger DTB sums clamp here (checked math, never wrap).
const HOUSE_RAM_TCR_MAX: u64 = 256 << 30;
const STACK_RESERVE: u64 = 0x200000;
/// HW table bound (see module docs): 32-entry OFF/EPOCH/mask/pending tables.
const HOUSE_HW_SMP_MAX: i32 = 32;

#[no_mangle]
pub static mut house_ram_bytes: u64 = 0;
#[no_mangle]
pub static mut house_boot_stack_top: u64 = 0;
#[no_mangle]
pub static mut house_smp: i32 = 0;
#[no_mangle]
pub static mut house_ram_source: *const u8 = b"unknown\0".as_ptr();

extern "C" {
    static __boot_dtb: u64;
    static mut house_smp_n: i32;
}

extern "C" {
    fn fdt_valid(dtb: *const u8) -> i32;
    fn fdt_get_ram_bytes(dtb: *const u8) -> u64;
    fn fdt_get_cpu_count(dtb: *const u8) -> i32;
    fn fdt_ram_bank_count(dtb: *const u8) -> i32;
    fn fdt_get_ram_bank(dtb: *const u8, idx: i32, base: *mut u64, size: *mut u64) -> i32;
    fn house_ram_probe() -> u64;
    fn psci_affinity_info(mpidr: u64, lowest: u64) -> i64;
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
}

const FALLBACK_RAM: u64 = 512 << 20;

unsafe fn puthex(v: u64) {
    // SAFETY: uart_putc valid after uart_init (detect_early runs after it).
    unsafe {
        uart_puts(b"0x\0".as_ptr());
        for i in (0..16).rev() {
            let n = ((v >> (i * 4)) & 0xF) as usize;
            uart_putc(b"0123456789abcdef"[n]);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_detect_early() {
    // SAFETY: called early with BSS clear, single core, DAIF masked.
    unsafe {
        let mut ram: u64 = 0;
        let mut src: *const u8 = b"fallback\0".as_ptr();
        let mut smp: i32 = 0;
        let dtb = __boot_dtb as *const u8;
        if fdt_valid(dtb) != 0 {
            let dtb_ram = fdt_get_ram_bytes(dtb);
            if dtb_ram != 0 {
                ram = dtb_ram;
                src = b"dtb\0".as_ptr();
            }
            // DTB CPU count taken at face value up to the HW table bound.
            let cpus = fdt_get_cpu_count(dtb);
            if cpus >= 1 {
                smp = if cpus > HOUSE_HW_SMP_MAX {
                    HOUSE_HW_SMP_MAX
                } else {
                    cpus
                };
            }
            // Contiguity log from RAM_BASE (QEMU virt is one bank at 0x40000000).
            let nbanks = fdt_ram_bank_count(dtb);
            uart_puts(b"[house] dtb banks=\0".as_ptr());
            uart_putc(b'0' + (nbanks.min(9).max(0)) as u8);
            uart_puts(b"\n\0".as_ptr());
            if nbanks > 0 {
                let mut b0: u64 = 0;
                let mut s0: u64 = 0;
                if fdt_get_ram_bank(dtb, 0, &raw mut b0, &raw mut s0) != 0 {
                    uart_puts(b"[house] bank0 base=\0".as_ptr());
                    puthex(b0);
                    uart_puts(b" size=\0".as_ptr());
                    puthex(s0);
                    uart_puts(b"\n\0".as_ptr());
                }
            }
        }
        // Fault probe is last resort (DTB-missing boot only): on hvf, reads
        // beyond physical RAM can succeed (no stage-2 fault), so a bare-metal
        // probe false-positives. The `-kernel` flat binary boots via QEMU's
        // Linux path (x0=DTB), so DTB normally resolves first.
        if ram == 0 {
            let probed = house_ram_probe();
            if probed != 0 {
                ram = probed;
                src = b"probe\0".as_ptr();
            }
        }
        if ram == 0 {
            ram = FALLBACK_RAM;
            src = b"fallback\0".as_ptr();
        }
        // TCR capacity bound only (not a geometry cap): clamp absurd sums.
        if ram > HOUSE_RAM_TCR_MAX {
            ram = HOUSE_RAM_TCR_MAX;
        }
        // 2M alignment for the stack reservation math below.
        ram &= !(0x200000u64 - 1);
        // Arithmetic precondition: need room for the 2M stack reservation.
        if ram <= STACK_RESERVE {
            ram = FALLBACK_RAM;
            src = b"fallback\0".as_ptr();
        }
        // Stack top 2M below RAM end via checked math; buddy/MMU use it.
        let top = RAM_BASE
            .checked_add(ram)
            .and_then(|e| e.checked_sub(STACK_RESERVE));
        let Some(top) = top else {
            house_ram_bytes = FALLBACK_RAM;
            house_ram_source = b"fallback\0".as_ptr();
            house_boot_stack_top = RAM_BASE + FALLBACK_RAM - STACK_RESERVE;
            house_smp = if smp >= 1 { smp } else { 2 };
            return;
        };
        house_ram_bytes = ram;
        house_ram_source = src;
        house_boot_stack_top = top;
        if smp >= 1 {
            house_smp = smp;
        } else {
            house_smp = 2;
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_smp_detect_psci() -> i32 {
    // SAFETY: PSCI HVC may trap, but psci_affinity_info handles fallback.
    unsafe {
        let mut count: i32 = 0;
        // Probe up to the HW table bound; more cores have no OFF/pending slot.
        for i in 0..HOUSE_HW_SMP_MAX {
            let r = psci_affinity_info(i as u64, 0);
            if r == 0 || r == 1 || r == 3 {
                count += 1;
            }
        }
        if count < 1 {
            0
        } else {
            count
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_smp_detect_gicr() -> i32 {
    // SAFETY: GICR_TYPER at 0x080A0000+i*0x20000+0x08 MMIO, valid for virt.
    unsafe {
        const BASE: u64 = 0x080A0000;
        const STRIDE: u64 = 0x20000;
        let mut count: i32 = 0;
        for i in 0..HOUSE_HW_SMP_MAX {
            let Some(addr) = BASE
                .checked_add(i as u64 * STRIDE)
                .and_then(|a| a.checked_add(0x08))
            else {
                break;
            };
            let mut v: u64 = 0;
            core::arch::asm!("ldr {0}, [{1}]", out(reg) v, in(reg) addr, options(nostack, preserves_flags));
            core::arch::asm!("", options(nostack, preserves_flags));
            if i > 0 && v == 0 {
                break;
            }
            count += 1;
            if (v & (1u64 << 4)) != 0 {
                break;
            }
        }
        if count < 1 {
            0
        } else {
            count
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_detect_late() {
    // SAFETY: called after all cores possible, with heap.
    unsafe {
        let dtb = __boot_dtb as *const u8;
        let dtb_smp = if fdt_valid(dtb) != 0 {
            fdt_get_cpu_count(dtb)
        } else {
            0
        };
        let psci = house_smp_detect_psci();
        let gicr = house_smp_detect_gicr();
        // Max(DTB,PSCI,GICR), bounded only by the HW table size.
        let mut chosen = if dtb_smp >= 1 { dtb_smp } else { 0 };
        let mut src: *const u8 = b"dtb\0".as_ptr();
        if chosen < 1 {
            chosen = 2;
            src = b"fallback\0".as_ptr();
        }
        if psci > chosen {
            chosen = psci;
            src = b"psci>dtb\0".as_ptr();
        }
        if gicr > chosen {
            chosen = gicr;
            src = b"gicr>dtb\0".as_ptr();
        }
        if chosen < 1 {
            chosen = 1;
        }
        if chosen > HOUSE_HW_SMP_MAX {
            chosen = HOUSE_HW_SMP_MAX;
        }
        house_smp = chosen;
        core::ptr::write_volatile(&raw mut house_smp_n, chosen);
        uart_puts(b"[house] detect late: smp dtb=\0".as_ptr());
        let mut tmp = [b'0'; 2];
        if chosen >= 10 {
            tmp[0] = b'0' + (chosen / 10) as u8;
            tmp[1] = b'0' + (chosen % 10) as u8;
            uart_putc(tmp[0]);
            uart_putc(tmp[1]);
        } else {
            uart_putc(b'0' + chosen as u8);
        }
        uart_puts(b" src=\0".as_ptr());
        uart_puts(src);
        uart_puts(b" psci=\0".as_ptr());
        uart_putc(b'0' + (psci & 0xF) as u8);
        uart_puts(b" gicr=\0".as_ptr());
        uart_putc(b'0' + (gicr & 0xF) as u8);
        uart_puts(b"\n\0".as_ptr());
        let _ = src;
    }
}
