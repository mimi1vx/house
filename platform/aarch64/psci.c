#include <stdint.h>
#include "psci.h"

static int64_t psci_call3(uint64_t fid, uint64_t a1, uint64_t a2, uint64_t a3, int use_smc) {
    register uint64_t x0 __asm__("x0") = fid;
    register uint64_t x1 __asm__("x1") = a1;
    register uint64_t x2 __asm__("x2") = a2;
    register uint64_t x3 __asm__("x3") = a3;
    if (use_smc) {
        __asm__ volatile("smc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3) : "memory");
    } else {
        __asm__ volatile("hvc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3) : "memory");
    }
    return (int64_t)x0;
}

static int64_t psci_call1(uint32_t fid, int use_smc) {
    return psci_call3(fid, 0, 0, 0, use_smc);
}

void psci_system_off(void) {
    psci_call1(0x84000008u, 0);
    for (;;) __asm__ volatile("wfi");
}

void psci_system_reset(void) {
    psci_call1(0x84000009u, 0);
    for (;;) __asm__ volatile("wfi");
}

int64_t psci_cpu_on(uint64_t mpidr, uint64_t entry, uint64_t ctx) {
    int64_t r = psci_call3(0xC4000003ULL, mpidr, entry, ctx, 0);
    if (r == PSCI_NOT_SUPPORTED) {
        r = psci_call3(0xC4000003ULL, mpidr, entry, ctx, 1);
    }
    return r;
}

int64_t psci_cpu_off(void) {
    int64_t r = psci_call1(0x84000002u, 0);
    if (r == PSCI_NOT_SUPPORTED) r = psci_call1(0x84000002u, 1);
    return r;
}

int64_t psci_affinity_info(uint64_t mpidr, uint64_t lowest) {
    int64_t r = psci_call3(0xC4000004ULL, mpidr, lowest, 0, 0);
    if (r == PSCI_NOT_SUPPORTED) r = psci_call3(0xC4000004ULL, mpidr, lowest, 0, 1);
    return r;
}
