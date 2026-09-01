#include "virtio_net.h"
#include "virtio_transport.h"
#include "uart.h"
#include <stdint.h>
#include <stddef.h>

static inline uint32_t mmio_r32(uint64_t a) {
    return *(volatile uint32_t *)(uintptr_t)a;
}
static inline void mmio_w32(uint64_t a, uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)a = v;
}
static inline uint64_t slot_base(int slot) {
    return VIRTIO_MMIO_BASE_H + (uint64_t)slot * VIRTIO_MMIO_STRIDE_H;
}
static inline int slot_valid(int slot) {
    return slot >= 0 && slot < VIRTIO_MMIO_NUM_SLOTS_H;
}

struct net_slot_state {
    uint16_t avail_idx[2];
    uint16_t used_idx[2];
    uint64_t desc_pa[2];
    uint64_t avail_pa[2];
    uint64_t used_pa[2];
    uint32_t qsize[2];
    uint8_t inited;
};
static struct net_slot_state net_slots[8] = {0};

struct virtq_desc {
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

#define VIRTQ_DESC_F_NEXT 1
#define VIRTQ_DESC_F_WRITE 2

static inline void dc_flush(uint64_t pa, size_t len) {
    virtio_transport_dc_flush(pa, len);
}
static inline void dc_inv(uint64_t pa, size_t len) {
    if (len == 0) return;
    __asm__ volatile("dmb ish" ::: "memory");
    uint64_t start = pa & ~63ULL;
    uint64_t end = pa + len;
    for (uint64_t p = start; p < end; p += 64) {
        __asm__ volatile("dc ivac, %0" :: "r"(p) : "memory");
    }
    __asm__ volatile("dsb sy; dmb ish" ::: "memory");
}

void virtio_net_invalidate(uint64_t pa, size_t len) {
    dc_inv(pa, len);
}

int virtio_net_save_queues(int slot, uint64_t rx_desc, uint64_t rx_avail, uint64_t rx_used, uint64_t tx_desc, uint64_t tx_avail, uint64_t tx_used, uint32_t qsize_rx, uint32_t qsize_tx) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    net_slots[slot].desc_pa[0] = rx_desc;
    net_slots[slot].avail_pa[0] = rx_avail;
    net_slots[slot].used_pa[0] = rx_used;
    net_slots[slot].qsize[0] = qsize_rx;
    net_slots[slot].desc_pa[1] = tx_desc;
    net_slots[slot].avail_pa[1] = tx_avail;
    net_slots[slot].used_pa[1] = tx_used;
    net_slots[slot].qsize[1] = qsize_tx;
    net_slots[slot].inited = 1;
    net_slots[slot].avail_idx[0] = 0;
    net_slots[slot].used_idx[0] = 0;
    net_slots[slot].avail_idx[1] = 0;
    net_slots[slot].used_idx[1] = 0;
    return VIRTIO_OK;
}

int virtio_net_probe_mac(int slot, uint8_t mac[6]) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (!mac) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    uint32_t ver = mmio_r32(base + VIRTIO_MMIO_OFF_VERSION);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    if (ver != 1 && ver != 2) return VIRTIO_ERR_BAD_VERSION;
    uint32_t did = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_ID);
    if (did == 0) return VIRTIO_ERR_BAD_VERSION;
    if (did != VIRTIO_DEVICE_ID_NET) return VIRTIO_ERR_INVAL;
    uint32_t st = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    if ((st & VIRTIO_STATUS_FAILED) != 0) return VIRTIO_ERR_NEEDS_RESET;
    if ((st & (VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)) != (VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)) {
        return VIRTIO_ERR_NOT_READY;
    }
    // MAC at config offset 0x100, 6 bytes
    for (int i = 0; i < 6; i++) {
        // config space is MMIO Device region, byte readable via 32-bit loads
        // read as byte by reading 32-bit word and shifting (qemu allows byte?)
        // Use volatile 8-bit read via pointer arithmetic if supported, else word
        // Try byte load via volatile uint8_t
        uint64_t addr = base + VIRTIO_NET_CFG_OFF_MAC + i;
        mac[i] = *(volatile uint8_t *)(uintptr_t)addr;
    }
    return VIRTIO_OK;
}

