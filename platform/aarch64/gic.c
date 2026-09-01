/* GICv3 driver for QEMU virt,gic-version=3 per-core.
   System-register CPU interface (ICC_*), redistributor per core at
   0x080A0000 + core*0x20000, distributor at 0x08000000. */

#include <stdint.h>
#include "irq.h"
#include "uart.h"

#define GICD_BASE 0x08000000ULL
#define GICR_BASE 0x080A0000ULL
#define GICR_STRIDE 0x20000ULL
#define GICR_WAKER_OFF 0x14
#define GICR_SGI_OFF   0x10000
#define GICR_IGROUPR0  (GICR_SGI_OFF + 0x80)
#define GICR_ISENABLER0 (GICR_SGI_OFF + 0x100)
#define GICR_ICENABLER0 (GICR_SGI_OFF + 0x180)

static inline uint64_t gicr_base(uint32_t core) { return GICR_BASE + (uint64_t)core * GICR_STRIDE; }
static inline uint32_t mmio_r32(uint64_t a) { return *(volatile uint32_t *)(uintptr_t)a; }
static inline void mmio_w32(uint64_t a, uint32_t v) { *(volatile uint32_t *)(uintptr_t)a = v; }

static void puthex32(uint32_t v) {
    static const char d[] = "0123456789abcdef";
    for (int i = 28; i >= 0; i -= 4) uart_putc(d[(v >> i) & 0xf]);
}
static void puthex64(uint64_t v) {
    static const char d[] = "0123456789abcdef";
    for (int i = 60; i >= 0; i -= 4) uart_putc(d[(v >> i) & 0xf]);
}

static void gic_enable_sre(void) {
    uint64_t s;
    __asm__ volatile("mrs %0, ICC_SRE_EL1" : "=r"(s));
    s |= 1ULL;
    __asm__ volatile("msr ICC_SRE_EL1, %0" :: "r"(s));
    __asm__ volatile("isb");
    s = 0xff;
    __asm__ volatile("msr ICC_PMR_EL1, %0" :: "r"(s));
    __asm__ volatile("isb");
    s = 1;
    __asm__ volatile("msr ICC_IGRPEN1_EL1, %0" :: "r"(s));
    __asm__ volatile("isb");
    s = 0;
    __asm__ volatile("msr ICC_BPR1_EL1, %0" :: "r"(s));
    __asm__ volatile("isb");
}

void house_gic_init(void) {
    uint64_t s;
    gic_enable_sre();

    /* Wake redistributor CPU0 */
    uint64_t waker_addr = gicr_base(0) + GICR_WAKER_OFF;
    uint32_t w = mmio_r32(waker_addr);
    uart_puts("[house] gic: GICR_WAKER before=0x"); puthex32(w); uart_puts("\n");
    w &= ~(1u << 1);
    mmio_w32(waker_addr, w);
    for (int i = 0; i < 1000000; i++) {
        w = mmio_r32(waker_addr);
        if ((w & (1u << 2)) == 0) break;
    }
    uart_puts("[house] gic: GICR_WAKER after=0x"); puthex32(w); uart_puts("\n");
    if (w & (1u << 2)) uart_puts("[house] gic: WARN WAKER still asleep\n");

    uint64_t igroup_addr = gicr_base(0) + GICR_IGROUPR0;
    uint32_t gr = mmio_r32(igroup_addr);
    gr |= (1u << 27) | (1u << 29) | (1u << 30) | (1u << SGI_IPI);
    mmio_w32(igroup_addr, gr);
    uart_puts("[house] gic: GICR_IGROUPR0=0x"); puthex32(mmio_r32(igroup_addr)); uart_puts("\n");

    uint32_t ctlr = mmio_r32(GICD_BASE);
    uart_puts("[house] gic: GICD_CTLR before=0x"); puthex32(ctlr); uart_puts("\n");
    mmio_w32(GICD_BASE, ctlr | 0x02);
    ctlr = mmio_r32(GICD_BASE);
    uart_puts("[house] gic: GICD_CTLR after=0x"); puthex32(ctlr); uart_puts("\n");

    uint64_t isen_addr = gicr_base(0) + GICR_ISENABLER0;
    mmio_w32(isen_addr, (1u << 27) | (1u << 29) | (1u << 30) | (1u << SGI_IPI));
    uart_puts("[house] gic: GICR_ISENABLER0=0x"); puthex32(mmio_r32(isen_addr)); uart_puts("\n");

    __asm__ volatile("mrs %0, ICC_SRE_EL1" : "=r"(s));
    uart_puts("[house] gic: ICC_SRE_EL1=0x"); puthex64(s); uart_puts("\n");
    __asm__ volatile("mrs %0, ICC_PMR_EL1" : "=r"(s));
    uart_puts("[house] gic: ICC_PMR_EL1=0x"); puthex64(s); uart_puts("\n");
    __asm__ volatile("mrs %0, ICC_IGRPEN1_EL1" : "=r"(s));
    uart_puts("[house] gic: ICC_IGRPEN1_EL1=0x"); puthex64(s); uart_puts("\n");

    uart_puts("[house] gic ok\n");
}

