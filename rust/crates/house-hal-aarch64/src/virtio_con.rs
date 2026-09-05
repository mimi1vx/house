#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(clippy::all)]
//! Virtio console (ID 3) — `virtio_con.c` transliteration.
//! Port queues rx0/tx1 (WRITE/RX + READ/TX) plus serial control q2/q3
//! (DEVICE_READY/PORT_ADD discovery, PORT_READY/PORT_OPEN). Mirrors
//! `virtio_net.rs` queue state and cache discipline.

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
const OFF_CONFIG_MAX_PORTS: u64 = 0x104;

const DEVICE_ID_CONSOLE: u32 = 3;
// ID-11 multipoint: control RX/TX pair on queues 2/3 (PORT_READY/PORT_OPEN
// handshake). max_nr_ports is read from device config and clamped to
// 1..=32; the discovered port id selects the port queue pair.
const DEVICE_ID_SERIAL: u32 = 11;
const MAX_SERIAL_PORTS: u32 = 32;

const STATUS_FAILED: u32 = 0x80;
const STATUS_FEATURES_OK: u32 = 0x08;
const STATUS_DRIVER_OK: u32 = 0x04;

const VIRTIO_OK: i32 = 0;
const VIRTIO_ERR_BAD_SLOT: i32 = -1;
const VIRTIO_ERR_BAD_VERSION: i32 = -2;
const VIRTIO_ERR_NEEDS_RESET: i32 = -3;
const VIRTIO_ERR_NOT_READY: i32 = -7;
const VIRTIO_ERR_INVAL: i32 = -9;

const DESC_F_WRITE: u16 = 2;

#[repr(C, packed)]
struct VirtqDesc {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
}

struct ConSlotState {
    avail_idx: [u16; 4],
    used_idx: [u16; 4],
    desc_pa: [u64; 4],
    avail_pa: [u64; 4],
    used_pa: [u64; 4],
    qsize: [u32; 4],
    port_qrx: u32,
    port_qtx: u32,
    inited: u8,
}

static mut CON_SLOTS: [ConSlotState; 8] = [
    ConSlotState {
        avail_idx: [0, 0, 0, 0],
        used_idx: [0, 0, 0, 0],
        desc_pa: [0, 0, 0, 0],
        avail_pa: [0, 0, 0, 0],
        used_pa: [0, 0, 0, 0],
        qsize: [0, 0, 0, 0],
        port_qrx: 0,
        port_qtx: 1,
        inited: 0,
    },
    ConSlotState {
        avail_idx: [0, 0, 0, 0],
        used_idx: [0, 0, 0, 0],
        desc_pa: [0, 0, 0, 0],
        avail_pa: [0, 0, 0, 0],
        used_pa: [0, 0, 0, 0],
        qsize: [0, 0, 0, 0],
        port_qrx: 0,
        port_qtx: 1,
        inited: 0,
    },
    ConSlotState {
        avail_idx: [0, 0, 0, 0],
        used_idx: [0, 0, 0, 0],
        desc_pa: [0, 0, 0, 0],
        avail_pa: [0, 0, 0, 0],
        used_pa: [0, 0, 0, 0],
        qsize: [0, 0, 0, 0],
        port_qrx: 0,
        port_qtx: 1,
        inited: 0,
    },
    ConSlotState {
        avail_idx: [0, 0, 0, 0],
        used_idx: [0, 0, 0, 0],
        desc_pa: [0, 0, 0, 0],
        avail_pa: [0, 0, 0, 0],
        used_pa: [0, 0, 0, 0],
        qsize: [0, 0, 0, 0],
        port_qrx: 0,
        port_qtx: 1,
        inited: 0,
    },
    ConSlotState {
        avail_idx: [0, 0, 0, 0],
        used_idx: [0, 0, 0, 0],
        desc_pa: [0, 0, 0, 0],
        avail_pa: [0, 0, 0, 0],
        used_pa: [0, 0, 0, 0],
        qsize: [0, 0, 0, 0],
        port_qrx: 0,
        port_qtx: 1,
        inited: 0,
    },
    ConSlotState {
        avail_idx: [0, 0, 0, 0],
        used_idx: [0, 0, 0, 0],
        desc_pa: [0, 0, 0, 0],
        avail_pa: [0, 0, 0, 0],
        used_pa: [0, 0, 0, 0],
        qsize: [0, 0, 0, 0],
        port_qrx: 0,
        port_qtx: 1,
        inited: 0,
    },
    ConSlotState {
        avail_idx: [0, 0, 0, 0],
        used_idx: [0, 0, 0, 0],
        desc_pa: [0, 0, 0, 0],
        avail_pa: [0, 0, 0, 0],
        used_pa: [0, 0, 0, 0],
        qsize: [0, 0, 0, 0],
        port_qrx: 0,
        port_qtx: 1,
        inited: 0,
    },
    ConSlotState {
        avail_idx: [0, 0, 0, 0],
        used_idx: [0, 0, 0, 0],
        desc_pa: [0, 0, 0, 0],
        avail_pa: [0, 0, 0, 0],
        used_pa: [0, 0, 0, 0],
        qsize: [0, 0, 0, 0],
        port_qrx: 0,
        port_qtx: 1,
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

fn check_ready(slot: i32) -> i32 {
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
    if did != DEVICE_ID_CONSOLE && did != DEVICE_ID_SERIAL {
        return VIRTIO_ERR_INVAL;
    }
    let st = unsafe { mmio_r32(base + OFF_STATUS) };
    if st & STATUS_FAILED != 0 {
        return VIRTIO_ERR_NEEDS_RESET;
    }
    if st & (STATUS_FEATURES_OK | STATUS_DRIVER_OK) != (STATUS_FEATURES_OK | STATUS_DRIVER_OK) {
        return VIRTIO_ERR_NOT_READY;
    }
    VIRTIO_OK
}

// SAFETY: pa/len describe a Normal WB guest buffer; len 0 flushes nothing.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_invalidate(pa: u64, len: usize) {
    if len == 0 {
        return;
    }
    unsafe { dc_ivac_range(pa, len) };
}

// SAFETY: queue PAs are 4 KiB Grant-backed pages owned by the guest driver.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_save_queues(
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
    let ss = unsafe { &mut CON_SLOTS[slot as usize] };
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

// SAFETY: slot reset only clears guest-side indices; device re-init via transport.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_reset_slot(slot: i32) {
    if !slot_valid(slot) {
        return;
    }
    let ss = unsafe { &mut CON_SLOTS[slot as usize] };
    ss.avail_idx = [0, 0, 0, 0];
    ss.used_idx = [0, 0, 0, 0];
    ss.port_qrx = 0;
    ss.port_qtx = 1;
    ss.inited = 0;
}

