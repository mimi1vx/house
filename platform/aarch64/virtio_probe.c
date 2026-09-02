#include <stdint.h>
#include "virtio_probe.h"

static inline uint32_t mmio_r32(uint64_t a) {
    uint32_t v;
    __asm__ volatile("ldr %w0, [%1]" : "=r"(v) : "r"(a) : "memory");
    return v;
}

int virtio_probe_slot(int slot, uint32_t *device_id, uint32_t *vendor_id, uint32_t *version) {
    if (slot < 0 || slot >= VIRTIO_MMIO_NUM_SLOTS) return 0;
    uint64_t base = VIRTIO_MMIO_BASE + (uint64_t)slot * VIRTIO_MMIO_STRIDE;
    uint32_t magic = mmio_r32(base + 0x000);
    uint32_t ver = mmio_r32(base + 0x004);
    uint32_t did = mmio_r32(base + 0x008);
    uint32_t vid = mmio_r32(base + 0x00c);
    if (device_id) *device_id = did;
    if (vendor_id) *vendor_id = vid;
    if (version) *version = ver;
    if (magic == VIRTIO_MMIO_MAGIC && (ver == 1 || ver == 2) && did != 0) return 1;
    return 0;
}
