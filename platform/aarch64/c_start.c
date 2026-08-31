#include <stdint.h>
#include "HsFFI.h"
#include "uart.h"
#include "irq.h"

extern void house_spike_main(void);

static void uart_puthex(uint64_t v)
{
    static const char digits[] = "0123456789abcdef";
    int i;
    uart_puts("0x");
    for (i = 60; i >= 0; i -= 4)
        uart_putc(digits[(v >> i) & 0xf]);
}

/* Single-core exclusive emulation. Apple HVF exits guest LL/SC ops as
   ISV=0 data aborts (IMPDEF DFSC=0x35) that QEMU forwards into the guest,
   independent of the mapping's attributes; the same class arises on Device
   memory with the MMU off. With one CPU an always-succeeding STXR is
   architecturally sound, so replay the op with ordinary loads/stores.
   Returns 1 if the faulting instruction was an exclusive op we handled. */
static int emu_exclusive(uint32_t w, uint64_t *gpr)
{
    uint32_t op = w & 0xFFE0FC00u;
    int rn = (int)((w >> 5) & 0x1f);
    int rt = (int)(w & 0x1f);
    int rs = (int)((w >> 16) & 0x1f);
    static const int szb[4] = { 1, 2, 4, 8 };
    volatile uint8_t *m = (volatile uint8_t *)gpr[rn];
    int n = szb[(w >> 30) & 3], i;
    uint64_t v;

    switch (op) {
    case 0x08407C00u: case 0x0840FC00u:     /* ldxrb / ldaxrb */
    case 0x48407C00u: case 0x4840FC00u:     /* ldxrh / ldaxrh */
    case 0x88407C00u: case 0x8840FC00u:     /* ldxr w / ldaxr w */
    case 0xC8407C00u: case 0xC840FC00u:     /* ldxr x / ldaxr x */
        v = 0;
        for (i = 0; i < n; i++)
            v |= (uint64_t)m[i] << (8 * i);
        if (rt != 31)
            gpr[rt] = v;                    /* narrow loads zero-extend */
        return 1;
    case 0x08007C00u: case 0x0800FC00u:     /* stxrb / stlxrb */
    case 0x48007C00u: case 0x4800FC00u:     /* stxrh / stlxrh */
    case 0x88007C00u: case 0x8800FC00u:     /* stxr w / stlxr w */
    case 0xC8007C00u: case 0xC800FC00u:     /* stxr x / stlxr x */
        v = rt != 31 ? gpr[rt] : 0;         /* Rt==31 stores XZR */
        for (i = 0; i < n; i++)
            m[i] = (uint8_t)(v >> (8 * i));
        if (rs != 31)
            gpr[rs] = 0;                    /* report exclusive success */
        return 1;
    }
    return 0;
}

/* Vector table landing for synchronous exceptions. Phase-3 alignment
   emulation (DFSC=0x21) has been trimmed: Normal non-cacheable RAM plus
   SCTLR.A=0 never faults on the GHC code paths and house-check proved no
   remaining source. Only the single-core exclusive emulation (DFSC=0x35)
   remains; everything else is fatal. */
uint64_t c_handle_sync(uint64_t esr, uint64_t far, uint64_t elr,
                       uint64_t *gpr, void *fpi)
{
    (void)fpi;
    int ec = (int)((esr >> 26) & 0x3f);
    int dfsc = (int)(esr & 0x3f);

    if (ec == 0x25 && dfsc == 0x35 &&
        emu_exclusive(*(volatile uint32_t *)elr, gpr))
        return elr + 4;

    uart_puts("\n[house] fatal sync exception ESR=");
    uart_puthex(esr);
    uart_puts(" FAR=");
    uart_puthex(far);
    uart_puts(" ELR=");
    uart_puthex(elr);
    if (ec == 0x25) {
        int q;
        uart_puts(" INSN=");
        uart_puthex(*(volatile uint32_t *)elr);
        for (q = 0; q <= 30; q++) {
            int k;
            char c = q < 10 ? '0' + q : 'a' + q - 10;
            uart_puts(" x");
            uart_putc(c);
            uart_putc('=');
            for (k = 60; k >= 0; k -= 4)
                uart_putc("0123456789abcdef"[(gpr[q] >> k) & 0xf]);
        }
    }
    uart_puts("\n");
    for (;;)
        __asm__ volatile ("wfi");
}

void c_handle_irq(uint64_t *gpr, void *fpi)
{
    (void)gpr; (void)fpi;
    uint64_t iar;
    __asm__ volatile("mrs %0, ICC_IAR1_EL1" : "=r"(iar));
    uint32_t intid = (uint32_t)(iar & 0xFFFFFF);
    if (intid == 1023) return; /* spurious */
    if (intid == 27) {
        /* rearm virtual timer and feed tick to RTS via timerfd seam */
        extern volatile uint64_t house_isr_pending;
        extern volatile int house_isr_active;
        __asm__ volatile("msr CNTV_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
        __asm__ volatile("isb");
        if (house_isr_active) house_isr_pending++;
        house_irq_push(intid);
        extern void house_sched_maybe_preempt_from_isr(void);
        house_sched_maybe_preempt_from_isr();
    } else if (intid == 29 || intid == 30) {
        __asm__ volatile("msr CNTP_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
        __asm__ volatile("isb");
        house_irq_push(intid);
    } else {
        house_irq_push(intid);
    }
    __asm__ volatile("msr ICC_EOIR1_EL1, %0" :: "r"(iar));
    __asm__ volatile("isb");
}

void fatal_exception(void)
{
    uint64_t esr, far, elr;
    __asm__ volatile ("mrs %0, esr_el1" : "=r" (esr));
    __asm__ volatile ("mrs %0, far_el1" : "=r" (far));
    __asm__ volatile ("mrs %0, elr_el1" : "=r" (elr));
    uart_puts("\n[house] fatal exception ESR=");
    uart_puthex(esr);
    uart_puts(" FAR=");
    uart_puthex(far);
    uart_puts(" ELR=");
    uart_puthex(elr);
    uart_puts("\n");
    for (;;)
        __asm__ volatile ("wfi");
}

__attribute__((weak)) void house_spike_main(void);
__attribute__((weak)) void house_irqcheck_main(void);
__attribute__((weak)) void house_main(void);

void house_thread_init_main(void);
void c_start(void)
{
    static int argc = 1;
    static char *argv_vals[] = { "house", 0 };
    static char **argv = argv_vals;

    uart_init();
    uart_puts("[house] c_start: irq_init\n");
    house_irq_init();
    house_thread_init_main();
    uart_puts("[house] c_start: hs_init\n");
    hs_init(&argc, &argv);
    if (house_main)
        house_main();
    else if (house_irqcheck_main)
        house_irqcheck_main();
    else if (house_spike_main)
        house_spike_main();
    else {
        uart_puts("[house] no main\n");
    }
    uart_puts("[house] c_start: returned, halting\n");
    for (;;)
        __asm__ volatile ("wfi");
}