fn submit_inner(
    slot: i32,
    q: usize,
    notify_q: u32,
    data_pa: u64,
    len: u32,
    flags: u16,
    reject_zero_pa: bool,
    req_id: *mut u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if req_id.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    if reject_zero_pa && data_pa == 0 {
        return VIRTIO_ERR_INVAL;
    }
    if data_pa & 0xfff != 0 {
        return VIRTIO_ERR_INVAL;
    }
    if len == 0 || len > 4096 {
        return VIRTIO_ERR_INVAL;
    }
    if data_pa.checked_add(len as u64).is_none() {
        return VIRTIO_ERR_INVAL;
    }
    let rc = check_ready(slot);
    if rc != VIRTIO_OK {
        return rc;
    }
    unsafe {
        let ss = &mut CON_SLOTS[slot as usize];
        let mut qsize = ss.qsize[q];
        let desc_pa = ss.desc_pa[q];
        let avail_pa = ss.avail_pa[q];
        if desc_pa == 0 || avail_pa == 0 {
            return VIRTIO_ERR_NOT_READY;
        }
        if qsize == 0 {
            qsize = 64;
        }
        let desc = desc_pa as *mut VirtqDesc;
        let avail_idx_ptr = (avail_pa + 2) as *mut u16;
        let avail_ring = (avail_pa + 4) as *mut u16;
        let idx = ss.avail_idx[q];
        let head = (idx % qsize as u16) as usize;
        (*desc.add(head)).addr = data_pa;
        (*desc.add(head)).len = len;
        (*desc.add(head)).flags = flags;
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
        let base = slot_base(slot);
        mmio_w32(base + OFF_QUEUE_NOTIFY, notify_q);
        core::arch::asm!("dsb sy; dmb ish", options(nostack, preserves_flags));
        ss.avail_idx[q] = idx.wrapping_add(1);
        *req_id = idx as u32;
        VIRTIO_OK
    }
}

// SAFETY: data_pa is a guest Grant page; len 1..4096; req_id non-null.
// Port RX uses state pair 0 and notifies the mapped port queue
// (0/1 console default, 2*id/2*id+1 after con_set_port_queues).
#[no_mangle]
pub unsafe extern "C" fn virtio_con_submit_rx(
    slot: i32,
    data_pa: u64,
    len: u32,
    req_id: *mut u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    let notify_q = unsafe { CON_SLOTS[slot as usize].port_qrx };
    submit_inner(slot, 0, notify_q, data_pa, len, DESC_F_WRITE, false, req_id)
}

// SAFETY: data_pa is a guest Grant page; data_len 1..4096; req_id non-null.
// Port TX uses state pair 1 and notifies the mapped port queue.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_submit_tx(
    slot: i32,
    data_pa: u64,
    data_len: u32,
    req_id: *mut u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    let notify_q = unsafe { CON_SLOTS[slot as usize].port_qtx };
    submit_inner(slot, 1, notify_q, data_pa, data_len, 0, true, req_id)
}

