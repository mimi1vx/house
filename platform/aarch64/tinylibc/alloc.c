#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include "../spinlock.h"
#include "../house_detect.h"

void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);

static house_spinlock_t alloc_lock = {0};

extern char __heap_base[];

#ifndef HOUSE_SMP_N
#define HOUSE_SMP_N 2
#endif

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

static char *malloc_cur;
static char *mmap_cur;

static int in_ram(char *lo, size_t n)
{
    return lo >= __heap_base && lo + n <= (char *)RAM_LIMIT;
}

static int committable(char *lo, size_t n)
{
    if (in_ram(lo, n))
        return 1;
    /* RTS alias window (see mmu.c): VA 0x4200000000+ backed by the
       upper half of guest RAM, capped at 8GB, excluding the top
       BOOT_STACK area (2M + SMP_N*16K). Runtime uses house_ram_bytes
       if available so 512M vs 4G detection changes span. */
    {
        uint64_t stack_reserve = 0x200000ULL + (uint64_t)HOUSE_SMP_N * 16384ULL;
        uint64_t ram = runtime_ram_bytes();
        uint64_t half = ram >> 1;
        uint64_t span = half > stack_reserve ? half - stack_reserve : 0;
        if (span > (8UL << 30))
            span = 8UL << 30;
        return (char *)RTS_ALIAS_BASE <= lo &&
               lo + n <= (char *)RTS_ALIAS_BASE + span;
    }
}

/* Outstanding VA reservations (NORESERVE promises). The RTS reserves
   terabyte-scale heap arenas at hint addresses and only ever commits
   small chunks near the base, so promises need no backing — but they
   must not trample each other or the commit region. */
static struct { char *lo, *hi; } resv[32];
static int n_resv;

static int va_overlap(char *lo, char *hi)
{
    int i;
    for (i = 0; i < n_resv; i++)
        if (lo < resv[i].hi && resv[i].lo < hi)
            return 1;
    return 0;
}

static void va_record(char *lo, char *hi)
{
    if (n_resv < (int)(sizeof resv / sizeof resv[0])) {
        resv[n_resv].lo = lo;
        resv[n_resv].hi = hi;
        n_resv++;
    }
}

static void va_release(char *lo, char *hi)
{
    int i;
    for (i = 0; i < n_resv; i++) {
        if (resv[i].lo >= lo && resv[i].hi <= hi) {
            resv[i] = resv[n_resv - 1];
            n_resv--;
            i--;
        }
    }
}

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
    house_spin_lock(&alloc_lock);
    if (!malloc_cur)
        malloc_cur = __heap_base;
    h = (char *)(((uintptr_t)malloc_cur + 7) & ~(uintptr_t)7);
    p = (char *)(((uintptr_t)h + 16 + align - 1) & ~(uintptr_t)(align - 1));
    if (p + n > pool_top()) {
        *__errno_location() = ENOMEM_;
        ret = 0;
    } else {
        *(uint64_t *)h = (uint64_t)n;
        malloc_cur = p + n;
        ret = p;
    }
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
    size_t n = a * b;
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

/* POSIX semantics, freestanding edition:
   - MAP_FIXED commits demand real RAM ([heap_base, ram_top)); everything
     the RTS commits lives there.
   - Hinted reservations are granted exactly at the hint as VA promises
     (GHC probes descending sizes at ascending hints and retries on
     failure — matching Linux's overlap refusals keeps its loop sane).
   - No-hint allocations bump upward through RAM, mblock-aligned so the
     RTS block map stays anchored in one arena. */
void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off)
{
    char *lo, *hi;
    void *ret;
    (void)prot; (void)fd; (void)off;
    house_spin_lock(&alloc_lock);
    if (!len) {
        *__errno_location() = EINVAL;
        ret = (void *)-1;
        house_spin_unlock(&alloc_lock);
        return ret;
    }
    lo = addr;
    hi = lo ? lo + ((len + MBLOCK - 1) & ~(size_t)(MBLOCK - 1)) : 0;

    if ((flags & MAP_FIXED) && lo) {
        if (committable(lo, len)) {
            house_spin_unlock(&alloc_lock);
            return addr;
        }
        { /* TEMP */
            extern void uart_puts(const char *);
            extern long write(int, const void *, unsigned long);
            const char *d = "0123456789abcdef";
            size_t i;
            uart_puts("[commit FAIL] a=");
            for (i = 0; i < 16; i++)
                write(1, &d[((uintptr_t)lo >> (60 - 4 * i)) & 0xf], 1);
            uart_puts(" len=");
            for (i = 0; i < 16; i++)
                write(1, &d[((uintptr_t)len >> (60 - 4 * i)) & 0xf], 1);
            uart_puts("\n");
        }
        *__errno_location() = ENOMEM_;
        ret = (void *)-1;
        house_spin_unlock(&alloc_lock);
        return ret;
    }

    if (lo) {
        /* hinted reserve: promise the exact range (GHC probes ascending
           candidates, committing to whichever survives; rejects unmap) */
        if ((uintptr_t)hi <= 0x1000000000000ULL && !va_overlap(lo, hi)) {
            va_record(lo, hi);
            house_spin_unlock(&alloc_lock);
            return addr;
        }
        *__errno_location() = ENOMEM_;
        ret = (void *)-1;
        house_spin_unlock(&alloc_lock);
        return ret;
    }

    /* no hint: bump through real RAM */
    {
        char *p = mmap_cur ? (char *)(((uintptr_t)mmap_cur + (MBLOCK - 1)) &
                                       ~(uintptr_t)(MBLOCK - 1))
                            : pool_top();
        size_t rounded = (len + MBLOCK - 1) & ~(size_t)(MBLOCK - 1);
        if (p + rounded > (char *)RAM_LIMIT || va_overlap(p, p + rounded)) {
            *__errno_location() = ENOMEM_;
            ret = (void *)-1;
            house_spin_unlock(&alloc_lock);
            return ret;
        }
        mmap_cur = p + rounded;
        va_record(p, p + rounded);
        ret = p;
        house_spin_unlock(&alloc_lock);
        return ret;
    }
}

int munmap(void *a, size_t len)
{
    /* GHC unmaps rejected arena candidates; release their records so the
       next candidate can be promised. */
    house_spin_lock(&alloc_lock);
    if (a)
        va_release(a, (char *)a + ((len + MBLOCK - 1) & ~(size_t)(MBLOCK - 1)));
    house_spin_unlock(&alloc_lock);
    return 0;
}

int mprotect(void *a, size_t len, int prot)
{
    (void)a; (void)len; (void)prot;
    return 0;
}

char *strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p)
        strncpy(p, s, n);
    return p;
}
