#![allow(clippy::missing_safety_doc)]
//! MMIO helpers — volatile access abstraction.
//!
//! `aarch64` impl owns volatile `*mut u32` + `dmb sy`/`dc cvac` ordering.
//! This trait is intentionally minimal; arch impls provide concrete `r32`/`w32`.

/// MMIO access trait.
///
/// # Safety
/// `base` must be identity-mapped Device memory (e.g. GIC `0x08000000`,
/// PL011 `0x09000000`, virtio-MMIO `0x0a000000+i*0x200`). `off` is byte offset
/// within that window. Callers must hold the appropriate lock if the device
/// is shared.
pub trait Mmio {
    /// Volatile `u32` read at `base + off`.
    ///
    /// # Safety
    /// `base+off` must be valid MMIO.
    unsafe fn r32(base: usize, off: usize) -> u32;

    /// Volatile `u32` write at `base + off`.
    ///
    /// # Safety
    /// `base+off` must be valid MMIO.
    unsafe fn w32(base: usize, off: usize, v: u32);
}
