#include "virtio_blk.h"
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

// Per-slot state: avail/used idx are monotonic counters
struct blk_slot_state {
    uint16_t avail_idx;
    uint16_t used_idx;
    uint8_t req_buf[16];
    uint8_t status_byte;
    uint8_t inited;
    uint64_t desc_pa;
    uint64_t avail_pa;
    uint64_t used_pa;
    uint32_t qsize;
};
static struct blk_slot_state blk_slots[8] = {0};

void virtio_blk_save_queue(int slot, uint64_t desc_pa, uint64_t avail_pa, uint64_t used_pa, uint32_t qsize) {
    if (!slot_valid(slot)) return;
    blk_slots[slot].desc_pa = desc_pa;
    blk_slots[slot].avail_pa = avail_pa;
    blk_slots[slot].used_pa = used_pa;
    blk_slots[slot].qsize = qsize;
}

// Queue descriptor layout (Virtio 1.0)
struct virtq_desc {
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

// Avail header: flags, idx, then ring[]
// Used header: flags, idx, then ring {id,len}[]

#define VIRTQ_DESC_F_NEXT 1
#define VIRTQ_DESC_F_WRITE 2

static inline void dc_flush(uint64_t pa, size_t len) {
    virtio_transport_dc_flush(pa, len);
}
static inline void dc_invalidate(uint64_t pa, size_t len) {
    if (len == 0) return;
    __asm__ volatile("dmb ish" ::: "memory");
    uint64_t start = pa & ~63ULL;
    uint64_t end = pa + len;
    for (uint64_t p = start; p < end; p += 64) {
        __asm__ volatile("dc ivac, %0" :: "r"(p) : "memory");
    }
    __asm__ volatile("dsb sy; dmb ish" ::: "memory");
}

void virtio_blk_reset_slot(int slot) {
    if (!slot_valid(slot)) return;
    blk_slots[slot].avail_idx = 0;
    blk_slots[slot].used_idx = 0;
    blk_slots[slot].status_byte = 0;
    for (int i = 0; i < 16; i++) blk_slots[slot].req_buf[i] = 0;
}

void virtio_blk_invalidate(uint64_t pa, size_t len) {
    dc_invalidate(pa, len);
}

static uint64_t queue_desc_pa(int slot) {
    uint64_t base = slot_base(slot);
    uint32_t lo = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_DESC_LOW);
    uint32_t hi = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_DESC_HIGH);
    return ((uint64_t)hi << 32) | lo;
}
static uint64_t queue_avail_pa(int slot) {
    uint64_t base = slot_base(slot);
    uint32_t lo = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_AVAIL_LOW);
    uint32_t hi = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_AVAIL_HIGH);
    return ((uint64_t)hi << 32) | lo;
}
static uint64_t queue_used_pa(int slot) {
    uint64_t base = slot_base(slot);
    uint32_t lo = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_USED_LOW);
    uint32_t hi = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_USED_HIGH);
    return ((uint64_t)hi << 32) | lo;
}
static uint32_t queue_qsize(int slot) __attribute__((unused));
static uint32_t queue_qsize(int slot) {
    uint64_t base = slot_base(slot);
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_SEL, 0);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    // queue num is at 0x038 but after setup it reflects negotiated size
    return mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_NUM);
}

// Probe capacity (sectors, 512B units) from device config at base+0x100
int virtio_blk_probe_capacity(int slot, uint64_t *capacity_sectors) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (!capacity_sectors) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    uint32_t ver = mmio_r32(base + VIRTIO_MMIO_OFF_VERSION);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    if (ver != 1 && ver != 2) return VIRTIO_ERR_BAD_VERSION;
    uint32_t did = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_ID);
    if (did == 0) return VIRTIO_ERR_BAD_VERSION;
    if (did != VIRTIO_DEVICE_ID_BLK) return VIRTIO_ERR_INVAL;
    // capacity only valid after FEATURES_OK|DRIVER_OK, but probe reads it anyway
    // config generation not needed for single read
    uint32_t cap_lo = mmio_r32(base + VIRTIO_BLK_CFG_OFF_CAPACITY);
    uint32_t cap_hi = mmio_r32(base + VIRTIO_BLK_CFG_OFF_CAPACITY + 4);
    *capacity_sectors = ((uint64_t)cap_hi << 32) | cap_lo;
    return VIRTIO_OK;
}

