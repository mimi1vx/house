/* Link-compat shims for host facilities the stock RTS/libffi references but
   this kernel has none of. Pulled-in-but-unexecuted objects (LoadArchive,
   Hpc, threaded-only paths) land here; functions that DO run at startup
   (getrlimit, ctime_r, math, strtod) behave plausibly instead of failing. */

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/select.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <math.h>

__attribute__((noreturn)) void exit(int status);
int *__errno_location(void);
uint64_t house_uptime_ns(void);
void *memset(void *dst, int c, size_t n);
size_t strlen(const char *s);
char *strncpy(char *dst, const char *src, size_t n);

#define EBADF_ 9
#define ENOENT_ 2
#define ENOTTY_ 25
#define FAKE_EPOCH_ 1785000000ULL

/* ---- pthreads: single capability, every op trivially succeeds ---- */

int pthread_mutex_init(void *m, void *a) { (void)m; (void)a; return 0; }
int pthread_mutex_destroy(void *m) { (void)m; return 0; }
int pthread_mutex_lock(void *m) { (void)m; return 0; }
int pthread_mutex_trylock(void *m) { (void)m; return 0; }
int pthread_mutex_unlock(void *m) { (void)m; return 0; }

int pthread_cond_init(void *c, void *a) { (void)c; (void)a; return 0; }
int pthread_cond_destroy(void *c) { (void)c; return 0; }
int pthread_cond_signal(void *c) { (void)c; return 0; }
int pthread_cond_broadcast(void *c) { (void)c; return 0; }
int pthread_cond_wait(void *c, void *m)
{
    (void)c; (void)m;
    *__errno_location() = EINVAL;
    return EINVAL;              /* never legitimately reached */
}
int pthread_cond_timedwait(void *c, void *m, const struct timespec *t)
{
    (void)c; (void)m; (void)t;
    *__errno_location() = ETIMEDOUT;
    return ETIMEDOUT;
}

int pthread_condattr_init(void *a) { (void)a; return 0; }
int pthread_condattr_destroy(void *a) { (void)a; return 0; }
int pthread_condattr_setclock(void *a, int clk) { (void)a; (void)clk; return 0; }

int pthread_attr_init(void *a) { (void)a; return 0; }
int pthread_attr_destroy(void *a) { (void)a; return 0; }
int pthread_attr_getstacksize(void *a, size_t *s)
{
    (void)a;
    *s = 8 << 20;
    return 0;
}

unsigned long pthread_self(void) { return 1; }
int pthread_join(unsigned long t, void **r) { (void)t; (void)r; return 0; }
int pthread_detach(unsigned long t) { (void)t; return 0; }
__attribute__((noreturn)) void pthread_exit(void *r) { (void)r; exit(0); }
int pthread_kill(unsigned long t, int s) { (void)t; extern int raise(int); return raise(s); }
int pthread_setname_np(unsigned long t, const char *n) { (void)t; (void)n; return 0; }

/* ---- stdio FILE-based: report failure so callers skip dead features ---- */

FILE *fopen(const char *p, const char *m) { (void)p; (void)m; return NULL; }
int fclose(FILE *f) { (void)f; return EOF; }
size_t fread(void *b, size_t s, size_t n, FILE *f) { (void)b; (void)s; (void)n; (void)f; return 0; }
char *fgets(char *b, int n, FILE *f) { (void)b; (void)n; (void)f; return NULL; }
int feof(FILE *f) { (void)f; return 1; }
int fseek(FILE *f, long o, int w) { (void)f; (void)o; (void)w; return -1; }
long ftell(FILE *f) { (void)f; return -1; }
int getc(FILE *f) { (void)f; return EOF; }
ssize_t getline(char **b, size_t *n, FILE *f) { (void)b; (void)n; (void)f; return -1; }

int __isoc99_sscanf(const char *s, const char *fmt, ...)
{
    (void)s; (void)fmt;
    return 0;
}

/* ---- dynamic linking ---- */

void *dlopen(const char *f, int fl) { (void)f; (void)fl; return 0; }
void *dlsym(void *h, const char *n) { (void)h; (void)n; return 0; }
int dlclose(void *h) { (void)h; *__errno_location() = ENOENT_; return -1; }
char *dlerror(void) { return "house: no dynamic loader"; }
int dlinfo(void *h, int rq, void *v) { (void)h; (void)rq; (void)v; return -1; }
int dl_iterate_phdr(int (*cb)(void *, size_t, void *), void *d)
{
    (void)cb; (void)d;
    return 0;
}

/* ---- fstab probing (libffi exec-file search): all fail -> anon mmap ---- */

