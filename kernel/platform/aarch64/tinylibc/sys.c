/* Freestanding syscall/signal shims backing the stock non-threaded RTS.
   The ticker seam lives here: setitimer/timer_* and sigaction(SIGVTALRM)
   are recorded instead of programmed into hardware; house_rts_tick()
   replays the recorded handler synchronously from the timer ISR.
   Struct layouts/types come from the real glibc headers so the ABI matches
   what the GHC bindist archives were compiled against. */

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include "uart.h"
#include "tick.h"

int *__errno_location(void)
{
    static int e;
    return &e;
}

void *memset(void *dst, int c, size_t n);
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);

/* ---- fake fd table: timerfds + pipes backed by tiny ring buffers ---- */

#define FAKE_FD_BASE 3
#define FAKE_FD_N 16
#define PIPE_CAP 1024

enum { FD_FREE = 0, FD_TIMER, FD_PIPE_R, FD_PIPE_W };

static struct {
    int kind;
    int peer;
    uint64_t ticks;
    char buf[PIPE_CAP];
    size_t len;
} fdt[FAKE_FD_N];

static int fd_slot(int fd)
{
    int s = fd - FAKE_FD_BASE;
    return (s >= 0 && s < FAKE_FD_N) ? s : -1;
}

static char *empty_env[] = { 0 };
char **environ = empty_env;

char *getenv(const char *n)
{
    (void)n;
    return 0;
}

/* ---- time ---- */

static uint64_t counter_hz(void)
{
    uint64_t f;
    __asm__ volatile ("mrs %0, cntfrq_el0" : "=r" (f));
    return f ? f : 62500000;
}

uint64_t house_uptime_ns(void)
{
    uint64_t c;
    __asm__ volatile ("mrs %0, cntpct_el0" : "=r" (c));
    return (uint64_t)((__uint128_t)c * 1000000000ull / counter_hz());
}

#define FAKE_EPOCH 1785000000ULL

static void ns_to_ts(struct timespec *tp, uint64_t ns)
{
    tp->tv_sec = (time_t)(ns / 1000000000ull);
    tp->tv_nsec = (long)(ns % 1000000000ull);
}

int clock_gettime(clockid_t clk, struct timespec *tp)
{
    uint64_t up = house_uptime_ns();
    if (clk == CLOCK_REALTIME)
        up += FAKE_EPOCH * 1000000000ull;
    ns_to_ts(tp, up);
    return 0;
}

int clock_getres(clockid_t clk, struct timespec *res)
{
    (void)clk;
    res->tv_sec = 0;
    res->tv_nsec = 100;
    return 0;
}

int gettimeofday(struct timeval *tv, void *tz)
{
    uint64_t ns = house_uptime_ns() + FAKE_EPOCH * 1000000000ull;
    (void)tz;
    tv->tv_sec = (long)(ns / 1000000000ull);
    tv->tv_usec = (long)((ns / 1000ull) % 1000000ull);
    return 0;
}

struct tms {
    long tms_utime, tms_stime, tms_cutime, tms_cstime;
};

clock_t times(struct tms *t)
{
    clock_t ticks = (clock_t)(house_uptime_ns() / 10000000ull);
    if (t)
        t->tms_utime = t->tms_stime = t->tms_cutime = t->tms_cstime = ticks;
    return ticks;
}

/* ---- signals: record handlers, replay on demand ---- */

static struct sigaction recorded[32];
static sigset_t curmask;

int sigemptyset(sigset_t *s) { memset(s, 0, sizeof *s); return 0; }
int sigfillset(sigset_t *s) { memset(s, 0xff, sizeof *s); return 0; }

int sigaddset(sigset_t *s, int n)
{
    unsigned long *w = (unsigned long *)s;
    w[(n - 1) / (8 * sizeof(long))] |= 1ul << ((n - 1) % (8 * sizeof(long)));
    return 0;
}

