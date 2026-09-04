#![allow(unused_assignments)]
//! DTB parser — `house_dtb.c` transliteration (bounds-checked, 8M cap).

const FDT_MAGIC: u32 = 0xd00dfeed;
const FDT_MAX_SIZE: u32 = 8 << 20;

#[inline]
fn be32(p: *const u8) -> u32 {
    // SAFETY: caller guarantees p valid for 4 bytes.
    unsafe {
        ((*p as u32) << 24)
            | ((*p.add(1) as u32) << 16)
            | ((*p.add(2) as u32) << 8)
            | (*p.add(3) as u32)
    }
}

#[no_mangle]
pub unsafe extern "C" fn fdt_valid(dtb: *const u8) -> i32 {
    if dtb.is_null() {
        return 0;
    }
    // SAFETY: dtb checked non-null, need at least 40 bytes header; we probe via raw reads with bounds later.
    unsafe {
        let magic = be32(dtb);
        if magic != FDT_MAGIC {
            return 0;
        }
        let totalsize = be32(dtb.add(4));
        if totalsize < 40 || totalsize > FDT_MAX_SIZE {
            return 0;
        }
        let off_struct = be32(dtb.add(8));
        let off_strings = be32(dtb.add(12));
        let version = be32(dtb.add(20));
        if version < 16 || version > 17 {
            return 0;
        }
        if off_struct >= totalsize || off_strings >= totalsize {
            return 0;
        }
        if off_struct.checked_add(4).unwrap_or(u32::MAX) > totalsize {
            return 0;
        }
        1
    }
}

#[inline]
fn streq(a: *const u8, b: &[u8]) -> bool {
    // compare null-terminated a with b (b not nul)
    unsafe {
        for i in 0..b.len() {
            if *a.add(i) != b[i] {
                return false;
            }
        }
        *a.add(b.len()) == 0
    }
}

#[inline]
fn startswith(a: *const u8, pref: &[u8]) -> bool {
    unsafe {
        for i in 0..pref.len() {
            if *a.add(i) != pref[i] {
                return false;
            }
        }
        true
    }
}

#[inline]
fn align4(v: u32) -> u32 {
    (v + 3) & !3
}