void *setmntent(const char *f, const char *m) { (void)f; (void)m; return 0; }
int endmntent(void *f) { (void)f; return 1; }
char *hasmntopt(void *e, const char *o) { (void)e; (void)o; return 0; }
struct mntent_dummy;
int getmntent_r(void *f, struct mntent_dummy *m, char *b, int n)
{
    (void)f; (void)m; (void)b; (void)n;
    *__errno_location() = ENOENT_;
    return -1;
}

int memfd_create(const char *n, unsigned fl) { (void)n; (void)fl; *__errno_location() = ENOSYS; return -1; }
int mkstemp(char *t) { (void)t; *__errno_location() = ENOENT_; return -1; }
int access(const char *p, int m) { (void)p; (void)m; *__errno_location() = ENOENT_; return -1; }
int ftruncate(int fd, long len) { (void)fd; (void)len; *__errno_location() = EBADF_; return -1; }
int madvise(void *a, size_t l, int adv) { (void)a; (void)l; (void)adv; return 0; }
int mkdir(const char *p, unsigned mode) { (void)p; (void)mode; *__errno_location() = ENOENT_; return -1; }
int mknod(const char *p, unsigned mode, unsigned long dev) { (void)p; (void)mode; (void)dev; *__errno_location() = ENOENT_; return -1; }
int fork(void) { *__errno_location() = ENOSYS; return -1; }
pid_t getppid(void) { return 1; }
int atexit(void (*fn)(void)) { (void)fn; return 0; }
long syscall(long num, ...)
{
    (void)num;
    *__errno_location() = ENOSYS;
    return -1;
}

int sched_yield(void) { return 0; }
int sched_setaffinity(pid_t pid, size_t sz, const void *mask)
{
    (void)pid; (void)sz; (void)mask;
    *__errno_location() = ENOENT_;
    return -1;
}

/* ---- filesystem/process syscalls nothing here can honour ---- */

pid_t waitpid(pid_t pid, int *status, int opts)
{
    (void)pid; (void)status; (void)opts;
    *__errno_location() = ENOSYS;
    return -1;
}
int link(const char *a, const char *b) { (void)a; (void)b; *__errno_location() = ENOENT_; return -1; }
int creat(const char *p, unsigned mode) { (void)p; (void)mode; *__errno_location() = ENOENT_; return -1; }
int chmod(const char *p, unsigned mode) { (void)p; (void)mode; *__errno_location() = ENOENT_; return -1; }
unsigned umask(unsigned m) { return m; }
int mkfifo(const char *p, unsigned mode) { (void)p; (void)mode; *__errno_location() = ENOENT_; return -1; }
int utime(const char *p, const void *t) { (void)p; (void)t; *__errno_location() = ENOENT_; return -1; }
int lstat(const char *p, struct stat *st) { (void)p; (void)st; *__errno_location() = ENOENT_; return -1; }
/* CODESET (14 on glibc) must advertise UTF-8: base's locale encoding is
   derived from it, and an empty name drops GHC into its wide-char
   fallback (UCS-4 bytes on the wire). */
char *nl_langinfo(int item) { return item == 14 ? "UTF-8" : ""; }

/* ---- iconv: failing open makes base fall back to its pure codecs ---- */

typedef void *iconv_t_placeholder;
/* Iconv: byte-preserving pass-through. GHC only converts between UTF-8/
   ASCII locale variants for its Handles, so no real transcoding is needed
   and there are no gconv module files to load; //TRANSLIT etc. accepted,
   ignored. */
void *iconv_open(const char *to, const char *from)
{
    (void)to; (void)from;
    return (void *)1;           /* opaque cookie */
}

size_t iconv(void *cd, char **in, size_t *il, char **out, size_t *ol)
{
    size_t n;
    (void)cd;
    if (!in || !*in)
        return 0;               /* state reset request */
    n = *il < *ol ? *il : *ol;
    memcpy(*out, *in, n);
    *in += n;
    *out += n;
    *il -= n;
    *ol -= n;
    if (*il) {
        *__errno_location() = E2BIG;
        return (size_t)-1;      /* output full: caller retries */
    }
    return 0;
}

int iconv_close(void *cd) { (void)cd; return 0; }

/* ---- eventfd / epoll: no IO manager in this kernel ---- */

int eventfd(unsigned initval, int flags)
{
    (void)initval; (void)flags;
    *__errno_location() = ENOSYS;
    return -1;
}
int eventfd_write(int fd, unsigned long value)
{
    (void)fd; (void)value;
    *__errno_location() = ENOSYS;
    return -1;
}
int epoll_create(int size)
{
    (void)size;
    *__errno_location() = ENOSYS;
    return -1;
}
int epoll_create1(int flags)
{
    (void)flags;
    *__errno_location() = ENOSYS;
    return -1;
}
int epoll_ctl(int ep, int op, int fd, void *ev)
{
    (void)ep; (void)op; (void)fd; (void)ev;
    *__errno_location() = ENOSYS;
    return -1;
}
int epoll_wait(int ep, void *events, int maxev, int timeout)
{
    (void)ep; (void)events; (void)maxev; (void)timeout;
    *__errno_location() = ENOSYS;
    return -1;
}

