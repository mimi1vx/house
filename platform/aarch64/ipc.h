#pragma once
#include <stdint.h>
#include <stddef.h>

// Phase 1b EL0 svc multiplex — reserved numbers, dispatch is ENOSYS until TTBR0 landing (Track 6).
// Same Endpoint API as Haskell Phase 1a; no ABI break.
#define HOUSE_SVC_IPC_SEND   0x10
#define HOUSE_SVC_IPC_RECV   0x11
#define HOUSE_SVC_IPC_CALL   0x12
#define HOUSE_SVC_IPC_REPLY  0x13
#define HOUSE_SVC_IPC_GRANT_MAP 0x14

// Copy helper for future TTBR0 user pages. Current Haskell path uses RTS heap coherency
// via SCTLR.C/I=1 WB + dmb ish in irq.c ring; this stub marks where EL0 copy will need
// dmb ish / dc cvac / dsb sy .
void house_ipc_copy_msg(const void *src, void *dst, size_t len);

// EL0 svc dispatch — returns -ENOSYS until EL0/TTBR0 wired. Guarded behind HOUSE_IPC.
int64_t house_ipc_svc_dispatch(uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3);
