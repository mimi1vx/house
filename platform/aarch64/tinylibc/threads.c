#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/select.h>
#include "threads.h"
#include "uart.h"

void *malloc(size_t n);
void free(void *p);
void *memset(void *dst, int c, size_t n);
void *memcpy(void *dst, const void *src, size_t n);
uint64_t house_uptime_ns(void);
int raise(int sig);
void uart_puts(const char *s);
void uart_putc(char c);

volatile int house_sched_lock = 0;
volatile int house_sched_deferred = 0;
int house_thr_mode = 1;

static house_thread_t threads[HOUSE_MAX_THREADS];
static house_thread_t *house_current_thr = NULL;
static house_thread_t *run_head = NULL;
static house_thread_t *run_tail = NULL;
static int next_tid = 1;

static void enqueue_run(house_thread_t *thr) {
    thr->next = NULL;
    thr->state = HOUSE_THR_RUNNABLE;
    if (run_tail) run_tail->next = thr;
    else run_head = thr;
    run_tail = thr;
}

static house_thread_t *dequeue_run(void) {
    house_thread_t *thr = run_head;
    if (!thr) return NULL;
    run_head = thr->next;
    if (!run_head) run_tail = NULL;
    thr->next = NULL;
    return thr;
}

static house_thread_t *alloc_thread(void) {
    for (int i = 0; i < HOUSE_MAX_THREADS; i++) {
        if (threads[i].state == HOUSE_THR_UNUSED) {
            return &threads[i];
        }
    }
    return NULL;
}

house_thread_t *house_thread_current(void) {
    return house_current_thr;
}

void house_sched_lock_acquire(void) {
    __asm__ volatile("msr daifset, #2" ::: "memory");
    house_sched_lock++;
    __asm__ volatile("msr daifclr, #2" ::: "memory");
}

void house_sched_lock_release(void) {
    __asm__ volatile("msr daifset, #2" ::: "memory");
    house_sched_lock--;
    int deferred = house_sched_deferred;
    __asm__ volatile("msr daifclr, #2" ::: "memory");
    if (deferred && house_sched_lock == 0) {
        house_sched_deferred = 0;
        house_sched_yield();
    }
}

void house_threads_init(void) {
    for (int i = 0; i < HOUSE_MAX_THREADS; i++) threads[i].state = HOUSE_THR_UNUSED;
    next_tid = 1;
    run_head = run_tail = NULL;
    house_current_thr = NULL;
    house_sched_lock = 0;
    house_sched_deferred = 0;
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
    memset(&main_thr->sigmask, 0, sizeof(main_thr->sigmask));
    void *tcb = house_tls_alloc();
    main_thr->tcb = tcb;
    uint64_t tp = (uint64_t)tcb;
    main_thr->tpidr = tp;
    __asm__ volatile("msr tpidr_el0, %0" :: "r"(tp) : "memory");
    __asm__ volatile("isb" ::: "memory");
    house_current_thr = main_thr;
}

void house_sched_wake(house_thread_t *thr) {
    if (!thr) return;
    if (thr->state == HOUSE_THR_BLOCKED) {
        enqueue_run(thr);
    }
}

