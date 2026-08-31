#pragma once
#include <stdint.h>

#define HOUSE_MAX_SMP 8
#define SGI_IPI 0

/* GICv3 + timer + IRQ ring API. */

void house_gic_init(void);
void house_gic_init_secondary(uint32_t core);
void house_gic_enable_int(uint32_t intid);
void house_gic_disable_int(uint32_t intid);
void house_gic_eoi(uint32_t intid_raw); /* raw IAR value */
void house_gic_send_sgi(uint32_t sgi_id, uint32_t aff0_mask);
void house_gic_enable_sgi(uint32_t id);

void house_timer_init(void);
void house_timer_init_secondary(uint32_t core);
uint64_t house_uptime_secs(void);
extern volatile int house_isr_active;
extern volatile uint64_t house_isr_pending[HOUSE_MAX_SMP];
extern uint32_t house_timer_interval;

void house_irq_init(void);

/* SPSC ring (single producer in IRQ, single consumer Haskell dispatcher). */
void house_irq_push(uint32_t intid);
int house_irq_pop(void); /* -1 if empty */
int house_irq_pipe_fd(void);
void house_irq_pipe_drain(void); /* consume wake-token bytes so pipe can empty */
int house_irq_pipe_readable(int fd); /* for poll shim */

/* I-bit */
void house_irq_enable(void);
void house_irq_disable(void);