int virtio_net_submit_rx(int slot, uint64_t data_pa, uint32_t len, uint32_t *req_id) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (!req_id) return VIRTIO_ERR_INVAL;
    if ((data_pa & 0xfffULL) != 0) return VIRTIO_ERR_INVAL;
    if (len == 0 || len > 4096) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    uint32_t ver = mmio_r32(base + VIRTIO_MMIO_OFF_VERSION);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    if (ver != 1 && ver != 2) return VIRTIO_ERR_BAD_VERSION;
    uint32_t did = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_ID);
    if (did != VIRTIO_DEVICE_ID_NET) return VIRTIO_ERR_INVAL;
    uint32_t st = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    if ((st & VIRTIO_STATUS_FAILED) != 0) return VIRTIO_ERR_NEEDS_RESET;
    if ((st & (VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)) != (VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK))
        return VIRTIO_ERR_NOT_READY;

    struct net_slot_state *ss = &net_slots[slot];
    uint32_t qsize = ss->qsize[0];
    uint64_t desc_pa = ss->desc_pa[0];
    uint64_t avail_pa = ss->avail_pa[0];
    if (desc_pa == 0 || avail_pa == 0) return VIRTIO_ERR_NOT_READY;
    if (qsize == 0) qsize = 64;
    if (qsize == 0) return VIRTIO_ERR_NOSPC;

    struct virtq_desc *desc = (struct virtq_desc *)(uintptr_t)desc_pa;
    volatile uint16_t *avail_idx = (volatile uint16_t *)(uintptr_t)(avail_pa + 2);
    volatile uint16_t *avail_ring = (volatile uint16_t *)(uintptr_t)(avail_pa + 4);

    uint16_t idx = ss->avail_idx[0];
    uint16_t head = idx % qsize;

    // Single descriptor: WRITE, len
    desc[head].addr = data_pa;
    desc[head].len = len;
    desc[head].flags = VIRTQ_DESC_F_WRITE;
    desc[head].next = 0;

    __asm__ volatile("dmb ish" ::: "memory");
    dc_flush(desc_pa + (uint64_t)head * 16, 16);
    dc_flush(data_pa, len);

    avail_ring[idx % qsize] = head;
    __asm__ volatile("dmb ish" ::: "memory");
    *avail_idx = idx + 1;
    __asm__ volatile("dmb ish" ::: "memory");
    dc_flush(avail_pa, 4096);
    __asm__ volatile("dmb ish" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_NOTIFY, 0);
    __asm__ volatile("dsb sy; dmb ish" ::: "memory");

    ss->avail_idx[0] = idx + 1;
    *req_id = idx;
    return VIRTIO_OK;
}

