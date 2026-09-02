#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include "../spinlock.h"
#include "../house_detect.h"
#include "../mm/vm.h"

void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);

static house_spinlock_t alloc_lock = {0};

extern char __heap_base[];

#ifndef HOUSE_SMP_N
#define HOUSE_SMP_N 2
#endif

static inline uint64_t runtime_ram_bytes(void) __attribute__((unused));
static inline uint64_t runtime_ram_bytes(void) {
    // No compile-time limit — pure auto-detect. Fallback to 512M until probe.
    if (house_ram_bytes) return house_ram_bytes;
    return 512ULL<<20;
}
#define RAM_LIMIT (0x40000000ULL + runtime_ram_bytes())

// Per-core boot stacks (16K each) are at runtime house_boot_stack_top;
// GIC/PL011 remain Device block 0. No compile-time RAM size check.

/* The RTS heap arena lives at GHC's working aarch64 base (VA
   0x4200000000, aliased onto upper-half guest RAM by mmu.c's L2 tier);
   commits there are backed by the same physical RAM as the identity
   map. Terabyte-scale reserve attempts elsewhere are granted as pure VA
   promises: GHC probes candidates and only keeps the one whose commits
   stick, unmapping the rest. */
#define RTS_ALIAS_BASE 0x4200000000ULL

/* Bump allocator for malloc; pool sits at the bottom of RAM, mmap arenas
   above it. free() is a no-op: RTS allocations are dominated by a few
   large, long-lived heap blocks during bring-up. */
#define MALLOC_POOL_BYTES (64UL << 20)
#define MBLOCK (1UL << 20)
#define MAP_FIXED 0x10
#define ENOMEM_ 12
#define PROT_NONE 0x0
#define PROT_READ 0x1
#define PROT_WRITE 0x2
#define PROT_EXEC 0x4

static char *malloc_cur;

int *__errno_location(void);
size_t strlen(const char *s);
char *strncpy(char *dst, const char *src, size_t n);

static char *pool_top(void)
{
    return (char *)__heap_base + MALLOC_POOL_BYTES;
}

/* Every object carries its size at p-16 (realloc needs it). The 16-byte
    header slot is carved out BEFORE the object so a following allocation's
    header can never stomp the previous one's tail — packing them flush
    corrupted RTS structs (gc_thread) and crashed GarbageCollect. */
static void *pool_alloc(size_t n, size_t align)
{
    char *h, *p;
    void *ret;
    size_t tmp;
    uintptr_t h_u, p_u;
    house_spin_lock(&alloc_lock);
    if (!malloc_cur)
        malloc_cur = __heap_base;
    // align must be power-of-two and non-zero; clamp to 16 if invalid
    if (align == 0 || (align & (align - 1)) != 0) align = 16;
    // overflow-safe: malloc_cur+7, h+16, h+16+align-1
    h_u = (uintptr_t)malloc_cur;
    if (__builtin_add_overflow(h_u, (uintptr_t)7, &h_u)) goto oom;
    h_u &= ~ (uintptr_t)7;
    h = (char *)h_u;
    if (__builtin_add_overflow((uintptr_t)h, (size_t)16, &p_u)) goto oom;
    if (__builtin_add_overflow(p_u, align - 1, &tmp)) goto oom;
    // p = align_up(p_u, align)
    p_u = (tmp & ~(uintptr_t)(align - 1));
    p = (char *)p_u;
    // p + n overflow and bounds check
    if (__builtin_add_overflow(p_u, n, &tmp)) goto oom;
    if ((char *)tmp > pool_top()) goto oom;
    *(uint64_t *)h = (uint64_t)n;
    malloc_cur = (char *)tmp;
    ret = p;
    house_spin_unlock(&alloc_lock);
    return ret;
oom:
    *__errno_location() = ENOMEM_;
    ret = 0;
    house_spin_unlock(&alloc_lock);
    return ret;
}

void *malloc(size_t n)
{
    return pool_alloc(n, 16);
}

void free(void *p)
{
    (void)p;
}

void *calloc(size_t a, size_t b)
{
    size_t n;
    if (__builtin_mul_overflow(a, b, &n)) {
        *__errno_location() = ENOMEM_;
        return 0;
    }
    void *p = malloc(n);
    if (p)
        memset(p, 0, n);
    return p;
}

void *realloc(void *old, size_t n)
{
    void *p;
    size_t oldn = 0;
    if (!old)
        return malloc(n);
    oldn = (size_t)*(uint64_t *)((char *)old - 16);
    p = malloc(n);
    if (p && oldn)
        memcpy(p, old, oldn < n ? oldn : n);
    return p;
}

int posix_memalign(void **out, size_t align, size_t n)
{
    void *p = pool_alloc(n, align);
    if (!p)
        return ENOMEM_;
    *out = p;
    return 0;
}

/* POSIX semantics via mm/vm.c — thin delegate seam.
   Keep malloc bump pool untouched; VM handles mmap/munmap/mprotect
   via buddy + TTBR0 demand pager (see mm/vm.c). in_ram/committable
   helpers retained for potential legacy use, but VM owns reservation. */
void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off)
{
    return house_vm_mmap(addr, len, prot, flags, fd, off);
}

int munmap(void *a, size_t len)
{
    return house_vm_munmap(a, len);
}

int mprotect(void *a, size_t len, int prot)
{
    return house_vm_mprotect(a, len, prot);
}

char *strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p)
        strncpy(p, s, n);
    return p;
}
