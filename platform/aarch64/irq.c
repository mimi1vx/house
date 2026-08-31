/* SPSC ring + pipe handoff for device IRQs.
   Producer: c_handle_irq (I-masked, single core) — lock-free.
   Consumer: Haskell dispatcher thread blocked in threadWaitRead on the
   pipe's read fd; drains ring via house_irq_pop. */

#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include "irq.h"
#include "uart.h"

#define RING_SZ 256
#define RING_MASK (RING_SZ - 1)

static volatile uint32_t ring_buf[RING_SZ];
static volatile uint32_t ring_head = 0;
static volatile uint32_t ring_tail = 0;

static int pipe_r = -1;
static int pipe_w = -1;

void house_irq_init(void) {
    house_gic_init();
    /* Create pipe before hs_init so dispatcher can find it via fd. */
    int fds[2];
    extern int pipe(int fds[2]);
    if (pipe(fds) == 0) {
        pipe_r = fds[0];
        pipe_w = fds[1];
        uart_puts("[house] irq: pipe r="); uart_putc('0' + (pipe_r % 10));
        uart_puts(" w="); uart_putc('0' + (pipe_w % 10)); uart_puts("\n");
    } else {
        uart_puts("[house] irq: pipe create failed\n");
    }
    house_timer_init();
    house_irq_enable(); /* unmask IRQ at CPU */
    uart_puts("[house] irq ok\n");
}

void house_sched_maybe_preempt_from_isr(void);
void house_irq_push(uint32_t intid) {
    uint32_t h = ring_head;
    uint32_t t = ring_tail;
    if ((h - t) >= RING_SZ) {
        /* ring full — drop oldest? For now drop newest. */
        return;
    }
    ring_buf[h & RING_MASK] = intid;
    __asm__ volatile("dmb ishst" ::: "memory");
    ring_head = h + 1;
    __asm__ volatile("dmb ish" ::: "memory");
    /* Wake dispatcher: one token byte. Avoid uart debug (write() temp prints
       in sys.c trigger on <=8 byte pipe writes — bypass via direct fdt manipulation
       by using write() but suppress? Write one byte; sys.c TEMP prints only for
       <=8 bytes with lr logging — still fires per IRQ (100Hz) and would spam.
       We already removed TEMP? Keep write; after step2 we will silence. */
    if (pipe_w >= 0) {
        char c = (char)intid;
        /* Use raw write; ignore EAGAIN/full (PIPE_CAP=1024, dispatcher keeps up). */
        extern ssize_t write(int fd, const void *buf, size_t n);
        write(pipe_w, &c, 1);
    }
}

int house_irq_pop(void) {
    uint32_t t = ring_tail;
    uint32_t h = ring_head;
    if (t == h) return -1;
    uint32_t v = ring_buf[t & RING_MASK];
    __asm__ volatile("dmb ishld" ::: "memory");
    ring_tail = t + 1;
    return (int)v;
}

int house_irq_pipe_fd(void) {
    return pipe_r;
}

/* Consume all pending wake-token bytes from the pipe read end. The ISR writes
   one byte per interrupt; the Haskell dispatcher calls this after threadWaitRead
   returns so the pipe empties and the next threadWaitRead blocks when idle
   (otherwise it stays readable and the dispatcher busy-loops, starving the
   scheduler). */
void house_irq_pipe_drain(void) {
    char buf[64];
    extern ssize_t read(int fd, void *buf, size_t n);
    if (pipe_r < 0) return;
    while (read(pipe_r, buf, sizeof buf) > 0) { }
}

/* For poll shim fallback — not needed if compat.c uses house_fd_pipe_readable
   directly, but expose for H.Interrupts to query readability without poll. */
int house_irq_pipe_readable(int fd) {
    extern int house_fd_pipe_readable(int fd);
    return house_fd_pipe_readable(fd);
}
