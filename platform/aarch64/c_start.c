#include <stdint.h>
#include "HsFFI.h"
#include "uart.h"
#include "irq.h"
#include "psci.h"
char *getenv(const char *n);
void hs_init(int *argc, char ***argv);

#ifndef HOUSE_SMP_N
#define HOUSE_SMP_N 2
#endif

extern void house_spike_main(void);

static void uart_puthex(uint64_t v)
{
    static const char digits[] = "0123456789abcdef";
    int i;
    uart_puts("0x");
    for (i = 60; i >= 0; i -= 4)
        uart_putc(digits[(v >> i) & 0xf]);
}

volatile uint32_t house_smp_online_mask = 1u; // core 0 online
volatile int house_smp_n = HOUSE_SMP_N;

static inline uint32_t house_cpu_id(void) {
    uint64_t mpidr;
    __asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
    return (uint32_t)(mpidr & 0xFF);
}

extern void secondary_entry(void);
extern void house_gic_init_secondary(uint32_t core);
extern void house_timer_init_secondary(uint32_t core);
extern void house_threads_init_secondary(uint32_t core);
void c_start_secondary(uint64_t core_id);

/* Synchronous exceptions: with I+D caches ON real LDXR/STXR are coherent
   across Inner-shareable Normal WB; the single-core exclusive emulation is
   removed. DFSC 0x35 is now fatal, as are all other sync faults. */
uint64_t c_handle_sync(uint64_t esr, uint64_t far, uint64_t elr,
                       uint64_t *gpr, void *fpi)
{
    (void)fpi;
    int ec = (int)((esr >> 26) & 0x3f);
    (void)ec;

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
    if (intid == 0) {
        // SGI IPI 0: scheduler kick
        extern void house_sched_ipi_handler(void);
        house_sched_ipi_handler();
        __asm__ volatile("msr ICC_EOIR1_EL1, %0" :: "r"(iar));
        __asm__ volatile("dsb sy; isb");
        return;
    }
    if (intid == 27) {
        /* rearm virtual timer and feed tick to RTS via timerfd seam */
        extern volatile uint64_t house_isr_pending[];
        extern volatile int house_isr_active;
        uint32_t core = house_cpu_id();
        __asm__ volatile("msr CNTV_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
        __asm__ volatile("isb");
        if (house_isr_active) house_isr_pending[core]++;
        // Timer tick is via pending counter + timerfd, not via H.Interrupts
        // ring. Suppress MPSC ring push for timer to avoid contention with N
        // cores each firing at 100Hz (SPSC assumption).
        extern void house_sched_maybe_preempt_from_isr(void);
        house_sched_maybe_preempt_from_isr();
    } else if (intid == 29 || intid == 30) {
        __asm__ volatile("msr CNTP_TVAL_EL0, %0" :: "r"((uint64_t)house_timer_interval));
        __asm__ volatile("isb");
        // physical timer also via pending; no ring push
        // house_irq_push(intid);
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
extern void house_mmu_early(void);

void c_start_secondary(uint64_t core_id)
{
    uint32_t core = (uint32_t)core_id;
    // Secondary cores: init GIC redistributor + timers + thread idle
    uart_puts("[house] c_start_secondary core "); uart_putc('0'+core); uart_puts("\n");
    house_gic_init_secondary(core);
    house_timer_init_secondary(core);
    house_threads_init_secondary(core);
    // Signal online: set bit and DSB
    house_smp_online_mask |= (1u << core);
    __asm__ volatile("dmb sy; dsb sy; sev");
    uart_puts("[house] secondary core "); uart_putc('0'+core); uart_puts(" online\n");
    // Idle loop: wait for work via IPI/wfi, handle irq via vectors
    house_irq_enable();
    for (;;) {
        __asm__ volatile("wfi");
        // IPI handler will have enqueued work; scheduler will switch via house_sched_yield
        // For now, just yield if runnable
        extern void house_sched_yield(void);
        house_sched_yield();
    }
}

void c_start(void)
{
    static int argc = 1;
    static char *argv_vals[] = { "house", 0 };
    static char **argv = argv_vals;

    uart_init();
    uart_puts("[house] c_start: irq_init\n");
    house_irq_init();
    house_thread_init_main();
    // SMP bring-up: PSCI CPU_ON for cores 1..N-1
    if (house_smp_n > 1) {
        uart_puts("[house] smp: bringing up "); uart_putc('0'+house_smp_n); uart_puts(" cores\n");
        for (int i = 1; i < house_smp_n; i++) {
            uint64_t entry = (uint64_t)(uintptr_t)secondary_entry;
            int64_t r = psci_cpu_on((uint64_t)i, entry, (uint64_t)i);
            uart_puts("[house] psci_cpu_on "); uart_putc('0'+i); uart_puts(" -> "); uart_puthex((uint64_t)r); uart_puts("\n");
        }
        // Wait for online mask (timeout ~1s)
        uint64_t start_ns;
        __asm__ volatile("mrs %0, cntvct_el0" : "=r"(start_ns));
        uint64_t freq; __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
        uint32_t want = (house_smp_n >= 32) ? 0xFFFFFFFFu : ((1u << house_smp_n)-1);
        while ((house_smp_online_mask & want) != want) {
            __asm__ volatile("wfe");
            uint64_t now; __asm__ volatile("mrs %0, cntvct_el0" : "=r"(now));
            if (freq && (now - start_ns) > freq) break; // 1s timeout
        }
        uart_puts("[house] smp: "); uart_puthex(house_smp_online_mask); uart_puts(" online mask (want "); uart_puthex(want); uart_puts(")\n");
        int online = 0;
        for (int i=0;i<32;i++) if (house_smp_online_mask & (1u<<i)) online++;
        uart_puts("[house] smp: "); uart_putc('0'+online); uart_puts(" cores online\n");
    }
    // RTS -N injection: default to -N = SMP_N if not already specified
    if (house_smp_n > 1) {
        int has_N = 0;
        for (int i=0;i<argc;i++) if (argv[i] && argv[i][0]=='-' && argv[i][1]=='N') has_N=1;
        char *ghcrts = getenv("GHCRTS");
        if (ghcrts) for (char *p=ghcrts; *p; p++) if (p[0]=='-' && p[1]=='N') has_N=1;
        if (!has_N) {
            static char nb[8];
            nb[0]='-'; nb[1]='N';
            int n=house_smp_n;
            int pos=2;
            if (n >= 100) nb[pos++]='0'+(n/100)%10;
            if (n >= 10) nb[pos++]='0'+(n/10)%10;
            nb[pos++]='0'+n%10;
            nb[pos]=0;
            static char *nargv[5];
            nargv[0]="house"; nargv[1]="+RTS"; nargv[2]=nb; nargv[3]="-RTS"; nargv[4]=0;
            argc=4; argv=nargv;
            uart_puts("[house] RTS "); uart_puts(nb); uart_puts(" injected\n");
        }
    }
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
