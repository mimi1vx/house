#include <stdint.h>
#include "uart.h"
#include "spinlock.h"

#define UART_BASE 0x09000000UL
static house_spinlock_t uart_lock = {0};
#define DR        (*(volatile uint32_t *)(UART_BASE + 0x000))
#define FR        (*(volatile uint32_t *)(UART_BASE + 0x018))
#define IBRD      (*(volatile uint32_t *)(UART_BASE + 0x024))
#define FBRD      (*(volatile uint32_t *)(UART_BASE + 0x028))
#define LCR_H     (*(volatile uint32_t *)(UART_BASE + 0x02c))
#define CR        (*(volatile uint32_t *)(UART_BASE + 0x030))
#define ICR       (*(volatile uint32_t *)(UART_BASE + 0x044))
#define FR_TXFF   (1u << 5)
#define FR_RXFE   (1u << 4)

void uart_init(void)
{
    CR = 0;
    ICR = 0x7ff;
    IBRD = 13;                  /* 24MHz clk -> 115200 baud */
    FBRD = 1;
    LCR_H = (3u << 5) | (1u << 4);
    CR = (1u << 9) | (1u << 8) | 1u;
}

void uart_putc(char c)
{
    house_spin_lock(&uart_lock);
    if (c == '\n') {
        while (FR & FR_TXFF) ;
        DR = '\r';
    }
    while (FR & FR_TXFF) ;
    DR = (uint8_t)c;
    house_spin_unlock(&uart_lock);
}

void uart_puts(const char *s)
{
    house_spin_lock(&uart_lock);
    while (*s) {
        char c = *s++;
        if (c == '\n') {
            while (FR & FR_TXFF) ;
            DR = '\r';
        }
        while (FR & FR_TXFF) ;
        DR = (uint8_t)c;
    }
    house_spin_unlock(&uart_lock);
}

int uart_getc_blocking(void)
{
    while (FR & FR_RXFE) ;
    return (int)(DR & 0xff);
}

int uart_getc_nonblock(void)
{
    if (FR & FR_RXFE)
        return -1;
    return (int)(DR & 0xff);
}
