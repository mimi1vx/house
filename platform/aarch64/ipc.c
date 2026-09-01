#include "ipc.h"
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>

// Stub for Phase 1b EL0 svc dispatch. No TTBR0 switch yet — returns ENOSYS.
// Guard behind HOUSE_IPC if needed; default enabled but no-op.

int64_t house_ipc_svc_dispatch(uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3) {
    (void)x0; (void)x1; (void)x2; (void)x3;
    // svc numbers 0x10-0x14 reserved; dispatch not wired until Track 6 (userspace)
    // ENOSYS == 38 on Linux aarch64
    return -38;
}

void house_ipc_copy_msg(const void *src, void *dst, size_t len) {
    // Future EL0 path: copy from TTBR0 user page to kernel.
    // Needs dmb ish + dc cvac per cache line when that path lands.
    // For now (Phase 1a Haskell-only) this is never called — queues are RTS heap
    // with SCTLR.C/I=1 WB and coherency via dmb ish in irq.c ring.
    //
    // When wired:
    //   __asm__ volatile("dmb ish" ::: "memory");
    //   memcpy(dst, src, len);
    //   __asm__ volatile("dmb ish" ::: "memory");
    //   for (uintptr_t p = (uintptr_t)dst & ~63; p < (uintptr_t)dst+len; p+=64)
    //       __asm__ volatile("dc cvac, %0" :: "r"(p) : "memory");
    //   __asm__ volatile("dsb sy; dmb ish" ::: "memory");
    //
    // Track 6 will add TTBR0 carve-out (TCR EPD1) + TLBI VAAE1IS + DSB ISH
    // as proven in userspace.c:invalidate_page. Disabled until then.
    if (!src || !dst) return;
    __asm__ volatile("dmb ish" ::: "memory");
    memcpy((void*)dst, src, len);
    __asm__ volatile("dmb ish" ::: "memory");
    // dc cvac not needed for Haskell RTS heap path; annotate for future DMA:
    // __asm__ volatile("dc cvac, %0" :: "r"(dst) : "memory");
    // __asm__ volatile("dsb sy" ::: "memory");
}