static int house_strerror_r(int errnum, char *buf, size_t buflen)
{
    (void)errnum;
    strncpy(buf, "house error", buflen);
    buf[buflen ? buflen - 1 : 0] = '\0';
    return 0;
}

int __xpg_strerror_r(int errnum, char *buf, size_t buflen);

int __xpg_strerror_r(int errnum, char *buf, size_t buflen)
{
    return house_strerror_r(errnum, buf, buflen);
}

/* glibc's headers redirect strerror_r to __xpg_strerror_r; alias at the
   symbol level so both names exist without a conflicting declaration. */
__asm__ (".globl strerror_r\n\t.set strerror_r, __xpg_strerror_r");

/* ---- large-file variants: same ABI on aarch64 ---- */

extern int stat(const char *, struct stat *);
extern int fstat(int, struct stat *);
extern int lstat(const char *, struct stat *);

int stat64(const char *p, struct stat *st) { return stat(p, st); }
int fstat64(int fd, struct stat *st) { return fstat(fd, st); }
int lstat64(const char *p, struct stat *st) { return lstat(p, st); }

unsigned long getauxval(unsigned long type)
{
    (void)type;
    return 0;
}
unsigned long __getauxval(unsigned long type)
{
    return getauxval(type);
}

int statfs(const char *p, void *buf)
{
    (void)p; (void)buf;
    *__errno_location() = ENOENT_;
    return -1;
}

static int digit_val_local(char c);

unsigned long long strtoull(const char *n, char **end, int base)
{
    unsigned long long v = 0;
    int d;
    while (*n == ' ' || (*n >= 9 && *n <= 13)) n++;
    if (*n == '+') n++;
    if ((base == 16 || base == 0) && n[0] == '0' && (n[1] | 0x20) == 'x') {
        n += 2; base = 16;
    } else if (base == 0) {
        base = (*n == '0') ? 8 : 10;
    }
    while ((d = digit_val_local(*n)) >= 0 && d < base) {
        v = v * (unsigned long long)base + (unsigned long long)d;
        n++;
    }
    if (end) *end = (char *)n;
    return v;
}

static int digit_val_local(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Ticker thread: accepted on paper, never scheduled. Ticks are delivered
   synchronously from the ARM timer ISR instead (house_rts_tick). */
int pthread_create(unsigned long *t, const void *a,
                   void *(*fn)(void *), void *arg)
{
    static unsigned long fake_tid = 100;
    (void)a; (void)fn; (void)arg;
    *t = ++fake_tid;
    return 0;
}

/* ---- FORTIFY_SOURCE forwards from the Debian-built RTS/libffi ---- */

int fprintf(FILE *, const char *, ...);

int __fprintf_chk(FILE *f, int flag, const char *fmt, ...)
{
    va_list ap;
    int r;
    (void)flag;
    va_start(ap, fmt);
    r = vfprintf(f, fmt, ap);
    va_end(ap);
    return r;
}
int __printf_chk(int flag, const char *fmt, ...)
{
    va_list ap;
    int r;
    (void)flag;
    va_start(ap, fmt);
    r = vfprintf(stdout, fmt, ap);
    va_end(ap);
    return r;
}
void *__memcpy_chk(void *d, const void *s, size_t n, size_t bs)
{
    (void)bs;
    return memcpy(d, s, n);
}
void *__memmove_chk(void *d, const void *s, size_t n, size_t bs)
{
    extern void *memmove(void *, const void *, size_t);
    (void)bs;
    return memmove(d, s, n);
}
void *__memset_chk(void *d, int c, size_t n, size_t bs)
{
    (void)bs;
    return memset(d, c, n);
}

__attribute__((noreturn)) void abort(void);
void __assert_fail(const char *assertion, const char *file, unsigned line,
                   const char *function)
{
    fprintf(stderr, "[house] ASSERT(%s) at %s:%u in %s\n",
            assertion ? assertion : "?", file ? file : "?", line,
            function ? function : "?");
    abort();
}

/* ---- blocking primitives: nothing should reach these ---- */

int nanosleep(const struct timespec *rq, struct timespec *rm)
{
    (void)rq; (void)rm;
    return 0;
}
int pause(void) { *__errno_location() = EINTR; return -1; }
struct pollfd {
    int fd;
    short events;
    short revents;
};
int house_timerfd_due(int fd);
int house_fd_pipe_readable(int fd);
int poll(struct pollfd *fds, unsigned long nfds, int timeout)
{
    /* Minimal readiness for the ticker loop: timerfds due on their paced
       interval (and pipe read ends with data) report POLLIN immediately;
       everything else reports nothing. timeout is not simulated — the
       RTS treats 0 as "poll again", which the scheduler interleaves. */
    unsigned long i;
    int ready = 0;
    (void)timeout;
    for (i = 0; i < nfds; i++) {
        fds[i].revents = 0;
        if ((fds[i].events & 0x0001) &&
            (house_timerfd_due(fds[i].fd) ||
             house_fd_pipe_readable(fds[i].fd))) {
            fds[i].revents |= 0x0001;   /* POLLIN */
            ready++;
        }
    }
    return ready;
}
int select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv)
{
    (void)nfds; (void)r; (void)w; (void)e;
    if (tv)
        tv->tv_sec = tv->tv_usec = 0;
    return 0;
}
/* timerfd_* live in sys.c (ticker seam) */

