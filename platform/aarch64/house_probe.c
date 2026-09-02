#include "house_detect.h"
#include <stdint.h>

volatile int house_in_probe = 0;
volatile uint64_t house_probe_recovery = 0;
volatile int house_probe_faulted = 0;

__attribute__((noinline))
static int probe_addr(uint64_t addr) {
    volatile uint64_t tmp = 0;
    house_in_probe = 1;
    __asm__ volatile("dsb sy; isb" ::: "memory");
    house_probe_recovery = (uint64_t)&&after;
    __asm__ volatile (
        "ldr %0, [%1]\n"
        : "=r"(tmp)
        : "r"((void *)(uintptr_t)addr)
        : "memory"
    );
after:
    __asm__ volatile("dsb sy; isb" ::: "memory");
    house_in_probe = 0;
    int f = house_probe_faulted;
    house_probe_faulted = 0;
    return f ? 0 : 1;
}

uint64_t house_ram_probe(void) {
    const uint64_t sizes[] = {
        16ULL<<30, 8ULL<<30, 4ULL<<30, 2ULL<<30,
        1ULL<<30, 512ULL<<20, 256ULL<<20, 128ULL<<20
    };
#ifdef HOUSE_RAM_LIMIT_BYTES
    uint64_t limit = HOUSE_RAM_LIMIT_BYTES;
#else
    uint64_t limit = 0;
#endif
    for (int i = 0; i < 8; i++) {
        uint64_t sz = sizes[i];
        if (limit && sz > limit) continue;
        uint64_t addr = HOUSE_RAM_BASE + sz - 8;
        if (probe_addr(addr)) return sz;
    }
    return 0;
}
