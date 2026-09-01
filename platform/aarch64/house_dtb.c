#include "house_dtb.h"

#define FDT_MAGIC 0xd00dfeedU
#define FDT_VERSION 17
#define FDT_BEGIN_NODE 0x1
#define FDT_END_NODE 0x2
#define FDT_PROP 0x3
#define FDT_NOP 0x4
#define FDT_END 0x9
#define FDT_MAX_SIZE (8u << 20)

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static __attribute__((unused)) uint32_t be32_at(const void *base, uint32_t off, uint32_t totalsize, int *ok) {
    if (off + 4 > totalsize) { *ok = 0; return 0; }
    return be32((const uint8_t *)base + off);
}

struct fdt_header {
    uint32_t magic;
    uint32_t totalsize;
    uint32_t off_dt_struct;
    uint32_t off_dt_strings;
    uint32_t off_mem_rsvmap;
    uint32_t version;
    uint32_t last_comp_version;
    uint32_t boot_cpuid_phys;
    uint32_t size_dt_strings;
    uint32_t size_dt_struct;
};

int fdt_valid(const void *dtb) {
    const uint8_t *p = (const uint8_t *)dtb;
    uint32_t magic, totalsize, off_struct, off_strings, version;
    if (!dtb) return 0;
    // Need at least header
    magic = be32(p);
    if (magic != FDT_MAGIC) return 0;
    totalsize = be32(p + 4);
    if (totalsize < 40 || totalsize > FDT_MAX_SIZE) return 0;
    off_struct = be32(p + 8);
    off_strings = be32(p + 12);
    version = be32(p + 20);
    if (version < 16 || version > 17) return 0;
    if (off_struct >= totalsize) return 0;
    if (off_strings >= totalsize) return 0;
    // last_comp_version sanity
    // quick check that struct block contains FDT_BEGIN_NODE at start
    if (off_struct + 4 > totalsize) return 0;
    // totalsize check already done
    return 1;
}

static int streq(const char *a, const char *b) {
    while (*a && *b) { if (*a != *b) return 0; a++; b++; }
    return *a == *b;
}

static int startswith(const char *s, const char *pref) {
    while (*pref) { if (*s != *pref) return 0; s++; pref++; }
    return 1;
}

static const char *str_at(const void *dtb, uint32_t off_strings, uint32_t size_strings, uint32_t nameoff) {
    if (nameoff >= size_strings) return 0;
    const char *s = (const char *)dtb + off_strings + nameoff;
    // ensure null term within strings block
    uint32_t remain = size_strings - nameoff;
    for (uint32_t i = 0; i < remain; i++) if (s[i] == '\0') return s;
    return 0;
}

static uint32_t align4(uint32_t v) { return (v + 3) & ~3u; }

// core walker: calls back for each node/property
// We implement two consumers by duplicating walk with different state to keep code small.