/* ---- termios: pretend not-a-tty so Handle layer skips raw-mode paths ---- */

struct termios_dummy;
int tcgetattr(int fd, struct termios_dummy *t) { (void)fd; (void)t; *__errno_location() = ENOTTY_; return -1; }
int tcsetattr(int fd, int act, const struct termios_dummy *t) { (void)fd; (void)act; (void)t; *__errno_location() = ENOTTY_; return -1; }

/* ---- limits / rusage / clocks ---- */

int getrlimit(int res, struct rlimit *rl)
{
    (void)res;
    rl->rlim_cur = rl->rlim_max = 1ull << 40;
    return 0;
}

int getrusage(int who, struct rusage *ru)
{
    uint64_t ns = house_uptime_ns();
    (void)who;
    memset(ru, 0, sizeof *ru);
    ru->ru_utime.tv_sec = (long)(ns / 1000000000ull);
    ru->ru_utime.tv_usec = (long)((ns / 1000ull) % 1000000ull);
    ru->ru_stime = ru->ru_utime;
    ru->ru_maxrss = 1 << 16;
    return 0;
}

int clock_getcpuclockid(pid_t pid, int *clk)
{
    (void)pid;
    *clk = 2;
    return 0;
}

time_t time(time_t *t)
{
    time_t now = (time_t)(FAKE_EPOCH_ + house_uptime_ns() / 1000000000ull);
    if (t)
        *t = now;
    return now;
}

char *ctime_r(const time_t *t, char *buf)
{
    (void)t;
    strncpy(buf, "Thu Jan  1 00:00:00 2026\n", 26);
    return buf;
}

char *dirname(char *path)
{
    char *slash;
    static char dot[] = ".";
    if (!path || !*path)
        return dot;
    slash = strrchr(path, '/');
    if (!slash)
        return dot;
    if (slash == path)
        return "/";
    *slash = '\0';
    return path;
}

char *stpcpy(char *dst, const char *src)
{
    while ((*dst++ = *src++)) ;
    return dst - 1;
}

/* ---- regex (Hpc only) ---- */

int regcomp(void *preg, const char *pat, int fl) { (void)preg; (void)pat; (void)fl; *__errno_location() = ENOSYS; return -1; }
int regexec(const void *preg, const char *s, size_t n, void *pm, int fl)
{
    (void)preg; (void)s; (void)n; (void)pm; (void)fl;
    return 1;                   /* REG_NOMATCH */
}
void regfree(void *preg) { (void)preg; }

/* ---- locale: one flat table, every class bit clear ---- */

void *newlocale(int mask, const char *name, void *base)
{
    (void)mask; (void)name;
    return base;
}
void freelocale(void *l) { (void)l; }
void *uselocale(void *l) { (void)l; return 0; }
/* Base derives the locale TextEncoding from this name: it must advertise
   UTF-8 or GHC falls back to its wide-char encoding (UCS-4 bytes on the
   wire). */
char *setlocale(int cat, const char *name)
{
    (void)cat; (void)name;
    return "C.UTF-8";
}

static unsigned short ctype_table[384];

const unsigned short **__ctype_b_loc(void)
{
    static const unsigned short *table_ptr = ctype_table + 128;
    return (const unsigned short **)&table_ptr;
}

/* ---- qsort: insertion sort, fine for the small arrays involved ---- */

void qsort(void *base, size_t nmemb, size_t size,
           int (*cmp)(const void *, const void *))
{
    char *b = base;
    size_t i, j;
    static char tmp[256];

    if (size > sizeof tmp || !nmemb)
        return;
    for (i = 1; i < nmemb; i++) {
        memcpy(tmp, b + i * size, size);
        j = i;
        while (j && cmp(b + (j - 1) * size, tmp) > 0) {
            memcpy(b + j * size, b + (j - 1) * size, size);
            j--;
        }
        memcpy(b + j * size, tmp, size);
    }
}