void house_gic_init_secondary(uint32_t core) {
    uint64_t waker_addr = gicr_base(core) + GICR_WAKER_OFF;
    uint32_t w = mmio_r32(waker_addr);
    w &= ~(1u << 1);
    mmio_w32(waker_addr, w);
    __asm__ volatile("dsb sy; isb");
    for (int i = 0; i < 1000000; i++) {
        w = mmio_r32(waker_addr);
        if ((w & (1u << 2)) == 0) break;
    }
    uint64_t igroup_addr = gicr_base(core) + GICR_IGROUPR0;
    uint32_t gr = mmio_r32(igroup_addr);
    gr |= (1u << 27) | (1u << 29) | (1u << 30) | (1u << SGI_IPI);
    mmio_w32(igroup_addr, gr);
    __asm__ volatile("dsb sy; isb");
    uint64_t isen_addr = gicr_base(core) + GICR_ISENABLER0;
    mmio_w32(isen_addr, (1u << 27) | (1u << 29) | (1u << 30) | (1u << SGI_IPI));
    __asm__ volatile("dsb sy; isb");
    gic_enable_sre();
    __asm__ volatile("dsb sy; isb");
    uart_puts("[house] gic secondary "); uart_putc('0'+core); uart_puts(" ok\n");
}

void house_gic_enable_int(uint32_t intid) {
    if (intid < 32) {
        // PPI on current core? Use calling core's redistributor
        uint64_t mpidr; __asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
        uint32_t core = (uint32_t)(mpidr & 0xFF);
        mmio_w32(gicr_base(core) + GICR_ISENABLER0, 1u << intid);
    } else {
        uint64_t off = 0x100 + (intid / 32) * 4;
        mmio_w32(GICD_BASE + off, 1u << (intid % 32));
        uint64_t igr = GICD_BASE + 0x80 + (intid / 32) * 4;
        uint32_t v = mmio_r32(igr);
        v |= 1u << (intid % 32);
        mmio_w32(igr, v);
    }
    __asm__ volatile("isb; dsb sy");
}

void house_gic_disable_int(uint32_t intid) {
    if (intid < 32) {
        uint64_t mpidr; __asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
        uint32_t core = (uint32_t)(mpidr & 0xFF);
        mmio_w32(gicr_base(core) + GICR_ICENABLER0, 1u << intid);
    } else {
        uint64_t off = 0x180 + (intid / 32) * 4;
        mmio_w32(GICD_BASE + off, 1u << (intid % 32));
    }
    __asm__ volatile("isb; dsb sy");
}

void house_gic_send_sgi_to_core(uint32_t sgi_id, uint32_t core) {
    // ICC_SGI1R_EL1 unicast: Aff3[55:48] Aff2[39:32] Aff1[23:16] RS[47:44] TargetList[15:0]
    // For N<=16 with Aff1=Aff2=Aff3=0 this reduces to old mask (1<<core).
    // RS selects 16-core slice, TargetList bit is core%16.
    uint64_t aff3 = (core >> 24) & 0xff;
    uint64_t aff2 = (core >> 16) & 0xff;
    uint64_t aff1 = (core >> 8) & 0xff;
    uint64_t rs = (core >> 4) & 0xf;
    uint64_t bit = 1ULL << (core & 0xf);
    uint64_t v = (aff3 << 48) | (rs << 44) | (aff2 << 32) |
                 ((uint64_t)(sgi_id & 0xf) << 24) | (aff1 << 16) | bit;
    __asm__ volatile("msr ICC_SGI1R_EL1, %0" :: "r"(v));
    __asm__ volatile("isb; dsb sy");
}

void house_gic_send_sgi(uint32_t sgi_id, uint32_t aff0_mask) {
    // Mask variant (single-cluster broadcast). For correctness across
    // clusters, iterate and use unicast helper per bit.
    if (aff0_mask == 0) return;
    // Fast path: if all targets share Aff1/Aff2/Aff3==0 and mask fits 16 bits,
    // we can use the direct encoding; otherwise unicast loop.
    // For now, always loop via unicast to stay correct for any Aff topology.
    for (int core = 0; core < 16; core++) {
        if (aff0_mask & (1u << core)) {
            house_gic_send_sgi_to_core(sgi_id, (uint32_t)core);
        }
    }
    // Handle bits beyond 15 via RS>0 (cores 16..)
    for (int core = 16; core < 32; core++) {
        if (aff0_mask & (1u << core)) { // overflow bit, but caller should use unicast for >15
            house_gic_send_sgi_to_core(sgi_id, (uint32_t)core);
        }
    }
}

void house_gic_enable_sgi(uint32_t id) {
    house_gic_enable_int(id);
}

void house_gic_eoi(uint32_t iar) {
    __asm__ volatile("msr ICC_EOIR1_EL1, %0" :: "r"((uint64_t)iar));
    __asm__ volatile("isb");
}

void house_irq_enable(void) {
    __asm__ volatile("msr daifclr, #2");
    __asm__ volatile("isb");
}
void house_irq_disable(void) {
    __asm__ volatile("msr daifset, #2");
    __asm__ volatile("isb");
}
