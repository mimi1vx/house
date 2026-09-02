//! Virtio transport — `virtio_transport.c` transliteration (minimal for probe).

use crate::mmio::{mmio_r32, mmio_w32};

const BASE_H: u64 = 0x0a000000;
const STRIDE_H: u64 = 0x200;
const NUM_SLOTS_H: i32 = 8;
const MAGIC_H: u32 = 0x74726976;

const OFF_MAGIC: u64 = 0x000;
const OFF_VERSION: u64 = 0x004;
const OFF_DEVICE_ID: u64 = 0x008;
const OFF_DEVICE_FEATURES: u64 = 0x010;
const OFF_DEVICE_FEATURES_SEL: u64 = 0x014;
const OFF_DRIVER_FEATURES: u64 = 0x020;
const OFF_DRIVER_FEATURES_SEL: u64 = 0x024;
const OFF_QUEUE_SEL: u64 = 0x030;
const OFF_QUEUE_NUM_MAX: u64 = 0x034;
const OFF_QUEUE_NUM: u64 = 0x038;
const OFF_QUEUE_READY: u64 = 0x044;
const OFF_QUEUE_NOTIFY: u64 = 0x050;
const OFF_INTERRUPT_STATUS: u64 = 0x060;
const OFF_INTERRUPT_ACK: u64 = 0x064;
const OFF_STATUS: u64 = 0x070;
const OFF_QUEUE_DESC_LOW: u64 = 0x080;
const OFF_QUEUE_DESC_HIGH: u64 = 0x084;
const OFF_QUEUE_AVAIL_LOW: u64 = 0x090;
const OFF_QUEUE_AVAIL_HIGH: u64 = 0x094;
const OFF_QUEUE_USED_LOW: u64 = 0x0A0;
const OFF_QUEUE_USED_HIGH: u64 = 0x0A4;

const STATUS_ACK: u32 = 0x01;
const STATUS_DRIVER: u32 = 0x02;
const STATUS_FEATURES_OK: u32 = 0x08;
const STATUS_FAILED: u32 = 0x80;

const VIRTIO_F_VERSION_1: u64 = 1 << 32;
const VIRTIO_F_RING_EVENT_IDX: u64 = 1 << 29;

const VIRTIO_OK: i32 = 0;
const VIRTIO_ERR_BAD_SLOT: i32 = -1;
const VIRTIO_ERR_BAD_VERSION: i32 = -2;
const VIRTIO_ERR_NEEDS_RESET: i32 = -3;
const VIRTIO_ERR_FEATURES_MISMATCH: i32 = -4;
const VIRTIO_ERR_INVAL: i32 = -9;

