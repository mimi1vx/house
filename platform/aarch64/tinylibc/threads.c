#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/select.h>
#include "threads.h"
#include "../uart.h"
#include "../irq.h"

void *malloc(size_t n);
void free(void *p);
void *memset(void *dst, int c, size_t n);
void *memcpy(void *dst, const void *src, size_t n);
uint64_t house_uptime_ns(void);
int raise(int sig);
void uart_puts(const char *s);
void uart_putc(char c);
extern void house_gic_send_sgi(uint32_t sgi_id, uint32_t aff0_mask);

house_spinlock_t sched_lock = {0};
volatile int house_sched_deferred[HOUSE_MAX_SMP] = {0};
volatile int house_ipi_pending[HOUSE_MAX_SMP] = {0};
int house_thr_mode = 1;

static house_thread_t threads[HOUSE_MAX_THREADS];
house_thread_t *house_current_thr[HOUSE_MAX_SMP] = {0};
static house_thread_t *run_head[HOUSE_MAX_SMP] = {0};
static house_thread_t *run_tail[HOUSE_MAX_SMP] = {0};
static int next_tid = 1;
extern volatile int house_smp_n;
extern volatile uint32_t house_smp_online_mask;

static void enqueue_run_core(int core, house_thread_t *thr) {
    thr->next = NULL;
    thr->state = HOUSE_THR_RUNNABLE;
    if (run_tail[core]) run_tail[core]->next = thr;
    else run_head[core] = thr;
    run_tail[core] = thr;
}
static void enqueue_run(house_thread_t *thr) {
    // default: enqueue to thr's affinity or round-robin core
    int core = thr->affinity ? __builtin_ctz(thr->affinity) : (thr->tid % house_smp_n);
    if (core >= house_smp_n) core = 0;
    enqueue_run_core(core, thr);
    // kick remote core if needed
    uint32_t cur = house_cpu_id();
    if ((uint32_t)core != cur) {
        house_sched_kick(core);
    }
}
static house_thread_t *dequeue_run_core(int core) {
    house_thread_t *thr = run_head[core];
    if (!thr) return NULL;
    run_head[core] = thr->next;
    if (!run_head[core]) run_tail[core] = NULL;
    thr->next = NULL;
    return thr;
}

static house_thread_t *alloc_thread(void) {
    for (int i = 0; i < HOUSE_MAX_THREADS; i++) {
        if (threads[i].state == HOUSE_THR_UNUSED) return &threads[i];
    }
    return NULL;
}

house_thread_t *house_thread_current(void) {
    uint32_t core = house_cpu_id();
    if (core >= HOUSE_MAX_SMP) core = 0;
    return house_current_thr[core];
}

void house_sched_lock_acquire(void) {
    // mask IRQ to avoid deadlock with ISR trying to acquire? ISR doesn't acquire.
    __asm__ volatile("msr daifset, #2" ::: "memory");
    house_spin_lock(&sched_lock);
}
void house_sched_lock_release(void) {
    uint32_t core = house_cpu_id();
    int deferred = 0;
    if (core < HOUSE_MAX_SMP) deferred = house_sched_deferred[core];
    house_spin_unlock(&sched_lock);
    __asm__ volatile("msr daifclr, #2" ::: "memory");
    if (deferred) {
        house_sched_deferred[core] = 0;
        house_sched_yield();
    }
}

void house_threads_init(void) {
    for (int i = 0; i < HOUSE_MAX_THREADS; i++) threads[i].state = HOUSE_THR_UNUSED;
    next_tid = 1;
    for (int c=0;c<HOUSE_MAX_SMP;c++) { run_head[c]=run_tail[c]=NULL; house_current_thr[c]=NULL; house_sched_deferred[c]=0; house_ipi_pending[c]=0; }
    house_spin_init(&sched_lock);
}

