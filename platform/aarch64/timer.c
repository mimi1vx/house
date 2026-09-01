/* EL1 virtual/physical timer driver — PPIs 27,29.
   Arms both timers to fire periodically; ISR rearms TVAL and feeds
   the timerfd pending counter so the RTS ticker (poll+read seam) is
   now hardware-sourced. */

#include <stdint.h>
#include "irq.h"
#include "uart.h"

#ifndef HOUSE_MAX_SMP
#define HOUSE_MAX_SMP 16
#endif

volatile int house_isr_active = 0;
volatile uint64_t house_isr_pending[HOUSE_MAX_SMP] = {0};
uint32_t house_timer_interval = 0;
static uint64_t house_boot_ticks[HOUSE_MAX_SMP] = {0};

static uint64_t cntfrq(void) {
    uint64_t f;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
    return f ? f : 62500000ULL;
}

uint64_t house_uptime_secs(void) {
    uint64_t now;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(now));
    uint64_t freq = cntfrq();
    if (freq == 0) return 0;
    uint64_t boot = house_boot_ticks[0];
    // use current core's boot if available
    uint64_t mpidr; __asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
    uint32_t core = (uint32_t)(mpidr & 0xFF);
    if (core < HOUSE_MAX_SMP && house_boot_ticks[core]) boot = house_boot_ticks[core];
    else if (house_boot_ticks[0]) boot = house_boot_ticks[0];
    return (now - boot) / freq;
}

static void puthex64(uint64_t v) {
    static const char d[] = "0123456789abcdef";
    for (int i = 60; i >= 0; i -= 4) uart_putc(d[(v >> i) & 0xf]);
}

static void house_timer_init_for_core(uint32_t core) {
    // Guard against out-of-range core index (HOUSE_MAX_SMP=16)
    if (core >= HOUSE_MAX_SMP) return;
    uint64_t now;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(now));
    house_boot_ticks[core] = now;
    uint64_t freq = cntfrq();
    uint32_t interval = house_timer_interval;
    if (interval == 0) {
        interval = (uint32_t)(freq / 100);
        if (interval == 0) interval = (uint32_t)(freq / 10);
        house_timer_interval = interval;
        uart_puts("[house] timer: cntfrq=0x"); puthex64(freq);
        uart_puts(" interval=0x"); puthex64(interval); uart_puts("\n");
    }
    __asm__ volatile("msr CNTV_TVAL_EL0, %0" :: "r"((uint64_t)interval));
    __asm__ volatile("msr CNTV_CTL_EL0, %0" :: "r"((uint64_t)1));
    __asm__ volatile("isb");
    __asm__ volatile("msr CNTP_TVAL_EL0, %0" :: "r"((uint64_t)interval));
    __asm__ volatile("msr CNTP_CTL_EL0, %0" :: "r"((uint64_t)1));
    __asm__ volatile("isb");
    uint64_t ctl;
    __asm__ volatile("mrs %0, CNTV_CTL_EL0" : "=r"(ctl));
    uart_puts("[house] timer: CNTV_CTL=0x"); puthex64(ctl); uart_puts("\n");
    __asm__ volatile("mrs %0, CNTP_CTL_EL0" : "=r"(ctl));
    uart_puts("[house] timer: CNTP_CTL=0x"); puthex64(ctl); uart_puts("\n");
    house_isr_active = 1;
    __asm__ volatile("dsb sy; isb");
    uart_puts("[house] timer ok (isr_active=1) core "); uart_putc('0'+core); uart_puts("\n");
}

void house_timer_init(void) {
    house_timer_init_for_core(0);
}

void house_timer_init_secondary(uint32_t core) {
    // Single global ticker: keep timer disabled on secondaries to avoid MPSC
    // ring contention and per-core pending divergence. The primary core's
    // 100Hz tick drives timerfd for all caps (RTS ticker is single-threaded
    // or pinned to core 0 via tid<10). Secondaries still record boot tick
    // for uptime but do not arm their virtual/physical timers.
    if (core >= HOUSE_MAX_SMP) return;
    uint64_t now; __asm__ volatile("mrs %0, cntvct_el0" : "=r"(now));
    house_boot_ticks[core] = now;
    house_isr_pending[core] = 0;
    __asm__ volatile("msr CNTV_CTL_EL0, %0" :: "r"((uint64_t)0));
    __asm__ volatile("msr CNTP_CTL_EL0, %0" :: "r"((uint64_t)0));
    __asm__ volatile("isb");
    uart_puts("[house] timer secondary "); uart_putc('0'+core); uart_puts(" ok (no arm)\n");
}

void house_timer_rearm_virt(void) {
    __asm__ volatile("msr CNTV_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
    __asm__ volatile("isb");
}
void house_timer_rearm_phys(void) {
    __asm__ volatile("msr CNTP_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
    __asm__ volatile("isb");
}
