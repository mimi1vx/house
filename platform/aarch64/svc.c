#include "svc.h"
#include "ipc.h"
#include "uart.h"
#include "buddy.h"
#include <stdint.h>
#include <stddef.h>

volatile int house_user_exited = 0;
volatile int house_user_exit_code = 0;

void house_set_exit(int code) {
    house_user_exit_code = code;
    house_user_exited = 1;
    __asm__ volatile("dsb sy; sev" ::: "memory");
}

int house_get_exit_code(void) {
    return house_user_exit_code;
}

void house_clear_exit(void) {
    house_user_exited = 0;
    house_user_exit_code = 0;
    __asm__ volatile("dsb sy" ::: "memory");
}

int house_is_exited(void) {
    return house_user_exited;
}

// Translate user VA to PA via current TTBR0 walk.
// Returns 0 on invalid/unmapped.
static uintptr_t translate_va(uint64_t va) {
    extern void *current_pdir(void);
    void *pdir = current_pdir();
    if (!pdir) return 0;
    if ((uintptr_t)pdir & 4095) return 0;
    uint64_t *l0 = (uint64_t *)pdir;
    uint64_t d0 = l0[(va >> 39) & 0x1FF];
    if ((d0 & 1) == 0) return 0;
    uint64_t *l1 = (uint64_t *)(uintptr_t)(d0 & ~0xFFFULL);
    uint64_t d1 = l1[(va >> 30) & 0x1FF];
    if ((d1 & 1) == 0) return 0;
    uint64_t *l2 = (uint64_t *)(uintptr_t)(d1 & ~0xFFFULL);
    uint64_t d2 = l2[(va >> 21) & 0x1FF];
    if ((d2 & 1) == 0) return 0;
    uint64_t *l3 = (uint64_t *)(uintptr_t)(d2 & ~0xFFFULL);
    uint64_t d3 = l3[(va >> 12) & 0x1FF];
    if ((d3 & 1) == 0) return 0;
    uintptr_t pa = (uintptr_t)(d3 & ~0xFFFULL) | (va & 0xFFF);
    return pa;
}

// Validate user buffer [va, va+len) is within window and mapped.
// Does not check intra-page holes beyond walk per page.
static int validate_user_buffer(uint64_t va, uint64_t len) {
    if (len == 0) return 0;
    if (len > 65536) return -1;
    uint64_t end;
    if (__builtin_add_overflow(va, len, &end)) return -1;
    if (va < 0x01000000ULL || end > 0x100000000ULL) return -1;
    // Check each page touched is mapped
    uint64_t start_page = va & ~4095ULL;
    uint64_t end_page = (end - 1) & ~4095ULL;
    for (uint64_t p = start_page; p <= end_page; p += 4096) {
        if (translate_va(p) == 0) return -1;
        if (p == end_page) break;
        if (p + 4096 < p) return -1;
    }
    return 0;
}

int64_t house_svc_dispatch(uint32_t imm, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t *gpr) {
    (void)x3;
    switch (imm) {
    case HOUSE_SVC_WRITE: {
        // x0=fd, x1=buf, x2=len
        int64_t fd = (int64_t)x0;
        uint64_t va = x1;
        uint64_t len = x2;
        if (fd != 1) {
            uart_puts("[svc] write bad fd\n");
            if (gpr) gpr[0] = (uint64_t)(int64_t)-9; // EBADF
            return (int64_t)-9;
        }
        if (len > 65536) {
            if (gpr) gpr[0] = (uint64_t)(int64_t)-22; // EINVAL
            return (int64_t)-22;
        }
        if (len == 0) {
            if (gpr) gpr[0] = 0;
            return 0;
        }
        if (validate_user_buffer(va, len) != 0) {
            uart_puts("[svc] write EFAULT\n");
            if (gpr) gpr[0] = (uint64_t)(int64_t)-14; // EFAULT
            return (int64_t)-14;
        }
        // Copy chunk-wise by page to avoid crossing unmapped holes
        uint64_t remaining = len;
        uint64_t cur = va;
        while (remaining > 0) {
            uint64_t page_off = cur & 0xFFF;
            uint64_t chunk = 4096 - page_off;
            if (chunk > remaining) chunk = remaining;
            uintptr_t pa = translate_va(cur);
            if (pa == 0) {
                if (gpr) gpr[0] = (uint64_t)(int64_t)-14;
                return (int64_t)-14;
            }
            char *src = (char *)(uintptr_t)pa;
            for (uint64_t i = 0; i < chunk; i++) {
                char c = src[i];
                // Use uart_putc for each char to preserve spinlock safety
                uart_putc(c);
            }
            cur += chunk;
            remaining -= chunk;
        }
        if (gpr) gpr[0] = (uint64_t)len;
        return (int64_t)len;
    }
    case HOUSE_SVC_EXIT: {
        int code = (int)(x0 & 0xFF);
        house_set_exit(code);
        uart_puts("[svc] exit\n");
        if (gpr) gpr[0] = 0;
        return 0;
    }
    case HOUSE_SVC_BRK: {
        uart_puts("[svc] ENOSYS brk\n");
        if (gpr) gpr[0] = (uint64_t)(int64_t)-38; // ENOSYS
        return (int64_t)-38;
    }
    case HOUSE_SVC_IPC_SEND:
    case HOUSE_SVC_IPC_RECV:
    case HOUSE_SVC_IPC_CALL:
    case HOUSE_SVC_IPC_REPLY:
    case HOUSE_SVC_IPC_GRANT_MAP: {
        int64_t r = house_ipc_svc_dispatch(x0, x1, x2, x3);
        if (gpr) gpr[0] = (uint64_t)r;
        if (r == -38) {
            uart_puts("[svc] ENOSYS ipc\n");
        }
        return r;
    }
    default: {
        uart_puts("[svc] ENOSYS imm=");
        {
            char buf[16];
            const char *hex = "0123456789abcdef";
            buf[0]='0'; buf[1]='x';
            for (int i=0;i<4;i++) buf[2+i]= hex[(imm >> (12-4*i)) & 0xF];
            buf[6]=0;
            uart_puts(buf);
            uart_puts("\n");
        }
        if (gpr) gpr[0] = (uint64_t)(int64_t)-38;
        return (int64_t)-38;
    }
    }
}
