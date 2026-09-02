#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include "../spinlock.h"
#include "../house_detect.h"
#include "../buddy.h"
#include "vm.h"

#ifndef HOUSE_SMP_N
#define HOUSE_SMP_N 2
#endif

#define RTS_ALIAS_BASE 0x4200000000ULL
#define MBLOCK (1UL << 20)
#define PAGE_SIZE 4096ULL
#define MAP_FIXED 0x10
#define PROT_NONE 0x0
#define PROT_READ 0x1
#define PROT_WRITE 0x2
#define PROT_EXEC 0x4

extern char __heap_base[];
static house_spinlock_t vm_lock = {0};

// reservations for hinted VA promises (terabyte probe)
static struct { char *lo, *hi; } vm_resv[32];
static int vm_n_resv;

static inline uint64_t runtime_ram_bytes_vm(void) {
    if (house_ram_bytes) return house_ram_bytes;
    return 512ULL<<20;
}
#define VM_RAM_LIMIT (0x40000000ULL + runtime_ram_bytes_vm())

static int vm_in_ram(char *lo, size_t n) {
    if (lo < __heap_base) return 0;
    uintptr_t lo_u = (uintptr_t)lo;
    uintptr_t lim = (uintptr_t)VM_RAM_LIMIT;
    if (n > lim - lo_u) return 0;
    return 1;
}
static int vm_in_user_window(char *lo, size_t n) {
    uintptr_t lo_u = (uintptr_t)lo;
    if (lo_u < HOUSE_USER_VA_MIN) return 0;
    if (n > HOUSE_USER_VA_MAX - lo_u + 1) return 0;
    if (lo_u + n < lo_u) return 0; // wrap
    if (lo_u + n > HOUSE_USER_VA_MAX + 1) return 0;
    return 1;
}
static int vm_committable(char *lo, size_t n) {
    if (vm_in_user_window(lo, n)) return 1;
    if (vm_in_ram(lo, n)) return 1;
    uintptr_t lo_u = (uintptr_t)lo;
    uintptr_t alias_base = (uintptr_t)RTS_ALIAS_BASE;
    uint64_t stack_reserve = 0x200000ULL + (uint64_t)HOUSE_SMP_N * 16384ULL;
    uint64_t ram = runtime_ram_bytes_vm();
    uint64_t half = ram >> 1;
    uint64_t span = half > stack_reserve ? half - stack_reserve : 0;
    if (span > (8UL << 30)) span = 8UL << 30;
    if (lo_u < alias_base) return 0;
    if (n > span) return 0;
    if (lo_u + n < lo_u) return 0;
    if (lo_u + n > alias_base + span) return 0;
    return 1;
}
static int vm_overlap(char *lo, char *hi) {
    for (int i=0;i<vm_n_resv;i++) if (lo < vm_resv[i].hi && vm_resv[i].lo < hi) return 1;
    return 0;
}
static void vm_record(char *lo, char *hi) {
    if (vm_n_resv < (int)(sizeof vm_resv/sizeof vm_resv[0])) {
        vm_resv[vm_n_resv].lo=lo; vm_resv[vm_n_resv].hi=hi; vm_n_resv++;
    }
}
static void vm_release(char *lo, char *hi) {
    for (int i=0;i<vm_n_resv;i++) {
        if (vm_resv[i].lo >= lo && vm_resv[i].hi <= hi) {
            vm_resv[i]=vm_resv[vm_n_resv-1]; vm_n_resv--; i--;
        }
    }
}

int *__errno_location(void);

// pagetable bits
#define PTE_VALID (1ULL<<0)
#define PTE_TABLE (1ULL<<1)
#define PTE_AP_SHIFT 6
#define PTE_AP_MASK (3ULL<<6)
#define PTE_AP_RW (1ULL<<6)
#define PTE_AP_RO (3ULL<<6)

extern void *current_pdir(void);
extern void house_tlb_shootdown(uint64_t vaddr);

// Walk to L3 entry pointer; returns 0 if any intermediate missing, else pointer to L3 slot
static uint64_t *vm_l3_entry(uint64_t va) {
    void *pdir = current_pdir();
    if (!pdir) return 0;
    if ((uintptr_t)pdir & 4095) return 0;
    uint64_t *l0 = (uint64_t*)pdir;
    uint64_t d0 = l0[(va>>39)&0x1FF];
    if ((d0 & PTE_VALID)==0) return 0;
    uint64_t *l1 = (uint64_t*)(uintptr_t)(d0 & ~0xFFFULL);
    uint64_t d1 = l1[(va>>30)&0x1FF];
    if ((d1 & PTE_VALID)==0) return 0;
    uint64_t *l2 = (uint64_t*)(uintptr_t)(d1 & ~0xFFFULL);
    uint64_t d2 = l2[(va>>21)&0x1FF];
    if ((d2 & PTE_VALID)==0) return 0;
    uint64_t *l3 = (uint64_t*)(uintptr_t)(d2 & ~0xFFFULL);
    return &l3[(va>>12)&0x1FF];
}

