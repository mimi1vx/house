#pragma once
#include <stdint.h>

extern void *min_user_addr;
extern void *max_user_addr;

void init_page_dir(void *pdir);
void *current_pdir(void);
void invalidate_page(uint64_t vaddr);
void house_userspace_init(void);
void house_tlb_shootdown(uint64_t vaddr);
int house_handle_user_fault(uint64_t far);
int house_is_ro_page(uint64_t va);

// Exit signalling for EL0 svc EXIT (polled by Haskell waitPid)
extern volatile int house_user_exited;
extern volatile int house_user_exit_code;
void house_set_exit(int code);

// EL0 entry provided by start.S
void house_enter_el0(uint64_t entry, uint64_t sp, void *pdir, uint64_t asid);
void svc_exit_trampoline(void);
uint64_t house_asid_for_pdir(void *pdir);
void house_set_recorded_pdir(void *pdir);
