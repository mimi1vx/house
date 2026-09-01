#include "house_detect.h"
#include <stdint.h>

// Minimal probe stub: will be replaced by fault-trapped scan in Step 4.
// Returns 0 to indicate no probe result, falling back to DTB/compile-time.
uint64_t house_ram_probe(void) {
    return 0;
}
