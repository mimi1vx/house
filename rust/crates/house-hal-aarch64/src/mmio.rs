#![allow(dead_code)]

//! Volatile MMIO helpers — `// SAFETY:` per access.
//!
//! Parity with `platform/aarch64/*.{c,h}` `*(volatile uint32_t*)` and
//! `asm("ldr %w0,[%1]")` sequences. HVF requires ISV=1 single-register
//! `ldr`/`str` (no `st*` writeback/LDP/SIMD).

use core::arch::asm;

/// Read 32-bit MMIO at absolute address `addr` via `ldr`.
///
/// # Safety
/// Caller guarantees `addr` is MMIO (GIC/UART/Virtio) identity-mapped,
/// 4-byte aligned, non-aliasing with normal RAM, and accessible at EL1.
#[inline(always)]
pub unsafe fn mmio_r32(addr: u64) -> u32 {
    // SAFETY: caller guarantees MMIO base/offset identity-mapped and valid.
    unsafe {
        let v: u32;
        asm!("ldr {0:w}, [{1}]", out(reg) v, in(reg) addr, options(nostack, preserves_flags));
        v
    }
}

/// Write 32-bit MMIO at `addr` via `str`.
///
/// # Safety
/// Same preconditions as `mmio_r32`.
#[inline(always)]
pub unsafe fn mmio_w32(addr: u64, v: u32) {
    // SAFETY: caller guarantees MMIO destination valid.
    unsafe {
        asm!("str {0:w}, [{1}]", in(reg) v, in(reg) addr, options(nostack, preserves_flags));
    }
}

/// Read 64-bit MMIO at `addr`.
/// # Safety
/// Same as `mmio_r32` but 8-byte aligned.
#[inline(always)]
pub unsafe fn mmio_r64(addr: u64) -> u64 {
    // SAFETY: caller guarantees 8-byte MMIO valid.
    unsafe {
        let v: u64;
        asm!("ldr {0}, [{1}]", out(reg) v, in(reg) addr, options(nostack, preserves_flags));
        v
    }
}

/// Write 64-bit MMIO at `addr`.
/// # Safety
/// Same as `mmio_w64`.
#[inline(always)]
pub unsafe fn mmio_w64(addr: u64, v: u64) {
    // SAFETY: caller guarantees MMIO destination valid.
    unsafe {
        asm!("str {0}, [{1}]", in(reg) v, in(reg) addr, options(nostack, preserves_flags));
    }
}

/// Base+offset variants used by Virtio `0x0a000000+i*0x200`.
///
/// # Safety
/// `base+off` must satisfy `mmio_r32` preconditions; overflow checked by caller.
#[inline(always)]
pub unsafe fn mmio_r32_off(base: usize, off: usize) -> u32 {
    // SAFETY: caller guarantees base+off MMIO.
    unsafe { mmio_r32((base + off) as u64) }
}

#[inline(always)]
pub unsafe fn mmio_w32_off(base: usize, off: usize, v: u32) {
    // SAFETY: caller guarantees base+off MMIO.
    unsafe { mmio_w32((base + off) as u64, v) }
}

/// Read 8-bit MMIO at `addr` via `ldrb`.
/// # Safety
/// Caller guarantees `addr` is MMIO, valid at EL1.
#[inline(always)]
pub unsafe fn mmio_r8(addr: u64) -> u8 {
    // SAFETY: caller guarantees MMIO base valid.
    unsafe {
        let v: u8;
        core::arch::asm!("ldrb {0:w}, [{1}]", out(reg) v, in(reg) addr, options(nostack, preserves_flags));
        v
    }
}

/// Write 8-bit MMIO at `addr` via `strb`.
/// # Safety
/// Same as `mmio_r8`.
#[inline(always)]
pub unsafe fn mmio_w8(addr: u64, v: u8) {
    // SAFETY: caller guarantees MMIO destination valid.
    unsafe {
        core::arch::asm!("strb {0:w}, [{1}]", in(reg) v, in(reg) addr, options(nostack, preserves_flags));
    }
}

// Barriers — preserve C `dmb sy`/`dsb sy`/`isb` ordering parity (SOTA Security 06).

#[inline(always)]
pub fn dmb_sy() {
    // SAFETY: `dmb sy` is always safe — no memory operand, orders prior accesses.
    unsafe { asm!("dmb sy", options(nostack, preserves_flags)) }
}

#[inline(always)]
pub fn dsb_sy() {
    // SAFETY: `dsb sy` is always safe at EL1.
    unsafe { asm!("dsb sy", options(nostack, preserves_flags)) }
}

#[inline(always)]
pub fn dsb_ish() {
    // SAFETY: `dsb ish` is always safe.
    unsafe { asm!("dsb ish", options(nostack, preserves_flags)) }
}

