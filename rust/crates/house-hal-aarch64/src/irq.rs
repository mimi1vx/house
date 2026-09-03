//! SPSC ring 256+pipe — `irq.c` transliteration.

#![allow(dead_code)]

use crate::virtio_transport::{virtio_transport_ack, virtio_transport_interrupt_status};

const RING_SZ: usize = 256;
const RING_MASK: usize = 255;

static mut RING_BUF: [u32; 256] = [0; 256];
static mut RING_HEAD: u32 = 0;
static mut RING_TAIL: u32 = 0;
static mut PIPE_R: i32 = -1;
static mut PIPE_W: i32 = -1;

extern "C" {
    fn pipe(fds: *mut i32) -> i32;
    fn write(fd: i32, buf: *const u8, n: usize) -> isize;
    fn read(fd: i32, buf: *mut u8, n: usize) -> isize;
    fn house_gic_init();
    fn house_timer_init();
    fn house_irq_enable();
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
    fn house_fd_pipe_readable(fd: i32) -> i32;
}

#[no_mangle]
pub unsafe extern "C" fn house_irq_init() {
    // SAFETY: called early, single core, BSS clear.
    unsafe {
        house_gic_init();
        let mut fds = [0i32; 2];
        if pipe(fds.as_mut_ptr()) == 0 {
            PIPE_R = fds[0];
            PIPE_W = fds[1];
            uart_puts(b"[house] irq: pipe r=\0".as_ptr());
            uart_putc(b'0' + (PIPE_R % 10) as u8);
            uart_puts(b" w=\0".as_ptr());
            uart_putc(b'0' + (PIPE_W % 10) as u8);
            uart_puts(b"\n\0".as_ptr());
        } else {
            uart_puts(b"[house] irq: pipe create failed\n\0".as_ptr());
        }
        house_timer_init();
        house_irq_enable();
        uart_puts(b"[house] irq ok\n\0".as_ptr());
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_irq_push(intid: u32) {
    // SAFETY: producer is c_handle_irq (IRQ masked, single core) — lock-free, no races on head.
    // Ack a pending virtio used-ring interrupt at the source first: the level
    // stays asserted until acked, and an unacked completion refires instantly,
    // starving the interrupted thread (livelock — polled drivers never run to
    // consume the ring). The Endpoint forward below still delivers one message
    // per completion; the used ring itself is consumed by the driver's poll.
    // Slot SPIs are 48..56 (32 + 16 + slot); MMIO only, no locks, no alloc.
    if (48..56).contains(&intid) {
        let slot = (intid - 48) as i32;
        if unsafe { virtio_transport_interrupt_status(slot) } & 1 != 0 {
            unsafe { virtio_transport_ack(slot, 1) };
        }
    }
    unsafe {
        let h = RING_HEAD;
        let t = RING_TAIL;
        if h.wrapping_sub(t) >= RING_SZ as u32 {
            return;
        }
        RING_BUF[(h as usize) & RING_MASK] = intid;
        core::arch::asm!("dmb ishst", options(nostack, preserves_flags));
        RING_HEAD = h.wrapping_add(1);
        core::arch::asm!("dmb ish", options(nostack, preserves_flags));
        if PIPE_W >= 0 {
            let c = intid as u8;
            // SAFETY: PIPE_W is valid pipe write end, write 1 byte, ignore errors.
            let _ = write(PIPE_W, &c as *const u8, 1);
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_irq_pop() -> i32 {
    unsafe {
        let t = RING_TAIL;
        let h = RING_HEAD;
        if t == h {
            return -1;
        }
        let v = RING_BUF[(t as usize) & RING_MASK];
        core::arch::asm!("dmb ishld", options(nostack, preserves_flags));
        RING_TAIL = t.wrapping_add(1);
        v as i32
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_irq_pipe_fd() -> i32 {
    unsafe { PIPE_R }
}

#[no_mangle]
pub unsafe extern "C" fn house_irq_pipe_drain() {
    unsafe {
        if PIPE_R < 0 {
            return;
        }
        let mut buf = [0u8; 64];
        // SAFETY: PIPE_R is valid read end, buf valid.
        while read(PIPE_R, buf.as_mut_ptr(), buf.len()) > 0 {}
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_irq_pipe_readable(fd: i32) -> i32 {
    // SAFETY: house_fd_pipe_readable is poll-like check.
    unsafe { house_fd_pipe_readable(fd) }
}
