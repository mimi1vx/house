#include <stddef.h>
#include <stdint.h>
#include <errno.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);

extern char __heap_base[];
extern char __heap_end[];

/* Guest RAM is one flat span from 0x40000000 upward (QEMU virt); with
   -m 512G it reaches past GHC's fixed heap-scan address 0x4200000000.
   Beyond adrp range, hence constants rather than linker symbols. */
#define HEAP2_BASE 0x4000000000UL
#define HEAP2_END  0x7F00000000UL

#define MALLOC_POOL_BYTES (64UL << 20)
#define MBLOCK (1UL << 20)
#define MAP_FIXED 0x10
#define ENOMEM_ 12

static char *malloc_cur;
static char *mmap_cur;

static int in_any_heap(char *lo, size_t n)
{
    return ((char *)lo >= __heap_base && lo + n <= __heap_end) ||
           ((char *)lo >= (char *)HEAP2_BASE &&
            lo + n <= (char *)HEAP2_END);
}

/* Advance the bump cursor past an exactly-honored hint so later scans of
   the same window do not hand out overlapping blocks. */
static void consume_up_to(char *p, size_t rounded)
{
    if (p + rounded > mmap_cur)
        mmap_cur = p + rounded;
}

int *__errno_location(void);
size_t strlen(const char *s);
char *strncpy(char *dst, const char *src, size_t n);

/* Fresh guest RAM is zero-filled; bump regions never need explicit zeroing.
   free() is a no-op: RTS allocations are dominated by a few large,
   long-lived heap blocks during bring-up. */
void *malloc(size_t n)
{
    char *p = (char *)(((uintptr_t)malloc_cur + 15) & ~(uintptr_t)15);
    if (!malloc_cur) {
        malloc_cur = __heap_base;
        p = (char *)(((uintptr_t)malloc_cur + 15) & ~(uintptr_t)15);
    }
    if (p + n + 16 > __heap_base + MALLOC_POOL_BYTES) {
        *__errno_location() = ENOMEM_;
        return 0;
    }
    *(uint64_t *)(p - 16) = (uint64_t)n;
    malloc_cur = p + n;
    return p;
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
    char *p;
    if (!malloc_cur)
        malloc_cur = __heap_base;
    p = (char *)(((uintptr_t)malloc_cur + align - 1) & ~(uintptr_t)(align - 1));
    if (p + n > __heap_base + MALLOC_POOL_BYTES)
        return ENOMEM_;
    malloc_cur = p + n;
    *out = p;
    return 0;
}

/* RTS block allocator: mmap(PROT_NONE|MAP_NORESERVE) reservations committed
   later with mprotect. Both are bookkeeping-free here: all guest RAM is
   always accessible and there is no page table to consult. */
extern void uart_puts(const char *);
extern void uart_putc(char);

static void ph(uint64_t v)
{
    static const char d[] = "0123456789abcdef";
    int i;
    for (i = 60; i >= 0; i -= 4)
        uart_putc(d[(v >> i) & 0xf]);
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off)
{
    char *p;
    static int log_count;
    (void)prot; (void)fd; (void)off;
    if (log_count < 16) {
        uart_puts("[mmap] a=");
        ph((uint64_t)addr);
        uart_puts(" len=");
        ph(len);
        uart_puts(" f=");
        ph((uint64_t)flags);
        uart_puts("\n");
        log_count++;
    }
    if (!len) {
        *__errno_location() = EINVAL;
        return (void *)-1;
    }
    /* The RTS scans hint addresses and requires the kernel to map exactly
       there; honor any hint inside our RAM windows. */
    if (addr && !(flags & MAP_FIXED)) {
        if ((char *)addr >= __heap_base && (char *)addr + len <= __heap_end) {
            consume_up_to((char *)addr, (len + MBLOCK - 1) & ~(size_t)(MBLOCK - 1));
            return addr;
        }
        if ((char *)addr >= (char *)HEAP2_BASE &&
            (char *)addr + len <= (char *)HEAP2_END) {
            static char *hi_cur;
            char *h = (char *)addr;
            size_t rounded = (len + MBLOCK - 1) & ~(size_t)(MBLOCK - 1);
            if (!hi_cur || h >= hi_cur) {
                hi_cur = h + rounded;
                return addr;
            }
            *__errno_location() = ENOMEM_;
            return (void *)-1;
        }
    }
    if ((flags & MAP_FIXED) && addr && in_any_heap((char *)addr, len)) {
        return addr;
    }
    if (!mmap_cur)
        mmap_cur = (char *)HEAP2_BASE;
    /* The RTS mblock allocator requires 1MB-aligned reservations and
       anchors its block map on the first returned address, so every
       no-hint allocation must stay in the same bank. */
    p = (char *)(((uintptr_t)mmap_cur + (MBLOCK - 1)) & ~(uintptr_t)(MBLOCK - 1));
    {
        size_t rounded = (len + MBLOCK - 1) & ~(size_t)(MBLOCK - 1);
        if (p + rounded > (char *)HEAP2_END) {
            *__errno_location() = ENOMEM_;
            return (void *)-1;
        }
        mmap_cur = p + rounded;
    }
    return p;
}

int munmap(void *a, size_t len)
{
    (void)a; (void)len;
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