int sigdelset(sigset_t *s, int n)
{
    unsigned long *w = (unsigned long *)s;
    w[(n - 1) / (8 * sizeof(long))] &= ~(1ul << ((n - 1) % (8 * sizeof(long))));
    return 0;
}

int sigismember(const sigset_t *s, int n)
{
    const unsigned long *w = (const unsigned long *)s;
    return (int)((w[(n - 1) / (8 * sizeof(long))] >>
                  ((n - 1) % (8 * sizeof(long)))) & 1ul);
}

int sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
    if (sig <= 0 || sig >= 32) {
        *__errno_location() = EINVAL;
        return -1;
    }
    if (old)
        *old = recorded[sig];
    if (act)
        recorded[sig] = *act;
    return 0;
}

static void deliver(int sig)
{
    void (*h)(int) = recorded[sig].sa_handler;
    if (!(recorded[sig].sa_flags & SA_SIGINFO) && h &&
        h != (__sighandler_t)SIG_IGN && h != (__sighandler_t)SIG_DFL)
        h(sig);
}

int sigprocmask(int how, const sigset_t *set, sigset_t *old)
{
    (void)how;
    if (old)
        *old = curmask;
    if (set)
        curmask = *set;
    return 0;
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old)
{
    return sigprocmask(how, set, old);
}

int raise(int sig)
{
    deliver(sig);
    return 0;
}

int kill(pid_t pid, int sig)
{
    (void)pid;
    deliver(sig);
    return 0;
}

/* Called from the ARM generic-timer ISR (phase 3): synchronous replay of
   whatever the RTS installed for SIGVTALRM. */
void house_rts_tick(void)
{
    deliver(SIGVTALRM);
}

/* ---- itimers / POSIX timers: arm nothing, remember intervals ---- */

static uint64_t tick_interval_ns;

int setitimer(int which, const struct itimerval *nv, struct itimerval *ov)
{
    (void)which;
    if (ov)
        memset(ov, 0, sizeof *ov);
    if (nv) {
        tick_interval_ns = (uint64_t)nv->it_value.tv_sec * 1000000000ull +
                           (uint64_t)nv->it_value.tv_usec * 1000ull;
    }
    return 0;
}

int getitimer(int which, struct itimerval *v)
{
    (void)which;
    memset(v, 0, sizeof *v);
    v->it_interval.tv_sec = (long)(tick_interval_ns / 1000000000ull);
    v->it_interval.tv_usec = (long)((tick_interval_ns / 1000ull) % 1000000ull);
    return 0;
}

int timer_create(clockid_t clk, struct sigevent *ev, timer_t *tid)
{
    static int next_id = 1;
    (void)clk;
    (void)ev;
    *tid = (timer_t)(uintptr_t)next_id++;
    return 0;
}

int timer_settime(timer_t tid, int flags, const struct itimerspec *nv,
                  struct itimerspec *ov)
{
    (void)tid; (void)flags;
    if (ov)
        memset(ov, 0, sizeof *ov);
    if (nv) {
        tick_interval_ns = (uint64_t)nv->it_value.tv_sec * 1000000000ull +
                           (uint64_t)nv->it_value.tv_nsec;
    }
    return 0;
}

int timer_gettime(timer_t tid, struct itimerspec *v)
{
    (void)tid;
    memset(v, 0, sizeof *v);
    v->it_interval.tv_sec = (long)(tick_interval_ns / 1000000000ull);
    v->it_interval.tv_nsec = (long)(tick_interval_ns % 1000000000ull);
    return 0;
}

int timer_getoverrun(timer_t tid) { (void)tid; return 0; }
int timer_delete(timer_t tid) { (void)tid; return 0; }

/* ---- timerfds: GHC 9.14's non-threaded ticker arms one of these.
   We hand out fake fds and serve an incrementing 8-byte tick counter
   from read(); actual periodic delivery arrives with the timer ISR in
   phase 3 via house_rts_tick(). ---- */

