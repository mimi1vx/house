/* EL1 virtual/physical timer driver — PPIs 27,29.
   Arms both timers to fire periodically; ISR rearms TVAL and feeds
   the timerfd pending counter so the RTS ticker (poll+read seam) is
   now hardware-sourced. */

#include <stdint.h>
#include "irq.h"
#include "uart.h"

volatile int house_isr_active = 0;
volatile uint64_t house_isr_pending = 0;
uint32_t house_timer_interval = 0;

static uint64_t cntfrq(void) {
    uint64_t f;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
    return f ? f : 62500000ULL;
}

static void puthex64(uint64_t v) {
    static const char d[] = "0123456789abcdef";
    for (int i = 60; i >= 0; i -= 4) uart_putc(d[(v >> i) & 0xf]);
}

void house_timer_init(void) {
    uint64_t freq = cntfrq();
    /* 10ms tick — cntfrq/100 */
    uint32_t interval = (uint32_t)(freq / 100);
    if (interval == 0) interval = (uint32_t)(freq / 10);
    house_timer_interval = interval;

    uart_puts("[house] timer: cntfrq=0x"); puthex64(freq);
    uart_puts(" interval=0x"); puthex64(interval); uart_puts("\n");

    /* Virtual timer (PPI 27): enable, not masked. */
    __asm__ volatile("msr CNTV_TVAL_EL0, %0" :: "r"((uint64_t)interval));
    __asm__ volatile("msr CNTV_CTL_EL0, %0" :: "r"((uint64_t)1)); /* ENABLE=1, IMASK=0 */
    __asm__ volatile("isb");

    /* Physical timer (PPI 29): second source for dispatcher test. */
    __asm__ volatile("msr CNTP_TVAL_EL0, %0" :: "r"((uint64_t)interval));
    __asm__ volatile("msr CNTP_CTL_EL0, %0" :: "r"((uint64_t)1));
    __asm__ volatile("isb");

    uint64_t ctl;
    __asm__ volatile("mrs %0, CNTV_CTL_EL0" : "=r"(ctl));
    uart_puts("[house] timer: CNTV_CTL=0x"); puthex64(ctl); uart_puts("\n");
    __asm__ volatile("mrs %0, CNTP_CTL_EL0" : "=r"(ctl));
    uart_puts("[house] timer: CNTP_CTL=0x"); puthex64(ctl); uart_puts("\n");

    /* From now on house_timerfd_due returns pending>0 instead of wall-clock. */
    house_isr_active = 1;
    __asm__ volatile("dsb sy; isb");
    uart_puts("[house] timer ok (isr_active=1)\n");
}

void house_timer_rearm_virt(void) {
    __asm__ volatile("msr CNTV_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
    __asm__ volatile("isb");
}
void house_timer_rearm_phys(void) {
    __asm__ volatile("msr CNTP_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
    __asm__ volatile("isb");
}