int virtio_net_submit_tx(int slot, uint64_t hdr_pa, uint64_t data_pa, uint32_t data_len, uint32_t *req_id) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (!req_id) return VIRTIO_ERR_INVAL;
    if ((hdr_pa & 0xfffULL) == 0) {
        // hdr_pa is 12-byte header inside a page? It's within a Grant page, must be page-aligned start, offset 0
        // Accept any alignment for hdr (12 bytes), but ensure it's identity mapped WB
    }
    if (data_pa == 0) return VIRTIO_ERR_INVAL;
    if (data_len == 0 || data_len > 4096 - VIRTIO_NET_HDR_SIZE) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    uint32_t ver = mmio_r32(base + VIRTIO_MMIO_OFF_VERSION);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    if (ver != 1 && ver != 2) return VIRTIO_ERR_BAD_VERSION;
    uint32_t did = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_ID);
    if (did != VIRTIO_DEVICE_ID_NET) return VIRTIO_ERR_INVAL;
    uint32_t st = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    if ((st & VIRTIO_STATUS_FAILED) != 0) return VIRTIO_ERR_NEEDS_RESET;
    if ((st & (VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)) != (VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK))
        return VIRTIO_ERR_NOT_READY;

    struct net_slot_state *ss = &net_slots[slot];
    uint32_t qsize = ss->qsize[1];
    uint64_t desc_pa = ss->desc_pa[1];
    uint64_t avail_pa = ss->avail_pa[1];
    if (desc_pa == 0 || avail_pa == 0) return VIRTIO_ERR_NOT_READY;
    if (qsize == 0) qsize = 64;
    if (qsize < 2) return VIRTIO_ERR_NOSPC;

    struct virtq_desc *desc = (struct virtq_desc *)(uintptr_t)desc_pa;
    volatile uint16_t *avail_idx = (volatile uint16_t *)(uintptr_t)(avail_pa + 2);
    volatile uint16_t *avail_ring = (volatile uint16_t *)(uintptr_t)(avail_pa + 4);

    uint16_t idx = ss->avail_idx[1];
    uint16_t head = idx % qsize;
    uint16_t next1 = (head + 1) % qsize;

    // Chain: hdr (12) -> data (data_len)  , hdr NEXT, data not WRITE
    desc[head].addr = hdr_pa;
    desc[head].len = VIRTIO_NET_HDR_SIZE;
    desc[head].flags = VIRTQ_DESC_F_NEXT;
    desc[head].next = next1;

    desc[next1].addr = data_pa;
    desc[next1].len = data_len;
    desc[next1].flags = 0;
    desc[next1].next = 0;

    __asm__ volatile("dmb ish" ::: "memory");
    dc_flush(desc_pa + (uint64_t)head * 16, 16);
    dc_flush(desc_pa + (uint64_t)next1 * 16, 16);
    dc_flush(hdr_pa, VIRTIO_NET_HDR_SIZE);
    dc_flush(data_pa, data_len);

    avail_ring[idx % qsize] = head;
    __asm__ volatile("dmb ish" ::: "memory");
    *avail_idx = idx + 1;
    __asm__ volatile("dmb ish" ::: "memory");
    dc_flush(avail_pa, 4096);

    __asm__ volatile("dmb ish" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_NOTIFY, 1);
    __asm__ volatile("dsb sy; dmb ish" ::: "memory");

    ss->avail_idx[1] = idx + 1;
    *req_id = idx;
    return VIRTIO_OK;
}

int virtio_net_poll_used(int slot, int qidx, uint32_t *out_id, uint32_t *out_len) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (qidx < 0 || qidx > 1) return VIRTIO_ERR_INVAL;
    if (!out_id || !out_len) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    struct net_slot_state *ss = &net_slots[slot];
    uint64_t used_pa = ss->used_pa[qidx];
    if (used_pa == 0) return VIRTIO_ERR_NOT_READY;

    volatile uint16_t *used_idx = (volatile uint16_t *)(uintptr_t)(used_pa + 2);
    dc_inv(used_pa, 8);
    __asm__ volatile("dmb ish" ::: "memory");
    uint16_t uidx = *used_idx;
    if (uidx == ss->used_idx[qidx]) {
        return 1;
    }
    uint32_t qsize = ss->qsize[qidx];
    if (qsize == 0) qsize = 64;
    uint16_t local = ss->used_idx[qidx] % qsize;
    dc_inv(used_pa + 4 + (uint64_t)local * 8, 8);
    __asm__ volatile("dmb ish" ::: "memory");
    volatile uint32_t *used_ring = (volatile uint32_t *)(uintptr_t)(used_pa + 4);
    uint32_t id = used_ring[local * 2];
    uint32_t len = used_ring[local * 2 + 1];

    mmio_w32(base + VIRTIO_MMIO_OFF_INTERRUPT_ACK, 1);
    __asm__ volatile("dsb sy; isb" ::: "memory");

    ss->used_idx[qidx]++;
    *out_id = id;
    *out_len = len;
    return 0;
}
