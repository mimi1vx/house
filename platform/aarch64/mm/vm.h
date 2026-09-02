#pragma once
#include <stddef.h>
#include <stdint.h>

#define HOUSE_USER_VA_MIN 0x01000000ULL
#define HOUSE_USER_VA_MAX 0xFFFFFFFFULL

void *house_vm_mmap(void *addr, size_t len, int prot, int flags, int fd, long off);
int house_vm_munmap(void *addr, size_t len);
int house_vm_mprotect(void *addr, size_t len, int prot);
int house_vm_demand_single(void);
int house_vm_demand_100(void);
void house_puts_after(void);
