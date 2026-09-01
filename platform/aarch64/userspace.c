#include <stdint.h>
#include "userspace.h"
#include "buddy.h"
#include "house_detect.h"
#include "spinlock.h"

/* Freestanding page-pool + per-process TTBR0/ASID for H.Pages / H.VirtualMemory.
    Legacy 512-page .bss pool kept as fallback until buddy_init wires the
    elastic window (H.Pages enumerates min..max at first alloc, so min/max
    must be updated before hs_init). Buddy region is
    __heap_base+64M .. house_boot_stack_top-16*16K, i.e. all RAM minus
    bump heap and top stacks, giving ~100K@512M / ~1M@4G pages.
    TTBR0 is per-PageMap via house_mmu_set_ttbr0 + 8-bit ASID tag. */

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
static house_spinlock_t asid_lock = {0};
static uint16_t next_asid = 1; // 0 reserved for kernel TTBR0 identity
#define ASID_MAP_N 64
static struct { void *pdir; uint16_t asid; } asid_map[ASID_MAP_N];
static int asid_map_n = 0;

extern void house_mmu_set_ttbr0(void *pdir, uint64_t asid);

static uint16_t asid_for_pdir(void *pdir) {
    house_spin_lock(&asid_lock);
    for (int i = 0; i < asid_map_n; i++) if (asid_map[i].pdir == pdir) {
        uint16_t a = asid_map[i].asid;
        house_spin_unlock(&asid_lock);
        return a;
    }
    uint16_t a = next_asid++;
    if (next_asid == 0 || next_asid > 250) next_asid = 1; // wrap, keep <255
    if (a == 0) a = next_asid++;
    if (asid_map_n < ASID_MAP_N) {
        asid_map[asid_map_n].pdir = pdir;
        asid_map[asid_map_n].asid = a;
        asid_map_n++;
    }
    house_spin_unlock(&asid_lock);
    return a;
}

void init_page_dir(void *pdir) {
    if (!pdir) return;
    if ((uintptr_t)pdir & 4095) return; // misaligned - ignore
    uint16_t asid = asid_for_pdir(pdir);
    recorded_pdir = pdir;
    house_mmu_set_ttbr0(pdir, asid);
}

void *current_pdir(void) {
    return recorded_pdir;
}

void invalidate_page(uint64_t vaddr) {
    /* TLBI VAAE1IS expects VA[55:12] in Xn; DSB/ISB complete the broadcast. */
    uint64_t va = vaddr >> 12;
    __asm__ volatile("tlbi vaae1is, %0; dsb ish; isb" :: "r"(va) : "memory");
}

void house_tlb_shootdown(uint64_t vaddr) {
    uint64_t va = vaddr >> 12;
    __asm__ volatile("dsb ishst; tlbi vaae1is, %0; dsb ish; isb" :: "r"(va) : "memory");
    extern int house_smp_n;
    extern void house_gic_send_sgi_to_core(uint32_t sgi_id, uint32_t core);
    if (house_smp_n > 1) {
        for (int c = 1; c < house_smp_n && c < 16; c++) house_gic_send_sgi_to_core(1, (uint32_t)c);
        __asm__ volatile("dsb sy; isb" ::: "memory");
    }
}

// Demand pager: EL1 translation fault at user VA (TTBR0) → allocate 4K and map.
// Returns 1 if handled (retry instruction), 0 to fall through to fatal.
int house_handle_user_fault(uint64_t far) {
    const uint64_t minV = 0x01000000ULL;
    const uint64_t maxV = 0x3FFFFFFFULL;
    if (far < minV || far > maxV) return 0;
    uint64_t va = far & ~4095ULL;
    void *pdir = recorded_pdir;
    if (!pdir) return 0;
    if ((uintptr_t)pdir & 4095) return 0;
    void *page = buddy_alloc_page();
    if (!page) return 0;
    // Table walk: allocate missing levels via buddy (pre-pinned Normal WB)
    #define PTE_VALID  (1ULL<<0)
    #define PTE_TABLE  (1ULL<<1)
    #define PTE_AF     (1ULL<<10)
    #define PTE_SH_INNER (3ULL<<8)
    #define PTE_NG     (1ULL<<11)
    #define PTE_UXN    (1ULL<<54)
    #define PTE_PXN    (1ULL<<53)
    #define PTE_AP_RW  (1ULL<<6)
    #define PTE_ATTR(n) ((uint64_t)(n)<<2)
    uint64_t *l0 = (uint64_t *)pdir;
    int i0 = (int)((va>>39)&0x1FF);
    uint64_t d0 = l0[i0];
    if ((d0 & PTE_VALID)==0) {
        uint64_t *nl1 = (uint64_t *)buddy_alloc_page();
        if (!nl1) { buddy_free_page(page); return 0; }
        l0[i0] = ((uint64_t)(uintptr_t)nl1 & ~0xFFFULL) | PTE_VALID | PTE_TABLE;
        __asm__ volatile("dsb sy; isb" ::: "memory");
        d0 = l0[i0];
    }
    uint64_t *l1 = (uint64_t *)(uintptr_t)(d0 & ~0xFFFULL);
    int i1 = (int)((va>>30)&0x1FF);
    uint64_t d1 = l1[i1];
    uint64_t *l2;
    if ((d1 & PTE_VALID)==0) {
        l2 = (uint64_t *)buddy_alloc_page();
        if (!l2) { buddy_free_page(page); return 0; }
        l1[i1] = ((uint64_t)(uintptr_t)l2 & ~0xFFFULL) | PTE_VALID | PTE_TABLE;
        d1 = l1[i1];
    }
    l2 = (uint64_t *)(uintptr_t)(d1 & ~0xFFFULL);
    int i2 = (int)((va>>21)&0x1FF);
    uint64_t d2 = l2[i2];
    uint64_t *l3;
    if ((d2 & PTE_VALID)==0) {
        l3 = (uint64_t *)buddy_alloc_page();
        if (!l3) { buddy_free_page(page); return 0; }
        l2[i2] = ((uint64_t)(uintptr_t)l3 & ~0xFFFULL) | PTE_VALID | PTE_TABLE;
        d2 = l2[i2];
    }
    l3 = (uint64_t *)(uintptr_t)(d2 & ~0xFFFULL);
    int i3 = (int)((va>>12)&0x1FF);
    uint64_t d3 = l3[i3];
    if ((d3 & PTE_VALID)!=0) {
        // Already mapped - spurious fault (permission maybe), don't leak page
        buddy_free_page(page);
        return 0;
    }
    uint64_t desc = ((uint64_t)(uintptr_t)page & ~0xFFFULL)
                  | PTE_VALID | PTE_TABLE | PTE_AF | PTE_SH_INNER | PTE_NG | PTE_UXN | PTE_PXN
                  | PTE_ATTR(0) | PTE_AP_RW;
    l3[i3] = desc;
    __asm__ volatile("dsb ishst; tlbi vaae1is, %0; dsb ish; isb" :: "r"(va>>12) : "memory");
    #undef PTE_VALID
    #undef PTE_TABLE
    #undef PTE_AF
    #undef PTE_SH_INNER
    #undef PTE_NG
    #undef PTE_UXN
    #undef PTE_PXN
    #undef PTE_AP_RW
    #undef PTE_ATTR
    return 1;
}
