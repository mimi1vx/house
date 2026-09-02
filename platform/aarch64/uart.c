#include <stdint.h>
#include "uart.h"
#include "spinlock.h"

#define UART_BASE 0x09000000UL
static house_spinlock_t uart_lock = {0};
#define FR_TXFF   (1u << 5)
#define FR_RXFE   (1u << 4)

/* MMIO helpers that avoid ST* with writeback / LDP / SIMD — HVF needs ISV=1 */
static inline void mmio_w32_u(uint64_t a, uint32_t v) {
    __asm__ volatile("str %w0, [%1]" :: "r"(v), "r"(a) : "memory");
}
static inline uint32_t mmio_r32_u(uint64_t a) {
    uint32_t v;
    __asm__ volatile("ldr %w0, [%1]" : "=r"(v) : "r"(a) : "memory");
    return v;
}

void uart_init(void)
{
    mmio_w32_u(UART_BASE + 0x030, 0);
    __asm__ volatile("" ::: "memory");
    mmio_w32_u(UART_BASE + 0x044, 0x7ff);
    __asm__ volatile("" ::: "memory");
    mmio_w32_u(UART_BASE + 0x024, 13);                  /* 24MHz clk -> 115200 baud */
    __asm__ volatile("" ::: "memory");
    mmio_w32_u(UART_BASE + 0x028, 1);
    __asm__ volatile("" ::: "memory");
    mmio_w32_u(UART_BASE + 0x02c, (3u << 5) | (1u << 4));
    __asm__ volatile("" ::: "memory");
    mmio_w32_u(UART_BASE + 0x030, (1u << 9) | (1u << 8) | 1u);
    __asm__ volatile("" ::: "memory");
}

void uart_putc(char c)
{
    house_spin_lock(&uart_lock);
    if (c == '\n') {
        while (mmio_r32_u(UART_BASE + 0x018) & FR_TXFF) __asm__ volatile("" ::: "memory");
        mmio_w32_u(UART_BASE + 0x000, '\r');
    }
    while (mmio_r32_u(UART_BASE + 0x018) & FR_TXFF) __asm__ volatile("" ::: "memory");
    mmio_w32_u(UART_BASE + 0x000, (uint8_t)c);
    house_spin_unlock(&uart_lock);
}

void uart_puts(const char *s)
{
    house_spin_lock(&uart_lock);
    while (*s) {
        char c = *s++;
        if (c == '\n') {
            while (mmio_r32_u(UART_BASE + 0x018) & FR_TXFF) __asm__ volatile("" ::: "memory");
            mmio_w32_u(UART_BASE + 0x000, '\r');
        }
        while (mmio_r32_u(UART_BASE + 0x018) & FR_TXFF) __asm__ volatile("" ::: "memory");
        mmio_w32_u(UART_BASE + 0x000, (uint8_t)c);
    }
    house_spin_unlock(&uart_lock);
}

int uart_getc_blocking(void)
{
    while (mmio_r32_u(UART_BASE + 0x018) & FR_RXFE) __asm__ volatile("" ::: "memory");
    return (int)(mmio_r32_u(UART_BASE + 0x000) & 0xff);
}

int uart_getc_nonblock(void)
{
    if (mmio_r32_u(UART_BASE + 0x018) & FR_RXFE)
        return -1;
    return (int)(mmio_r32_u(UART_BASE + 0x000) & 0xff);
}
