#pragma once
#include <stddef.h>
#include <stdint.h>
#include <signal.h>
#include <sys/types.h>

#define HOUSE_THREAD_STACK_BYTES (256UL * 1024UL)
#define HOUSE_MAX_THREADS 64

typedef struct house_thread house_thread_t;

struct house_thread {
    void *sp;
    uint64_t tpidr;
    int tid;
    int state;
    void *(*start)(void *);
    void *arg;
    void *retval;
    int detached;
    int exited;
    house_thread_t *next;
    house_thread_t *wait_next;
    house_thread_t *joiner;
    void *stack_base;
    size_t stack_size;
    void *tcb;
    sigset_t sigmask;
    int errno_val;
    uint64_t wake_ns;
};

enum { HOUSE_THR_UNUSED = 0, HOUSE_THR_RUNNABLE = 1, HOUSE_THR_RUNNING = 2, HOUSE_THR_BLOCKED = 3, HOUSE_THR_EXITED = 4 };

typedef struct {
    int locked;
    house_thread_t *owner;
    house_thread_t *wait_head;
    house_thread_t *wait_tail;
} house_mutex_t;

typedef struct {
    house_thread_t *wait_head;
    house_thread_t *wait_tail;
} house_cond_t;

void house_threads_init(void);
void house_thread_init_main(void);
house_thread_t *house_thread_current(void);
void house_sched_lock_acquire(void);
void house_sched_lock_release(void);
void house_sched_yield(void);
void house_sched_block(void);
void house_sched_wake(house_thread_t *thr);
void house_thread_switch(house_thread_t *old_thr, house_thread_t *new_thr);
void house_sched_maybe_preempt_from_isr(void);

extern volatile int house_sched_lock;
extern volatile int house_sched_deferred;
extern int house_thr_mode;

void house_tls_init_main(void);
void *house_tls_alloc(void);
