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

// Flush Normal WB range before QueueNotify: DMB ISH -> DC CVAC per 64B -> DSB SY
void virtio_transport_dc_flush(uint64_t pa, size_t len) {
    if (len == 0) return;
    __asm__ volatile("dmb ish" ::: "memory");
    uint64_t start = pa & ~63ULL;
    uint64_t end = pa + len;
    for (uint64_t p = start; p < end; p += 64) {
        __asm__ volatile("dc cvac, %0" :: "r"(p) : "memory");
    }
    __asm__ volatile("dsb sy; dmb ish" ::: "memory");
}

int virtio_transport_get_status(int slot, uint32_t *status) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (!status) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    *status = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    return VIRTIO_OK;
}

int virtio_transport_set_status(int slot, uint32_t status) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    uint64_t base = slot_base(slot);
    mmio_w32(base + VIRTIO_MMIO_OFF_STATUS, status);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    return VIRTIO_OK;
}

int virtio_transport_init(int slot, uint32_t *dev_features_lo, uint32_t *dev_features_hi) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    uint32_t ver = mmio_r32(base + VIRTIO_MMIO_OFF_VERSION);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    if (ver != 1 && ver != 2) return VIRTIO_ERR_BAD_VERSION;
    uint32_t did = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_ID);
    if (did == 0) return VIRTIO_ERR_BAD_VERSION;
    // Reset then ACK | DRIVER
    mmio_w32(base + VIRTIO_MMIO_OFF_STATUS, 0);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_STATUS, VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    // Optionally return device features for logging
    if (dev_features_lo) {
        mmio_w32(base + VIRTIO_MMIO_OFF_DEVICE_FEATURES_SEL, 0);
        __asm__ volatile("dsb sy; isb" ::: "memory");
        *dev_features_lo = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_FEATURES);
    }
    if (dev_features_hi) {
        mmio_w32(base + VIRTIO_MMIO_OFF_DEVICE_FEATURES_SEL, 1);
        __asm__ volatile("dsb sy; isb" ::: "memory");
        *dev_features_hi = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_FEATURES);
    }
    uint32_t st = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    if (st & VIRTIO_STATUS_FAILED) return VIRTIO_ERR_NEEDS_RESET;
    return VIRTIO_OK;
}

int virtio_transport_set_features(int slot, uint64_t wanted) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    uint64_t base = slot_base(slot);
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    uint32_t ver = mmio_r32(base + VIRTIO_MMIO_OFF_VERSION);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    if (ver != 1 && ver != 2) return VIRTIO_ERR_BAD_VERSION;
    // Read device features
    mmio_w32(base + VIRTIO_MMIO_OFF_DEVICE_FEATURES_SEL, 0);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    uint32_t dev_lo = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_FEATURES);
    mmio_w32(base + VIRTIO_MMIO_OFF_DEVICE_FEATURES_SEL, 1);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    uint32_t dev_hi = mmio_r32(base + VIRTIO_MMIO_OFF_DEVICE_FEATURES);
    uint64_t dev = ((uint64_t)dev_hi << 32) | dev_lo;
    uint64_t neg = dev & wanted;
    // Virtio 1.0 requires VERSION_1 if host offers it; if host doesn't have it we feature-mismatch
    // For our wanted set, we only negotiate bits host has.
    uint32_t neg_lo = (uint32_t)(neg & 0xffffffffULL);
    uint32_t neg_hi = (uint32_t)((neg >> 32) & 0xffffffffULL);
    mmio_w32(base + VIRTIO_MMIO_OFF_DRIVER_FEATURES_SEL, 0);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_DRIVER_FEATURES, neg_lo);
    mmio_w32(base + VIRTIO_MMIO_OFF_DRIVER_FEATURES_SEL, 1);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_DRIVER_FEATURES, neg_hi);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    uint32_t st = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    st |= VIRTIO_STATUS_FEATURES_OK;
    mmio_w32(base + VIRTIO_MMIO_OFF_STATUS, st);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    st = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    if (st & VIRTIO_STATUS_FAILED) return VIRTIO_ERR_NEEDS_RESET;
    if ((st & VIRTIO_STATUS_FEATURES_OK) == 0) return VIRTIO_ERR_FEATURES_MISMATCH;
    return VIRTIO_OK;
}

int virtio_transport_queue_max(int slot, uint32_t *max) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (!max) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_SEL, 0);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    *max = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_NUM_MAX);
    return VIRTIO_OK;
}

