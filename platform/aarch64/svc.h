#pragma once
#include <stdint.h>

// Syscall numbers (svc #imm)
#define HOUSE_SVC_WRITE    0x01
#define HOUSE_SVC_EXIT     0x02
#define HOUSE_SVC_BRK      0x03

// EL0 entry: noreturn until svc EXIT erets to trampoline
void house_enter_el0(uint64_t entry, uint64_t sp, void *pdir, uint64_t asid);

// SVC dispatch: validates args, performs write/exit/brk/ipc.
// gpr is the saved x0-x30 frame; gpr[0] is set to return value on success.
// Returns 1 if handled (caller should use updated gpr and advance ELR),
// 0 if not handled (fall through to fatal).
int64_t house_svc_dispatch(uint32_t imm, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t *gpr);

// Exit signalling polled by Haskell waitPid
extern volatile int house_user_exited;
extern volatile int house_user_exit_code;
void house_set_exit(int code);
int house_get_exit_code(void);
void house_clear_exit(void);
int house_is_exited(void);

// Symbol provided by start.S — EL1 trampoline after EL0 exit
extern void svc_exit_trampoline(void);