static int blk_submit(int slot, uint64_t lba_blocks, uint64_t data_pa, uint32_t nblocks, uint32_t *req_id, uint32_t type) {
    if (!slot_valid(slot)) { uart_puts("blk bad slot\n"); return VIRTIO_ERR_BAD_SLOT; }
    if (nblocks != 1) { uart_puts("blk nblocks !=1\n"); return VIRTIO_ERR_INVAL; }
    if (!req_id) { uart_puts("blk !req_id\n"); return VIRTIO_ERR_INVAL; }
    // data_pa must be 4K aligned identity
    if ((data_pa & 0xfffULL) != 0) { uart_puts("blk data_pa align\n"); return VIRTIO_ERR_INVAL; }

    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    uint32_t ver = mmio_r32(base + VIRTIO_MMIO_OFF_VERSION);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    if (ver != 1 && ver != 2) return VIRTIO_ERR_BAD_VERSION;
    uint32_t did = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_ID);
    if (did != VIRTIO_DEVICE_ID_BLK) return VIRTIO_ERR_INVAL;
    uint32_t st = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    if ((st & VIRTIO_STATUS_FAILED) != 0) { uart_puts("blk st FAILED\n"); return VIRTIO_ERR_NEEDS_RESET; }
    if ((st & (VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)) != (VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)) {
        uart_puts("blk st not ready st=0x");
        {
            char buf[9]; const char *hex="0123456789abcdef";
            for(int i=7;i>=0;i--) { buf[7-i]=hex[(st>> (i*4)) &0xF]; } buf[8]=0; uart_puts(buf);
        }
        uart_puts("\n");
        return VIRTIO_ERR_NOT_READY;
    }

    struct blk_slot_state *ss = &blk_slots[slot];
    uint32_t qsize = ss->qsize;
    if (qsize == 0) qsize = 64;
    if (qsize < 3) return VIRTIO_ERR_NOSPC;
    uint64_t desc_pa = ss->desc_pa;
    uint64_t avail_pa = ss->avail_pa;
    uint64_t used_pa = ss->used_pa;
    if (desc_pa == 0 || avail_pa == 0 || used_pa == 0) {
        // fallback to MMIO on first use
        desc_pa = queue_desc_pa(slot);
        avail_pa = queue_avail_pa(slot);
        used_pa = queue_used_pa(slot);
        if (desc_pa == 0 || avail_pa == 0 || used_pa == 0) {
            uart_puts("blk pa 0 desc=0x");
            {
                const char *hex="0123456789abcdef";
                for(int i=15;i>=0;i--) { char c=hex[(desc_pa >> (i*4)) &0xF]; char tmp[2]={c,0}; uart_puts(tmp); }
                uart_puts(" avail=0x");
                for(int i=15;i>=0;i--) { char c=hex[(avail_pa >> (i*4)) &0xF]; char tmp[2]={c,0}; uart_puts(tmp); }
                uart_puts(" used=0x");
                for(int i=15;i>=0;i--) { char c=hex[(used_pa >> (i*4)) &0xF]; char tmp[2]={c,0}; uart_puts(tmp); }
                uart_puts("\n");
            }
            return VIRTIO_ERR_NOT_READY;
        }
        ss->desc_pa = desc_pa;
        ss->avail_pa = avail_pa;
        ss->used_pa = used_pa;
        ss->qsize = qsize;
    }
    // ensure qsize stored
    ss->qsize = qsize;

    // capacity bound check: lba*8 + nblocks*8 <= capacity
    uint32_t cap_lo = mmio_r32(base + VIRTIO_BLK_CFG_OFF_CAPACITY);
    uint32_t cap_hi = mmio_r32(base + VIRTIO_BLK_CFG_OFF_CAPACITY + 4);
    uint64_t capacity = ((uint64_t)cap_hi << 32) | cap_lo;
    uint64_t sector = lba_blocks * VIRTIO_BLK_SECTORS_PER_BLOCK;
    uint64_t nsectors = (uint64_t)nblocks * VIRTIO_BLK_SECTORS_PER_BLOCK;
    if (sector + nsectors > capacity) return VIRTIO_ERR_INVAL;

    // init state on first use
    // avail_idx/used_idx already 0

    // descriptor addresses via PA as VA (identity)
    struct virtq_desc *desc = (struct virtq_desc *)(uintptr_t)desc_pa;
    volatile uint16_t *avail_flags = (volatile uint16_t *)(uintptr_t)avail_pa;
    volatile uint16_t *avail_idx = (volatile uint16_t *)(uintptr_t)(avail_pa + 2);
    volatile uint16_t *avail_ring = (volatile uint16_t *)(uintptr_t)(avail_pa + 4);
    (void)avail_flags;

    uint16_t idx = ss->avail_idx;
    uint16_t head = idx % qsize;
    if (qsize < 3) return VIRTIO_ERR_NOSPC;
    uint16_t next1 = (head + 1) % qsize;
    uint16_t next2 = (head + 2) % qsize;

    // Prepare request header (16B) in WB memory
    uint64_t req_pa = (uint64_t)(uintptr_t)&ss->req_buf[0];
    uint64_t status_pa = (uint64_t)(uintptr_t)&ss->status_byte;
    ss->req_buf[0] = (type & 0xff);
    ss->req_buf[1] = (type >> 8) & 0xff;
    ss->req_buf[2] = (type >> 16) & 0xff;
    ss->req_buf[3] = (type >> 24) & 0xff;
    ss->req_buf[4] = 0; ss->req_buf[5] = 0; ss->req_buf[6] = 0; ss->req_buf[7] = 0;
    ss->req_buf[8] = sector & 0xff;
    ss->req_buf[9] = (sector >> 8) & 0xff;
    ss->req_buf[10] = (sector >> 16) & 0xff;
    ss->req_buf[11] = (sector >> 24) & 0xff;
    ss->req_buf[12] = (sector >> 32) & 0xff;
    ss->req_buf[13] = (sector >> 40) & 0xff;
    ss->req_buf[14] = (sector >> 48) & 0xff;
    ss->req_buf[15] = (sector >> 56) & 0xff;
    ss->status_byte = 0xff; // poison

    uint32_t data_len = nblocks * VIRTIO_BLK_BLOCK_BYTES;

    // Fill descriptors
    desc[head].addr = req_pa;
    desc[head].len = 16;
    desc[head].flags = VIRTQ_DESC_F_NEXT;
    desc[head].next = next1;

    desc[next1].addr = data_pa;
    desc[next1].len = data_len;
    desc[next1].flags = VIRTQ_DESC_F_NEXT;
    desc[next1].next = next2;
    if (type == VIRTIO_BLK_T_IN) {
        // device writes to data
        desc[next1].flags |= VIRTQ_DESC_F_WRITE;
    }

    desc[next2].addr = status_pa;
    desc[next2].len = 1;
    desc[next2].flags = VIRTQ_DESC_F_WRITE;
    desc[next2].next = 0;

    // Ensure descriptor writes are visible before avail update
    __asm__ volatile("dmb ish" ::: "memory");

    // Flush descriptor table + req + data (for write) + status
    dc_flush(desc_pa, qsize * 16);
    dc_flush(req_pa, 16);
    // For write, data is dirty (to device) -> clean; for read, data is zero but still clean to avoid dirty overwritten
    dc_flush(data_pa, data_len);
    dc_flush(status_pa, 1);

    // Publish to avail ring
    avail_ring[idx % qsize] = head;
    __asm__ volatile("dmb ish" ::: "memory");
    *avail_idx = idx + 1;
    __asm__ volatile("dmb ish" ::: "memory");
    dc_flush(avail_pa, 4096);

    // Queue notify
    __asm__ volatile("dmb ish" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_NOTIFY, 0);
    __asm__ volatile("dsb sy; dmb ish" ::: "memory");

    ss->avail_idx = idx + 1;
    *req_id = idx;
    (void)used_pa;
    uart_puts("blk submit ok\n");
    return VIRTIO_OK;
}