#[inline(always)]
pub fn dsb_ishst() {
    // SAFETY: `dsb ishst` is always safe.
    unsafe { asm!("dsb ishst", options(nostack, preserves_flags)) }
}

#[inline(always)]
pub fn isb() {
    // SAFETY: `isb` flushes pipeline, always safe at EL1.
    unsafe { asm!("isb", options(nostack, preserves_flags)) }
}

// Cache maintenance — `dc cvac`/`dc ivac` over physical alias (Virtio DMA).

const DC_LINE: u64 = 64;

/// Clean D-cache by VA to PoC — single line.
/// # Safety
/// `pa` must be Normal WB memory, mapped via alias or identity, EL1 accessible.
#[inline(always)]
pub unsafe fn dc_cvac_va(pa: u64) {
    // SAFETY: caller guarantees pa is valid Normal WB VA and EL1.
    unsafe { asm!("dc cvac, {0}", in(reg) pa, options(nostack, preserves_flags)) }
}

/// Invalidate D-cache by VA to PoC — single line.
/// # Safety
/// Same as `dc_cvac_va`, but for device-written buffers before consumption.
#[inline(always)]
pub unsafe fn dc_ivac_va(pa: u64) {
    // SAFETY: caller guarantees pa valid for invalidation.
    unsafe { asm!("dc ivac, {0}", in(reg) pa, options(nostack, preserves_flags)) }
}

/// Clean D-cache over `[pa, pa+len)` — 64B lines, `dsb sy` after.
/// Mirrors `virtio_transport.c:flush` `dc cvac` loop + `dsb sy` + `dmb sy`.
/// # Safety
/// Range must be Normal WB, not overlapping MMIO/Device.
pub unsafe fn dc_cvac_range(pa: u64, len: usize) {
    // SAFETY: caller guarantees range valid; loop handles unaligned start.
    unsafe {
        let end = pa + len as u64;
        let mut cur = pa & !(DC_LINE - 1);
        while cur < end {
            asm!("dc cvac, {0}", in(reg) cur, options(nostack, preserves_flags));
            cur += DC_LINE;
        }
        asm!("dsb sy", options(nostack, preserves_flags));
        asm!("dmb sy", options(nostack, preserves_flags));
    }
}

/// Invalidate D-cache over `[pa, pa+len)` before reading device memory.
/// # Safety
/// Same as `dc_cvac_range`; caller must `dmb sy` before reading buffer.
pub unsafe fn dc_ivac_range(pa: u64, len: usize) {
    // SAFETY: caller guarantees range valid.
    unsafe {
        let end = pa + len as u64;
        let mut cur = pa & !(DC_LINE - 1);
        while cur < end {
            asm!("dc ivac, {0}", in(reg) cur, options(nostack, preserves_flags));
            cur += DC_LINE;
        }
        asm!("dsb sy", options(nostack, preserves_flags));
        asm!("dmb sy", options(nostack, preserves_flags));
    }
}

// TLBI helpers — parity with C `tlbi vae1is` / `vmalle1is` + `dsb`/`isb`.

/// TLBI VAE1IS by VA (VA>>12 in register), Inner Shareable, ASID-tagged.
/// # Safety
/// EL1 only, `va>>12` is 48-bit VA valid for current TTBR0 `T0SZ=16`.
#[inline(always)]
pub unsafe fn tlbi_vae1is(va: u64) {
    // SAFETY: EL1, VA valid per TCR, ASID-matched.
    unsafe {
        let v = va >> 12;
        asm!("tlbi vae1is, {0}", in(reg) v, options(nostack, preserves_flags));
        asm!("dsb ish; isb", options(nostack, preserves_flags));
    }
}

/// TLBI VAE1IS with explicit dsb sequence for demand-pager fast-path.
/// # Safety
/// Same as `tlbi_vae1is`; caller holds `SpinLock` if over page-table walk.
#[inline(always)]
pub unsafe fn tlbi_vae1is_ish(va: u64) {
    // SAFETY: same preconditions.
    unsafe {
        let v = va >> 12;
        asm!("dsb ishst; tlbi vae1is, {0}; dsb ish; isb", in(reg) v, options(nostack, preserves_flags));
    }
}

/// TLBI VMALLE1IS — flush all ASIDs Inner Shareable (wrap path).
/// # Safety
/// EL1 only; broadcasts to all cores, needs `dsb`/`isb`.
#[inline(always)]
pub unsafe fn tlbi_vmalle1is() {
    // SAFETY: EL1, broadcast flush.
    unsafe {
        asm!(
            "dsb ishst; tlbi vmalle1is; dsb ish; isb",
            options(nostack, preserves_flags)
        );
    }
}

#[inline(always)]
pub unsafe fn ic_iallu() {
    // SAFETY: `ic iallu` is always safe at EL1 (invalidate I-cache).
    unsafe { asm!("ic iallu", options(nostack, preserves_flags)) }
}
