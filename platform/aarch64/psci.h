#pragma once
#include <stdint.h>

void psci_system_off(void);
void psci_system_reset(void);
int64_t psci_cpu_on(uint64_t mpidr, uint64_t entry, uint64_t ctx);
int64_t psci_cpu_off(void);
int64_t psci_affinity_info(uint64_t mpidr, uint64_t lowest);

#define PSCI_SUCCESS 0
#define PSCI_NOT_SUPPORTED (-1)
#define PSCI_ALREADY_ON (-2)
#define PSCI_ON_PENDING (-3)
