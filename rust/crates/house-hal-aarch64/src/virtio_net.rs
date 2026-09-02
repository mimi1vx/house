#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(clippy::all)]
//! Virtio net — `virtio_net.c` transliteration.

use crate::mmio::{dc_cvac_range, dc_ivac_range, mmio_r32, mmio_w32};

const BASE_H: u64 = 0x0a000000;
const STRIDE_H: u64 = 0x200;
const NUM_SLOTS_H: i32 = 8;
const MAGIC_H: u32 = 0x74726976;
const OFF_MAGIC: u64 = 0x000;
const OFF_VERSION: u64 = 0x004;
const OFF_DEVICE_ID: u64 = 0x008;
const OFF_STATUS: u64 = 0x070;
const OFF_QUEUE_NOTIFY: u64 = 0x050;
const OFF_INTERRUPT_ACK: u64 = 0x064;

const DEVICE_ID_NET: u32 = 1;
const NET_CFG_OFF_MAC: u64 = 0x100;
const HDR_SIZE: u32 = 12;

const STATUS_FAILED: u32 = 0x80;
const STATUS_FEATURES_OK: u32 = 0x08;
const STATUS_DRIVER_OK: u32 = 0x04;

const VIRTIO_OK: i32 = 0;
const VIRTIO_ERR_BAD_SLOT: i32 = -1;
const VIRTIO_ERR_BAD_VERSION: i32 = -2;
const VIRTIO_ERR_NEEDS_RESET: i32 = -3;
const VIRTIO_ERR_NOT_READY: i32 = -7;
const VIRTIO_ERR_INVAL: i32 = -9;
const VIRTIO_ERR_NOSPC: i32 = -5;

const DESC_F_NEXT: u16 = 1;
const DESC_F_WRITE: u16 = 2;

#[repr(C, packed)]
struct VirtqDesc {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
}

struct NetSlotState {
    avail_idx: [u16; 2],
    used_idx: [u16; 2],
    desc_pa: [u64; 2],
    avail_pa: [u64; 2],
    used_pa: [u64; 2],
    qsize: [u32; 2],
    inited: u8,
}

static mut NET_SLOTS: [NetSlotState; 8] = [
    NetSlotState {
        avail_idx: [0, 0],
        used_idx: [0, 0],
        desc_pa: [0, 0],
        avail_pa: [0, 0],
        used_pa: [0, 0],
        qsize: [0, 0],
        inited: 0,
    },
    NetSlotState {
        avail_idx: [0, 0],
        used_idx: [0, 0],
        desc_pa: [0, 0],
        avail_pa: [0, 0],
        used_pa: [0, 0],
        qsize: [0, 0],
        inited: 0,
    },
    NetSlotState {
        avail_idx: [0, 0],
        used_idx: [0, 0],
        desc_pa: [0, 0],
        avail_pa: [0, 0],
        used_pa: [0, 0],
        qsize: [0, 0],
        inited: 0,
    },
    NetSlotState {
        avail_idx: [0, 0],
        used_idx: [0, 0],
        desc_pa: [0, 0],
        avail_pa: [0, 0],
        used_pa: [0, 0],
        qsize: [0, 0],
        inited: 0,
    },
    NetSlotState {
        avail_idx: [0, 0],
        used_idx: [0, 0],
        desc_pa: [0, 0],
        avail_pa: [0, 0],
        used_pa: [0, 0],
        qsize: [0, 0],
        inited: 0,
    },
    NetSlotState {
        avail_idx: [0, 0],
        used_idx: [0, 0],
        desc_pa: [0, 0],
        avail_pa: [0, 0],
        used_pa: [0, 0],
        qsize: [0, 0],
        inited: 0,
    },
    NetSlotState {
        avail_idx: [0, 0],
        used_idx: [0, 0],
        desc_pa: [0, 0],
        avail_pa: [0, 0],
        used_pa: [0, 0],
        qsize: [0, 0],
        inited: 0,
    },
    NetSlotState {
        avail_idx: [0, 0],
        used_idx: [0, 0],
        desc_pa: [0, 0],
        avail_pa: [0, 0],
        used_pa: [0, 0],
        qsize: [0, 0],
        inited: 0,
    },
];

#[inline]
fn slot_base(slot: i32) -> u64 {
    BASE_H + slot as u64 * STRIDE_H
}
#[inline]
fn slot_valid(slot: i32) -> bool {
    slot >= 0 && slot < NUM_SLOTS_H
}

