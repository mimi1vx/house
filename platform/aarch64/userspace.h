#pragma once
#include <stdint.h>

extern void *min_user_addr;
extern void *max_user_addr;

void init_page_dir(void *pdir);
void *current_pdir(void);
void invalidate_page(uint64_t vaddr);
void house_userspace_init(void);
