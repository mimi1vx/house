/* Guest RAM discovery + early identity page tables.

   With the MMU disabled every data access is Device-nGnRnE: unaligned
   pairs fault regardless of SCTLR.A, and exclusive ops abort outright.
   Two levels, 1GB blocks: TTBR0 -> L0 -> one populated L1 covering the
   first 512GB of VA. Block 0 keeps peripheral attributes (PL011/GIC),
   the guest RAM blocks become Normal; every other entry stays invalid
   so wild pointers fault loudly instead of silently reading zeros.
   48-bit VA because the stock RTS reserves terabyte-scale address-space
   arenas (NORESERVE promises — only committed chunks, backed by real
   RAM, are ever touched).

   The RTS heap arena (VA 0x4200000000+, see alloc.c) aliases the second
   half of guest RAM through a third-level tier of 2MB blocks, sized so
   commits can never reach past real RAM even for small guests.

   RAM extent comes from HOUSE_RAM_BYTES (from the top-level Makefile,
   paired with the -m flag of the QEMU invocation).
   Caches stay off (SCTLR.C/I=0): Normal non-cacheable already carries
   full access semantics, without cache-maintenance hazards. */

#include <stdint.h>

#include "uart.h"

#ifndef HOUSE_RAM_BYTES
#define HOUSE_RAM_BYTES 0x100000000ULL   /* 4G */
#endif
#define RAM_BASE 0x40000000ULL   /* QEMU virt RAM start */

#define PTE_VALID    (1UL << 0)
#define PTE_TABLE    (1UL << 1)
#define PTE_BLOCK_AF (1UL << 10)
#define PTE_ATTR(n)  ((uint64_t)(n) << 2)
#define PTE_SH_INNER ((uint64_t)3 << 8)

#define ATTR_NORMAL 0            /* MAIR attr0: Normal inner/outer WB */
#define ATTR_DEVICE 1            /* MAIR attr1: Device-nGnRE */

static uint64_t l0_table[512] __attribute__((aligned(4096)));
static uint64_t l1_low[512] __attribute__((aligned(4096)));
/* RTS arena alias tier: two level-2 tables of 2MB blocks cover up to
   2GB of VA 0x4200000000+ mapped onto upper-half guest RAM. */
static uint64_t l1_rts[512] __attribute__((aligned(4096)));
static uint64_t l2_rts[2][512] __attribute__((aligned(4096)));

/* Global 1GB block index within the first 512GB of VA (l1_low slot). */
static void map_block(int idx, int attr)
{
    l1_low[idx] = PTE_VALID | PTE_BLOCK_AF | PTE_SH_INNER |
                  PTE_ATTR(attr) | ((uint64_t)idx << 30);
}

/* Called from start.S once BSS is clear and SP is live; DAIF masked. */
void house_mmu_early(void)
{
    int i, blocks;
    uint64_t sctlr;
    uint64_t span = HOUSE_RAM_BYTES;
    uint64_t half = span >> 1;

    /* Block 0 stays Device: PL011 @0x09000000, GIC @0x08000000. */
    map_block(0, ATTR_DEVICE);
    blocks = (int)((span + (1UL << 30) - 1) >> 30);
    for (i = 1; i <= blocks && i < 256; i++)     /* identity RAM */
        map_block(i, ATTR_NORMAL);

    /* RTS working window: VA 0x4200000000+k*2MB -> upper-half RAM.
       2MB granularity keeps the committable span exact even for small
       guests; commits walk upward from the base and never reach past
       the aliased span. */
    {
        /* 32-bit int would truncate a 2GB-span intermediate below: keep
           the arithmetic in u64 and bound before narrowing. */
        uint64_t vspan64 = half > (2UL << 30) ? (2UL << 30) : half;
        int n_l2 = (int)((vspan64 + (1UL << 30) - 1) >> 30);
        uint64_t off;
        uint64_t pa = RAM_BASE + half;
        if (n_l2 > 2)
            n_l2 = 2;
        for (i = 0; i < n_l2; i++) {
            l1_rts[i] = PTE_VALID | PTE_TABLE |
                        (uint64_t)(uintptr_t)l2_rts[i];
            l1_low[264 + i] = l1_rts[i];         /* VA 0x4200000000+ */
        }
        for (off = 0; off < vspan64; off += (1UL << 21)) {
            int t = (int)(off >> 30);
            int e = (int)((off >> 21) & 511);
            l2_rts[t][e] = PTE_VALID | PTE_BLOCK_AF | PTE_SH_INNER |
                           PTE_ATTR(ATTR_NORMAL) | (pa + off);
        }
    }
    /* Root pointer: without it EVERY walk fails at level 0 and the
       first post-enable fetch storms forever. */
    l0_table[0] = PTE_VALID | PTE_TABLE | (uint64_t)(uintptr_t)l1_low;
    /* every other entry stays invalid: touching it faults loudly */

    __asm__ volatile("msr mair_el1, %0" ::
                     "r"((uint64_t)0xFF | ((uint64_t)0x04 << 8)));
    __asm__ volatile("msr tcr_el1, %0" :: "r"(
        (uint64_t)16             /* T0SZ: 48-bit VA, walk starts at L0 */
        | ((uint64_t)1 << 8)     /* IRGN0 write-back */
        | ((uint64_t)1 << 10)    /* ORGN0 write-back */
        | ((uint64_t)3 << 12)    /* SH0 inner-shareable */
        | ((uint64_t)1 << 23)    /* EPD1: never walk TTBR1 */
        | ((uint64_t)2 << 32))); /* IPS: 40-bit PA */
    __asm__ volatile("msr ttbr0_el1, %0" :: "r"((uint64_t)l0_table));
    __asm__ volatile("isb; dsb sy; tlbi vmalle1; dsb sy");

    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    __asm__ volatile("msr sctlr_el1, %0" :: "r"(sctlr | 1UL)); /* M=1 */
    __asm__ volatile("isb");
}
