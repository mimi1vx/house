#ifndef HOUSE_TICK_H
#define HOUSE_TICK_H

#include <stdint.h>

/* Replay of the recorded RTS SIGVTALRM handler (see tinylibc/sys.c). */
void house_rts_tick(void);

uint64_t house_uptime_ns(void);

#endif