int virtio_transport_queue_setup(int slot, uint64_t desc_pa, uint64_t avail_pa, uint64_t used_pa, uint32_t qsize) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    if (qsize == 0) return VIRTIO_ERR_INVAL;
    if ((desc_pa & 0xfffULL) || (avail_pa & 0xfffULL) || (used_pa & 0xfffULL)) return VIRTIO_ERR_INVAL;
    uint64_t base = slot_base(slot);
    // Verify device present
    uint32_t magic = mmio_r32(base + VIRTIO_MMIO_OFF_MAGIC);
    uint32_t ver = mmio_r32(base + VIRTIO_MMIO_OFF_VERSION);
    if (magic != VIRTIO_MMIO_MAGIC_H) return VIRTIO_ERR_BAD_VERSION;
    if (ver != 1 && ver != 2) return VIRTIO_ERR_BAD_VERSION;
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_SEL, 0);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    uint32_t qmax = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_NUM_MAX);
    if (qsize > qmax) return VIRTIO_ERR_NOSPC;
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_NUM, qsize);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_DESC_LOW, (uint32_t)(desc_pa & 0xffffffffULL));
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_DESC_HIGH, (uint32_t)((desc_pa >> 32) & 0xffffffffULL));
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_AVAIL_LOW, (uint32_t)(avail_pa & 0xffffffffULL));
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_AVAIL_HIGH, (uint32_t)((avail_pa >> 32) & 0xffffffffULL));
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_USED_LOW, (uint32_t)(used_pa & 0xffffffffULL));
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_USED_HIGH, (uint32_t)((used_pa >> 32) & 0xffffffffULL));
    __asm__ volatile("dsb sy; isb" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_READY, 1);
    __asm__ volatile("dsb sy; isb" ::: "memory");
    uint32_t ready = mmio_r32(base + VIRTIO_MMIO_OFF_QUEUE_READY);
    uint32_t st2 = mmio_r32(base + VIRTIO_MMIO_OFF_STATUS);
    if (ready != 1) {
        // debug via uart hex
        {
            // simple: print ready and status via uart_puts
            uart_puts("virtio queue ready fail ready=0x");
            const char *hex="0123456789abcdef";
            for(int i=7;i>=0;i--) {
                char c = hex[(ready >> (i*4)) & 0xF];
                char tmp[2] = {c,0};
                uart_puts(tmp);
            }
            uart_puts(" status=0x");
            for(int i=7;i>=0;i--) {
                char c = hex[(st2 >> (i*4)) & 0xF];
                char tmp[2] = {c,0};
                uart_puts(tmp);
            }
            uart_puts(" qmax=0x");
            for(int i=7;i>=0;i--) {
                char c = hex[(qmax >> (i*4)) & 0xF];
                char tmp[2] = {c,0};
                uart_puts(tmp);
            }
            uart_puts(" qsize=0x");
            for(int i=7;i>=0;i--) {
                char c = hex[(qsize >> (i*4)) & 0xF];
                char tmp[2] = {c,0};
                uart_puts(tmp);
            }
            uart_puts("\n");
        }
        return VIRTIO_ERR_NOT_READY;
    }
    (void)st2;
    return VIRTIO_OK;
}

int virtio_transport_notify(int slot, uint32_t qidx) {
    if (!slot_valid(slot)) return VIRTIO_ERR_BAD_SLOT;
    uint64_t base = slot_base(slot);
    // Caller should have flushed via dc_flush; double dmb for ordering
    __asm__ volatile("dmb ish" ::: "memory");
    mmio_w32(base + VIRTIO_MMIO_OFF_QUEUE_NOTIFY, qidx);
    __asm__ volatile("dsb sy; dmb ish" ::: "memory");
    return VIRTIO_OK;
}

uint32_t virtio_transport_interrupt_status(int slot) {
    if (!slot_valid(slot)) return 0;
    uint64_t base = slot_base(slot);
    return mmio_r32(base + VIRTIO_MMIO_OFF_INTERRUPT_STATUS);
}

void virtio_transport_ack(int slot, uint32_t mask) {
    if (!slot_valid(slot)) return;
    uint64_t base = slot_base(slot);
    mmio_w32(base + VIRTIO_MMIO_OFF_INTERRUPT_ACK, mask);
    __asm__ volatile("dsb sy; isb" ::: "memory");
}

uint64_t virtio_page_pa(void *p) {
    return (uint64_t)(uintptr_t)p;
}
