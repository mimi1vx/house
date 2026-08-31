#include "../uart.h"

void c_print(const char *s) {
    while (*s) uart_putc(*s++);
}
