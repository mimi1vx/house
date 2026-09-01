#pragma once
#include <stdint.h>
#include <stddef.h>

#ifndef HOUSE_VIRTIO_TRANSPORT
#define HOUSE_VIRTIO_TRANSPORT 1
#endif

// Virtio-MMIO transport constants (device-agnostic).
// Guard central - probe reuses same base/stride/magic via virtio_probe.h include chain.
// Offsets per Virtio 1.0 MMIO spec, all 32-bit.

#define VIRTIO_MMIO_BASE_H 0x0a000000ULL
#define VIRTIO_MMIO_STRIDE_H 0x200
#define VIRTIO_MMIO_NUM_SLOTS_H 8
#define VIRTIO_MMIO_MAGIC_H 0x74726976

#define VIRTIO_MMIO_OFF_MAGIC 0x000
#define VIRTIO_MMIO_OFF_VERSION 0x004
#define VIRTIO_MMIO_OFF_DEVICE_ID 0x008
#define VIRTIO_MMIO_OFF_VENDOR_ID 0x00c
#define VIRTIO_MMIO_OFF_DEVICE_FEATURES 0x010
#define VIRTIO_MMIO_OFF_DEVICE_FEATURES_SEL 0x014
#define VIRTIO_MMIO_OFF_DRIVER_FEATURES 0x020
#define VIRTIO_MMIO_OFF_DRIVER_FEATURES_SEL 0x024
#define VIRTIO_MMIO_OFF_QUEUE_SEL 0x030
#define VIRTIO_MMIO_OFF_QUEUE_NUM_MAX 0x034
#define VIRTIO_MMIO_OFF_QUEUE_NUM 0x038
#define VIRTIO_MMIO_OFF_QUEUE_READY 0x044
#define VIRTIO_MMIO_OFF_QUEUE_NOTIFY 0x050
#define VIRTIO_MMIO_OFF_INTERRUPT_STATUS 0x060
#define VIRTIO_MMIO_OFF_INTERRUPT_ACK 0x064
#define VIRTIO_MMIO_OFF_STATUS 0x070
#define VIRTIO_MMIO_OFF_QUEUE_DESC_LOW 0x080
#define VIRTIO_MMIO_OFF_QUEUE_DESC_HIGH 0x084
#define VIRTIO_MMIO_OFF_QUEUE_AVAIL_LOW 0x090
#define VIRTIO_MMIO_OFF_QUEUE_AVAIL_HIGH 0x094
#define VIRTIO_MMIO_OFF_QUEUE_USED_LOW 0x0A0
#define VIRTIO_MMIO_OFF_QUEUE_USED_HIGH 0x0A4
#define VIRTIO_MMIO_OFF_CONFIG_GENERATION 0x0FC

// Status bits (Virtio 1.0)
#define VIRTIO_STATUS_ACK 0x01
#define VIRTIO_STATUS_DRIVER 0x02
#define VIRTIO_STATUS_DRIVER_OK 0x04
#define VIRTIO_STATUS_FEATURES_OK 0x08
#define VIRTIO_STATUS_FAILED 0x80
#define VIRTIO_STATUS_NEEDS_RESET 0x80

// Feature bits
#define VIRTIO_F_RING_EVENT_IDX (1ULL << 29)
#define VIRTIO_F_VERSION_1 (1ULL << 32)
#define VIRTIO_WANTED_FEATURES (VIRTIO_F_VERSION_1 | VIRTIO_F_RING_EVENT_IDX)

// Error codes (negative, mapped to VirtioError in Haskell)
#define VIRTIO_OK 0
#define VIRTIO_ERR_BAD_SLOT -1
#define VIRTIO_ERR_BAD_VERSION -2
#define VIRTIO_ERR_NEEDS_RESET -3
#define VIRTIO_ERR_FEATURES_MISMATCH -4
#define VIRTIO_ERR_NOSPC -5
#define VIRTIO_ERR_QUEUE_FULL -6
#define VIRTIO_ERR_NOT_READY -7
#define VIRTIO_ERR_SPURIOUS -8
#define VIRTIO_ERR_INVAL -9

// MMIO helpers
int virtio_transport_init(int slot, uint32_t *dev_features_lo, uint32_t *dev_features_hi);
int virtio_transport_set_features(int slot, uint64_t wanted);
int virtio_transport_get_status(int slot, uint32_t *status);
int virtio_transport_set_status(int slot, uint32_t status);
int virtio_transport_queue_max(int slot, uint32_t *max);
int virtio_transport_queue_max_q(int slot, int qidx, uint32_t *max);
int virtio_transport_queue_setup(int slot, uint64_t desc_pa, uint64_t avail_pa, uint64_t used_pa, uint32_t qsize);
int virtio_transport_queue_setup_q(int slot, int qidx, uint64_t desc_pa, uint64_t avail_pa, uint64_t used_pa, uint32_t qsize);
int virtio_transport_notify(int slot, uint32_t qidx);
uint32_t virtio_transport_interrupt_status(int slot);
void virtio_transport_ack(int slot, uint32_t mask);
void virtio_transport_dc_flush(uint64_t pa, size_t len);
uint64_t virtio_page_pa(void *p);
