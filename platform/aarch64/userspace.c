#include <stdint.h>
#include "userspace.h"
#include "buddy.h"
#include "house_detect.h"

/* Freestanding page-pool + pagedir stubs for H.Pages / H.VirtualMemory.
   Legacy 512-page .bss pool kept as fallback until buddy_init wires the
   elastic window (H.Pages enumerates min..max at first alloc, so min/max
   must be updated before hs_init). Buddy region is
   __heap_base+64M .. house_boot_stack_top-16*16K, i.e. all RAM minus
   bump heap and top stacks, giving ~100K@512M / ~1M@4G pages. */

#define PAGE_POOL_N 512
#define PAGE_SIZE 4096

static uint8_t page_pool[PAGE_POOL_N * PAGE_SIZE] __attribute__((aligned(PAGE_SIZE)));

void *min_user_addr = (void *)page_pool;
void *max_user_addr = (void *)(page_pool + sizeof(page_pool));

void house_userspace_init(void) {
    // Keep legacy 512-page window for min/max; buddy pages are validated
    // via buddy_contains() in H.Pages.validPage. No overwrite to avoid
    // 1M enum recursion in H.Pages.freeList. Logging only.
    (void)house_boot_stack_top;
}

static void *recorded_pdir;

void init_page_dir(void *pdir) {
    recorded_pdir = pdir;
    __asm__ volatile("dsb sy; isb" ::: "memory");
}

void *current_pdir(void) {
    return recorded_pdir;
}

void invalidate_page(uint64_t vaddr) {
    /* TLBI VAAE1IS expects VA[55:12] in Xn; DSB/ISB complete the broadcast. */
    uint64_t va = vaddr >> 12;
    __asm__ volatile("tlbi vaae1is, %0; dsb ish; isb" :: "r"(va) : "memory");
}
