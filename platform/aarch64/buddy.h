#ifndef HOUSE_BUDDY_H
#define HOUSE_BUDDY_H
#include <stdint.h>
#include <stddef.h>

void buddy_init(uint64_t start, uint64_t end);
void *buddy_alloc_page(void);
void buddy_free_page(void *p);
int buddy_free_count(void);
int buddy_total_count(void);
void house_mem_stats(uint64_t *total, uint64_t *free_pages);

#endif
