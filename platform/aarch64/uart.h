#ifndef HOUSE_AARCH64_UART_H
#define HOUSE_AARCH64_UART_H

void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
int uart_getc_blocking(void);
int uart_getc_nonblock(void);

#endif
