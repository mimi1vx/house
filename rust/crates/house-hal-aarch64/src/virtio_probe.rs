//! Virtio probe — `virtio_probe.c` transliteration.

use crate::mmio::mmio_r32;

const VIRTIO_BASE: u64 = 0x0a000000;
const VIRTIO_STRIDE: u64 = 0x200;
// QEMU's `virt` machine default is 32 virtio-mmio transports; the guest
// probes all of them so no harness has to narrow the machine.
const VIRTIO_NUM_SLOTS: i32 = 32;
const VIRTIO_MAGIC: u32 = 0x74726976;

/// Probe a virtio-mmio slot, reporting device/vendor/version.
///
/// # Safety
///
/// `dev`, `vendor` and `ver` must each be null or valid for a `u32` write.
/// Call at EL1 with the virtio MMIO window (0x0a000000) identity-mapped.
#[unsafe(no_mangle)]
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

/// Translate a RAM pointer to its physical address (identity map).
///
/// # Safety
///
/// Safe with any pointer value including null: the pointer is only cast,
/// never dereferenced. The result is meaningful only for identity-mapped RAM.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn virtio_page_pa(p: *mut u8) -> u64 {
    // Identity-mapped RAM at 0x40000000.
    p as u64
}