void *house_vm_mmap(void *addr, size_t len, int prot, int flags, int fd, long off) {
    char *lo, *hi;
    size_t rounded;
    void *ret;
    if (fd != -1) { *__errno_location()=ENOSYS; return (void*)-1; }
    if (off != 0) { *__errno_location()=EINVAL; return (void*)-1; }
    if (prot & ~(PROT_READ|PROT_WRITE|PROT_EXEC)) { *__errno_location()=EINVAL; return (void*)-1; }
    house_spin_lock(&vm_lock);
    if (!len) { *__errno_location()=EINVAL; ret=(void*)-1; house_spin_unlock(&vm_lock); return ret; }
    {
        size_t tmp;
        if (__builtin_add_overflow(len, MBLOCK-1, &tmp)) { *__errno_location()=EINVAL; ret=(void*)-1; house_spin_unlock(&vm_lock); return ret; }
        rounded = tmp & ~(size_t)(MBLOCK-1);
    }
    lo = addr;
    if (lo) {
        uintptr_t hi_u;
        if (__builtin_add_overflow((uintptr_t)lo, rounded, &hi_u)) { *__errno_location()=EINVAL; ret=(void*)-1; house_spin_unlock(&vm_lock); return ret; }
        hi=(char*)hi_u;
    } else hi=0;

    if ((flags & MAP_FIXED) && lo) {
        if (vm_committable(lo, len)) {
            // demand-lazy: no reservation needed, TLBI to ensure stale not cached
            // For user window, future fault will allocate. For in_ram/RTS alias, already backed.
            house_spin_unlock(&vm_lock);
            return addr;
        }
#ifdef HOUSE_DEBUG_MMAP
        { extern void uart_puts(const char *); extern long write(int, const void*, unsigned long);
          const char *d="0123456789abcdef"; for (int i=0;i<16;i++) write(1,&d[((uintptr_t)lo>>(60-4*i))&0xf],1); uart_puts(" commit FAIL\n"); }
#endif
        *__errno_location()=ENOMEM;
        ret=(void*)-1; house_spin_unlock(&vm_lock); return ret;
    }
    if (lo) {
        if ((uintptr_t)hi <= 0x1000000000000ULL && !vm_overlap(lo,hi)) { vm_record(lo,hi); house_spin_unlock(&vm_lock); return addr; }
        *__errno_location()=ENOMEM; ret=(void*)-1; house_spin_unlock(&vm_lock); return ret;
    }
    // no hint: bump through user window? For now bump through RAM alias via in_ram check, but also support user window bump
    // Prefer user window low 16M upward for anonymous mmap without hint when not RTS-driven
    // For RTS compatibility, keep bump through RAM (alias) as before via separate cursor
    // Here we bump through RAM_LIMIT alias area (physical) for simplicity; RTS tests use hinted path.
    {
        // Anonymous mmap without hint: bump through user window at 0x80000000 (L1[2] table, not kernel block at 1GB)
        static char *vm_mmap_cur;
        char *anon_base = (char*)0x81000000ULL;
        char *p = vm_mmap_cur ? (char*)(((uintptr_t)vm_mmap_cur + (MBLOCK-1)) & ~(uintptr_t)(MBLOCK-1)) : anon_base;
        uintptr_t p_end;
        if (__builtin_add_overflow((uintptr_t)p, rounded, &p_end)) { *__errno_location()=ENOMEM; ret=(void*)-1; house_spin_unlock(&vm_lock); return ret; }
        if (p_end > HOUSE_USER_VA_MAX+1 || vm_overlap(p,(char*)p_end)) { *__errno_location()=ENOMEM; ret=(void*)-1; house_spin_unlock(&vm_lock); return ret; }
        vm_mmap_cur=(char*)p_end;
        vm_record(p,(char*)p_end);
        ret=p; house_spin_unlock(&vm_lock); return ret;
    }
}

int house_vm_munmap(void *addr, size_t len) {
    if (!addr) return 0;
    if (!len) { *__errno_location()=EINVAL; return -1; }
    size_t rounded;
    {
        size_t tmp;
        if (__builtin_add_overflow(len, PAGE_SIZE-1, &tmp)) { *__errno_location()=EINVAL; return -1; }
        rounded = tmp & ~(PAGE_SIZE-1);
    }
    uintptr_t lo = (uintptr_t)addr;
    uintptr_t hi;
    if (__builtin_add_overflow(lo, rounded, &hi)) { *__errno_location()=EINVAL; return -1; }
    // If entirely in user window, free buddy pages page-wise
    if (lo >= HOUSE_USER_VA_MIN && hi <= HOUSE_USER_VA_MAX+1) {
        house_spin_lock(&vm_lock);
        for (uintptr_t va=lo; va<hi; va+=PAGE_SIZE) {
            uint64_t *slot = vm_l3_entry(va);
            if (!slot) continue;
            uint64_t d = *slot;
            if ((d & PTE_VALID)==0) continue;
            void *page = (void*)(uintptr_t)(d & ~0xFFFULL);
            *slot = 0;
            __asm__ volatile("dsb ishst" ::: "memory");
            // free buddy page - buddy_contains check inside free
            buddy_free_page(page);
            house_tlb_shootdown(va);
        }
        // also release reservation record if any
        vm_release((char*)lo,(char*)hi);
        house_spin_unlock(&vm_lock);
        return 0;
    }
    // fallback: just release reservation (RTS alias hint)
    house_spin_lock(&vm_lock);
    {
        size_t tmp2; size_t rnd2; if (__builtin_add_overflow(len, MBLOCK-1, &tmp2)) rnd2=len; else rnd2=tmp2 & ~(MBLOCK-1);
        uintptr_t hi2; if (__builtin_add_overflow((uintptr_t)addr, rnd2, &hi2)) hi2=(uintptr_t)addr+len;
        vm_release((char*)addr,(char*)hi2);
    }
    house_spin_unlock(&vm_lock);
    return 0;
}