int timerfd_create(int clockid, int flags)
{
    int i;
    (void)clockid; (void)flags;
    for (i = 0; i < FAKE_FD_N; i++) {
        if (fdt[i].kind == FD_FREE) {
            fdt[i].kind = FD_TIMER;
            return FAKE_FD_BASE + i;
        }
    }
    *__errno_location() = ENFILE;
    return -1;
}

int timerfd_settime(int fd, int flags, const struct itimerspec *nv,
                    struct itimerspec *ov)
{
    (void)fd; (void)flags;
    if (ov)
        memset(ov, 0, sizeof *ov);
    if (nv) {
        tick_interval_ns = (uint64_t)nv->it_interval.tv_sec * 1000000000ull +
                           (uint64_t)nv->it_interval.tv_nsec;
    }
    return 0;
}

int timerfd_gettime(int fd, struct itimerspec *v)
{
    (void)fd;
    v->it_value.tv_sec = 0;
    v->it_value.tv_nsec = 0;
    v->it_interval.tv_sec = (long)(tick_interval_ns / 1000000000ull);
    v->it_interval.tv_nsec = (long)(tick_interval_ns % 1000000000ull);
    return 0;
}

/* ---- console / fd io ---- */

ssize_t write(int fd, const void *buf, size_t n)
{
    const char *b = buf;
    size_t i;
    int s = fd_slot(fd);

    if (s >= 0 && fdt[s].kind == FD_PIPE_W) {
        int p = fd_slot(fdt[s].peer);
        size_t room, k;
        if (p < 0)
            return -1;
        room = PIPE_CAP - fdt[p].len;
        k = n < room ? n : room;
        memcpy(fdt[p].buf + fdt[p].len, b, k);
        fdt[p].len += k;
        return (ssize_t)k;
    }
    if (fd != 1 && fd != 2) {
        *__errno_location() = EBADF;
        return -1;
    }
    for (i = 0; i < n; i++)
        uart_putc(b[i]);
    return (ssize_t)n;
}

ssize_t read(int fd, void *buf, size_t n)
{
    int s = fd_slot(fd);
    if (s < 0)
        return 0;
    if (fdt[s].kind == FD_TIMER && buf && n >= 8) {
        *(uint64_t *)buf = ++fdt[s].ticks;
        return 8;
    }
    if (fdt[s].kind == FD_PIPE_R && fdt[s].len > 0 && buf) {
        size_t k = fdt[s].len < n ? fdt[s].len : n;
        memcpy(buf, fdt[s].buf, k);
        memmove(fdt[s].buf, fdt[s].buf + k, fdt[s].len - k);
        fdt[s].len -= k;
        return (ssize_t)k;
    }
    return 0;
}

int open(const char *path, int flags, ...)
{
    (void)path; (void)flags;
    *__errno_location() = ENOENT;
    return -1;
}

int close(int fd)
{
    int s = fd_slot(fd);
    if (s >= 0 && fdt[s].kind != FD_FREE) {
        fdt[s].kind = FD_FREE;
        fdt[s].len = 0;
    }
    return 0;
}

off_t lseek(int fd, off_t off, int whence)
{
    (void)fd; (void)off; (void)whence;
    *__errno_location() = ESPIPE;
    return -1;
}

int fcntl(int fd, int cmd, ...)
{
    (void)fd; (void)cmd;
    return 0;
}

int ioctl(int fd, unsigned long req, ...)
{
    (void)fd; (void)req;
    return 0;
}

int isatty(int fd)
{
    return fd <= 2;
}

int fstat(int fd, struct stat *st)
{
    (void)fd;
    memset(st, 0, sizeof *st);
    st->st_mode = S_IFCHR | 0666;
    st->st_blksize = 4096;
    st->st_dev = 1;
    st->st_ino = (ino_t)fd + 1;
    return 0;
}

int stat(const char *path, struct stat *st)
{
    (void)path; (void)st;
    *__errno_location() = ENOENT;
    return -1;
}

