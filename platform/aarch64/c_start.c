#include <stdint.h>
#include "HsFFI.h"
#include "uart.h"
#include "irq.h"
#include "psci.h"
#include "house_detect.h"
#include "buddy.h"
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

extern volatile int house_in_probe;
extern volatile uint64_t house_probe_recovery;
extern volatile int house_probe_faulted;

/* Synchronous exceptions: with I+D caches ON real LDXR/STXR are coherent
   across Inner-shareable Normal WB; the single-core exclusive emulation is
   removed. DFSC 0x35 is now fatal, as are all other sync faults. Probe
   path (house_probe.c) uses fault-trapped scan: if house_in_probe and
   EC 0x25 data abort, flag fault and jump to recovery ELR. */
uint64_t c_handle_sync(uint64_t esr, uint64_t far, uint64_t elr,
                       uint64_t *gpr, void *fpi)
{
    (void)fpi;
    int ec = (int)((esr >> 26) & 0x3f);
    if (house_in_probe && (ec == 0x24 || ec == 0x25)) {
        house_probe_faulted = 1;
        __asm__ volatile("dsb sy; isb");
        // Skip faulting LDR (4 bytes) — more robust than label address
        return elr + 4;
    }
    // Demand-pager: EL1 faults on TTBR0 user VA (0x01000000–0xFFFFFFFF) — try to allocate
    {
        int is_data_abort = (ec == 0x24 || ec == 0x25);
        int is_insn_abort = (ec == 0x20 || ec == 0x21);
        if ((is_data_abort || is_insn_abort) && far >= 0x01000000ULL && far <= 0xFFFFFFFFULL) {
            extern int house_handle_user_fault(uint64_t far);
            if (house_handle_user_fault(far)) {
                __asm__ volatile("dsb ish; isb");
                return elr; // retry faulting instruction
            }
        }
    }
    // Permission fault RO guard: DFSC 0x0C..0x0F, WnR=1, FAR in user window, PTE AP_RO
    {
        uint64_t dfsc = esr & 0x3f;
        int is_data_abort = (ec == 0x24 || ec == 0x25);
        int is_insn_abort = (ec == 0x20 || ec == 0x21);
        int is_permission = (dfsc >= 0x0C && dfsc <= 0x0F);
        int wnr = (int)((esr >> 6) & 1);
        if ((is_data_abort || is_insn_abort) && is_permission && wnr) {
            if (far >= 0x01000000ULL && far <= 0xFFFFFFFFULL) {
                extern int house_is_ro_page(uint64_t);
                if (house_is_ro_page(far)) {
                    uart_puts("[demand] perm fault RO far="); uart_puthex(far);
                    uart_puts(" DFSC="); uart_puthex(dfsc);
                    uart_puts(" ESR="); uart_puthex(esr); uart_puts("\n");
                    // Skip faulting store to avoid livelock; SIGSEGV delivery deferred to PR2b
                    __asm__ volatile("dsb sy; isb");
                    return elr + 4;
                } else {
                    uart_puts("[demand] perm fault far="); uart_puthex(far);
                    uart_puts(" DFSC="); uart_puthex(dfsc); uart_puts("\n");
                }
            }
        }
    }
    // SVC EC 0x15 dispatch — EL0 svc #imm after probe+pager
    if (ec == 0x15) {
        uint64_t spsr_val;
        __asm__ volatile("mrs %0, spsr_el1" : "=r"(spsr_val));
        int is_el0 = ((spsr_val & 0xF) == 0);
        if (is_el0) {
            uint32_t svc_imm = (uint32_t)(esr & 0xFFFF);
            extern int64_t house_svc_dispatch(uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t *);
            int64_t r = house_svc_dispatch(svc_imm, gpr[0], gpr[1], gpr[2], gpr[3], gpr);
            (void)r;
            if (svc_imm == 0x02) {
                // EXIT: restore kernel TTBR0 and return to EL1 trampoline
                extern uint64_t ttbr0_l0[512];
                extern void svc_exit_trampoline(void);
                extern void house_set_recorded_pdir(void*);
                house_set_recorded_pdir((void*)ttbr0_l0);
                __asm__ volatile("msr ttbr0_el1, %0" :: "r"((uint64_t)(uintptr_t)ttbr0_l0) : "memory");
                __asm__ volatile("dsb ish; tlbi vmalle1is; dsb ish; isb" ::: "memory");
                __asm__ volatile("msr spsr_el1, %0" :: "r"((uint64_t)0x3c5) : "memory");
                return (uint64_t)(uintptr_t)svc_exit_trampoline;
            }
            return elr;
        }
        // EL1 SVC unexpected — fall through to fatal after logging
        uart_puts("[svc] EL1 SVC unexpected imm="); uart_puthex(esr & 0xFFFF); uart_puts("\n");
    }
    uart_puts("[probe] in_probe="); uart_putc('0'+ (house_in_probe?1:0)); uart_puts(" ec="); uart_puthex(esr); uart_puts(" far="); uart_puthex(far); uart_puts(" elr="); uart_puthex(elr); uart_puts(" rec="); uart_puthex(house_probe_recovery); uart_puts("\n");

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
    if (intid == 1) {
        // SGI 1: TLB shootdown (invalidate all, ASID-aware would be VAE1)
        __asm__ volatile("dsb ish; tlbi vmalle1is; dsb ish; isb" ::: "memory");
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
        if (house_isr_active) __atomic_fetch_add(&house_isr_pending[core], 1, __ATOMIC_SEQ_CST);
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
    uart_puts("[house] c_start_secondary core "); uart_putc('0'+core); uart_puts("\n");
    house_gic_init_secondary(core);
    house_timer_init_secondary(core);
    house_threads_init_secondary(core);
    // Signal online: atomic OR and DSB
    __atomic_fetch_or(&house_smp_online_mask, 1u << core, __ATOMIC_SEQ_CST);
    __asm__ volatile("dmb sy; dsb sy; sev");
    uart_puts("[house] secondary core "); uart_putc('0'+core); uart_puts(" online\n");
    // Idle loop: wait for work via IPI/wfe with SEV fallback.
    house_irq_enable();
    for (;;) {
        __asm__ volatile("wfe");
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
    house_detect_early();
    {
        uart_puts("[house] detect early: ram=");
        uart_puthex(house_ram_bytes);
        uart_puts(" smp="); uart_putc('0'+house_smp);
        uart_puts(" src="); uart_puts(house_ram_source);
        uart_puts(" stack_top="); uart_puthex(house_boot_stack_top);
        { extern uint64_t __boot_dtb; uart_puts(" dtb="); uart_puthex((uint64_t)(uintptr_t)__boot_dtb); }
        uart_puts("\n");
        // Rebase SP from early low stacks to runtime high stacks now that
        // house_boot_stack_top is known (safe for both 512M and 4G QEMU).
        {
            uint64_t core = (uint64_t)house_cpu_id();
            uint64_t new_sp = house_boot_stack_top - core * 16384ULL;
            __asm__ volatile("mov sp, %0" :: "r"(new_sp) : "memory");
        }
    }
    // Update RTS alias for correct half-RAM after probe (mmu early used fallback)
    {
        extern void house_mmu_update_alias(void);
        house_mmu_update_alias();
        uart_puts("[house] mmu alias updated for ram "); uart_puthex(house_ram_bytes); uart_puts("\n");
    }
    uart_puts("[house] c_start: irq_init\n");
    house_irq_init();
    // Buddy over whole RAM minus bump heap (64M at 0x42000000) and top stacks
    {
        extern char __heap_base[];
        uint64_t pool_top = (uint64_t)(uintptr_t)__heap_base + (64ULL << 20);
        uint64_t b_start = (pool_top + 4095) & ~4095ULL;
        uint64_t b_end = house_boot_stack_top;
        if (b_end > (uint64_t)HOUSE_MAX_SMP * 16384ULL) b_end -= (uint64_t)HOUSE_MAX_SMP * 16384ULL;
        b_end &= ~4095ULL;
        if (b_end > b_start) {
            buddy_init(b_start, b_end);
            uart_puts("[house] buddy: "); uart_puthex(b_start); uart_puts(".."); uart_puthex(b_end);
            uart_puts(" pages="); {
                uint64_t tp, fp; house_mem_stats(&tp, &fp);
                uart_puthex(tp); uart_puts("/"); uart_puthex(fp);
            } uart_puts("\n");
            extern void house_userspace_init(void);
            extern void *min_user_addr;
            extern void *max_user_addr;
            house_userspace_init();
            uart_puts("[house] userspace: "); uart_puthex((uint64_t)(uintptr_t)min_user_addr); uart_puts(".."); uart_puthex((uint64_t)(uintptr_t)max_user_addr); uart_puts("\n");
        }
    }
    house_detect_late();
    // Sync late SMP to global and log
    uart_puts("[house] c_start: house_smp_n="); uart_putc('0'+house_smp_n); uart_puts("\n");
    house_thread_init_main();
    // SMP bring-up: PSCI CPU_ON for cores 1..N-1
    if (house_smp_n > 1) {
        uart_puts("[house] smp: bringing up "); uart_putc('0'+house_smp_n); uart_puts(" cores\n");
        for (int i = 1; i < house_smp_n; i++) {
            uint64_t entry = (uint64_t)(uintptr_t)secondary_entry;
            int64_t r = psci_cpu_on((uint64_t)i, entry, (uint64_t)i);
            uart_puts("[house] psci_cpu_on "); uart_putc('0'+i); uart_puts(" -> "); uart_puthex((uint64_t)r); uart_puts("\n");
        }
        // Wait for online mask (timeout ~2s for TCG 4 cores)
        uint64_t start_ns;
        __asm__ volatile("mrs %0, cntvct_el0" : "=r"(start_ns));
        uint64_t freq; __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(freq));
        uint32_t want = (house_smp_n >= 32) ? 0xFFFFFFFFu : ((1u << house_smp_n)-1);
        while ((__atomic_load_n(&house_smp_online_mask, __ATOMIC_SEQ_CST) & want) != want) {
            __asm__ volatile("wfe");
            uint64_t now; __asm__ volatile("mrs %0, cntvct_el0" : "=r"(now));
            if (freq && (now - start_ns) > freq * 2) break; // 2s timeout
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