int virtio_blk_submit_read(int slot, uint64_t lba_blocks, uint64_t data_pa, uint32_t nblocks, uint32_t *req_id) {
    return blk_submit(slot, lba_blocks, data_pa, nblocks, req_id, VIRTIO_BLK_T_IN);
}

int virtio_blk_submit_write(int slot, uint64_t lba_blocks, uint64_t data_pa, uint32_t nblocks, uint32_t *req_id) {
    return blk_submit(slot, lba_blocks, data_pa, nblocks, req_id, VIRTIO_BLK_T_OUT);
}

// Poll used ring: 0 = completion id+status set, 1 = no completion, negative = error
int virtio_blk_poll_used(int slot, uint32_t *out_id, uint8_t *out_status) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (!out_id || !out_status) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    struct blk_slot_state *ss = &blk_slots[slot];
    uint64_t avail_pa = ss->avail_pa;
    uint64_t used_pa = ss->used_pa;
    if (avail_pa == 0 || used_pa == 0) {
        avail_pa = queue_avail_pa(slot);
        used_pa = queue_used_pa(slot);
        if (avail_pa == 0 || used_pa == 0) return VIRTIO_ERR_NOT_READY;
        ss->avail_pa = avail_pa;
        ss->used_pa = used_pa;
    }
    volatile uint16_t *used_flags = (volatile uint16_t *)(uintptr_t)used_pa;
    volatile uint16_t *used_idx = (volatile uint16_t *)(uintptr_t)(used_pa + 2);
    // used ring base +4
    (void)used_flags;
    // Also need to ensure we see device's writes: invalidate used header?
    // Used header is WB - device writes to it, need invalidate before reading
    // Do lightweight invalidate of used page header (but poll loop already flushed? do ivac)
    dc_invalidate(used_pa, 8);
    __asm__ volatile("dmb ish" ::: "memory");
    uint16_t uidx = *used_idx;
    if (uidx == ss->used_idx) {
        return 1; // no new entry
    }
    // There is at least one new entry
    // Invalidate the specific used entry before reading (header already invalidated)
    uint32_t qsize = 64;
    uint16_t local = ss->used_idx % qsize;
    dc_invalidate(used_pa + 4 + (uint64_t)local * 8, 8);
    __asm__ volatile("dmb ish" ::: "memory");
    // Read ring entry: each entry is 8 bytes {uint32 id, uint32 len}
    volatile uint32_t *used_ring = (volatile uint32_t *)(uintptr_t)(used_pa + 4);
    // Each used elem is 2*4 bytes: id at ring[local*2], len at ring[local*2+1]
    // Because used_ring as uint32 array: index*2
    uint32_t id = used_ring[local * 2];
    // len not needed
    // Status byte was written by device to status_pa
    dc_invalidate((uint64_t)(uintptr_t)&ss->status_byte, 1);
    __asm__ volatile("dmb ish" ::: "memory");
    uint8_t st = ss->status_byte;
    // Ack interrupt
    mmio_w32(base + VIRTIO_MMIO_OFF_INTERRUPT_ACK, 1);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    // If read, invalidate data page was written by device - but we don't know data_pa here.
    // Caller (Haskell poll after submit) knows data_pa and should invalidate there.
    // For now, we at least advance used idx
    ss->used_idx++;
    *out_id = id;
    *out_status = st;
    return 0;
}
