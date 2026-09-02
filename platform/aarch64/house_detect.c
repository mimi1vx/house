#include "house_detect.h"
#include "house_dtb.h"
#include "uart.h"
#include "psci.h"

#ifndef HOUSE_SMP_N
#define HOUSE_SMP_N 2
#endif

uint64_t house_ram_bytes = 0;
uint64_t house_boot_stack_top = 0;
int house_smp = 0;
const char *house_ram_source = "unknown";

// provided by start.S
extern uint64_t __boot_dtb;
extern volatile int house_smp_n;

static uint64_t fallback_ram(void) { return HOUSE_RAM_MIN_BYTES; }
static int fallback_smp(void) { return HOUSE_SMP_N; }

void house_detect_early(void) {
    uint64_t ram = 0;
    const char *src = "fallback";
    int smp = 0;

    // DTB first
    const void *dtb = (const void *)(uintptr_t)__boot_dtb;
    if (fdt_valid(dtb)) {
        uint64_t dtb_ram = fdt_get_ram_bytes(dtb);
        if (dtb_ram >= HOUSE_RAM_MIN_BYTES && dtb_ram <= HOUSE_RAM_MAX_BYTES) {
            ram = dtb_ram;
            src = "dtb";
        }
        int cpus = fdt_get_cpu_count(dtb);
        if (cpus >= 1 && cpus <= HOUSE_MAX_SMP) smp = cpus;
    }

    if (!ram) {
        uint64_t probed = house_ram_probe();
        if (probed >= HOUSE_RAM_MIN_BYTES && probed <= HOUSE_RAM_MAX_BYTES) {
            ram = probed;
            src = "probe";
        }
    }
    if (!ram) {
        ram = fallback_ram();
        src = "fallback";
    }
    // clamp to 2M alignment
    ram &= ~((1ULL << 21) - 1);
    if (ram < HOUSE_RAM_MIN_BYTES) ram = HOUSE_RAM_MIN_BYTES;
    if (ram > HOUSE_RAM_MAX_BYTES) ram = HOUSE_RAM_MAX_BYTES;

    house_ram_bytes = ram;
    house_ram_source = src;
    house_boot_stack_top = HOUSE_RAM_BASE + ram - 0x200000ULL;

    if (smp) house_smp = smp;
    else house_smp = fallback_smp();
    if (house_smp < 1) house_smp = 1;
    if (house_smp > HOUSE_MAX_SMP) house_smp = HOUSE_MAX_SMP;

    // limit caps
#ifdef HOUSE_SMP_LIMIT
    if (house_smp > HOUSE_SMP_LIMIT) house_smp = HOUSE_SMP_LIMIT;
#endif
#ifdef HOUSE_RAM_LIMIT_BYTES
    if (house_ram_bytes > HOUSE_RAM_LIMIT_BYTES) {
        house_ram_bytes = HOUSE_RAM_LIMIT_BYTES;
        house_boot_stack_top = HOUSE_RAM_BASE + house_ram_bytes - 0x200000ULL;
    }
#endif
}

int house_smp_detect_psci(void) {
    int count = 0;
    for (int i = 0; i < 32; i++) {
        int64_t r = psci_affinity_info((uint64_t)i, 0);
        if (r == 0 || r == 1 || r == 3) count++;
    }
    if (count < 1) return 0;
    if (count > HOUSE_MAX_SMP) count = HOUSE_MAX_SMP;
    return count;
}

int house_smp_detect_gicr(void) {
    // GICR_TYPER at 0x080A0000 + i*0x20000 + 0x08, bit 4 = Last - use plain LDR to keep ISV=1
    const uint64_t base = 0x080A0000ULL;
    const uint64_t stride = 0x20000ULL;
    int count = 0;
    for (int i = 0; i < HOUSE_MAX_SMP; i++) {
        uint64_t addr = base + (uint64_t)i * stride + 0x08;
        uint64_t v;
        __asm__ volatile("ldr %0, [%1]" : "=r"(v) : "r"(addr) : "memory");
        __asm__ volatile("" ::: "memory");
        // If reading unmapped GICR returns 0, stop after at least 1
        if (i > 0 && v == 0) break;
        count++;
        if (v & (1ULL << 4)) break; // Last
        if (count >= HOUSE_MAX_SMP) break;
    }
    if (count < 1) return 0;
    if (count > HOUSE_MAX_SMP) count = HOUSE_MAX_SMP;
    return count;
}

void house_detect_late(void) {
    int dtb_smp = 0;
    const void *dtb = (const void *)(uintptr_t)__boot_dtb;
    if (fdt_valid(dtb)) dtb_smp = fdt_get_cpu_count(dtb);
    int psci = house_smp_detect_psci();
    int gicr = house_smp_detect_gicr();
    int chosen = dtb_smp;
    const char *src = "dtb";

    if (dtb_smp <= 0 || dtb_smp > HOUSE_MAX_SMP) {
        if (psci >= 1 && psci <= HOUSE_MAX_SMP) { chosen = psci; src = "psci"; }
        else if (gicr >= 1 && gicr <= HOUSE_MAX_SMP) { chosen = gicr; src = "gicr"; }
        else { chosen = fallback_smp(); src = "fallback"; }
    } else {
        src = "dtb";
        // If PSCI/GICR report more, take max (handles stale DTB vs QEMU smp mismatch)
        if (psci > chosen && psci <= HOUSE_MAX_SMP) { chosen = psci; src = "psci>d tb"; }
        if (gicr > chosen && gicr <= HOUSE_MAX_SMP) { chosen = gicr; src = "gicr>dtb"; }
    }

    // clamp to compile-time limit/MAX
    if (chosen < 1) chosen = 1;
    if (chosen > HOUSE_MAX_SMP) chosen = HOUSE_MAX_SMP;
#ifdef HOUSE_SMP_LIMIT
    if (chosen > HOUSE_SMP_LIMIT) chosen = HOUSE_SMP_LIMIT;
#endif

    house_smp = chosen;
    house_smp_n = chosen;

    // Recompute stack top if ram changed? keep.

    // Log late detection
    uart_puts("[house] detect late: smp dtb=");
    // hex print helper inline
    {
        char buf[32];
        // simple decimal print for small ints
        int n = chosen;
        uart_puts(" chosen="); uart_putc('0' + (n >= 10 ? (n/10)%10 : 0)); if (n>=10) uart_putc('0'+n%10); else uart_putc('0'+ (n%10));
        uart_puts(" src="); uart_puts(src);
        uart_puts(" psci="); uart_putc('0'+psci); uart_puts(" gicr="); uart_putc('0'+gicr); uart_puts("\n");
        (void)buf;
    }
}
