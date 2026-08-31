/* GICv3 driver for QEMU virt,gic-version=3 (single core).
   System-register CPU interface (ICC_*), redistributor at 0x080A0000,
   distributor at 0x08000000. Single-core, no affinity routing, no nesting. */

#include <stdint.h>
#include "irq.h"
#include "uart.h"

#define GICD_BASE 0x08000000ULL
#define GICR_BASE 0x080A0000ULL
#define GICR_WAKER_OFF 0x14
#define GICR_SGI_OFF   0x10000
#define GICR_IGROUPR0  (GICR_SGI_OFF + 0x80)
#define GICR_ISENABLER0 (GICR_SGI_OFF + 0x100)
#define GICR_ICENABLER0 (GICR_SGI_OFF + 0x180)
#define GICR_IGRPMODR0 (GICR_SGI_OFF + 0x0D00) /* optional */

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

void house_gic_init(void) {
    uint64_t s;
    /* ICC_SRE_EL1.SRE=1 (system register interface). ISB required. */
    __asm__ volatile("mrs %0, ICC_SRE_EL1" : "=r"(s));
    s |= 1ULL;
    __asm__ volatile("msr ICC_SRE_EL1, %0" :: "r"(s));
    __asm__ volatile("isb");

    /* PMR = 0xff (allow all priorities) */
    s = 0xff;
    __asm__ volatile("msr ICC_PMR_EL1, %0" :: "r"(s));
    __asm__ volatile("isb");

    /* Wake redistributor CPU0: clear ProcessorSleep (bit1), wait ChildrenAsleep==0 (bit2) */
    uint64_t waker_addr = GICR_BASE + GICR_WAKER_OFF;
    uint32_t w = mmio_r32(waker_addr);
    uart_puts("[house] gic: GICR_WAKER before=0x"); puthex32(w); uart_puts("\n");
    w &= ~(1u << 1); /* clear ProcessorSleep */
    mmio_w32(waker_addr, w);
    for (int i = 0; i < 1000000; i++) {
        w = mmio_r32(waker_addr);
        if ((w & (1u << 2)) == 0) break;
    }
    uart_puts("[house] gic: GICR_WAKER after=0x"); puthex32(w); uart_puts("\n");
    if (w & (1u << 2)) uart_puts("[house] gic: WARN WAKER still asleep\n");

    /* Mark PPIs 27,29,30 as Group1 (NS). SGI/PPI group via GICR.
       PPI 27 = virtual timer, 30 = non-secure physical timer (29 = secure
       phys on some configs — enable both 29 and 30 to be empirical-proof). */
    uint64_t igroup_addr = GICR_BASE + GICR_IGROUPR0;
    uint32_t gr = mmio_r32(igroup_addr);
    gr |= (1u << 27) | (1u << 29) | (1u << 30);
    mmio_w32(igroup_addr, gr);
    uart_puts("[house] gic: GICR_IGROUPR0=0x"); puthex32(mmio_r32(igroup_addr)); uart_puts("\n");

    /* Enable GICD (Group1). ARE=1 is already set by QEMU; enable via CTLR. */
    uint32_t ctlr = mmio_r32(GICD_BASE);
    uart_puts("[house] gic: GICD_CTLR before=0x"); puthex32(ctlr); uart_puts("\n");
    /* EnableGrp1 (bit1) — with ARE=1 this is EnableGrp1A. Try 0x02, fallback readback. */
    mmio_w32(GICD_BASE, ctlr | 0x02);
    ctlr = mmio_r32(GICD_BASE);
    uart_puts("[house] gic: GICD_CTLR after=0x"); puthex32(ctlr); uart_puts("\n");

    /* Enable PPIs 27,29,30 at redistributor. */
    uint64_t isen_addr = GICR_BASE + GICR_ISENABLER0;
    mmio_w32(isen_addr, (1u << 27) | (1u << 29) | (1u << 30));
    uart_puts("[house] gic: GICR_ISENABLER0=0x"); puthex32(mmio_r32(isen_addr)); uart_puts("\n");

    /* Enable Group1 via CPU interface. */
    s = 1;
    __asm__ volatile("msr ICC_IGRPEN1_EL1, %0" :: "r"(s));
    __asm__ volatile("isb");
    /* BPR: no grouping. */
    s = 0;
    __asm__ volatile("msr ICC_BPR1_EL1, %0" :: "r"(s));
    __asm__ volatile("isb");

    /* Check SRE again */
    __asm__ volatile("mrs %0, ICC_SRE_EL1" : "=r"(s));
    uart_puts("[house] gic: ICC_SRE_EL1=0x"); puthex64(s); uart_puts("\n");
    __asm__ volatile("mrs %0, ICC_PMR_EL1" : "=r"(s));
    uart_puts("[house] gic: ICC_PMR_EL1=0x"); puthex64(s); uart_puts("\n");
    __asm__ volatile("mrs %0, ICC_IGRPEN1_EL1" : "=r"(s));
    uart_puts("[house] gic: ICC_IGRPEN1_EL1=0x"); puthex64(s); uart_puts("\n");

    uart_puts("[house] gic ok\n");
}

void house_gic_enable_int(uint32_t intid) {
    if (intid < 32) {
        mmio_w32(GICR_BASE + GICR_ISENABLER0, 1u << intid);
    } else {
        uint64_t off = 0x100 + (intid / 32) * 4;
        mmio_w32(GICD_BASE + off, 1u << (intid % 32));
        /* ensure SPI is Group1: GICD IGROUPR at 0x80 */
        uint64_t igr = GICD_BASE + 0x80 + (intid / 32) * 4;
        uint32_t v = mmio_r32(igr);
        v |= 1u << (intid % 32);
        mmio_w32(igr, v);
    }
    __asm__ volatile("isb; dsb sy");
}

void house_gic_disable_int(uint32_t intid) {
    if (intid < 32) {
        mmio_w32(GICR_BASE + GICR_ICENABLER0, 1u << intid);
    } else {
        uint64_t off = 0x180 + (intid / 32) * 4;
        mmio_w32(GICD_BASE + off, 1u << (intid % 32));
    }
    __asm__ volatile("isb; dsb sy");
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
