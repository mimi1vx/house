//! PL011 UART 0x09000000 — `uart.c` transliteration.
//!
//! `// SAFETY:` per MMIO access discharging base 0x09000000 identity-mapped.

use crate::mmio::{mmio_r32, mmio_w32};
use crate::spinlock::RawSpinLock;

const UART_BASE: u64 = 0x09000000;
const UARTDR: u64 = 0x00;
const UARTFR: u64 = 0x18;
const FR_TXFF: u32 = 1 << 5;
const FR_RXFE: u32 = 1 << 4;

// Static spinlock — matches `static house_spinlock_t uart_lock = {0}`.
static UART_LOCK: RawSpinLock = RawSpinLock::new();

#[inline]
unsafe fn mmio_w32_u(addr: u64, v: u32) {
    // SAFETY: caller guarantees MMIO addr valid.
    unsafe { mmio_w32(addr, v) }
}

#[inline]
unsafe fn mmio_r32_u(addr: u64) -> u32 {
    // SAFETY: caller guarantees MMIO addr valid.
    unsafe { mmio_r32(addr) }
}

/// void uart_init(void)
#[no_mangle]
pub unsafe extern "C" fn uart_init() {
    // SAFETY: PL011 base 0x09000000 identity-mapped by TTBR1 L1 block 0 (Device).
    unsafe {
        mmio_w32_u(UART_BASE + 0x030, 0);
        core::arch::asm!("", options(nostack, preserves_flags));
        mmio_w32_u(UART_BASE + 0x044, 0x7ff);
        core::arch::asm!("", options(nostack, preserves_flags));
        mmio_w32_u(UART_BASE + 0x024, 13);
        core::arch::asm!("", options(nostack, preserves_flags));
        mmio_w32_u(UART_BASE + 0x028, 1);
        core::arch::asm!("", options(nostack, preserves_flags));
        mmio_w32_u(UART_BASE + 0x02c, (3u32 << 5) | (1u32 << 4));
        core::arch::asm!("", options(nostack, preserves_flags));
        mmio_w32_u(UART_BASE + 0x030, (1u32 << 9) | (1u32 << 8) | 1u32);
        core::arch::asm!("", options(nostack, preserves_flags));
    }
}

/// void uart_putc(char c)
#[no_mangle]
pub unsafe extern "C" fn uart_putc(c: u8) {
    UART_LOCK.lock();
    // SAFETY: PL011 FR/DR MMIO valid while lock held; polling TXFF preserves ordering.
    unsafe {
        if c == b'\n' {
            while mmio_r32_u(UART_BASE + UARTFR) & FR_TXFF != 0 {
                core::arch::asm!("", options(nostack, preserves_flags));
            }
            mmio_w32_u(UART_BASE + UARTDR, b'\r' as u32);
        }
        while mmio_r32_u(UART_BASE + UARTFR) & FR_TXFF != 0 {
            core::arch::asm!("", options(nostack, preserves_flags));
        }
        mmio_w32_u(UART_BASE + UARTDR, c as u32);
    }
    UART_LOCK.unlock();
}

/// void uart_puts(const char *s) — null-terminated, 4K cap.
#[no_mangle]
pub unsafe extern "C" fn uart_puts(s: *const u8) {
    if s.is_null() {
        return;
    }
    UART_LOCK.lock();
    // SAFETY: s is null-terminated C string; caller guarantees nul within 4K (Haskell hPutStr/printk).
    // Cap at 4096 to avoid unbounded read if caller passes non-nul (Security 01 allowlist + defense).
    unsafe {
        let mut p = s;
        for _ in 0..4096 {
            let c = *p;
            if c == 0 {
                break;
            }
            p = p.wrapping_add(1);
            if c == b'\n' {
                while mmio_r32_u(UART_BASE + UARTFR) & FR_TXFF != 0 {
                    core::arch::asm!("", options(nostack, preserves_flags));
                }
                mmio_w32_u(UART_BASE + UARTDR, b'\r' as u32);
            }
            while mmio_r32_u(UART_BASE + UARTFR) & FR_TXFF != 0 {
                core::arch::asm!("", options(nostack, preserves_flags));
            }
            mmio_w32_u(UART_BASE + UARTDR, c as u32);
        }
    }
    UART_LOCK.unlock();
}

/// int uart_getc_blocking(void)
#[no_mangle]
pub unsafe extern "C" fn uart_getc_blocking() -> i32 {
    // SAFETY: PL011 MMIO valid.
    unsafe {
        while mmio_r32_u(UART_BASE + UARTFR) & FR_RXFE != 0 {
            core::arch::asm!("", options(nostack, preserves_flags));
        }
        (mmio_r32_u(UART_BASE + UARTDR) & 0xff) as i32
    }
}

/// int uart_getc_nonblock(void) — returns -1 if RXFE.
#[no_mangle]
pub unsafe extern "C" fn uart_getc_nonblock() -> i32 {
    // SAFETY: PL011 MMIO valid.
    unsafe {
        if mmio_r32_u(UART_BASE + UARTFR) & FR_RXFE != 0 {
            return -1;
        }
        (mmio_r32_u(UART_BASE + UARTDR) & 0xff) as i32
    }
}