#[no_mangle]
pub unsafe extern "C" fn virtio_net_invalidate(pa: u64, len: usize) {
    if len == 0 {
        return;
    }
    unsafe { dc_ivac_range(pa, len) };
}

#[no_mangle]
pub unsafe extern "C" fn virtio_net_save_queues(
    slot: i32,
    rx_desc: u64,
    rx_avail: u64,
    rx_used: u64,
    tx_desc: u64,
    tx_avail: u64,
    tx_used: u64,
    qsize_rx: u32,
    qsize_tx: u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    let ss = unsafe { &mut NET_SLOTS[slot as usize] };
    ss.desc_pa[0] = rx_desc;
    ss.avail_pa[0] = rx_avail;
    ss.used_pa[0] = rx_used;
    ss.qsize[0] = qsize_rx;
    ss.desc_pa[1] = tx_desc;
    ss.avail_pa[1] = tx_avail;
    ss.used_pa[1] = tx_used;
    ss.qsize[1] = qsize_tx;
    ss.inited = 1;
    ss.avail_idx[0] = 0;
    ss.used_idx[0] = 0;
    ss.avail_idx[1] = 0;
    ss.used_idx[1] = 0;
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_net_probe_mac(slot: i32, mac: *mut u8) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if mac.is_null() {
        return VIRTIO_ERR_INVAL;
    }
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
    if did != DEVICE_ID_NET {
        return VIRTIO_ERR_INVAL;
    }
    let st = mmio_r32(base + OFF_STATUS);
    if st & STATUS_FAILED != 0 {
        return VIRTIO_ERR_NEEDS_RESET;
    }
    if st & (STATUS_FEATURES_OK | STATUS_DRIVER_OK) != (STATUS_FEATURES_OK | STATUS_DRIVER_OK) {
        return VIRTIO_ERR_NOT_READY;
    }
    for i in 0..6 {
        let addr = base + NET_CFG_OFF_MAC + i as u64;
        let v = mmio_r32(addr & !3) >> ((addr & 3) * 8) & 0xff;
        // Use ldrb via mmio_r32 shift; C uses ldrb.
        unsafe { *mac.add(i) = v as u8 };
        core::arch::asm!("", options(nostack, preserves_flags));
    }
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_net_submit_rx(
    slot: i32,
    data_pa: u64,
    len: u32,
    req_id: *mut u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if req_id.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    if data_pa & 0xfff != 0 {
        return VIRTIO_ERR_INVAL;
    }
    if len == 0 || len > 4096 {
        return VIRTIO_ERR_INVAL;
    }
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
    if did != DEVICE_ID_NET {
        return VIRTIO_ERR_INVAL;
    }
    let st = mmio_r32(base + OFF_STATUS);
    if st & STATUS_FAILED != 0 {
        return VIRTIO_ERR_NEEDS_RESET;
    }
    if st & (STATUS_FEATURES_OK | STATUS_DRIVER_OK) != (STATUS_FEATURES_OK | STATUS_DRIVER_OK) {
        return VIRTIO_ERR_NOT_READY;
    }
    let ss = unsafe { &mut NET_SLOTS[slot as usize] };
    let mut qsize = ss.qsize[0];
    let desc_pa = ss.desc_pa[0];
    let avail_pa = ss.avail_pa[0];
    if desc_pa == 0 || avail_pa == 0 {
        return VIRTIO_ERR_NOT_READY;
    }
    if qsize == 0 {
        qsize = 64;
    }
    let desc = desc_pa as *mut VirtqDesc;
    let avail_idx_ptr = (avail_pa + 2) as *mut u16;
    let avail_ring = (avail_pa + 4) as *mut u16;
    let idx = ss.avail_idx[0];
    let head = (idx % qsize as u16) as usize;
    (*desc.add(head)).addr = data_pa;
    (*desc.add(head)).len = len;
    (*desc.add(head)).flags = DESC_F_WRITE;
    (*desc.add(head)).next = 0;
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    dc_cvac_range(desc_pa + head as u64 * 16, 16);
    dc_cvac_range(data_pa, len as usize);
    *avail_ring.add((idx % qsize as u16) as usize) = head as u16;
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    *avail_idx_ptr = idx.wrapping_add(1);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    dc_cvac_range(avail_pa, 4096);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    mmio_w32(base + OFF_QUEUE_NOTIFY, 0);
    core::arch::asm!("dsb sy; dmb ish", options(nostack, preserves_flags));
    ss.avail_idx[0] = idx.wrapping_add(1);
    *req_id = idx as u32;
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_net_submit_tx(
    slot: i32,
    hdr_pa: u64,
    data_pa: u64,
    data_len: u32,
    req_id: *mut u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if req_id.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    if data_pa == 0 {
        return VIRTIO_ERR_INVAL;
    }
    if data_len == 0 || data_len > 4096 - HDR_SIZE {
        return VIRTIO_ERR_INVAL;
    }
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
    if did != DEVICE_ID_NET {
        return VIRTIO_ERR_INVAL;
    }
    let st = mmio_r32(base + OFF_STATUS);
    if st & STATUS_FAILED != 0 {
        return VIRTIO_ERR_NEEDS_RESET;
    }
    if st & (STATUS_FEATURES_OK | STATUS_DRIVER_OK) != (STATUS_FEATURES_OK | STATUS_DRIVER_OK) {
        return VIRTIO_ERR_NOT_READY;
    }
    let ss = unsafe { &mut NET_SLOTS[slot as usize] };
    let mut qsize = ss.qsize[1];
    let desc_pa = ss.desc_pa[1];
    let avail_pa = ss.avail_pa[1];
    if desc_pa == 0 || avail_pa == 0 {
        return VIRTIO_ERR_NOT_READY;
    }
    if qsize == 0 {
        qsize = 64;
    }
    if qsize < 2 {
        return VIRTIO_ERR_NOSPC;
    }
    let desc = desc_pa as *mut VirtqDesc;
    let avail_idx_ptr = (avail_pa + 2) as *mut u16;
    let avail_ring = (avail_pa + 4) as *mut u16;
    let idx = ss.avail_idx[1];
    let head = (idx % qsize as u16) as usize;
    let next1 = ((head as u32 + 1) % qsize) as usize;
    (*desc.add(head)).addr = hdr_pa;
    (*desc.add(head)).len = HDR_SIZE;
    (*desc.add(head)).flags = DESC_F_NEXT;
    (*desc.add(head)).next = next1 as u16;
    (*desc.add(next1)).addr = data_pa;
    (*desc.add(next1)).len = data_len;
    (*desc.add(next1)).flags = 0;
    (*desc.add(next1)).next = 0;
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    dc_cvac_range(desc_pa + head as u64 * 16, 16);
    dc_cvac_range(desc_pa + next1 as u64 * 16, 16);
    dc_cvac_range(hdr_pa, HDR_SIZE as usize);
    dc_cvac_range(data_pa, data_len as usize);
    *avail_ring.add((idx % qsize as u16) as usize) = head as u16;
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    *avail_idx_ptr = idx.wrapping_add(1);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    dc_cvac_range(avail_pa, 4096);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    mmio_w32(base + OFF_QUEUE_NOTIFY, 1);
    core::arch::asm!("dsb sy; dmb ish", options(nostack, preserves_flags));
    ss.avail_idx[1] = idx.wrapping_add(1);
    *req_id = idx as u32;
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_net_poll_used(
    slot: i32,
    qidx: i32,
    out_id: *mut u32,
    out_len: *mut u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if qidx < 0 || qidx > 1 {
        return VIRTIO_ERR_INVAL;
    }
    if out_id.is_null() || out_len.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    let base = slot_base(slot);
    let magic = mmio_r32(base + OFF_MAGIC);
    if magic != MAGIC_H {
        return VIRTIO_ERR_BAD_VERSION;
    }
    let ss = unsafe { &mut NET_SLOTS[slot as usize] };
    let used_pa = ss.used_pa[qidx as usize];
    if used_pa == 0 {
        return VIRTIO_ERR_NOT_READY;
    }
    let used_idx_ptr = (used_pa + 2) as *const u16;
    dc_ivac_range(used_pa, 8);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    let uidx = *used_idx_ptr;
    if uidx == ss.used_idx[qidx as usize] {
        return 1;
    }
    let mut qsize = ss.qsize[qidx as usize];
    if qsize == 0 {
        qsize = 64;
    }
    let local = (ss.used_idx[qidx as usize] % qsize as u16) as usize;
    dc_ivac_range(used_pa + 4 + local as u64 * 8, 8);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    let used_ring = (used_pa + 4) as *const u32;
    let id = *used_ring.add(local * 2);
    let len = *used_ring.add(local * 2 + 1);
    mmio_w32(base + OFF_INTERRUPT_ACK, 1);
    core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    ss.used_idx[qidx as usize] = ss.used_idx[qidx as usize].wrapping_add(1);
    *out_id = id;
    *out_len = len;
    0
}
