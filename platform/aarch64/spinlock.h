#pragma once
#include <stdint.h>

typedef struct { volatile uint32_t v; } house_spinlock_t;

static inline void house_spin_init(house_spinlock_t *l) { l->v = 0; }

static inline void house_spin_lock(house_spinlock_t *l) {
    uint32_t tmp, res;
    __asm__ volatile(
        "1: ldaxr %w0, [%2]\n"
        "   cbnz %w0, 1b\n"
        "   mov %w1, #1\n"
        "   stxr %w0, %w1, [%2]\n"
        "   cbnz %w0, 1b\n"
        "   dmb sy\n"
        : "=&r"(res), "=&r"(tmp)
        : "r"(&l->v)
        : "memory");
}

static inline int house_spin_trylock(house_spinlock_t *l) {
    uint32_t tmp, res;
    __asm__ volatile(
        "   ldaxr %w0, [%2]\n"
        "   cbnz %w0, 1f\n"
        "   mov %w1, #1\n"
        "   stxr %w0, %w1, [%2]\n"
        "   cbnz %w0, 1f\n"
        "   dmb sy\n"
        "   mov %w0, #0\n"
        "   b 2f\n"
        "1: mov %w0, #1\n"
        "2:\n"
        : "=&r"(res), "=&r"(tmp)
        : "r"(&l->v)
        : "memory");
    return res == 0 ? 0 : 1;
}

static inline void house_spin_unlock(house_spinlock_t *l) {
    __asm__ volatile(
        "dmb sy\n"
        "stlr wzr, [%0]\n"
        "dmb sy\n"
        :: "r"(&l->v) : "memory");
}
