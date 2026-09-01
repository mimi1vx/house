#pragma once
#include <stdint.h>
#include <stddef.h>
#include "virtio_transport.h"

#ifndef HOUSE_VIRTIO_BLK
#define HOUSE_VIRTIO_BLK 1
#endif

// Virtio block device id
#define VIRTIO_DEVICE_ID_BLK 2

// Request types
#define VIRTIO_BLK_T_IN 0
#define VIRTIO_BLK_T_OUT 1

// Status codes
#define VIRTIO_BLK_S_OK 0
#define VIRTIO_BLK_S_IOERR 1
#define VIRTIO_BLK_S_UNSUPP 2

// Feature bits (optional, for documentation)
#define VIRTIO_BLK_F_RO (1ULL << 5)
#define VIRTIO_BLK_F_SIZE_MAX (1ULL << 1)
#define VIRTIO_BLK_F_SEG_MAX (1ULL << 2)
#define VIRTIO_BLK_F_BLK_SIZE (1ULL << 6)

// Transport sizing (Q2=B): 4 KiB blocks, 512 B sectors on wire
#define VIRTIO_BLK_BLOCK_BYTES 4096
#define VIRTIO_BLK_SECTOR_BYTES 512
#define VIRTIO_BLK_SECTORS_PER_BLOCK 8

// Config offset: capacity lives at base+0x100 (8 bytes LE)
#define VIRTIO_BLK_CFG_OFF_CAPACITY 0x100

// Block request layout (16 bytes)
struct virtio_blk_req {
    uint32_t type;
    uint32_t reserved;
    uint64_t sector;
} __attribute__((packed));

// API: all are aarch64-only, unsafe-ffi reachable
int virtio_blk_probe_capacity(int slot, uint64_t *capacity_sectors);
int virtio_blk_submit_read(int slot, uint64_t lba_blocks, uint64_t data_pa, uint32_t nblocks, uint32_t *req_id);
int virtio_blk_submit_write(int slot, uint64_t lba_blocks, uint64_t data_pa, uint32_t nblocks, uint32_t *req_id);
int virtio_blk_poll_used(int slot, uint32_t *out_id, uint8_t *out_status);
void virtio_blk_reset_slot(int slot);
void virtio_blk_invalidate(uint64_t pa, size_t len);
void virtio_blk_save_queue(int slot, uint64_t desc_pa, uint64_t avail_pa, uint64_t used_pa, uint32_t qsize);
