/* Guest RAM discovery + TTBR0/TTBR1 split.

   TTBR1 = kernel identity + RTS alias (Normal WB), TTBR0 = user (zeroed
   initially, per-process via house_mmu_set_ttbr0). 48-bit VA, 4K granule,
   IPS=40, TCR EPD1=0, MAIR 0xFF/0x04. RAM size is runtime house_ram_bytes
   (auto-detected, no compile limit). */

#include <stdint.h>

#include "uart.h"
#include "house_detect.h"

#ifndef HOUSE_SMP_N
#define HOUSE_SMP_N 2
#endif
#define RAM_BASE 0x40000000ULL   /* QEMU virt RAM start */

#define PTE_VALID    (1UL << 0)
#define PTE_TABLE    (1UL << 1)
#define PTE_BLOCK_AF (1UL << 10)
#define PTE_ATTR(n)  ((uint64_t)(n) << 2)
#define PTE_SH_INNER ((uint64_t)3 << 8)

#define ATTR_NORMAL 0            /* MAIR attr0: Normal inner/outer WB */
#define ATTR_DEVICE 1            /* MAIR attr1: Device-nGnRE */

static uint64_t ttbr1_l0[512] __attribute__((aligned(4096)));
uint64_t ttbr0_l0[512] __attribute__((aligned(4096)));
uint64_t l1_low[512] __attribute__((aligned(4096)));
/* RTS arena alias tier: eight level-2 tables of 2MB blocks cover up to
    8GB of VA 0x4200000000+ mapped onto upper-half guest RAM (4G working
    set uses 2GB, 8G/16G hosts use more). */
static uint64_t l1_rts[512] __attribute__((aligned(4096)));
static uint64_t l2_rts[8][512] __attribute__((aligned(4096)));
/* compat alias: old l0_table now ttbr1_l0 */
#define l0_table ttbr1_l0

/* Global 1GB block index within the first 512GB of VA (l1_low slot). */
static void map_block(int idx, int attr)
{
    l1_low[idx] = PTE_VALID | PTE_BLOCK_AF | PTE_SH_INNER |
                  PTE_ATTR(attr) | ((uint64_t)idx << 30);
}

static void dcache_clean_invalidate_all(void)
{
    // Minimal: QEMU virt has no real D-cache levels that need cleaning;
    // a full DCISW loop can fault on some TCG configurations. Just DSB.
    __asm__ volatile("dsb sy");
}

static inline uint64_t get_ram_bytes(void) {
    if (house_ram_bytes) return house_ram_bytes;
    // Early (before detect) — no limit, probe will determine. Map 16G max for probe.
    return 0;
}

static uint64_t tcr_value(void) {
    return (uint64_t)16             /* T0SZ 48-bit */
         | ((uint64_t)1 << 8)       /* IRGN0 WB */
         | ((uint64_t)1 << 10)      /* ORGN0 WB */
         | ((uint64_t)3 << 12)      /* SH0 inner */
         | ((uint64_t)0 << 14)      /* TG0 4K */
         | ((uint64_t)16 << 16)     /* T1SZ 48-bit */
         | ((uint64_t)0 << 22)      /* A1: TTBR0 base */
         | ((uint64_t)0 << 23)      /* EPD1 0: TTBR1 enabled, split VA */
         | ((uint64_t)1 << 24)      /* IRGN1 WB */
         | ((uint64_t)1 << 26)      /* ORGN1 WB */
         | ((uint64_t)3 << 28)      /* SH1 inner */
         | ((uint64_t)2 << 30)      /* TG1 4K */
         | ((uint64_t)2 << 32);     /* IPS 40-bit */
}

static void build_rts_alias(uint64_t span) {
    int i;
    uint64_t half = span >> 1;
    uint64_t stack_reserve = 0x200000ULL + (uint64_t)HOUSE_SMP_N * 16384ULL;
    uint64_t usable_half = half > stack_reserve ? half - stack_reserve : 0;
    uint64_t vspan64 = usable_half > (8UL << 30) ? (8UL << 30) : usable_half;
    int n_l2 = (int)((vspan64 + (1UL << 30) - 1) >> 30);
    uint64_t off;
    uint64_t pa = RAM_BASE + half;
    // Clear previous alias entries
    for (i = 0; i < 8; i++) {
        for (int e = 0; e < 512; e++) l2_rts[i][e] = 0;
        l1_rts[i] = 0;
        l1_low[264 + i] = 0;
    }
    if (n_l2 > 8) n_l2 = 8;
    for (i = 0; i < n_l2; i++) {
        l1_rts[i] = PTE_VALID | PTE_TABLE | (uint64_t)(uintptr_t)l2_rts[i];
        l1_low[264 + i] = l1_rts[i];
    }
    for (off = 0; off < vspan64; off += (1UL << 21)) {
        int t = (int)(off >> 30);
        int e = (int)((off >> 21) & 511);
        l2_rts[t][e] = PTE_VALID | PTE_BLOCK_AF | PTE_SH_INNER | PTE_ATTR(ATTR_NORMAL) | (pa + off);
    }
    __asm__ volatile("dsb sy; tlbi vmalle1; dsb sy; isb" ::: "memory");
}

void house_mmu_update_alias(void) {
    uint64_t span = get_ram_bytes();
    build_rts_alias(span);
}

