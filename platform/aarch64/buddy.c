#include "buddy.h"
#include "house_detect.h"
#include "spinlock.h"
#include <stdint.h>

#define PAGE_SIZE 4096

// Intrusive free-list + bump allocator over whole detected RAM minus
// kernel/bump/stack carve-out. Keeps 4K alignment, spinlocked via
// house_spinlock_t (DMB SY), stats reflect ram pages. Buddy orders 0..12
// deferred — split/merge not needed until hugepage/large alloc paths.

static uint64_t buddy_start = 0;
static uint64_t buddy_end = 0;
static uint64_t buddy_cur = 0;
static house_spinlock_t lock = {0};
static int total_pages = 0;
static int free_pages = 0;
static void *free_head = 0;

void buddy_init(uint64_t start, uint64_t end) {
    start = (start + 4095) & ~4095ULL;
    end &= ~4095ULL;
    if (end <= start) return;
    house_spin_lock(&lock);
    // Allow re-init if called twice early (keep first region)
    if (buddy_start && buddy_end) { house_spin_unlock(&lock); return; }
    buddy_start = start;
    buddy_end = end;
    buddy_cur = start;
    total_pages = (int)((end - start) >> 12);
    free_pages = total_pages;
    free_head = 0;
    house_spin_unlock(&lock);
}

void *buddy_alloc_page(void) {
    void *p = 0;
    house_spin_lock(&lock);
    if (free_head) {
        p = free_head;
        free_head = *(void **)p;
        if (free_pages > 0) free_pages--;
    } else if (buddy_cur + PAGE_SIZE <= buddy_end) {
        p = (void *)(uintptr_t)buddy_cur;
        buddy_cur += PAGE_SIZE;
        if (free_pages > 0) free_pages--;
    }
    house_spin_unlock(&lock);
    if (p) {
        for (int i = 0; i < PAGE_SIZE; i += 8) *(uint64_t *)((uint8_t *)p + i) = 0;
    }
    return p;
}

void buddy_free_page(void *p) {
    if (!p) return;
    uintptr_t v = (uintptr_t)p;
    if (v < buddy_start || v >= buddy_end) return;
    if (v & 4095) return;
    house_spin_lock(&lock);
    *(void **)p = free_head;
    free_head = p;
    if (free_pages < total_pages) free_pages++;
    house_spin_unlock(&lock);
}

int buddy_free_count(void) { return free_pages; }
int buddy_total_count(void) { return total_pages; }

void house_mem_stats(uint64_t *total, uint64_t *free_pages_out) {
    int tp, fp;
    house_spin_lock(&lock);
    tp = total_pages; fp = free_pages;
    house_spin_unlock(&lock);
    if (total) *total = (uint64_t)tp;
    if (free_pages_out) *free_pages_out = (uint64_t)fp;
}

int buddy_contains(void *p) {
    uintptr_t v = (uintptr_t)p;
    if (v & 4095) return 0;
    // copy under lock? start/end stable after init
    uint64_t s = buddy_start, e = buddy_end;
    return v >= s && v < e;
}