#[inline]
fn slot_base(slot: i32) -> u64 {
    BASE_H + slot as u64 * STRIDE_H
}
#[inline]
fn slot_valid(slot: i32) -> bool {
    slot >= 0 && slot < NUM_SLOTS_H
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_dc_flush(pa: u64, len: usize) {
    if len == 0 {
        return;
    }
    // SAFETY: pa is Normal WB, length-checked.
    unsafe {
        core::arch::asm!("dmb ish", options(nostack, preserves_flags));
        let start = pa & !63;
        let end = pa + len as u64;
        let mut p = start;
        while p < end {
            core::arch::asm!("dc cvac, {0}", in(reg) p, options(nostack, preserves_flags));
            p += 64;
        }
        core::arch::asm!("dsb sy; dmb ish", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_get_status(slot: i32, status: *mut u32) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if status.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    unsafe {
        let base = slot_base(slot);
        *status = mmio_r32(base + OFF_STATUS);
    }
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_set_status(slot: i32, status: u32) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    unsafe {
        let base = slot_base(slot);
        mmio_w32(base + OFF_STATUS, status);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_init(slot: i32, lo: *mut u32, hi: *mut u32) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    unsafe {
        let base = slot_base(slot);
        let magic = mmio_r32(base + OFF_MAGIC);
        let ver = mmio_r32(base + OFF_VERSION);
        if magic != MAGIC_H {
            return VIRTIO_ERR_BAD_VERSION;
        }
        if ver != 1 && ver != 2 {
            return VIRTIO_ERR_BAD_VERSION;
        }
        let did = mmio_r32(base + OFF_DEVICE_ID);
        if did == 0 {
            return VIRTIO_ERR_BAD_VERSION;
        }
        mmio_w32(base + OFF_STATUS, 0);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        mmio_w32(base + OFF_STATUS, STATUS_ACK | STATUS_DRIVER);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        if !lo.is_null() {
            mmio_w32(base + OFF_DEVICE_FEATURES_SEL, 0);
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
            *lo = mmio_r32(base + OFF_DEVICE_FEATURES);
        }
        if !hi.is_null() {
            mmio_w32(base + OFF_DEVICE_FEATURES_SEL, 1);
            core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
            *hi = mmio_r32(base + OFF_DEVICE_FEATURES);
        }
        let st = mmio_r32(base + OFF_STATUS);
        if st & STATUS_FAILED != 0 {
            return VIRTIO_ERR_NEEDS_RESET;
        }
        VIRTIO_OK
    }
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_set_features(slot: i32, wanted: u64) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    unsafe {
        let base = slot_base(slot);
        let magic = mmio_r32(base + OFF_MAGIC);
        let ver = mmio_r32(base + OFF_VERSION);
        if magic != MAGIC_H {
            return VIRTIO_ERR_BAD_VERSION;
        }
        if ver != 1 && ver != 2 {
            return VIRTIO_ERR_BAD_VERSION;
        }
        mmio_w32(base + OFF_DEVICE_FEATURES_SEL, 0);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        let dev_lo = mmio_r32(base + OFF_DEVICE_FEATURES);
        mmio_w32(base + OFF_DEVICE_FEATURES_SEL, 1);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        let dev_hi = mmio_r32(base + OFF_DEVICE_FEATURES);
        let dev = ((dev_hi as u64) << 32) | dev_lo as u64;
        let neg = dev & wanted;
        let neg_lo = neg as u32;
        let neg_hi = (neg >> 32) as u32;
        mmio_w32(base + OFF_DRIVER_FEATURES_SEL, 0);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        mmio_w32(base + OFF_DRIVER_FEATURES, neg_lo);
        mmio_w32(base + OFF_DRIVER_FEATURES_SEL, 1);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        mmio_w32(base + OFF_DRIVER_FEATURES, neg_hi);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        let mut st = mmio_r32(base + OFF_STATUS);
        st |= STATUS_FEATURES_OK;
        mmio_w32(base + OFF_STATUS, st);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        st = mmio_r32(base + OFF_STATUS);
        if st & STATUS_FAILED != 0 {
            return VIRTIO_ERR_NEEDS_RESET;
        }
        if st & STATUS_FEATURES_OK == 0 {
            return VIRTIO_ERR_FEATURES_MISMATCH;
        }
        VIRTIO_OK
    }
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_queue_max(slot: i32, max: *mut u32) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if max.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    unsafe {
        let base = slot_base(slot);
        mmio_w32(base + OFF_QUEUE_SEL, 0);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        *max = mmio_r32(base + OFF_QUEUE_NUM_MAX);
    }
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_queue_max_q(slot: i32, qidx: i32, max: *mut u32) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if qidx < 0 || qidx > 7 {
        return VIRTIO_ERR_INVAL;
    }
    if max.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    unsafe {
        let base = slot_base(slot);
        mmio_w32(base + OFF_QUEUE_SEL, qidx as u32);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        *max = mmio_r32(base + OFF_QUEUE_NUM_MAX);
    }
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_queue_setup(
    slot: i32,
    desc_pa: u64,
    avail_pa: u64,
    used_pa: u64,
    qsize: u32,
) -> i32 {
    unsafe { virtio_transport_queue_setup_q(slot, 0, desc_pa, avail_pa, used_pa, qsize) }
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_queue_setup_q(
    slot: i32,
    qidx: i32,
    desc_pa: u64,
    avail_pa: u64,
    used_pa: u64,
    qsize: u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if qidx < 0 || qidx > 7 {
        return VIRTIO_ERR_INVAL;
    }
    unsafe {
        let base = slot_base(slot);
        mmio_w32(base + OFF_QUEUE_SEL, qidx as u32);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        mmio_w32(base + OFF_QUEUE_NUM, qsize);
        mmio_w32(base + OFF_QUEUE_DESC_LOW, (desc_pa & 0xFFFFFFFF) as u32);
        mmio_w32(base + OFF_QUEUE_DESC_HIGH, (desc_pa >> 32) as u32);
        mmio_w32(base + OFF_QUEUE_AVAIL_LOW, (avail_pa & 0xFFFFFFFF) as u32);
        mmio_w32(base + OFF_QUEUE_AVAIL_HIGH, (avail_pa >> 32) as u32);
        mmio_w32(base + OFF_QUEUE_USED_LOW, (used_pa & 0xFFFFFFFF) as u32);
        mmio_w32(base + OFF_QUEUE_USED_HIGH, (used_pa >> 32) as u32);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
        mmio_w32(base + OFF_QUEUE_READY, 1);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_notify(slot: i32, qidx: u32) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    unsafe {
        let base = slot_base(slot);
        mmio_w32(base + OFF_QUEUE_NOTIFY, qidx);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_interrupt_status(slot: i32) -> u32 {
    if !slot_valid(slot) {
        return 0;
    }
    unsafe { mmio_r32(slot_base(slot) + OFF_INTERRUPT_STATUS) }
}

#[no_mangle]
pub unsafe extern "C" fn virtio_transport_ack(slot: i32, mask: u32) {
    if !slot_valid(slot) {
        return;
    }
    unsafe {
        mmio_w32(slot_base(slot) + OFF_INTERRUPT_ACK, mask);
        core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    }
}