/// uint64_t fdt_get_ram_bytes(const void *dtb) — sum of `reg` sizes for `memory` nodes.
#[no_mangle]
pub unsafe extern "C" fn fdt_get_ram_bytes(dtb: *const u8) -> u64 {
    if unsafe { fdt_valid(dtb) } == 0 {
        return 0;
    }
    unsafe {
        let base = dtb;
        let totalsize = be32(base.add(4));
        let off_struct = be32(base.add(8));
        let off_strings = be32(base.add(12));
        let size_strings = be32(base.add(32));
        let size_struct = be32(base.add(36));
        let mut struct_end = off_struct.checked_add(size_struct).unwrap_or(totalsize);
        if struct_end > totalsize {
            struct_end = totalsize;
        }
        let mut addr_cells: u32 = 2;
        let mut size_cells: u32 = 2;
        let mut total_ram: u64 = 0;
        // node stack depth up to 16, names up to 31 chars
        let mut stack_depth: i32 = 0;
        // store current memory flag per depth
        let mut is_memory_stack = [false; 16];
        // simple name buffer for current node
        let mut p = off_struct;
        let mut ok = true;
        while ok && p.checked_add(4).unwrap_or(u32::MAX) <= struct_end {
            let token = be32(base.add(p as usize));
            p = p.wrapping_add(4);
            if token == 0x1 {
                // BEGIN_NODE
                let name_ptr = base.add(p as usize) as *const u8;
                let mut namelen: u32 = 0;
                while p.checked_add(namelen).unwrap_or(u32::MAX) < totalsize
                    && *base.add((p + namelen) as usize) != 0
                {
                    namelen += 1;
                    if namelen > 64 {
                        break;
                    }
                }
                if p.checked_add(namelen).unwrap_or(u32::MAX) >= totalsize {
                    ok = false;
                    break;
                }
                namelen += 1; // include nul
                              // track memory node startswith "memory"
                let is_mem = if !name_ptr.is_null() {
                    // "memory" or "memory@..." — not "memory-controller" etc.
                    let n0 = *name_ptr;
                    let n1 = *name_ptr.add(1);
                    let n2 = *name_ptr.add(2);
                    let n3 = *name_ptr.add(3);
                    let n4 = *name_ptr.add(4);
                    let n5 = *name_ptr.add(5);
                    let n6 = *name_ptr.add(6);
                    n0 == b'm'
                        && n1 == b'e'
                        && n2 == b'm'
                        && n3 == b'o'
                        && n4 == b'r'
                        && n5 == b'y'
                        && (n6 == 0 || n6 == b'@')
                } else {
                    false
                };
                if stack_depth >= 0 && (stack_depth as usize) < 16 {
                    is_memory_stack[stack_depth as usize] = is_mem;
                }
                stack_depth += 1;
                if stack_depth > 16 {
                    stack_depth = 16;
                }
                p = align4(p.wrapping_add(namelen));
            } else if token == 0x2 {
                // END_NODE
                if stack_depth > 0 {
                    stack_depth -= 1;
                }
            } else if token == 0x3 {
                // PROP
                if p.checked_add(8).unwrap_or(u32::MAX) > struct_end {
                    ok = false;
                    break;
                }
                let len = be32(base.add(p as usize));
                p = p.wrapping_add(4);
                let nameoff = be32(base.add(p as usize));
                p = p.wrapping_add(4);
                let prop_ptr = base.add(p as usize);
                if p.checked_add(len).unwrap_or(u32::MAX) > struct_end {
                    ok = false;
                    break;
                }
                // root cells when depth==1 (root's direct children after root node)
                if stack_depth == 1 {
                    // need property name
                    if nameoff < size_strings {
                        let s = base.add((off_strings + nameoff) as usize) as *const u8;
                        // "#address-cells"
                        if len == 4 {
                            let ac: &[u8] = b"#address-cells";
                            let sc: &[u8] = b"#size-cells";
                            // manual compare with null term
                            let is_ac = {
                                let mut eq = true;
                                for i in 0..ac.len() {
                                    if *s.add(i) != ac[i] {
                                        eq = false;
                                        break;
                                    }
                                }
                                if eq {
                                    *s.add(ac.len()) == 0
                                } else {
                                    false
                                }
                            };
                            let is_sc = {
                                let mut eq = true;
                                for i in 0..sc.len() {
                                    if *s.add(i) != sc[i] {
                                        eq = false;
                                        break;
                                    }
                                }
                                if eq {
                                    *s.add(sc.len()) == 0
                                } else {
                                    false
                                }
                            };
                            if is_ac {
                                let v = be32(prop_ptr);
                                addr_cells = if v > 2 { 2 } else { v };
                            } else if is_sc {
                                let v = be32(prop_ptr);
                                size_cells = if v > 2 { 2 } else { v };
                            }
                        }
                    }
                }
                // memory reg
                let cur_is_mem = if stack_depth > 0 && (stack_depth as usize) <= 16 {
                    is_memory_stack[(stack_depth - 1) as usize]
                } else {
                    false
                };
                if cur_is_mem && nameoff < size_strings {
                    let s = base.add((off_strings + nameoff) as usize) as *const u8;
                    // "reg"
                    let is_reg =
                        *s == b'r' && *s.add(1) == b'e' && *s.add(2) == b'g' && *s.add(3) == 0;
                    if is_reg {
                        let cells = addr_cells + size_cells;
                        if cells != 0 && cells <= 4 {
                            let entry_bytes = cells * 4;
                            let mut off: u32 = 0;
                            while off.checked_add(entry_bytes).unwrap_or(u32::MAX) <= len {
                                let e = prop_ptr.add(off as usize);
                                let size: u64 = if size_cells == 2 {
                                    let hi = be32(e.add((addr_cells * 4) as usize));
                                    let lo = be32(e.add((addr_cells * 4 + 4) as usize));
                                    ((hi as u64) << 32) | lo as u64
                                } else if size_cells == 1 {
                                    let lo = be32(e.add((addr_cells * 4) as usize));
                                    lo as u64
                                } else {
                                    0
                                };
                                total_ram = total_ram.checked_add(size).unwrap_or(16 << 30);
                                if total_ram > (16u64 << 30) {
                                    total_ram = 16u64 << 30;
                                }
                                off += entry_bytes;
                            }
                        }
                    }
                }
                p = align4(p.wrapping_add(len));
            } else if token == 0x4 {
                continue;
            } else if token == 0x9 {
                break;
            } else {
                ok = false;
                break;
            }
        }
        total_ram
    }
}

