#include <stdint.h>
#include "userspace.h"

/* Freestanding page-pool + pagedir stubs for H.Pages / H.VirtualMemory.
   See plans/phase-3-interrupts-vm.md: the window is a real RAM pool carved
   outside the RTS alias/malloc arenas. Here the pool lives in .bss so it is
   identity-mapped Normal and distinct from the bump heap at __heap_base
   (0x42000000). TLBI is a safe no-op while user tables are never loaded
   into TTBR0. */

#define PAGE_POOL_N 512
#define PAGE_SIZE 4096

static uint8_t page_pool[PAGE_POOL_N * PAGE_SIZE] __attribute__((aligned(PAGE_SIZE)));

void *min_user_addr = (void *)page_pool;
void *max_user_addr = (void *)(page_pool + sizeof(page_pool));

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
