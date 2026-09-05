#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(clippy::all)]
//! Virtio blk — `virtio_blk.c` transliteration.

use crate::mmio::{dc_cvac_range, dc_ivac_range, mmio_r32, mmio_w32};

const BASE_H: u64 = 0x0a000000;
const STRIDE_H: u64 = 0x200;
const NUM_SLOTS_H: i32 = 8;
const MAGIC_H: u32 = 0x74726976;
const OFF_MAGIC: u64 = 0x000;
const OFF_VERSION: u64 = 0x004;
const OFF_DEVICE_ID: u64 = 0x008;
const OFF_STATUS: u64 = 0x070;
const OFF_QUEUE_DESC_LOW: u64 = 0x080;
const OFF_QUEUE_DESC_HIGH: u64 = 0x084;
const OFF_QUEUE_AVAIL_LOW: u64 = 0x090;
const OFF_QUEUE_AVAIL_HIGH: u64 = 0x094;
const OFF_QUEUE_USED_LOW: u64 = 0x0A0;
const OFF_QUEUE_USED_HIGH: u64 = 0x0A4;
const OFF_QUEUE_SEL: u64 = 0x030;
const OFF_QUEUE_NUM: u64 = 0x038;
const OFF_QUEUE_NOTIFY: u64 = 0x050;
const OFF_INTERRUPT_ACK: u64 = 0x064;

const STATUS_FAILED: u32 = 0x80;
const STATUS_FEATURES_OK: u32 = 0x08;
const STATUS_DRIVER_OK: u32 = 0x04;

const DEVICE_ID_BLK: u32 = 2;
const BLK_CFG_OFF_CAPACITY: u64 = 0x100;
const SECTORS_PER_BLOCK: u64 = 8;
const BLOCK_BYTES: u32 = 4096;
const BLK_T_IN: u32 = 0;
const BLK_T_OUT: u32 = 1;

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

struct BlkSlotState {
    avail_idx: u16,
    used_idx: u16,
    req_buf: [u8; 16],
    status_byte: u8,
    inited: u8,
    desc_pa: u64,
    avail_pa: u64,
    used_pa: u64,
    qsize: u32,
}

