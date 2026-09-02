//! Virtio probe — `virtio_probe.c` transliteration.

use crate::mmio::mmio_r32;

const VIRTIO_BASE: u64 = 0x0a000000;
const VIRTIO_STRIDE: u64 = 0x200;
const VIRTIO_NUM_SLOTS: i32 = 8;
const VIRTIO_MAGIC: u32 = 0x74726976;

#[no_mangle]
pub unsafe extern "C" fn virtio_probe_slot(
    slot: i32,
    dev: *mut u32,
    vendor: *mut u32,
    ver: *mut u32,
) -> i32 {
    if slot < 0 || slot >= VIRTIO_NUM_SLOTS {
        return 0;
    }
    let base = VIRTIO_BASE + slot as u64 * VIRTIO_STRIDE;
    // SAFETY: MMIO base 0x0a000000 identity-mapped.
    unsafe {
        let magic = mmio_r32(base + 0x000);
        let version = mmio_r32(base + 0x004);
        let did = mmio_r32(base + 0x008);
        let vid = mmio_r32(base + 0x00c);
        if !dev.is_null() {
            *dev = did;
        }
        if !vendor.is_null() {
            *vendor = vid;
        }
        if !ver.is_null() {
            *ver = version;
        }
        if magic == VIRTIO_MAGIC && (version == 1 || version == 2) && did != 0 {
            1
        } else {
            0
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn virtio_page_pa(p: *mut u8) -> u64 {
    // Identity-mapped RAM at 0x40000000.
    p as u64
}
