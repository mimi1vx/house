#include <stddef.h>
#include <stdint.h>
#include "threads.h"

void *malloc(size_t n);
void *memset(void *dst, int c, size_t n);

// TLS TCB + static TLS block (my_task = 8 bytes at offset 16)
void *house_tls_alloc(void);

void house_tls_init_main(void) {
    // alias for threads init main
    house_thread_init_main();
}