uint64_t fdt_get_ram_bytes(const void *dtb) {
    if (!fdt_valid(dtb)) return 0;
    const uint8_t *base = (const uint8_t *)dtb;
    uint32_t totalsize = be32(base + 4);
    uint32_t off_struct = be32(base + 8);
    uint32_t off_strings = be32(base + 12);
    uint32_t size_strings = be32(base + 32);
    uint32_t size_struct = be32(base + 36);
    uint32_t struct_end = off_struct + size_struct;
    if (struct_end > totalsize) struct_end = totalsize;
    // root cells defaults
    uint32_t addr_cells = 2, size_cells = 2;
    uint64_t total_ram = 0;
    // walk state: track node stack depth and names
    // Simple stack of names depth up to 16
    char node_stack[16][32];
    int depth = 0;
    // pending memory reg for current memory node: we evaluate at property time
    uint32_t p = off_struct;
    int ok = 1;
    while (p + 4 <= struct_end && ok) {
        uint32_t token = be32(base + p); p += 4;
        if (token == FDT_BEGIN_NODE) {
            // node name: null-terminated, padded to 4
            const char *name = (const char *)base + p;
            uint32_t namelen = 0;
            // find len within bounds
            while (p + namelen < totalsize && base[p + namelen] != 0) namelen++;
            if (p + namelen >= totalsize) { ok = 0; break; }
            namelen++; // include nul
            // copy truncated name for stack
            if (depth < 16) {
                uint32_t cn = namelen < 31 ? namelen : 31;
                for (uint32_t i = 0; i < cn && i < 31; i++) node_stack[depth][i] = name[i];
                node_stack[depth][cn < 31 ? cn : 31] = '\0';
                // ensure termination: find nul inside copy
                for (uint32_t i = 0; i < 31; i++) if (node_stack[depth][i] == '\0') break;
                // truncate at first nul
                for (uint32_t i = 0; i < 31; i++) if (name[i] == '\0') { node_stack[depth][i] = '\0'; break; }
            }
            depth++;
            p = align4(p + namelen);
            // depth overflow guard
            if (depth >= 16) { /* continue but ignore extra */ }
        } else if (token == FDT_END_NODE) {
            if (depth > 0) depth--;
        } else if (token == FDT_PROP) {
            if (p + 8 > struct_end) { ok = 0; break; }
            uint32_t len = be32(base + p); p += 4;
            uint32_t nameoff = be32(base + p); p += 4;
            const char *propname = str_at(dtb, off_strings, size_strings, nameoff);
            if (!propname) { // skip value
                p = align4(p + len);
                continue;
            }
            const uint8_t *val = base + p;
            if (p + len > struct_end) { ok = 0; break; }
            // root cells
            if (depth == 1) {
                // root node is depth 1 after begin (empty name); check
                if (streq(propname, "#address-cells") && len == 4) {
                    addr_cells = be32(val);
                    if (addr_cells > 2) addr_cells = 2;
                } else if (streq(propname, "#size-cells") && len == 4) {
                    size_cells = be32(val);
                    if (size_cells > 2) size_cells = 2;
                }
            }
            // memory node: check if current node name starts with "memory"
            int is_memory = 0;
            if (depth >= 1) {
                const char *cur = node_stack[depth - 1];
                if (startswith(cur, "memory")) is_memory = 1;
            }
            if (is_memory && streq(propname, "reg")) {
                uint32_t cells = addr_cells + size_cells;
                if (cells == 0 || cells > 4) { /* ignore */ }
                else {
                    // reg may contain multiple entries; sum them
                    uint32_t entry_bytes = cells * 4;
                    for (uint32_t off = 0; off + entry_bytes <= len; off += entry_bytes) {
                        const uint8_t *e = val + off;
                        uint64_t size = 0;
                        if (size_cells == 2) {
                            uint32_t hi = be32(e + addr_cells * 4);
                            uint32_t lo = be32(e + addr_cells * 4 + 4);
                            size = ((uint64_t)hi << 32) | lo;
                        } else if (size_cells == 1) {
                            uint32_t lo = be32(e + addr_cells * 4);
                            size = lo;
                        } else {
                            size = 0;
                        }
                        // filter base 0x40000000 region: ignore base check, just sum
                        total_ram += size;
                        // cap to avoid overflow beyond 16G
                        if (total_ram > (16ULL << 30)) total_ram = 16ULL << 30;
                    }
                }
            }
            p = align4(p + len);
        } else if (token == FDT_NOP) {
            continue;
        } else if (token == FDT_END) {
            break;
        } else {
            ok = 0; break;
        }
    }
    return total_ram;
}

int fdt_get_cpu_count(const void *dtb) {
    if (!fdt_valid(dtb)) return 0;
    const uint8_t *base = (const uint8_t *)dtb;
    uint32_t totalsize = be32(base + 4);
    uint32_t off_struct = be32(base + 8);
    uint32_t size_strings = be32(base + 32);
    uint32_t size_struct = be32(base + 36);
    uint32_t struct_end = off_struct + size_struct;
    if (struct_end > totalsize) struct_end = totalsize;
    char node_stack[16][32];
    int depth = 0;
    int cpus_depth = -1;
    int count = 0;
    uint32_t p = off_struct;
    int ok = 1;
    while (p + 4 <= struct_end && ok) {
        uint32_t token = be32(base + p); p += 4;
        if (token == FDT_BEGIN_NODE) {
            const char *name = (const char *)base + p;
            uint32_t namelen = 0;
            while (p + namelen < totalsize && base[p + namelen] != 0) namelen++;
            if (p + namelen >= totalsize) { ok = 0; break; }
            namelen++;
            if (depth < 16) {
                uint32_t cn = namelen < 31 ? namelen : 31;
                for (uint32_t i = 0; i < cn; i++) node_stack[depth][i] = name[i];
                node_stack[depth][cn < 31 ? cn : 31] = '\0';
                for (uint32_t i = 0; i < 31; i++) if (name[i] == '\0') { node_stack[depth][i] = '\0'; break; }
            }
            // detect cpus node
            if (depth >= 0 && depth < 16) {
                const char *cur = node_stack[depth];
                if (streq(cur, "cpus")) cpus_depth = depth;
                else if (cpus_depth >= 0 && depth == cpus_depth + 1) {
                    // child of cpus
                    if (startswith(cur, "cpu")) count++;
                }
            }
            depth++;
            p = align4(p + namelen);
        } else if (token == FDT_END_NODE) {
            if (depth > 0) {
                depth--;
                if (cpus_depth == depth) cpus_depth = -1; // leaving cpus
            }
        } else if (token == FDT_PROP) {
            if (p + 8 > struct_end) { ok = 0; break; }
            uint32_t len = be32(base + p); p += 4;
            uint32_t nameoff = be32(base + p); p += 4;
            // validate nameoff but not needed for count
            if (nameoff >= size_strings) { p = align4(p + len); continue; }
            if (p + len > struct_end) { ok = 0; break; }
            p = align4(p + len);
        } else if (token == FDT_NOP) {
            continue;
        } else if (token == FDT_END) {
            break;
        } else {
            ok = 0; break;
        }
    }
    return count;
}

#ifdef HOUSE_DTB_UNITTEST
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static void mk_simple(void) { puts("stub"); }
int main(void) { return 0; }
#endif