void house_thread_init_main(void) {
    house_threads_init();
    house_thread_t *main_thr = alloc_thread();
    if (!main_thr) return;
    main_thr->tid = next_tid++;
    main_thr->state = HOUSE_THR_RUNNING;
    main_thr->detached = 0;
    main_thr->exited = 0;
    main_thr->stack_base = NULL;
    main_thr->stack_size = 0;
    main_thr->start = NULL;
    main_thr->arg = NULL;
    main_thr->retval = NULL;
    main_thr->wait_next = NULL;
    main_thr->joiner = NULL;
    main_thr->next = NULL;
    main_thr->errno_val = 0;
    main_thr->wake_ns = 0;
    main_thr->affinity = 1u << 0;
    memset(&main_thr->sigmask, 0, sizeof(main_thr->sigmask));
    void *tcb = house_tls_alloc();
    main_thr->tcb = tcb;
    uint64_t tp = (uint64_t)tcb;
    main_thr->tpidr = tp;
    __asm__ volatile("msr tpidr_el0, %0" :: "r"(tp) : "memory");
    __asm__ volatile("isb" ::: "memory");
    house_current_thr[0] = main_thr;
}

void house_threads_init_secondary(uint32_t core) {
    if (core >= HOUSE_MAX_SMP) return;
    // Allocate idle thread for this core if not yet
    house_thread_t *idle = alloc_thread();
    if (!idle) return;
    idle->tid = next_tid++;
    idle->state = HOUSE_THR_RUNNING;
    idle->detached = 0;
    idle->exited = 0;
    idle->stack_base = NULL;
    idle->stack_size = 0;
    idle->start = NULL;
    idle->arg = NULL;
    idle->retval = NULL;
    idle->wait_next = NULL;
    idle->joiner = NULL;
    idle->next = NULL;
    idle->errno_val = 0;
    idle->wake_ns = 0;
    idle->affinity = 1u << core;
    memset(&idle->sigmask, 0, sizeof(idle->sigmask));
    void *tcb = house_tls_alloc();
    idle->tcb = tcb;
    idle->tpidr = (uint64_t)tcb;
    __asm__ volatile("msr tpidr_el0, %0" :: "r"((uint64_t)tcb) : "memory");
    __asm__ volatile("isb" ::: "memory");
    house_current_thr[core] = idle;
}

void house_sched_wake(house_thread_t *thr) {
    if (!thr) return;
    house_spin_lock(&sched_lock);
    if (thr->state == HOUSE_THR_BLOCKED) {
        enqueue_run(thr);
    }
    house_spin_unlock(&sched_lock);
}

void house_sched_ipi_handler(void) {
    uint32_t core = house_cpu_id();
    if (core < HOUSE_MAX_SMP) house_ipi_pending[core] = 1;
    __asm__ volatile("dsb sy; isb");
}

void house_sched_kick(int core) {
    if (core < 0 || core >= house_smp_n) return;
    if (!(house_smp_online_mask & (1u << core))) return;
    house_gic_send_sgi(SGI_IPI, 1u << core);
}

