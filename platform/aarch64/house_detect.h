#ifndef HOUSE_DETECT_H
#define HOUSE_DETECT_H
#include <stdint.h>

#define HOUSE_RAM_MIN_BYTES (128ULL << 20)
#define HOUSE_RAM_MAX_BYTES (16ULL << 30)
#define HOUSE_MAX_SMP 16
#define HOUSE_RAM_BASE 0x40000000ULL

extern uint64_t house_ram_bytes;
extern uint64_t house_boot_stack_top;
extern int house_smp;
extern const char *house_ram_source;

void house_detect_early(void);
void house_detect_late(void);
uint64_t house_ram_probe(void);
int house_smp_detect_psci(void);
int house_smp_detect_gicr(void);

#endif