void house_sched_block(void) {
    // current already marked BLOCKED, pick next
    house_thread_t *old = house_current_thr;
    house_thread_t *next = dequeue_run();
    if (!next) {
        // no runnable threads, idle with wfi until ISR wakes someone
        // re-enable IRQ and wait
        __asm__ volatile("msr daifclr, #2" ::: "memory");
        __asm__ volatile("wfi");
        __asm__ volatile("msr daifset, #2" ::: "memory");
        next = dequeue_run();
        if (!next) {
            // still nothing, stay blocked (will be woken by ISR)
            // for now spin
            __asm__ volatile("msr daifclr, #2" ::: "memory");
            return;
        }
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr = next;
    __asm__ volatile("msr daifset, #2" ::: "memory");
    house_thread_switch(old, next);
    __asm__ volatile("msr daifclr, #2" ::: "memory");
}

void house_sched_yield(void) {
    __asm__ volatile("msr daifset, #2" ::: "memory");
    if (house_sched_lock > 0) {
        house_sched_deferred = 1;
        __asm__ volatile("msr daifclr, #2" ::: "memory");
        return;
    }
    house_thread_t *old = house_current_thr;
    if (!old) {
        __asm__ volatile("msr daifclr, #2" ::: "memory");
        return;
    }
    if (old->state == HOUSE_THR_RUNNING) {
        old->state = HOUSE_THR_RUNNABLE;
        enqueue_run(old);
    }
    house_thread_t *next = dequeue_run();
    if (!next) {
        // no other runnable, keep running current
        if (old->state == HOUSE_THR_RUNNABLE) {
            // it was requeued, dequeue it again
            next = dequeue_run();
            if (!next) next = old;
            else {
                // we have next, but old is candidate
                // actually if only old was runnable, next == old
            }
        } else {
            __asm__ volatile("msr daifclr, #2" ::: "memory");
            return;
        }
    }
    if (next == old) {
        old->state = HOUSE_THR_RUNNING;
        __asm__ volatile("msr daifclr, #2" ::: "memory");
        return;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr = next;
    __asm__ volatile("msr daifclr, #2" ::: "memory");
    house_thread_switch(old, next);
    // when we return, we are back in old's context
}

void house_sched_maybe_preempt_from_isr(void) {
    if (house_sched_lock > 0) {
        house_sched_deferred = 1;
        return;
    }
    // simple round-robin preemption each tick
    if (!house_current_thr) return;
    if (!run_head) return;
    // preempt current
    __asm__ volatile("msr daifset, #2" ::: "memory");
    house_thread_t *old = house_current_thr;
    old->state = HOUSE_THR_RUNNABLE;
    enqueue_run(old);
    house_thread_t *next = dequeue_run();
    if (!next || next == old) {
        if (next) {
            // only old
            old->state = HOUSE_THR_RUNNING;
            __asm__ volatile("msr daifclr, #2" ::: "memory");
            return;
        }
        old->state = HOUSE_THR_RUNNING;
        __asm__ volatile("msr daifclr, #2" ::: "memory");
        return;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr = next;
    // Need to switch stacks while still in ISR context.
    // The ISR's stack is the interrupted thread's stack; switching sp there
    // will make eret resume the next thread. We use the same switch routine
    // but we are inside IRQ handler with its own saved frame above.
    // Instead of direct switch, we do deferred switch via handler return?
    // For now, do direct switch; the IRQ handler's frame stays on old stack,
    // new thread's eret will use its own saved IRQ frame? This is subtle.
    // Simpler: just set deferred and let thread yield at next poll.
    // To avoid complexity, we defer preemption to thread context by setting flag.
    // Undo enqueue and mark deferred.
    // Instead of switching in ISR, defer.
    // Remove old from queue and keep it running, set deferred
    // (we already enqueued old, need to rollback)
    // For correctness, just mark deferred and revert.
    // Pull old back from queue if it was enqueued at tail
    // Actually we enqueued old, dequeued next, so old is in queue tail.
    // Let's revert: put next back to head, remove old from tail.
    // Simpler: just keep deferred flag and revert state.
    // For now, revert:
    // remove old from tail (it is at tail)
    if (run_tail == old) {
        // find previous
        house_thread_t *prev = run_head;
        if (prev == old) {
            run_head = run_tail = NULL;
        } else {
            while (prev && prev->next != old) prev = prev->next;
            if (prev) {
                prev->next = NULL;
                run_tail = prev;
            }
        }
    }
    // put next back to head
    next->next = run_head;
    run_head = next;
    if (!run_tail) run_tail = next;
    old->state = HOUSE_THR_RUNNING;
    house_current_thr = old;
    house_sched_deferred = 1;
    __asm__ volatile("msr daifclr, #2" ::: "memory");
}

/* ---- TLS ---- */
void *house_tls_alloc(void) {
    // 32 bytes: 16 TCB header + 8 tls + 8 pad
    void *p = malloc(32);
    if (!p) return NULL;
    memset(p, 0, 32);
    return p;
}

/* ---- trampoline ---- */
static void house_thread_trampoline(void) {
    house_thread_t *self = house_current_thr;
    void *(*fn)(void *) = self->start;
    void *arg = self->arg;
    void *ret = NULL;
    if (fn) ret = fn(arg);
    // exit
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
        house_sched_lock_acquire();
        if (!mu->locked) {
            mu->locked = 1;
            mu->owner = house_current_thr;
            house_sched_lock_release();
            return 0;
        }
        house_thread_t *cur = house_current_thr;
        cur->state = HOUSE_THR_BLOCKED;
        cur->wait_next = NULL;
        if (mu->wait_tail) mu->wait_tail->wait_next = cur;
        else mu->wait_head = cur;
        mu->wait_tail = cur;
        house_sched_lock_release();
        house_sched_block();
        // when woken, retry
    }
}

int pthread_mutex_trylock(void *m) {
    house_mutex_t *mu = (house_mutex_t *)m;
    house_sched_lock_acquire();
    if (!mu->locked) {
        mu->locked = 1;
        mu->owner = house_current_thr;
        house_sched_lock_release();
        return 0;
    }
    house_sched_lock_release();
    return 16; // EBUSY
}

int pthread_mutex_unlock(void *m) {
    house_mutex_t *mu = (house_mutex_t *)m;
    house_sched_lock_acquire();
    mu->locked = 0;
    mu->owner = NULL;
    if (mu->wait_head) {
        house_thread_t *w = mu->wait_head;
        mu->wait_head = w->wait_next;
        if (!mu->wait_head) mu->wait_tail = NULL;
        w->wait_next = NULL;
        w->state = HOUSE_THR_RUNNABLE;
        enqueue_run(w);
    }
    house_sched_lock_release();
    return 0;
}

int pthread_cond_init(void *c, void *a) { (void)a; house_cond_t *cond = (house_cond_t *)c; cond->wait_head = cond->wait_tail = NULL; return 0; }
int pthread_cond_destroy(void *c) { (void)c; return 0; }

int pthread_cond_signal(void *c) {
    house_cond_t *cond = (house_cond_t *)c;
    house_sched_lock_acquire();
    if (cond->wait_head) {
        house_thread_t *w = cond->wait_head;
        cond->wait_head = w->wait_next;
        if (!cond->wait_head) cond->wait_tail = NULL;
        w->wait_next = NULL;
        enqueue_run(w);
    }
    house_sched_lock_release();
    return 0;
}

int pthread_cond_broadcast(void *c) {
    house_cond_t *cond = (house_cond_t *)c;
    house_sched_lock_acquire();
    while (cond->wait_head) {
        house_thread_t *w = cond->wait_head;
        cond->wait_head = w->wait_next;
        w->wait_next = NULL;
        enqueue_run(w);
    }
    cond->wait_tail = NULL;
    house_sched_lock_release();
    return 0;
}

int pthread_cond_wait(void *c, void *m) {
    house_cond_t *cond = (house_cond_t *)c;
    house_mutex_t *mu = (house_mutex_t *)m;
    house_sched_lock_acquire();
    // enqueue on cond
    house_thread_t *cur = house_current_thr;
    cur->state = HOUSE_THR_BLOCKED;
    cur->wait_next = NULL;
    if (cond->wait_tail) cond->wait_tail->wait_next = cur;
    else cond->wait_head = cur;
    cond->wait_tail = cur;
    // unlock mutex
    mu->locked = 0;
    mu->owner = NULL;
    if (mu->wait_head) {
        house_thread_t *w = mu->wait_head;
        mu->wait_head = w->wait_next;
        if (!mu->wait_head) mu->wait_tail = NULL;
        w->wait_next = NULL;
        enqueue_run(w);
    }
    house_thread_t *old = cur;
    house_thread_t *next = dequeue_run();
    if (!next) {
        // no runnable, idle
        house_sched_lock_release();
        // spin until woken? For now yield
        while (cur->state == HOUSE_THR_BLOCKED) {
            __asm__ volatile("wfi");
            // ISR may have woken cond waiter via signal
        }
        house_sched_lock_acquire();
        goto reacquire;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr = next;
    house_sched_lock_release();
    house_thread_switch(old, next);
    // resumed
    house_sched_lock_acquire();
reacquire:
    while (mu->locked) {
        cur = house_current_thr;
        cur->state = HOUSE_THR_BLOCKED;
        cur->wait_next = NULL;
        if (mu->wait_tail) mu->wait_tail->wait_next = cur;
        else mu->wait_head = cur;
        mu->wait_tail = cur;
        house_thread_t *old2 = cur;
        house_thread_t *n2 = dequeue_run();
        if (!n2) {
            house_sched_lock_release();
            __asm__ volatile("wfi");
            house_sched_lock_acquire();
            continue;
        }
        n2->state = HOUSE_THR_RUNNING;
        house_current_thr = n2;
        house_sched_lock_release();
        house_thread_switch(old2, n2);
        house_sched_lock_acquire();
    }
    mu->locked = 1;
    mu->owner = house_current_thr;
    house_sched_lock_release();
    return 0;
}

int pthread_cond_timedwait(void *c, void *m, const struct timespec *t) {
    if (!t) return pthread_cond_wait(c, m);
    uint64_t now = house_uptime_ns();
    uint64_t abs_ns = (uint64_t)t->tv_sec * 1000000000ULL + (uint64_t)t->tv_nsec;
    // CLOCK_MONOTONIC is based on uptime, CLOCK_REALTIME adds epoch
    // The RTS uses CLOCK_MONOTONIC for timedwait (set via pthread_condattr_setclock)
    // We'll treat t as monotonic first, but if it looks like realtime (large secs), adjust
    if (t->tv_sec > 1000000000) {
        // likely realtime, subtract epoch
        extern uint64_t house_uptime_ns(void);
        // FAKE_EPOCH is 1785000000, so realtime = uptime + epoch
        if (abs_ns >= 1785000000ULL * 1000000000ULL) abs_ns -= 1785000000ULL * 1000000000ULL;
    }
    if (abs_ns <= now) return ETIMEDOUT;
    house_cond_t *cond = (house_cond_t *)c;
    house_mutex_t *mu = (house_mutex_t *)m;
    house_sched_lock_acquire();
    house_thread_t *cur = house_current_thr;
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
        enqueue_run(w);
    }
    house_thread_t *old = cur;
    house_thread_t *next = dequeue_run();
    if (!next) {
        house_sched_lock_release();
        // no runnable, wait until timeout or signal
        while (cur->state == HOUSE_THR_BLOCKED) {
            uint64_t now2 = house_uptime_ns();
            if (now2 >= abs_ns) {
                house_sched_lock_acquire();
                // remove from cond queue if still there
                house_thread_t *prev = NULL;
                house_thread_t *it = cond->wait_head;
                while (it) {
                    if (it == cur) {
                        if (prev) prev->wait_next = it->wait_next;
                        else cond->wait_head = it->wait_next;
                        if (cond->wait_tail == it) cond->wait_tail = prev;
                        it->wait_next = NULL;
                        it->state = HOUSE_THR_RUNNABLE;
                        break;
                    }
                    prev = it;
                    it = it->wait_next;
                }
                if (cur->state == HOUSE_THR_BLOCKED) {
                    cur->state = HOUSE_THR_RUNNABLE;
                    cur->wake_ns = 0;
                }
                house_sched_lock_release();
                goto timed_reacquire;
            }
            __asm__ volatile("wfi");
        }
        house_sched_lock_acquire();
        goto timed_reacquire;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr = next;
    house_sched_lock_release();
    house_thread_switch(old, next);
    house_sched_lock_acquire();
    // check if we were woken by signal or timeout
    uint64_t now3 = house_uptime_ns();
    if (now3 >= abs_ns && cur->wake_ns != 0) {
        // timeout; ensure removed from cond if still queued
        // cur already dequeued via signal path? If we are here, we were signaled or timeout poll woke us
        // For simplicity, treat as timeout if time exceeded and we weren't signaled via enqueue
        // But enqueue happens on signal; if we timed out, we would have been woken via timeout check elsewhere
    }
    cur->wake_ns = 0;
    // fall through to reacquire mutex
timed_reacquire:
    while (mu->locked) {
        cur = house_current_thr;
        cur->state = HOUSE_THR_BLOCKED;
        cur->wait_next = NULL;
        if (mu->wait_tail) mu->wait_tail->wait_next = cur;
        else mu->wait_head = cur;
        mu->wait_tail = cur;
        house_thread_t *old2 = cur;
        house_thread_t *n2 = dequeue_run();
        if (!n2) {
            house_sched_lock_release();
            __asm__ volatile("wfi");
            house_sched_lock_acquire();
            continue;
        }
        n2->state = HOUSE_THR_RUNNING;
        house_current_thr = n2;
        house_sched_lock_release();
        house_thread_switch(old2, n2);
        house_sched_lock_acquire();
    }
    mu->locked = 1;
    mu->owner = house_current_thr;
    int ret = 0;
    if (house_uptime_ns() >= abs_ns) {
        // check if we returned due to timeout without signal
        // If we were signaled, cond would have removed us and enqueued; timeout case we re-added
        // Heuristic: if time exceeded, return ETIMEDOUT
        // But if signal arrived just before timeout, we should return 0.
        // We cannot distinguish perfectly; use time.
        // Only return ETIMEDOUT if we weren't signaled recently? For now check if we are still in cond? 
        // Simplify: if now >= abs_ns, report timeout
        ret = ETIMEDOUT;
    }
    house_sched_lock_release();
    return ret;
}

int pthread_condattr_init(void *a) { (void)a; return 0; }
int pthread_condattr_destroy(void *a) { (void)a; return 0; }
int pthread_condattr_setclock(void *a, int clk) { (void)a; (void)clk; return 0; }

int pthread_attr_init(void *a) { (void)a; return 0; }
int pthread_attr_destroy(void *a) { (void)a; return 0; }
int pthread_attr_getstacksize(void *a, size_t *s) { (void)a; *s = HOUSE_THREAD_STACK_BYTES; return 0; }

unsigned long pthread_self(void) {
    if (!house_current_thr) return 1;
    return (unsigned long)house_current_thr->tid;
}

int pthread_join(unsigned long t, void **r) {
    house_thread_t *target = NULL;
    for (int i = 0; i < HOUSE_MAX_THREADS; i++) {
        if (threads[i].tid == (int)t && threads[i].state != HOUSE_THR_UNUSED) { target = &threads[i]; break; }
    }
    if (!target) return 3; // ESRCH
    if (target->detached) return EINVAL;
    while (!target->exited) {
        house_sched_lock_acquire();
        if (target->exited) { house_sched_lock_release(); break; }
        house_thread_t *cur = house_current_thr;
        cur->state = HOUSE_THR_BLOCKED;
        target->joiner = cur;
        house_thread_t *old = cur;
        house_thread_t *next = dequeue_run();
        if (!next) { house_sched_lock_release(); __asm__ volatile("wfi"); house_sched_lock_acquire(); continue; }
        next->state = HOUSE_THR_RUNNING;
        house_current_thr = next;
        house_sched_lock_release();
        house_thread_switch(old, next);
        house_sched_lock_acquire();
        house_sched_lock_release();
    }
    if (r) *r = target->retval;
    // free resources
    house_sched_lock_acquire();
    if (target->stack_base) free(target->stack_base);
    if (target->tcb) free(target->tcb);
    target->state = HOUSE_THR_UNUSED;
    target->tid = 0;
    house_sched_lock_release();
    return 0;
}

int pthread_detach(unsigned long t) {
    for (int i = 0; i < HOUSE_MAX_THREADS; i++) {
        if (threads[i].tid == (int)t) { threads[i].detached = 1; if (threads[i].exited && threads[i].state != HOUSE_THR_UNUSED) { if (threads[i].stack_base) free(threads[i].stack_base); if (threads[i].tcb) free(threads[i].tcb); threads[i].state = HOUSE_THR_UNUSED; } return 0; }
    }
    return 0;
}

__attribute__((noreturn)) void pthread_exit(void *r) {
    house_thread_t *cur = house_current_thr;
    cur->retval = r;
    cur->exited = 1;
    cur->state = HOUSE_THR_EXITED;
    if (cur->joiner) {
        enqueue_run(cur->joiner);
        cur->joiner = NULL;
    }
    if (cur->detached) {
        if (cur->stack_base) free(cur->stack_base);
        if (cur->tcb) free(cur->tcb);
        cur->state = HOUSE_THR_UNUSED;
    }
    house_thread_t *next = dequeue_run();
    if (!next) {
        // no more threads, halt
        for (;;) __asm__ volatile("wfi");
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr = next;
    house_thread_t *old = cur;
    // switch, never returns
    house_thread_switch(old, next);
    for (;;) __asm__ volatile("wfi");
}

int pthread_kill(unsigned long t, int s) { (void)t; return raise(s); }
int pthread_setname_np(unsigned long t, const char *n) { (void)t; (void)n; return 0; }

int pthread_create(unsigned long *thr, const void *a, void *(*fn)(void *), void *arg) {
    (void)a;
    house_sched_lock_acquire();
    house_thread_t *t = alloc_thread();
    if (!t) { house_sched_lock_release(); return EAGAIN; }
    void *stack = malloc(HOUSE_THREAD_STACK_BYTES);
    if (!stack) { t->state = HOUSE_THR_UNUSED; house_sched_lock_release(); return ENOMEM; }
    void *tcb = house_tls_alloc();
    if (!tcb) { free(stack); t->state = HOUSE_THR_UNUSED; house_sched_lock_release(); return ENOMEM; }
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
    memset(&t->sigmask, 0, sizeof(t->sigmask));
    // setup initial stack frame
    uintptr_t top = (uintptr_t)stack + HOUSE_THREAD_STACK_BYTES;
    top &= ~15ULL;
    // reserve space for switch frame (160 bytes)
    top -= 160;
    uint64_t *sp = (uint64_t *)top;
    // layout as switch expects: d14,d15,d12,d13,d10,d11,d8,d9,x29,x30,x27,x28,x25,x26,x23,x24,x21,x22,x19,x20
    for (int i = 0; i < 20; i++) sp[i] = 0;
    sp[9] = (uint64_t)house_thread_trampoline;
    t->sp = (void *)sp;
    t->next = NULL;
    t->wait_next = NULL;
    t->joiner = NULL;
    t->state = HOUSE_THR_RUNNABLE;
    enqueue_run(t);
    *thr = (unsigned long)t->tid;
    house_sched_lock_release();
    return 0;
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old) {
    house_thread_t *cur = house_current_thr;
    if (!cur) {
        // fallback to global
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
        *(unsigned long *)mask = 1UL;
        if (sz > sizeof(unsigned long)) memset((char *)mask + sizeof(unsigned long), 0, sz - sizeof(unsigned long));
    }
    return 0;
}

int nanosleep(const struct timespec *rq, struct timespec *rm) {
    if (!rq) return 0;
    uint64_t ns = (uint64_t)rq->tv_sec * 1000000000ULL + (uint64_t)rq->tv_nsec;
    if (ns == 0) {
        house_sched_yield();
        return 0;
    }
    uint64_t until = house_uptime_ns() + ns;
    house_sched_lock_acquire();
    house_thread_t *cur = house_current_thr;
    if (!cur) { house_sched_lock_release(); house_sched_yield(); return 0; }
    cur->wake_ns = until;
    cur->state = HOUSE_THR_BLOCKED;
    // put on sleep list? reuse wait queue via simple polling in yield
    // For now, just block and have poll/yield check timeouts
    house_thread_t *old = cur;
    house_thread_t *next = dequeue_run();
    if (!next) {
        // no other runnable, wait until timeout
        house_sched_lock_release();
        while (house_uptime_ns() < until) {
            __asm__ volatile("wfi");
            // check if woken early? nanosleep not interruptible in our simple model
        }
        house_sched_lock_acquire();
        cur->wake_ns = 0;
        cur->state = HOUSE_THR_RUNNING;
        house_current_thr = cur;
        house_sched_lock_release();
        return 0;
    }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr = next;
    house_sched_lock_release();
    house_thread_switch(old, next);
    // when resumed, check if we slept enough; if not, loop
    while (house_uptime_ns() < until) {
        // if we were woken early, sleep again
        uint64_t rem = until - house_uptime_ns();
        struct timespec tmp = { .tv_sec = rem / 1000000000ULL, .tv_nsec = rem % 1000000000ULL };
        return nanosleep(&tmp, rm);
    }
    if (rm) { rm->tv_sec = 0; rm->tv_nsec = 0; }
    return 0;
}

// poll shim with yielding
struct pollfd {
    int fd;
    short events;
    short revents;
};
extern int house_timerfd_due(int fd);
extern int house_fd_pipe_readable(int fd);
int poll(struct pollfd *fds, unsigned long nfds, int timeout) {
    unsigned long i;
    // first quick check
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
    // nothing ready, yield
    // if timeout <0, wait indefinitely; if >0, we could timed wait
    // simple: yield once, then recheck
    // If we are in thr mode, blocking poll should not busy-spin, so we block.
    // Check if there are other runnable threads; if yes, yield.
    // If not, wfi until timer tick.
    if (run_head) {
        house_sched_yield();
    } else {
        // no other thread, wfi until timer tick makes fd ready
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
    // after yield, recheck
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
    // block indefinitely until signal
    house_sched_lock_acquire();
    house_thread_t *cur = house_current_thr;
    cur->state = HOUSE_THR_BLOCKED;
    house_thread_t *old = cur;
    house_thread_t *next = dequeue_run();
    if (!next) { house_sched_lock_release(); for (;;) __asm__ volatile("wfi"); }
    next->state = HOUSE_THR_RUNNING;
    house_current_thr = next;
    house_sched_lock_release();
    house_thread_switch(old, next);
    return -1;
}
