#ifndef HOUSE_DTB_H
#define HOUSE_DTB_H
#include <stdint.h>
#include <stddef.h>

int fdt_valid(const void *dtb);
uint64_t fdt_get_ram_bytes(const void *dtb);
int fdt_get_cpu_count(const void *dtb);

#endif
