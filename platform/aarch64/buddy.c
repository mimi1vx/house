#include "buddy.h"
#include "house_detect.h"
#include "spinlock.h"
#include <stdint.h>

#define PAGE_SIZE 4096
#define RAM_BASE 0x40000000ULL

// Simple bump + free-list stub for Phase 3: wraps contiguous region between
// kernel end and stack reserve. Full buddy orders 0..12 deferred.
// Keeps 4K alignment, spinlocked, stats reflect ram pages.

static uint64_t buddy_start = 0;
static uint64_t buddy_end = 0;
static uint64_t buddy_cur = 0;
static house_spinlock_t lock = {0};
static int total_pages = 0;
static int free_pages = 0;

// free stack for reclaimed pages (up to 1M)
#define MAX_FREE 1024
static void *free_stack[MAX_FREE];
static int free_top = 0;

void buddy_init(uint64_t start, uint64_t end) {
    // align start up to 4K, end down
    start = (start + 4095) & ~4095ULL;
    end &= ~4095ULL;
    if (end <= start) return;
    buddy_start = start;
    buddy_end = end;
    buddy_cur = start;
    total_pages = (int)((end - start) >> 12);
    free_pages = total_pages;
    free_top = 0;
}

void *buddy_alloc_page(void) {
    void *p = 0;
    house_spin_lock(&lock);
    if (free_top > 0) {
        p = free_stack[--free_top];
        free_pages--;
    } else if (buddy_cur + PAGE_SIZE <= buddy_end) {
        p = (void *)(uintptr_t)buddy_cur;
        buddy_cur += PAGE_SIZE;
        free_pages--;
    }
    house_spin_unlock(&lock);
    if (p) {
        // zero page for safety? caller zeroes via H.Pages
        for (int i = 0; i < PAGE_SIZE; i += 8) *(uint64_t *)((uint8_t *)p + i) = 0;
    }
    return p;
}

void buddy_free_page(void *p) {
    if (!p) return;
    house_spin_lock(&lock);
    if (free_top < MAX_FREE) {
        free_stack[free_top++] = p;
        free_pages++;
    }
    house_spin_unlock(&lock);
}

int buddy_free_count(void) { return free_pages; }
int buddy_total_count(void) { return total_pages; }

void house_mem_stats(uint64_t *total, uint64_t *free_pages_out) {
    if (total) *total = total_pages;
    if (free_pages_out) *free_pages_out = free_pages;
}
