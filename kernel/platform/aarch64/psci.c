#include <stdint.h>

static void psci_call(uint32_t fid) {
    register uint64_t x0 __asm__("x0") = fid;
    __asm__ volatile("hvc #0" : "+r"(x0) :: "memory");
}

void psci_system_off(void) {
    psci_call(0x84000008u);
    for (;;) __asm__ volatile("wfi");
}

void psci_system_reset(void) {
    psci_call(0x84000009u);
    for (;;) __asm__ volatile("wfi");
}