#[no_mangle]
pub unsafe extern "C" fn fdt_get_cpu_count(dtb: *const u8) -> i32 {
    if unsafe { fdt_valid(dtb) } == 0 {
        return 0;
    }
    unsafe {
        let base = dtb;
        let totalsize = be32(base.add(4));
        let off_struct = be32(base.add(8));
        let size_struct = be32(base.add(36));
        let mut struct_end = off_struct.checked_add(size_struct).unwrap_or(totalsize);
        if struct_end > totalsize {
            struct_end = totalsize;
        }
        let mut stack_depth: i32 = 0;
        let mut cpus_depth: i32 = -1;
        let mut count: i32 = 0;
        let mut p = off_struct;
        let mut ok = true;
        while ok && p.checked_add(4).unwrap_or(u32::MAX) <= struct_end {
            let token = be32(base.add(p as usize));
            p = p.wrapping_add(4);
            if token == 0x1 {
                let name_ptr = base.add(p as usize) as *const u8;
                let mut namelen: u32 = 0;
                while p.checked_add(namelen).unwrap_or(u32::MAX) < totalsize
                    && *base.add((p + namelen) as usize) != 0
                {
                    namelen += 1;
                    if namelen > 64 {
                        break;
                    }
                }
                if p.checked_add(namelen).unwrap_or(u32::MAX) >= totalsize {
                    ok = false;
                    break;
                }
                namelen += 1;
                // check for "cpus"
                if stack_depth >= 0 && (stack_depth as usize) < 16 {
                    let is_cpus = *name_ptr == b'c'
                        && *name_ptr.add(1) == b'p'
                        && *name_ptr.add(2) == b'u'
                        && *name_ptr.add(3) == b's'
                        && *name_ptr.add(4) == 0;
                    if is_cpus {
                        cpus_depth = stack_depth;
                    } else if cpus_depth >= 0 && stack_depth == cpus_depth + 1 {
                        // child of cpus named "cpu" or "cpu@..." — not
                        // "cpu-map" (topology container, no '@'/NUL after cpu)
                        let is_cpu = *name_ptr == b'c'
                            && *name_ptr.add(1) == b'p'
                            && *name_ptr.add(2) == b'u'
                            && (*name_ptr.add(3) == 0 || *name_ptr.add(3) == b'@');
                        if is_cpu {
                            count += 1;
                        }
                    }
                }
                stack_depth += 1;
                if stack_depth > 16 {
                    stack_depth = 16;
                }
                p = align4(p.wrapping_add(namelen));
            } else if token == 0x2 {
                if stack_depth > 0 {
                    stack_depth -= 1;
                    if cpus_depth == stack_depth {
                        cpus_depth = -1;
                    }
                }
            } else if token == 0x3 {
                if p.checked_add(8).unwrap_or(u32::MAX) > struct_end {
                    ok = false;
                    break;
                }
                let len = be32(base.add(p as usize));
                p = p.wrapping_add(4);
                let _nameoff = be32(base.add(p as usize));
                p = p.wrapping_add(4);
                if p.checked_add(len).unwrap_or(u32::MAX) > struct_end {
                    ok = false;
                    break;
                }
                p = align4(p.wrapping_add(len));
            } else if token == 0x4 {
                continue;
            } else if token == 0x9 {
                break;
            } else {
                ok = false;
                break;
            }
        }
        count
    }
}
