#pragma once
#include <stdint.h>

#define VIRTIO_MMIO_BASE 0x0a000000ULL
#define VIRTIO_MMIO_STRIDE 0x200
#define VIRTIO_MMIO_NUM_SLOTS 8
#define VIRTIO_MMIO_MAGIC 0x74726976

int virtio_probe_slot(int slot, uint32_t *device_id, uint32_t *vendor_id, uint32_t *version);