/* Called from start.S once BSS is clear and SP is live; DAIF masked. */
void house_mmu_early(void)
{
    int i, blocks;
    uint64_t sctlr;
    uint64_t span = get_ram_bytes();
    if (span == 0) span = 4ULL<<30; // fallback 4G for early map (probe capped)

    /* Block 0 stays Device: PL011 @0x09000000, GIC @0x08000000. */
    map_block(0, ATTR_DEVICE);
    blocks = (int)((span + (1UL << 30) - 1) >> 30);
    for (i = 1; i <= blocks && i < 256; i++)     /* identity RAM */
        map_block(i, ATTR_NORMAL);

    build_rts_alias(span);
    /* Root pointers: staged identity via TTBR0 (TTBR1 disabled via EPD1). */
    for (i = 0; i < 512; i++) ttbr0_l0[i] = 0;
    for (i = 0; i < 512; i++) ttbr1_l0[i] = 0;
    ttbr1_l0[0] = PTE_VALID | PTE_TABLE | (uint64_t)(uintptr_t)l1_low;
    ttbr0_l0[0] = PTE_VALID | PTE_TABLE | (uint64_t)(uintptr_t)l1_low;
    /* every other entry stays invalid: fault loudly */

    __asm__ volatile("msr mair_el1, %0" ::
                     "r"((uint64_t)0xFF | ((uint64_t)0x04 << 8)));
    __asm__ volatile("msr tcr_el1, %0" :: "r"(tcr_value()));
    __asm__ volatile("msr ttbr0_el1, %0" :: "r"((uint64_t)ttbr0_l0));
    __asm__ volatile("msr ttbr1_el1, %0" :: "r"((uint64_t)ttbr1_l0));
    // Caches ON: clean D$, invalidate I$, TLB flush before enabling
    __asm__ volatile("dsb sy");
    __asm__ volatile("tlbi vmalle1");
    __asm__ volatile("ic iallu");
    __asm__ volatile("dsb sy; isb");
    dcache_clean_invalidate_all();
    __asm__ volatile("dsb sy; isb");

    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    __asm__ volatile("msr sctlr_el1, %0" :: "r"(sctlr | (1UL<<0) | (1UL<<2) | (1UL<<12)));
    __asm__ volatile("isb");
}

void house_mmu_enable_secondary(void)
{
    uint64_t sctlr;
    __asm__ volatile("msr mair_el1, %0" :: "r"((uint64_t)0xFF | ((uint64_t)0x04 << 8)));
    __asm__ volatile("msr tcr_el1, %0" :: "r"(tcr_value()));
    __asm__ volatile("msr ttbr0_el1, %0" :: "r"((uint64_t)ttbr0_l0));
    __asm__ volatile("msr ttbr1_el1, %0" :: "r"((uint64_t)ttbr1_l0));
    __asm__ volatile("dsb sy; tlbi vmalle1; ic iallu; dsb sy; isb");
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    __asm__ volatile("msr sctlr_el1, %0" :: "r"(sctlr | (1UL<<0) | (1UL<<2) | (1UL<<12)));
    __asm__ volatile("isb");
}

void house_mmu_set_ttbr0(void *pdir, uint64_t asid) {
    uint64_t v = ((uint64_t)(uintptr_t)pdir & ~0xFFFFULL) | (asid & 0xFFFF);
    {
        extern void uart_puts(const char *);
        uart_puts("[mmu] set start\n");
    }
    __asm__ volatile("msr ttbr0_el1, %0" :: "r"(v));
    {
        extern void uart_puts(const char *);
        uart_puts("[mmu] msr done\n");
    }
    __asm__ volatile("isb" ::: "memory");
    {
        extern void uart_puts(const char *);
        uart_puts("[mmu] isb done\n");
    }
    __asm__ volatile("dsb sy; isb" ::: "memory");
    {
        extern void uart_puts(const char *);
        uart_puts("[mmu] dsb done\n");
    }
}

void house_mmu_clone_kernel_l1(void *new_l1) {
    extern uint64_t l1_low[512];
    uint64_t *nl1 = (uint64_t *)new_l1;
    for (int i = 0; i < 512; i++) {
        uint64_t d = l1_low[i];
        if (d == 0) continue;
        if (i <= 3) continue; // user window 0x01000000–0xFFFFFFFF spans L1 0..3 (4×1GB); leave as tables/fault, don't clone kernel blocks
        nl1[i] = d;
    }
    __asm__ volatile("dsb sy; isb" ::: "memory");
}
void house_mmu_clone_kernel_l2(void *new_l2) {
    uint64_t *nl2 = (uint64_t *)new_l2;
    uint64_t dev_desc_08000000 = (0x08000000ULL) | (1ULL<<0) | (1ULL<<10) | (3ULL<<8) | (1ULL<<2);
    uint64_t dev_desc_09000000 = (0x09000000ULL) | (1ULL<<0) | (1ULL<<10) | (3ULL<<8) | (1ULL<<2);
    nl2[64] = dev_desc_08000000;
    nl2[72] = dev_desc_09000000;
    __asm__ volatile("dsb sy; isb" ::: "memory");
}

void house_mmu_map_kernel(uint64_t pa, uint64_t va, uint64_t size, uint64_t attr) {
    (void)pa; (void)va; (void)size; (void)attr;
    // stub for Phase 5 kernel vm: to be implemented when buddy live
}

void house_get_ttbrs(uint64_t *ttbr0, uint64_t *ttbr1, uint64_t *tcr) {
    uint64_t a,b,c;
    __asm__ volatile("mrs %0, ttbr0_el1" : "=r"(a));
    __asm__ volatile("mrs %0, ttbr1_el1" : "=r"(b));
    __asm__ volatile("mrs %0, tcr_el1" : "=r"(c));
    if (ttbr0) *ttbr0 = a;
    if (ttbr1) *ttbr1 = b;
    if (tcr) *tcr = c;
}
