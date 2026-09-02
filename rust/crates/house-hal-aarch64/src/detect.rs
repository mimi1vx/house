//! RAM/SMP auto-detect — `house_detect.c` transliteration.

const HOUSE_RAM_MIN: u64 = 128 << 20;
const HOUSE_RAM_MAX: u64 = 16 << 30;
const HOUSE_MAX_SMP: i32 = 16;
const RAM_BASE: u64 = 0x40000000;

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
    fn house_ram_probe() -> u64;
    fn psci_affinity_info(mpidr: u64, lowest: u64) -> i64;
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
}

const FALLBACK_RAM: u64 = 512 << 20; // fallback 512M matches old stub; probe should override to 4G

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
            if dtb_ram >= HOUSE_RAM_MIN && dtb_ram <= HOUSE_RAM_MAX {
                ram = dtb_ram;
                src = b"dtb\0".as_ptr();
            }
            let cpus = fdt_get_cpu_count(dtb);
            if cpus >= 1 && cpus <= HOUSE_MAX_SMP {
                smp = cpus;
            }
        }
        if ram == 0 {
            let probed = house_ram_probe();
            if probed >= HOUSE_RAM_MIN && probed <= HOUSE_RAM_MAX {
                ram = probed;
                src = b"probe\0".as_ptr();
            }
        }
        if ram == 0 {
            ram = FALLBACK_RAM;
            src = b"fallback\0".as_ptr();
        }
        ram &= !((1u64 << 21) - 1);
        if ram < HOUSE_RAM_MIN {
            ram = HOUSE_RAM_MIN;
        }
        if ram > HOUSE_RAM_MAX {
            ram = HOUSE_RAM_MAX;
        }
        // HOUSE_RAM_LIMIT_BYTES is compile-time def in C; we read via env at runtime? keep as-is.
        // In Rust we don't have compile-time def, so just keep ram.
        house_ram_bytes = ram;
        house_ram_source = src;
        house_boot_stack_top = RAM_BASE + ram - 0x200000;
        if smp != 0 {
            house_smp = smp;
        } else {
            // fallback SMP_N is compile-time; use 2 as default (matches Makefile SMP_N=2)
            house_smp = 2;
        }
        if house_smp < 1 {
            house_smp = 1;
        }
        if house_smp > HOUSE_MAX_SMP {
            house_smp = HOUSE_MAX_SMP;
        }
        // clamp to HOUSE_SMP_LIMIT if defined — not available in Rust, skip.
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_smp_detect_psci() -> i32 {
    // SAFETY: PSCI HVC may trap, but psci_affinity_info handles fallback.
    unsafe {
        let mut count: i32 = 0;
        for i in 0..32 {
            let r = psci_affinity_info(i as u64, 0);
            if r == 0 || r == 1 || r == 3 {
                count += 1;
            }
        }
        if count < 1 {
            return 0;
        }
        if count > HOUSE_MAX_SMP {
            count = HOUSE_MAX_SMP;
        }
        count
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_smp_detect_gicr() -> i32 {
    // SAFETY: GICR_TYPER at 0x080A0000+i*0x20000+0x08 MMIO, valid for virt.
    unsafe {
        const BASE: u64 = 0x080A0000;
        const STRIDE: u64 = 0x20000;
        let mut count: i32 = 0;
        for i in 0..HOUSE_MAX_SMP {
            let addr = BASE + i as u64 * STRIDE + 0x08;
            // use mmio_r32 for low, and read 64 via two? simpler use inline asm ldr 64.
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
            if count >= HOUSE_MAX_SMP {
                break;
            }
        }
        if count < 1 {
            return 0;
        }
        if count > HOUSE_MAX_SMP {
            count = HOUSE_MAX_SMP;
        }
        count
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
        let mut chosen = dtb_smp;
        let mut src: *const u8 = b"dtb\0".as_ptr();
        if dtb_smp <= 0 || dtb_smp > HOUSE_MAX_SMP {
            if psci >= 1 && psci <= HOUSE_MAX_SMP {
                chosen = psci;
                src = b"psci\0".as_ptr();
            } else if gicr >= 1 && gicr <= HOUSE_MAX_SMP {
                chosen = gicr;
                src = b"gicr\0".as_ptr();
            } else {
                chosen = 2;
                src = b"fallback\0".as_ptr();
            }
        } else {
            // dtb valid, but take max if psci/gicr larger
            if psci > chosen && psci <= HOUSE_MAX_SMP {
                chosen = psci;
                src = b"psci>dtb\0".as_ptr();
            }
            if gicr > chosen && gicr <= HOUSE_MAX_SMP {
                chosen = gicr;
                src = b"gicr>dtb\0".as_ptr();
            }
        }
        if chosen < 1 {
            chosen = 1;
        }
        if chosen > HOUSE_MAX_SMP {
            chosen = HOUSE_MAX_SMP;
        }
        house_smp = chosen;
        core::ptr::write_volatile(&raw mut house_smp_n, chosen);
        // minimal log
        uart_puts(b"[house] detect late: smp dtb=\0".as_ptr());
        // print numbers as ascii (simple)
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