// SAFETY: data_pa is a guest Grant page; len 1..4096; req_id non-null.
// Control RX (queue 2): device-written event bytes, same contract as port RX.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_submit_ctrl_rx(
    slot: i32,
    data_pa: u64,
    len: u32,
    req_id: *mut u32,
) -> i32 {
    submit_inner(slot, 2, 2, data_pa, len, DESC_F_WRITE, false, req_id)
}

// SAFETY: data_pa is a guest Grant page; data_len 1..4096; req_id non-null.
// Control TX (queue 3): 8-byte {id LE32, event LE16, value LE16} messages
// (DEVICE_READY 0 / PORT_READY 3 / PORT_OPEN 6 per Linux virtio_console.h).
#[no_mangle]
pub unsafe extern "C" fn virtio_con_submit_ctrl_tx(
    slot: i32,
    data_pa: u64,
    data_len: u32,
    req_id: *mut u32,
) -> i32 {
    submit_inner(slot, 3, 3, data_pa, data_len, 0, true, req_id)
}

// SAFETY: qidx 0|1 port queues, 2|3 serial control queues; out_id/out_len non-null.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_poll_used(
    slot: i32,
    qidx: i32,
    out_id: *mut u32,
    out_len: *mut u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if qidx < 0 || qidx > 3 {
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
    let ss = unsafe { &mut CON_SLOTS[slot as usize] };
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

// SAFETY: reads device config only; out_ports non-null. Accepts the serial
// bus (3, multipoint when control queues exist) and rproc-serial (11).
// Rejects 0 and values above MAX_SERIAL_PORTS (untrusted device config is
// clamped here, and the Haskell side re-checks 1..=32 before driving port 0).
// Pure 2-queue consoles expose only cols/rows here, so the read yields 0 and
// the caller stays on the classic path.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_max_ports(slot: i32, out_ports: *mut u32) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if out_ports.is_null() {
        return VIRTIO_ERR_INVAL;
    }
    unsafe {
        let base = slot_base(slot);
        if mmio_r32(base + OFF_MAGIC) != MAGIC_H {
            return VIRTIO_ERR_BAD_VERSION;
        }
        let ver = mmio_r32(base + OFF_VERSION);
        if ver != 1 && ver != 2 {
            return VIRTIO_ERR_BAD_VERSION;
        }
        let did = mmio_r32(base + OFF_DEVICE_ID);
        if did != DEVICE_ID_CONSOLE && did != DEVICE_ID_SERIAL {
            return VIRTIO_ERR_INVAL;
        }
        let n = mmio_r32(base + OFF_CONFIG_MAX_PORTS);
        if n == 0 || n > MAX_SERIAL_PORTS {
            return VIRTIO_ERR_INVAL;
        }
        *out_ports = n;
    }
    VIRTIO_OK
}

// SAFETY: queue PAs are 4 KiB Grant-backed pages owned by the guest driver.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_save_ctrl_queues(
    slot: i32,
    crx_desc: u64,
    crx_avail: u64,
    crx_used: u64,
    ctx_desc: u64,
    ctx_avail: u64,
    ctx_used: u64,
    qsize_crx: u32,
    qsize_ctx: u32,
) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    let ss = unsafe { &mut CON_SLOTS[slot as usize] };
    ss.desc_pa[2] = crx_desc;
    ss.avail_pa[2] = crx_avail;
    ss.used_pa[2] = crx_used;
    ss.qsize[2] = qsize_crx;
    ss.desc_pa[3] = ctx_desc;
    ss.avail_pa[3] = ctx_avail;
    ss.used_pa[3] = ctx_used;
    ss.qsize[3] = qsize_ctx;
    ss.avail_idx[2] = 0;
    ss.used_idx[2] = 0;
    ss.avail_idx[3] = 0;
    ss.used_idx[3] = 0;
    VIRTIO_OK
}

// Transport queue indices for the port pair (submit notify values).
// Defaults 0/1 (console); serial sets 2*id/2*id+1 after PORT_ADD discovery.
// SAFETY: pure index mapping, no DMA; qidx values are bounded to real queues.
#[no_mangle]
pub unsafe extern "C" fn virtio_con_set_port_queues(slot: i32, rx_qidx: u32, tx_qidx: u32) -> i32 {
    if !slot_valid(slot) {
        return VIRTIO_ERR_BAD_SLOT;
    }
    if rx_qidx > 127 || tx_qidx > 127 {
        return VIRTIO_ERR_INVAL;
    }
    let ss = unsafe { &mut CON_SLOTS[slot as usize] };
    ss.port_qrx = rx_qidx;
    ss.port_qtx = tx_qidx;
    VIRTIO_OK
}
