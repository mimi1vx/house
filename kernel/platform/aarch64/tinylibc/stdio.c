/* Minimal printf family for RTS belch()/error paths. Everything writes to
   the PL011 UART via write(2); FILE* arguments are dummy handles because
   stdout/stderr both land on the same serial line anyway. */

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

static char file_objs[3][256] __attribute__((aligned(16)));
FILE *stdin = (FILE *)file_objs[0];
FILE *stdout = (FILE *)file_objs[1];
FILE *stderr = (FILE *)file_objs[2];

struct sink {
    void *buf;                  /* char* cursor when buffering */
    size_t cap;
    size_t n;
    int to_uart;
};

void uart_putc(char c);

static void uart_putc_fast(char c)
{
    static char line[128];
    static size_t len;
    line[len++] = c;
    if (c == '\n' || len == sizeof line) {
        ssize_t w = write(2, line, len);
        (void)w;
        len = 0;
    }
}

static void emit_char(struct sink *k, char c)
{
    if (k->to_uart) {
        uart_putc_fast(c);
        k->n++;
    } else if (k->n < k->cap - 1) {
        ((char *)k->buf)[k->n++] = c;
    }
}

static void emit_num(struct sink *k, unsigned long long v, unsigned base,
                     int neg, int width, int zero_pad)
{
    char tmp[24];
    const char *digits = "0123456789abcdef";
    int i = 0, total;
    char sign = 0;

    if (neg)
        sign = '-';
    do {
        tmp[i++] = digits[v % base];
        v /= base;
    } while (v);
    total = i + (sign ? 1 : 0);
    while (total < width) {
        emit_char(k, zero_pad ? '0' : ' ');
        total++;
    }
    if (sign)
        emit_char(k, sign);
    while (i--)
        emit_char(k, tmp[i]);
}

static int vsfmt(struct sink *k, const char *f, va_list ap)
{
    for (; *f; f++) {
        int width = 0, zero_pad = 0;
        int lcount = 0, zmod = 0;
        char c = *f;

        if (c != '%') {
            emit_char(k, c);
            continue;
        }
        f++;
        if (*f == '%') {
            emit_char(k, '%');
            continue;
        }
        if (*f == '-') f++;     /* left-align accepted, ignored */
        if (*f == '0') {
            zero_pad = 1;
            f++;
        }
        while (*f >= '0' && *f <= '9')
            width = width * 10 + (*f++ - '0');
        if (*f == '.') {        /* precision: only strings use it */
            f++;
            while (*f >= '0' && *f <= '9')
                f++;
        }
        while (*f == 'l') { lcount++; f++; }
        if (*f == 'z') { zmod = 1; f++; }
        else if (*f == 'h') { f++; }
        switch (*f) {
        case 'd':
        case 'i': {
            long long v = lcount == 2 ? va_arg(ap, long long)
                        : lcount == 1 ? va_arg(ap, long)
                        : zmod        ? va_arg(ap, ssize_t)
                                      : va_arg(ap, int);
            emit_num(k, v < 0 ? -(unsigned long long)v : (unsigned long long)v,
                     10, v < 0, width, zero_pad);
            break;
        }
        case 'u':
        case 'o':
        case 'x':
        case 'X': {
            unsigned long long v =
                lcount == 2 ? va_arg(ap, unsigned long long)
                : lcount == 1 ? va_arg(ap, unsigned long)
                : zmod        ? va_arg(ap, size_t)
                              : va_arg(ap, unsigned int);
            unsigned base = *f == 'u' ? 10 : *f == 'o' ? 8 : 16;
            emit_num(k, v, base, 0, width, zero_pad);
            break;
        }
        case 'p': {
            unsigned long long v = (unsigned long long)(uintptr_t)
                va_arg(ap, void *);
            emit_char(k, '0');
            emit_char(k, 'x');
            emit_num(k, v, 16, 0, 0, 0);
            break;
        }
        case 'c':
            emit_char(k, (char)va_arg(ap, int));
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s)
                s = "(null)";
            while (*s)
                emit_char(k, *s++);
            break;
        }
        default:
            emit_char(k, '%');
            if (*f)
                emit_char(k, *f);
            break;
        }
    }
    return (int)k->n;
}

int vfprintf(FILE *f, const char *fmt, va_list ap)
{
    struct sink k;
    (void)f;
    k.to_uart = 1;
    k.n = 0;
    return vsfmt(&k, fmt, ap);
}

int fprintf(FILE *f, const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = vfprintf(f, fmt, ap);
    va_end(ap);
    return r;
}

int vprintf(const char *fmt, va_list ap)
{
    return vfprintf(stdout, fmt, ap);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = vprintf(fmt, ap);
    va_end(ap);
    return r;
}

int vsnprintf(char *buf, size_t n, const char *fmt, va_list ap)
{
    struct sink k;
    k.to_uart = 0;
    k.buf = buf;
    k.cap = n ? n : 1;
    k.n = 0;
    vsfmt(&k, fmt, ap);
    if (n)
        buf[k.n < n - 1 ? k.n : n - 1] = '\0';
    return (int)k.n;
}

int snprintf(char *buf, size_t n, const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return r;
}

int sprintf(char *buf, const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = vsnprintf(buf, (size_t)-1 >> 1, fmt, ap);
    va_end(ap);
    return r;
}

int puts(const char *s)
{
    struct sink k;
    k.to_uart = 1;
    k.n = 0;
    while (*s)
        emit_char(&k, *s++);
    emit_char(&k, '\n');
    return k.n;
}

int fputs(const char *s, FILE *f)
{
    struct sink k;
    (void)f;
    k.to_uart = 1;
    k.n = 0;
    while (*s)
        emit_char(&k, *s++);
    return 0;
}

int putchar(int c)
{
    uart_putc((char)c);
    return c;
}

int fputc(int c, FILE *f)
{
    (void)f;
    return putchar(c);
}

size_t fwrite(const void *p, size_t sz, size_t cnt, FILE *f)
{
    const char *b = p;
    size_t i;
    (void)f;
    for (i = 0; i < sz * cnt; i++)
        uart_putc(b[i]);
    return cnt;
}

int fflush(FILE *f)
{
    (void)f;
    return 0;
}