int unlink(const char *path) { (void)path; *__errno_location() = ENOENT; return -1; }
int chdir(const char *path) { (void)path; *__errno_location() = ENOENT; return -1; }

char *getcwd(char *buf, size_t n)
{
    if (!buf || n < 2)
        return 0;
    buf[0] = '/';
    buf[1] = '\0';
    return buf;
}

int pipe(int fds[2])
{
    int i, r = -1, w = -1;
    for (i = 0; i < FAKE_FD_N && (r < 0 || w < 0); i++) {
        if (fdt[i].kind == FD_FREE) {
            if (r < 0) {
                fdt[i].kind = FD_PIPE_R;
                r = i;
            } else {
                fdt[i].kind = FD_PIPE_W;
                w = i;
            }
        }
    }
    if (r < 0 || w < 0) {
        *__errno_location() = ENFILE;
        return -1;
    }
    fdt[r].peer = w;
    fdt[w].peer = r;
    fds[0] = FAKE_FD_BASE + r;
    fds[1] = FAKE_FD_BASE + w;
    return 0;
}
int dup(int fd) { (void)fd; *__errno_location() = EBADF; return -1; }
int dup2(int oldfd, int newfd) { (void)oldfd; return newfd; }
pid_t getpid(void) { return 42; }
uid_t getuid(void) { return 0; }
uid_t geteuid(void) { return 0; }
gid_t getgid(void) { return 0; }
gid_t getegid(void) { return 0; }

long sysconf(int name)
{
    switch (name) {
    case _SC_PAGESIZE:
        return 4096;
    case _SC_NPROCESSORS_ONLN:
    case _SC_NPROCESSORS_CONF:
        return 1;
    case _SC_PHYS_PAGES:
        return 131072;          /* 512 MiB / 4K: keeps the RTS heap
                                   reservation inside our bump region */
    case _SC_AVPHYS_PAGES:
        return 100000;
    case _SC_CLK_TCK:
        return 100;
    case _SC_OPEN_MAX:
        return 16;
    default:
        *__errno_location() = EINVAL;
        return -1;
    }
}

int getpagesize(void) { return 4096; }

/* ---- process exit ---- */

void exit(int status);
void _exit(int status);
void _Exit(int status);

void __attribute__((noreturn)) exit(int status)
{
    uart_puts("\n[house] exit(");
    uart_putc('0' + (status & 7));
    uart_puts(")\n");
    for (;;)
        __asm__ volatile ("wfi");
}

void _exit(int status) { exit(status); }
void _Exit(int status) { exit(status); }

void abort(void)
{
    uart_puts("\n[house] abort()\n");
    for (;;)
        __asm__ volatile ("wfi");
}

/* Debian-built archives may carry stack-protector references. */
uintptr_t __stack_chk_guard = 0xdeadbeefcafef00dULL;
void __stack_chk_fail(void) { abort(); }

/* ---- numeric parsing (RTS option paths reference these even when unused) ---- */

static int digit_val(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

long strtol(const char *n, char **end, int base)
{
    unsigned long v = 0;
    int neg = 0, d;
    while (*n == ' ' || (*n >= 9 && *n <= 13)) n++;
    if (*n == '-') { neg = 1; n++; } else if (*n == '+') n++;
    if ((base == 16 || base == 0) && n[0] == '0' && (n[1] | 0x20) == 'x') {
        n += 2; base = 16;
    } else if (base == 0) {
        base = (*n == '0') ? 8 : 10;
    }
    while ((d = digit_val(*n)) >= 0 && d < base) {
        v = v * (unsigned long)base + (unsigned long)d;
        n++;
    }
    if (end) *end = (char *)n;
    return neg ? -(long)v : (long)v;
}

unsigned long strtoul(const char *n, char **end, int base)
{
    return (unsigned long)strtol(n, end, base);
}

int atoi(const char *n) { return (int)strtol(n, 0, 10); }

char *strerror(int e)
{
    (void)e;
    return "house error";
}