int house_vm_mprotect(void *addr, size_t len, int prot) {
    extern void uart_puts(const char *);
    uart_puts("[mprotect] start\n");
    if (!addr) { *__errno_location()=EINVAL; return -1; }
    if (!len) { *__errno_location()=EINVAL; return -1; }
    if (prot & ~(PROT_READ|PROT_WRITE|PROT_EXEC)) { *__errno_location()=EINVAL; return -1; }
    // Only READ|WRITE and NONE supported; EXEC ignored
    int want_ro = (prot == PROT_NONE) || (prot == PROT_READ) || (prot == PROT_EXEC) || (prot == (PROT_READ|PROT_EXEC));
    // PROT_WRITE alone or READ|WRITE => RW (need WRITE bit)
    int want_rw = (prot & PROT_WRITE) != 0;
    // PROT_NONE => RO + treat as RO (will fault on write per plan)
    // For simplicity: if prot==0 => RO
    size_t rounded;
    {
        size_t tmp;
        if (__builtin_add_overflow(len, PAGE_SIZE-1, &tmp)) { *__errno_location()=EINVAL; return -1; }
        rounded = tmp & ~(PAGE_SIZE-1);
    }
    uintptr_t lo=(uintptr_t)addr;
    if (lo & (PAGE_SIZE-1)) { *__errno_location()=EINVAL; return -1; }
    uintptr_t hi; if (__builtin_add_overflow(lo, rounded, &hi)) { *__errno_location()=EINVAL; return -1; }
    if (hi < lo) { *__errno_location()=EINVAL; return -1; }
    if (lo < HOUSE_USER_VA_MIN || hi > HOUSE_USER_VA_MAX+1) { *__errno_location()=ENOMEM; return -1; }

    house_spin_lock(&vm_lock);
    uart_puts("[mprotect] lock done\n");
    for (uintptr_t va=lo; va<hi; va+=PAGE_SIZE) {
        uart_puts("[mprotect] loop va\n");
        uint64_t *slot = vm_l3_entry(va);
        uart_puts("[mprotect] slot done\n");
        if (!slot) { house_spin_unlock(&vm_lock); *__errno_location()=EINVAL; return -1; }
        uint64_t d = *slot;
        if ((d & PTE_VALID)==0) { house_spin_unlock(&vm_lock); *__errno_location()=EINVAL; return -1; }
        uint64_t ap = want_rw ? PTE_AP_RW : PTE_AP_RO;
        // Preserve other bits, replace AP
        d = (d & ~PTE_AP_MASK) | ap;
        *slot = d;
        __asm__ volatile("dsb ishst" ::: "memory");
        house_tlb_shootdown(va);
    }
    house_spin_unlock(&vm_lock);
    // suppress unused variable warning for want_ro
    (void)want_ro;
    return 0;
}

int house_vm_demand_single(void) {
    extern void uart_puts(const char *);
    uart_puts("[vm] demand single start\n");
    volatile uint32_t *p = (uint32_t*)0x80000000ULL;
    *p = 0xdeadbeef;
    uart_puts("[vm] demand single store done\n");
    uint32_t v = *p;
    uart_puts("[vm] demand single load done\n");
    return (v == 0xdeadbeef) ? 1 : 0;
}
int house_vm_demand_100(void) {
    extern void uart_puts(const char *);
    uart_puts("[vm] demand 100 start\n");
    for (int i=0;i<100;i++) {
        volatile uint8_t *p = (uint8_t*)(0x80000000ULL + i*4096);
        *p = (uint8_t)i;
    }
    uart_puts("[vm] demand 100 store done\n");
    for (int i=0;i<100;i++) {
        volatile uint8_t *p = (uint8_t*)(0x80000000ULL + i*4096);
        if (*p != (uint8_t)i) return 0;
    }
    uart_puts("[vm] demand 100 load done\n");
    return 1;
}
void house_puts_after(void) {
    extern void uart_puts(const char *);
    uart_puts("[vm] after alloc\n");
}