static mut BLK_SLOTS: [BlkSlotState; 8] = [
    BlkSlotState {
        avail_idx: 0,
        used_idx: 0,
        req_buf: [0; 16],
        status_byte: 0,
        inited: 0,
        desc_pa: 0,
        avail_pa: 0,
        used_pa: 0,
        qsize: 0,
    },
    BlkSlotState {
        avail_idx: 0,
        used_idx: 0,
        req_buf: [0; 16],
        status_byte: 0,
        inited: 0,
        desc_pa: 0,
        avail_pa: 0,
        used_pa: 0,
        qsize: 0,
    },
    BlkSlotState {
        avail_idx: 0,
        used_idx: 0,
        req_buf: [0; 16],
        status_byte: 0,
        inited: 0,
        desc_pa: 0,
        avail_pa: 0,
        used_pa: 0,
        qsize: 0,
    },
    BlkSlotState {
        avail_idx: 0,
        used_idx: 0,
        req_buf: [0; 16],
        status_byte: 0,
        inited: 0,
        desc_pa: 0,
        avail_pa: 0,
        used_pa: 0,
        qsize: 0,
    },
    BlkSlotState {
        avail_idx: 0,
        used_idx: 0,
        req_buf: [0; 16],
        status_byte: 0,
        inited: 0,
        desc_pa: 0,
        avail_pa: 0,
        used_pa: 0,
        qsize: 0,
    },
    BlkSlotState {
        avail_idx: 0,
        used_idx: 0,
        req_buf: [0; 16],
        status_byte: 0,
        inited: 0,
        desc_pa: 0,
        avail_pa: 0,
        used_pa: 0,
        qsize: 0,
    },
    BlkSlotState {
        avail_idx: 0,
        used_idx: 0,
        req_buf: [0; 16],
        status_byte: 0,
        inited: 0,
        desc_pa: 0,
        avail_pa: 0,
        used_pa: 0,
        qsize: 0,
    },
    BlkSlotState {
        avail_idx: 0,
        used_idx: 0,
        req_buf: [0; 16],
        status_byte: 0,
        inited: 0,
        desc_pa: 0,
        avail_pa: 0,
        used_pa: 0,
        qsize: 0,
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

unsafe fn queue_desc_pa(slot: i32) -> u64 {
    let base = slot_base(slot);
    let lo = unsafe { mmio_r32(base + OFF_QUEUE_DESC_LOW) } as u64;
    let hi = unsafe { mmio_r32(base + OFF_QUEUE_DESC_HIGH) } as u64;
    (hi << 32) | lo
}
unsafe fn queue_avail_pa(slot: i32) -> u64 {
    let base = slot_base(slot);
    let lo = unsafe { mmio_r32(base + OFF_QUEUE_AVAIL_LOW) } as u64;
    let hi = unsafe { mmio_r32(base + OFF_QUEUE_AVAIL_HIGH) } as u64;
    (hi << 32) | lo
}
unsafe fn queue_used_pa(slot: i32) -> u64 {
    let base = slot_base(slot);
    let lo = unsafe { mmio_r32(base + OFF_QUEUE_USED_LOW) } as u64;
    let hi = unsafe { mmio_r32(base + OFF_QUEUE_USED_HIGH) } as u64;
    (hi << 32) | lo
}

#[no_mangle]
pub unsafe extern "C" fn virtio_blk_save_queue(
    slot: i32,
    desc_pa: u64,
    avail_pa: u64,
    used_pa: u64,
    qsize: u32,
) {
    if !slot_valid(slot) {
        return;
    }
    let ss = unsafe { &mut BLK_SLOTS[slot as usize] };
    ss.desc_pa = desc_pa;
    ss.avail_pa = avail_pa;
    ss.used_pa = used_pa;
    ss.qsize = qsize;
}

#[no_mangle]
pub unsafe extern "C" fn virtio_blk_reset_slot(slot: i32) {
    if !slot_valid(slot) {
        return;
    }
    let ss = unsafe { &mut BLK_SLOTS[slot as usize] };
    ss.avail_idx = 0;
    ss.used_idx = 0;
    ss.status_byte = 0;
    ss.req_buf = [0; 16];
}

#[no_mangle]
pub unsafe extern "C" fn virtio_blk_invalidate(pa: u64, len: usize) {
    if len == 0 {
        return;
    }
    unsafe { dc_ivac_range(pa, len) };
}

#[no_mangle]
pub unsafe extern "C" fn virtio_blk_probe_capacity(slot: i32, cap: *mut u64) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if cap.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    let base = slot_base(slot);
    let magic = unsafe { mmio_r32(base + OFF_MAGIC) };
    let ver = unsafe { mmio_r32(base + OFF_VERSION) };
    if magic != MAGIC_H {
        return VIRTIO_ERR_BAD_VERSION;
    }
    if ver != 1 && ver != 2 {
        return VIRTIO_ERR_BAD_VERSION;
    }
    let did = unsafe { mmio_r32(base + OFF_DEVICE_ID) };
    if did == 0 {
        return VIRTIO_ERR_BAD_VERSION;
    }
    if did != DEVICE_ID_BLK {
        return VIRTIO_ERR_INVAL;
    }
    let lo = unsafe { mmio_r32(base + BLK_CFG_OFF_CAPACITY) } as u64;
    let hi = unsafe { mmio_r32(base + BLK_CFG_OFF_CAPACITY + 4) } as u64;
    unsafe { *cap = (hi << 32) | lo };
    VIRTIO_OK
}

unsafe fn blk_submit(
    slot: i32,
    lba_blocks: u64,
    data_pa: u64,
    nblocks: u32,
    req_id: *mut u32,
    typ: u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if nblocks != 1 {
        return VIRTIO_ERR_INVAL;
    }
    if req_id.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    if data_pa & 0xfff != 0 {
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
    if did != DEVICE_ID_BLK {
        return VIRTIO_ERR_INVAL;
    }
    let st = mmio_r32(base + OFF_STATUS);
    if st & STATUS_FAILED != 0 {
        return VIRTIO_ERR_NEEDS_RESET;
    }
    if st & (STATUS_FEATURES_OK | STATUS_DRIVER_OK) != (STATUS_FEATURES_OK | STATUS_DRIVER_OK) {
        return VIRTIO_ERR_NOT_READY;
    }
    let ss = &mut BLK_SLOTS[slot as usize];
    let mut qsize = ss.qsize;
    if qsize == 0 {
        qsize = 64;
    }
    if qsize < 3 {
        return VIRTIO_ERR_NOSPC;
    }
    let mut desc_pa = ss.desc_pa;
    let mut avail_pa = ss.avail_pa;
    let mut used_pa = ss.used_pa;
    if desc_pa == 0 || avail_pa == 0 || used_pa == 0 {
        desc_pa = queue_desc_pa(slot);
        avail_pa = queue_avail_pa(slot);
        used_pa = queue_used_pa(slot);
        if desc_pa == 0 || avail_pa == 0 || used_pa == 0 {
            return VIRTIO_ERR_NOT_READY;
        }
        ss.desc_pa = desc_pa;
        ss.avail_pa = avail_pa;
        ss.used_pa = used_pa;
        ss.qsize = qsize;
    }
    ss.qsize = qsize;
    let cap_lo = mmio_r32(base + BLK_CFG_OFF_CAPACITY) as u64;
    let cap_hi = mmio_r32(base + BLK_CFG_OFF_CAPACITY + 4) as u64;
    let capacity = (cap_hi << 32) | cap_lo;
    // SAFETY: sector arithmetic is checked — a wrapping LBA from untrusted
    // input must be rejected, not aliased into range.
    let sector = match lba_blocks.checked_mul(SECTORS_PER_BLOCK) {
        Some(s) => s,
        None => return VIRTIO_ERR_INVAL,
    };
    let nsectors = nblocks as u64 * SECTORS_PER_BLOCK;
    let end = match sector.checked_add(nsectors) {
        Some(e) => e,
        None => return VIRTIO_ERR_INVAL,
    };
    if end > capacity {
        return VIRTIO_ERR_INVAL;
    }

    let desc = desc_pa as *mut VirtqDesc;
    let avail_idx_ptr = (avail_pa + 2) as *mut u16;
    let avail_ring = (avail_pa + 4) as *mut u16;

    let idx = ss.avail_idx;
    let head = (idx % qsize as u16) as usize;
    let next1 = ((head as u32 + 1) % qsize) as usize;
    let next2 = ((head as u32 + 2) % qsize) as usize;

    let req_pa = ss.req_buf.as_ptr() as u64;
    let status_pa = &ss.status_byte as *const u8 as u64;
    // prepare req buf
    ss.req_buf[0] = (typ & 0xff) as u8;
    ss.req_buf[1] = ((typ >> 8) & 0xff) as u8;
    ss.req_buf[2] = ((typ >> 16) & 0xff) as u8;
    ss.req_buf[3] = ((typ >> 24) & 0xff) as u8;
    ss.req_buf[4] = 0;
    ss.req_buf[5] = 0;
    ss.req_buf[6] = 0;
    ss.req_buf[7] = 0;
    ss.req_buf[8] = (sector & 0xff) as u8;
    ss.req_buf[9] = ((sector >> 8) & 0xff) as u8;
    ss.req_buf[10] = ((sector >> 16) & 0xff) as u8;
    ss.req_buf[11] = ((sector >> 24) & 0xff) as u8;
    ss.req_buf[12] = ((sector >> 32) & 0xff) as u8;
    ss.req_buf[13] = ((sector >> 40) & 0xff) as u8;
    ss.req_buf[14] = ((sector >> 48) & 0xff) as u8;
    ss.req_buf[15] = ((sector >> 56) & 0xff) as u8;
    ss.status_byte = 0xff;

    let data_len = nblocks as usize * BLOCK_BYTES as usize;
    // SAFETY: pa+len is checked_add-guarded like virtio_con submit_inner —
    // dc_cvac_range skips wrapping ranges silently, so reject here instead
    // of notifying with unflushed data.
    if data_pa.checked_add(data_len as u64).is_none() {
        return VIRTIO_ERR_INVAL;
    }

    (*desc.add(head)).addr = req_pa;
    (*desc.add(head)).len = 16;
    (*desc.add(head)).flags = DESC_F_NEXT;
    (*desc.add(head)).next = next1 as u16;

    (*desc.add(next1)).addr = data_pa;
    (*desc.add(next1)).len = data_len as u32;
    (*desc.add(next1)).flags = DESC_F_NEXT;
    (*desc.add(next1)).next = next2 as u16;
    if typ == BLK_T_IN {
        (*desc.add(next1)).flags |= DESC_F_WRITE;
    }
    (*desc.add(next2)).addr = status_pa;
    (*desc.add(next2)).len = 1;
    (*desc.add(next2)).flags = DESC_F_WRITE;
    (*desc.add(next2)).next = 0;

    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    dc_cvac_range(desc_pa, qsize as usize * 16);
    dc_cvac_range(req_pa, 16);
    dc_cvac_range(data_pa, data_len);
    dc_cvac_range(status_pa, 1);

    *avail_ring.add((idx % qsize as u16) as usize) = head as u16;
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    *avail_idx_ptr = idx.wrapping_add(1);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    dc_cvac_range(avail_pa, 4096);

    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    mmio_w32(base + OFF_QUEUE_NOTIFY, 0);
    core::arch::asm!("dsb sy; dmb ish", options(nostack, preserves_flags));

    ss.avail_idx = idx.wrapping_add(1);
    *req_id = idx as u32;
    VIRTIO_OK
}

#[no_mangle]
pub unsafe extern "C" fn virtio_blk_submit_read(
    slot: i32,
    lba: u64,
    pa: u64,
    n: u32,
    id: *mut u32,
) -> i32 {
    unsafe { blk_submit(slot, lba, pa, n, id, BLK_T_IN) }
}

#[no_mangle]
pub unsafe extern "C" fn virtio_blk_submit_write(
    slot: i32,
    lba: u64,
    pa: u64,
    n: u32,
    id: *mut u32,
) -> i32 {
    unsafe { blk_submit(slot, lba, pa, n, id, BLK_T_OUT) }
}

#[no_mangle]
pub unsafe extern "C" fn virtio_blk_poll_used(
    slot: i32,
    out_id: *mut u32,
    out_status: *mut u8,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if out_id.is_null() || out_status.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    let base = slot_base(slot);
    let magic = mmio_r32(base + OFF_MAGIC);
    if magic != MAGIC_H {
        return VIRTIO_ERR_BAD_VERSION;
    }
    let ss = &mut BLK_SLOTS[slot as usize];
    let mut avail_pa = ss.avail_pa;
    let mut used_pa = ss.used_pa;
    if avail_pa == 0 || used_pa == 0 {
        avail_pa = queue_avail_pa(slot);
        used_pa = queue_used_pa(slot);
        if avail_pa == 0 || used_pa == 0 {
            return VIRTIO_ERR_NOT_READY;
        }
        ss.avail_pa = avail_pa;
        ss.used_pa = used_pa;
    }
    let used_idx_ptr = (used_pa + 2) as *const u16;
    dc_ivac_range(used_pa, 8);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    let uidx = *used_idx_ptr;
    if uidx == ss.used_idx {
        return 1;
    }
    let qsize = 64u32;
    let local = (ss.used_idx % qsize as u16) as usize;
    dc_ivac_range(used_pa + 4 + local as u64 * 8, 8);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    let used_ring = (used_pa + 4) as *const u32;
    let id = *used_ring.add(local * 2);
    dc_ivac_range(&ss.status_byte as *const u8 as u64, 1);
    core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    let st = ss.status_byte;
    mmio_w32(base + OFF_INTERRUPT_ACK, 1);
    core::arch::asm!("dsb sy; isb", options(nostack, preserves_flags));
    ss.used_idx = ss.used_idx.wrapping_add(1);
    *out_id = id;
    *out_status = st;
    0
}
