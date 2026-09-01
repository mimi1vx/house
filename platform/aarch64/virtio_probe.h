#pragma once
#include <stdint.h>
#include "virtio_transport.h"

#define VIRTIO_MMIO_BASE VIRTIO_MMIO_BASE_H
#define VIRTIO_MMIO_STRIDE VIRTIO_MMIO_STRIDE_H
#define VIRTIO_MMIO_NUM_SLOTS VIRTIO_MMIO_NUM_SLOTS_H
#define VIRTIO_MMIO_MAGIC VIRTIO_MMIO_MAGIC_H

int virtio_probe_slot(int slot, uint32_t *device_id, uint32_t *vendor_id, uint32_t *version);