void house_sched_block(void) {
    uint32_t core = house_cpu_id();
    house_thread_t *old = house_current_thr[core];
    house_spin_lock(&sched_lock);
    house_thread_t *next = dequeue_run_core(core);
    if (!next) {
        house_spin_unlock(&sched_lock);
        __asm__ volatile("msr daifclr, #2" ::: "memory");
        __asm__ volatile("wfi");
        __asm__ volatile("msr daifset, #2" ::: "memory");
        house_spin_lock(&sched_lock);
        next = dequeue_run_core(core);
        if (!next) {
            house_spin_unlock(&sched_lock);
            __asm__ volatile("msr daifclr, #2" ::: "memory");
            return;
        }
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr[core] = next;
    house_spin_unlock(&sched_lock);
    __asm__ volatile("msr daifset, #2" ::: "memory");
    house_thread_switch(old, next);
    __asm__ volatile("msr daifclr, #2" ::: "memory");
}

void house_sched_yield(void) {
    uint32_t core = house_cpu_id();
    // quick check for lock
    // use spinlock with deferred handling similar to old
    __asm__ volatile("msr daifset, #2" ::: "memory");
    // try lock without blocking? Use spin
    // If sched_lock is held, defer
    // We check via trylock to avoid deadlock
    if (house_spin_trylock(&sched_lock)) {
        if (core < HOUSE_MAX_SMP) house_sched_deferred[core] = 1;
        __asm__ volatile("msr daifclr, #2" ::: "memory");
        return;
    }
    house_thread_t *old = house_current_thr[core];
    if (!old) { house_spin_unlock(&sched_lock); __asm__ volatile("msr daifclr, #2" ::: "memory"); return; }
    if (old->state == HOUSE_THR_RUNNING) {
        old->state = HOUSE_THR_RUNNABLE;
        enqueue_run_core(core, old);
    }
    house_thread_t *next = dequeue_run_core(core);
    if (!next) {
        if (old->state == HOUSE_THR_RUNNABLE) {
            next = dequeue_run_core(core);
            if (!next) next = old;
        } else {
            house_spin_unlock(&sched_lock);
            __asm__ volatile("msr daifclr, #2" ::: "memory");
            return;
        }
    }
    if (next == old) {
        old->state = HOUSE_THR_RUNNING;
        house_spin_unlock(&sched_lock);
        __asm__ volatile("msr daifclr, #2" ::: "memory");
        return;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr[core] = next;
    house_spin_unlock(&sched_lock);
    __asm__ volatile("msr daifclr, #2" ::: "memory");
    house_thread_switch(old, next);
}

void house_sched_maybe_preempt_from_isr(void) {
    (void)house_sched_deferred;
}

/* ---- TLS ---- */
void *house_tls_alloc(void) {
    void *p = malloc(32);
    if (!p) return NULL;
    memset(p, 0, 32);
    return p;
}

/* ---- trampoline ---- */
static void house_thread_trampoline(void) {
    uint32_t core = house_cpu_id();
    house_thread_t *self = house_current_thr[core];
    void *(*fn)(void *) = self->start;
    void *arg = self->arg;
    void *ret = NULL;
    if (fn) ret = fn(arg);
    extern void pthread_exit(void *r);
    pthread_exit(ret);
}

/* ---- pthreads ---- */
int pthread_mutex_init(void *m, void *a) {
    (void)a;
    house_mutex_t *mu = (house_mutex_t *)m;
    mu->locked = 0;
    mu->owner = NULL;
    mu->wait_head = mu->wait_tail = NULL;
    return 0;
}
int pthread_mutex_destroy(void *m) { (void)m; return 0; }

int pthread_mutex_lock(void *m) {
    house_mutex_t *mu = (house_mutex_t *)m;
    for (;;) {
        house_spin_lock(&sched_lock);
        if (!mu->locked) {
            mu->locked = 1;
            mu->owner = house_thread_current();
            house_spin_unlock(&sched_lock);
            return 0;
        }
        house_thread_t *cur = house_thread_current();
        cur->state = HOUSE_THR_BLOCKED;
        cur->wait_next = NULL;
        if (mu->wait_tail) mu->wait_tail->wait_next = cur;
        else mu->wait_head = cur;
        mu->wait_tail = cur;
        house_spin_unlock(&sched_lock);
        house_sched_block();
    }
}

int pthread_mutex_trylock(void *m) {
    house_mutex_t *mu = (house_mutex_t *)m;
    house_spin_lock(&sched_lock);
    if (!mu->locked) {
        mu->locked = 1;
        mu->owner = house_thread_current();
        house_spin_unlock(&sched_lock);
        return 0;
    }
    house_spin_unlock(&sched_lock);
    return 16;
}

int pthread_mutex_unlock(void *m) {
    house_mutex_t *mu = (house_mutex_t *)m;
    house_spin_lock(&sched_lock);
    mu->locked = 0;
    mu->owner = NULL;
    if (mu->wait_head) {
        house_thread_t *w = mu->wait_head;
        mu->wait_head = w->wait_next;
        if (!mu->wait_head) mu->wait_tail = NULL;
        w->wait_next = NULL;
        w->state = HOUSE_THR_RUNNABLE;
        // enqueue to its affinity core (use w->affinity)
        int target = w->affinity ? __builtin_ctz(w->affinity) : 0;
        if (target >= house_smp_n) target = 0;
        enqueue_run_core(target, w);
        if ((uint32_t)target != house_cpu_id()) house_sched_kick(target);
    }
    house_spin_unlock(&sched_lock);
    return 0;
}

int pthread_cond_init(void *c, void *a) { (void)a; house_cond_t *cond = (house_cond_t *)c; cond->wait_head = cond->wait_tail = NULL; return 0; }
int pthread_cond_destroy(void *c) { (void)c; return 0; }

int pthread_cond_signal(void *c) {
    house_cond_t *cond = (house_cond_t *)c;
    house_spin_lock(&sched_lock);
    if (cond->wait_head) {
        house_thread_t *w = cond->wait_head;
        cond->wait_head = w->wait_next;
        if (!cond->wait_head) cond->wait_tail = NULL;
        w->wait_next = NULL;
        int target = w->affinity ? __builtin_ctz(w->affinity) : 0;
        if (target >= house_smp_n) target = 0;
        enqueue_run_core(target, w);
        if ((uint32_t)target != house_cpu_id()) house_sched_kick(target);
    }
    house_spin_unlock(&sched_lock);
    return 0;
}

int pthread_cond_broadcast(void *c) {
    house_cond_t *cond = (house_cond_t *)c;
    house_spin_lock(&sched_lock);
    while (cond->wait_head) {
        house_thread_t *w = cond->wait_head;
        cond->wait_head = w->wait_next;
        w->wait_next = NULL;
        int target = w->affinity ? __builtin_ctz(w->affinity) : 0;
        if (target >= house_smp_n) target = 0;
        enqueue_run_core(target, w);
        if ((uint32_t)target != house_cpu_id()) house_sched_kick(target);
    }
    cond->wait_tail = NULL;
    house_spin_unlock(&sched_lock);
    return 0;
}

int pthread_cond_wait(void *c, void *m) {
    house_cond_t *cond = (house_cond_t *)c;
    house_mutex_t *mu = (house_mutex_t *)m;
    house_spin_lock(&sched_lock);
    house_thread_t *cur = house_thread_current();
    cur->state = HOUSE_THR_BLOCKED;
    cur->wait_next = NULL;
    if (cond->wait_tail) cond->wait_tail->wait_next = cur;
    else cond->wait_head = cur;
    cond->wait_tail = cur;
    mu->locked = 0;
    mu->owner = NULL;
    if (mu->wait_head) {
        house_thread_t *w = mu->wait_head;
        mu->wait_head = w->wait_next;
        if (!mu->wait_head) mu->wait_tail = NULL;
        w->wait_next = NULL;
        int target = w->affinity ? __builtin_ctz(w->affinity) : 0;
        if (target >= house_smp_n) target = 0;
        enqueue_run_core(target, w);
        if ((uint32_t)target != house_cpu_id()) house_sched_kick(target);
    }
    uint32_t core = house_cpu_id();
    house_thread_t *old = cur;
    house_thread_t *next = dequeue_run_core(core);
    if (!next) {
        house_spin_unlock(&sched_lock);
        while (cur->state == HOUSE_THR_BLOCKED) { __asm__ volatile("wfi"); }
        house_spin_lock(&sched_lock);
        goto reacquire;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr[core] = next;
    house_spin_unlock(&sched_lock);
    house_thread_switch(old, next);
    house_spin_lock(&sched_lock);
reacquire:
    while (mu->locked) {
        cur = house_thread_current();
        cur->state = HOUSE_THR_BLOCKED;
        cur->wait_next = NULL;
        if (mu->wait_tail) mu->wait_tail->wait_next = cur;
        else mu->wait_head = cur;
        mu->wait_tail = cur;
        house_thread_t *old2 = cur;
        uint32_t c2 = house_cpu_id();
        house_thread_t *n2 = dequeue_run_core(c2);
        if (!n2) { house_spin_unlock(&sched_lock); __asm__ volatile("wfi"); house_spin_lock(&sched_lock); continue; }
        n2->state = HOUSE_THR_RUNNING;
        house_current_thr[c2] = n2;
        house_spin_unlock(&sched_lock);
        house_thread_switch(old2, n2);
        house_spin_lock(&sched_lock);
    }
    mu->locked = 1;
    mu->owner = house_thread_current();
    house_spin_unlock(&sched_lock);
    return 0;
}

int pthread_cond_timedwait(void *c, void *m, const struct timespec *t) {
    if (!t) return pthread_cond_wait(c,m);
    uint64_t now = house_uptime_ns();
    uint64_t abs_ns = (uint64_t)t->tv_sec * 1000000000ULL + (uint64_t)t->tv_nsec;
    if (t->tv_sec > 1000000000) {
        if (abs_ns >= 1785000000ULL * 1000000000ULL) abs_ns -= 1785000000ULL * 1000000000ULL;
    }
    if (abs_ns <= now) return ETIMEDOUT;
    house_cond_t *cond = (house_cond_t *)c;
    house_mutex_t *mu = (house_mutex_t *)m;
    house_spin_lock(&sched_lock);
    house_thread_t *cur = house_thread_current();
    cur->wake_ns = abs_ns;
    cur->state = HOUSE_THR_BLOCKED;
    cur->wait_next = NULL;
    if (cond->wait_tail) cond->wait_tail->wait_next = cur;
    else cond->wait_head = cur;
    cond->wait_tail = cur;
    mu->locked = 0;
    mu->owner = NULL;
    if (mu->wait_head) {
        house_thread_t *w = mu->wait_head;
        mu->wait_head = w->wait_next;
        if (!mu->wait_head) mu->wait_tail = NULL;
        w->wait_next = NULL;
        int target = w->affinity ? __builtin_ctz(w->affinity) : 0;
        if (target >= house_smp_n) target = 0;
        enqueue_run_core(target, w);
        if ((uint32_t)target != house_cpu_id()) house_sched_kick(target);
    }
    uint32_t core = house_cpu_id();
    house_thread_t *old = cur;
    house_thread_t *next = dequeue_run_core(core);
    if (!next) {
        house_spin_unlock(&sched_lock);
        while (cur->state == HOUSE_THR_BLOCKED) {
            uint64_t now2 = house_uptime_ns();
            if (now2 >= abs_ns) {
                house_spin_lock(&sched_lock);
                house_thread_t *prev=NULL; house_thread_t *it=cond->wait_head;
                while(it){ if(it==cur){ if(prev) prev->wait_next=it->wait_next; else cond->wait_head=it->wait_next; if(cond->wait_tail==it) cond->wait_tail=prev; it->wait_next=NULL; it->state=HOUSE_THR_RUNNABLE; break; } prev=it; it=it->wait_next; }
                if(cur->state==HOUSE_THR_BLOCKED){ cur->state=HOUSE_THR_RUNNABLE; cur->wake_ns=0; }
                house_spin_unlock(&sched_lock);
                goto timed_reacquire;
            }
            __asm__ volatile("wfi");
        }
        house_spin_lock(&sched_lock);
        goto timed_reacquire;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr[core] = next;
    house_spin_unlock(&sched_lock);
    house_thread_switch(old, next);
    house_spin_lock(&sched_lock);
    cur->wake_ns = 0;
timed_reacquire:
    while (mu->locked) {
        cur = house_thread_current();
        cur->state = HOUSE_THR_BLOCKED;
        cur->wait_next = NULL;
        if (mu->wait_tail) mu->wait_tail->wait_next = cur;
        else mu->wait_head = cur;
        mu->wait_tail = cur;
        house_thread_t *old2 = cur;
        uint32_t c2 = house_cpu_id();
        house_thread_t *n2 = dequeue_run_core(c2);
        if (!n2) { house_spin_unlock(&sched_lock); __asm__ volatile("wfi"); house_spin_lock(&sched_lock); continue; }
        n2->state = HOUSE_THR_RUNNING;
        house_current_thr[c2] = n2;
        house_spin_unlock(&sched_lock);
        house_thread_switch(old2, n2);
        house_spin_lock(&sched_lock);
    }
    mu->locked = 1;
    mu->owner = house_thread_current();
    int ret = 0;
    if (house_uptime_ns() >= abs_ns) ret = ETIMEDOUT;
    house_spin_unlock(&sched_lock);
    return ret;
}

int pthread_condattr_init(void *a) { (void)a; return 0; }
int pthread_condattr_destroy(void *a) { (void)a; return 0; }
int pthread_condattr_setclock(void *a, int clk) { (void)a; (void)clk; return 0; }

int pthread_attr_init(void *a) { (void)a; return 0; }
int pthread_attr_destroy(void *a) { (void)a; return 0; }
int pthread_attr_getstacksize(void *a, size_t *s) { (void)a; *s = HOUSE_THREAD_STACK_BYTES; return 0; }

unsigned long pthread_self(void) {
    house_thread_t *cur = house_thread_current();
    if (!cur) return 1;
    return (unsigned long)cur->tid;
}

int pthread_join(unsigned long t, void **r) {
    house_thread_t *target = NULL;
    for (int i = 0; i < HOUSE_MAX_THREADS; i++) if (threads[i].tid == (int)t && threads[i].state != HOUSE_THR_UNUSED) { target = &threads[i]; break; }
    if (!target) return 3;
    if (target->detached) return EINVAL;
    while (!target->exited) {
        house_spin_lock(&sched_lock);
        if (target->exited) { house_spin_unlock(&sched_lock); break; }
        house_thread_t *cur = house_thread_current();
        cur->state = HOUSE_THR_BLOCKED;
        target->joiner = cur;
        uint32_t core = house_cpu_id();
        house_thread_t *old = cur;
        house_thread_t *next = dequeue_run_core(core);
        if (!next) { house_spin_unlock(&sched_lock); __asm__ volatile("wfi"); continue; }
        next->state = HOUSE_THR_RUNNING;
        house_current_thr[core] = next;
        house_spin_unlock(&sched_lock);
        house_thread_switch(old, next);
    }
    if (r) *r = target->retval;
    house_spin_lock(&sched_lock);
    if (target->stack_base) free(target->stack_base);
    if (target->tcb) free(target->tcb);
    target->state = HOUSE_THR_UNUSED;
    target->tid = 0;
    house_spin_unlock(&sched_lock);
    return 0;
}

int pthread_detach(unsigned long t) {
    house_spin_lock(&sched_lock);
    for (int i = 0; i < HOUSE_MAX_THREADS; i++) if (threads[i].tid == (int)t) { threads[i].detached = 1; if (threads[i].exited && threads[i].state != HOUSE_THR_UNUSED) { if (threads[i].stack_base) free(threads[i].stack_base); if (threads[i].tcb) free(threads[i].tcb); threads[i].state = HOUSE_THR_UNUSED; } house_spin_unlock(&sched_lock); return 0; }
    house_spin_unlock(&sched_lock);
    return 0;
}

__attribute__((noreturn)) void pthread_exit(void *r) {
    uint32_t core = house_cpu_id();
    house_thread_t *cur = house_current_thr[core];
    cur->retval = r;
    cur->exited = 1;
    cur->state = HOUSE_THR_EXITED;
    house_spin_lock(&sched_lock);
    if (cur->joiner) {
        house_thread_t *j = cur->joiner;
        cur->joiner = NULL;
        int target = j->affinity ? __builtin_ctz(j->affinity) : 0;
        if (target >= house_smp_n) target = 0;
        enqueue_run_core(target, j);
        if ((uint32_t)target != core) house_sched_kick(target);
    }
    if (cur->detached) {
        if (cur->stack_base) free(cur->stack_base);
        if (cur->tcb) free(cur->tcb);
        cur->state = HOUSE_THR_UNUSED;
    }
    house_thread_t *next = dequeue_run_core(core);
    if (!next) { house_spin_unlock(&sched_lock); for (;;) __asm__ volatile("wfi"); }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr[core] = next;
    house_spin_unlock(&sched_lock);
    house_thread_t *old = cur;
    house_thread_switch(old, next);
    for (;;) __asm__ volatile("wfi");
}

int pthread_kill(unsigned long t, int s) { (void)t; return raise(s); }
int pthread_setname_np(unsigned long t, const char *n) { (void)t; (void)n; return 0; }

int pthread_create(unsigned long *thr, const void *a, void *(*fn)(void *), void *arg) {
    (void)a;
    house_spin_lock(&sched_lock);
    house_thread_t *t = alloc_thread();
    if (!t) { house_spin_unlock(&sched_lock); return EAGAIN; }
    void *stack = malloc(HOUSE_THREAD_STACK_BYTES);
    if (!stack) { t->state = HOUSE_THR_UNUSED; house_spin_unlock(&sched_lock); return ENOMEM; }
    void *tcb = house_tls_alloc();
    if (!tcb) { free(stack); t->state = HOUSE_THR_UNUSED; house_spin_unlock(&sched_lock); return ENOMEM; }
    t->tid = next_tid++;
    t->start = fn;
    t->arg = arg;
    t->retval = NULL;
    t->detached = 0;
    t->exited = 0;
    t->stack_base = stack;
    t->stack_size = HOUSE_THREAD_STACK_BYTES;
    t->tcb = tcb;
    t->tpidr = (uint64_t)tcb;
    t->errno_val = 0;
    t->wake_ns = 0;
    // For SMP bring-up debugging, pin all new threads to core 0
    // TODO: restore round-robin (t->tid % house_smp_n) for true parallelism
    int target = 0;
    t->affinity = 1u << target;
    memset(&t->sigmask, 0, sizeof(t->sigmask));
    uintptr_t top = (uintptr_t)stack + HOUSE_THREAD_STACK_BYTES;
    top &= ~15ULL;
    top -= 160;
    uint64_t *sp = (uint64_t *)top;
    for (int i = 0; i < 20; i++) sp[i] = 0;
    sp[9] = (uint64_t)house_thread_trampoline;
    t->sp = (void *)sp;
    t->next = NULL;
    t->wait_next = NULL;
    t->joiner = NULL;
    t->state = HOUSE_THR_RUNNABLE;
    enqueue_run_core(target, t);
    *thr = (unsigned long)t->tid;
    uint32_t cur = house_cpu_id();
    int need_kick = (target != (int)cur);
    house_spin_unlock(&sched_lock);
    if (need_kick) house_sched_kick(target);
    return 0;
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old) {
    house_thread_t *cur = house_thread_current();
    if (!cur) {
        extern int sigprocmask(int how, const sigset_t *set, sigset_t *old);
        return sigprocmask(how, set, old);
    }
    if (old) *old = cur->sigmask;
    if (set) {
        if (how == SIG_BLOCK) {
            unsigned long *d = (unsigned long *)&cur->sigmask;
            const unsigned long *s = (const unsigned long *)set;
            for (size_t i = 0; i < sizeof(sigset_t)/sizeof(unsigned long); i++) d[i] |= s[i];
        } else if (how == SIG_UNBLOCK) {
            unsigned long *d = (unsigned long *)&cur->sigmask;
            const unsigned long *s = (const unsigned long *)set;
            for (size_t i = 0; i < sizeof(sigset_t)/sizeof(unsigned long); i++) d[i] &= ~s[i];
        } else if (how == SIG_SETMASK) cur->sigmask = *set;
    }
    return 0;
}

int sched_yield(void) {
    house_sched_yield();
    return 0;
}

int sched_getaffinity(pid_t pid, size_t sz, void *mask) {
    (void)pid;
    if (mask && sz >= sizeof(unsigned long)) {
        unsigned long m = 0;
        if (house_smp_n >= (int)(sizeof(unsigned long)*8)) m = ~0UL;
        else m = (1UL << house_smp_n) - 1;
        *(unsigned long *)mask = m;
        if (sz > sizeof(unsigned long)) memset((char *)mask + sizeof(unsigned long), 0, sz - sizeof(unsigned long));
    }
    return 0;
}
int sched_setaffinity(pid_t pid, size_t sz, const void *mask) {
    (void)pid; (void)sz;
    if (mask) {
        house_thread_t *cur = house_thread_current();
        if (cur) cur->affinity = *(const uint32_t *)mask;
    }
    return 0;
}
int pthread_setaffinity_np(unsigned long tid, size_t sz, const void *mask) {
    (void)sz;
    house_spin_lock(&sched_lock);
    for (int i=0;i<HOUSE_MAX_THREADS;i++) if (threads[i].tid == (int)tid) { threads[i].affinity = *(const uint32_t*)mask; break; }
    house_spin_unlock(&sched_lock);
    return 0;
}
int pthread_getaffinity_np(unsigned long tid, size_t sz, void *mask) {
    (void)tid;
    if (mask && sz >= sizeof(unsigned long)) {
        unsigned long m = (1UL << house_smp_n)-1;
        *(unsigned long*)mask = m;
        if (sz > sizeof(unsigned long)) memset((char*)mask+sizeof(unsigned long),0,sz-sizeof(unsigned long));
    }
    return 0;
}
int pthread_attr_setaffinity_np(void *a, size_t sz, const void *mask) { (void)a; (void)sz; (void)mask; return 0; }
int pthread_attr_getaffinity_np(void *a, size_t sz, void *mask) { (void)a; if(mask&&sz>=sizeof(unsigned long)) *(unsigned long*)mask=(1UL<<house_smp_n)-1; return 0; }

int nanosleep(const struct timespec *rq, struct timespec *rm) {
    if (!rq) return 0;
    uint64_t ns = (uint64_t)rq->tv_sec * 1000000000ULL + (uint64_t)rq->tv_nsec;
    if (ns == 0) { house_sched_yield(); return 0; }
    uint64_t until = house_uptime_ns() + ns;
    uint32_t core = house_cpu_id();
    house_spin_lock(&sched_lock);
    house_thread_t *cur = house_current_thr[core];
    if (!cur) { house_spin_unlock(&sched_lock); house_sched_yield(); return 0; }
    cur->wake_ns = until;
    cur->state = HOUSE_THR_BLOCKED;
    house_thread_t *old = cur;
    house_thread_t *next = dequeue_run_core(core);
    if (!next) {
        house_spin_unlock(&sched_lock);
        while (house_uptime_ns() < until) { __asm__ volatile("wfi"); }
        house_spin_lock(&sched_lock);
        cur->wake_ns = 0;
        cur->state = HOUSE_THR_RUNNING;
        house_current_thr[core] = cur;
        house_spin_unlock(&sched_lock);
        return 0;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr[core] = next;
    house_spin_unlock(&sched_lock);
    house_thread_switch(old, next);
    while (house_uptime_ns() < until) {
        uint64_t rem = until - house_uptime_ns();
        struct timespec tmp = { .tv_sec = rem / 1000000000ULL, .tv_nsec = rem % 1000000000ULL };
        return nanosleep(&tmp, rm);
    }
    if (rm) { rm->tv_sec = 0; rm->tv_nsec = 0; }
    return 0;
}

struct pollfd { int fd; short events; short revents; };
extern int house_timerfd_due(int fd);
extern int house_fd_pipe_readable(int fd);
int poll(struct pollfd *fds, unsigned long nfds, int timeout) {
    unsigned long i;
    for (i = 0; i < nfds; i++) {
        fds[i].revents = 0;
        if ((fds[i].events & 0x0001) && (house_timerfd_due(fds[i].fd) || house_fd_pipe_readable(fds[i].fd))) {
            fds[i].revents |= 0x0001;
        }
    }
    int ready = 0;
    for (i = 0; i < nfds; i++) if (fds[i].revents) ready++;
    if (ready) return ready;
    if (timeout == 0) return 0;
    uint32_t core = house_cpu_id();
    if (run_head[core]) {
        house_sched_yield();
    } else {
        uint64_t start = house_uptime_ns();
        uint64_t timeout_ns = timeout < 0 ? 0xffffffffULL : (uint64_t)timeout * 1000000ULL;
        while (1) {
            __asm__ volatile("wfi");
            int r = 0;
            for (i = 0; i < nfds; i++) {
                if ((fds[i].events & 0x0001) && (house_timerfd_due(fds[i].fd) || house_fd_pipe_readable(fds[i].fd))) {
                    fds[i].revents |= 0x0001;
                    r++;
                }
            }
            if (r) return r;
            if (timeout > 0 && house_uptime_ns() - start >= timeout_ns) return 0;
            if (timeout == 0) return 0;
        }
    }
    ready = 0;
    for (i = 0; i < nfds; i++) {
        fds[i].revents = 0;
        if ((fds[i].events & 0x0001) && (house_timerfd_due(fds[i].fd) || house_fd_pipe_readable(fds[i].fd))) {
            fds[i].revents |= 0x0001;
            ready++;
        }
    }
    return ready;
}

int select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *tv) {
    (void)nfds; (void)r; (void)w; (void)e;
    if (tv) {
        uint64_t us = (uint64_t)tv->tv_sec * 1000000ULL + (uint64_t)tv->tv_usec;
        if (us == 0) return 0;
        struct timespec ts = { .tv_sec = us / 1000000ULL, .tv_nsec = (us % 1000000ULL) * 1000ULL };
        nanosleep(&ts, NULL);
        tv->tv_sec = tv->tv_usec = 0;
    } else {
        house_sched_yield();
    }
    return 0;
}

int pause(void) {
    uint32_t core = house_cpu_id();
    house_spin_lock(&sched_lock);
    house_thread_t *cur = house_current_thr[core];
    cur->state = HOUSE_THR_BLOCKED;
    house_thread_t *old = cur;
    house_thread_t *next = dequeue_run_core(core);
    if (!next) { house_spin_unlock(&sched_lock); for (;;) __asm__ volatile("wfi"); }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr[core] = next;
    house_spin_unlock(&sched_lock);
    house_thread_switch(old, next);
    return -1;
}
