#![allow(clippy::new_without_default)]
//! SpinLock — `spinlock.h` transliteration.
//!
//! `house-hal-aarch64::spinlock` owns the `LDAXR/STXR` + `dmb sy` loop.
//! This crate provides the arch-agnostic `RawSpinLock` re-export and
//! `SpinLock<T>` type. `RawSpinLock` uses `UnsafeCell<u32>` + `dmb sy`
//! ordering matching `platform/aarch64/spinlock.h: house_spin_lock`.
//!
//! No `spin` crate dependency — freestanding `panic="abort"` forbids extra deps.

use core::cell::UnsafeCell;
use core::ops::{Deref, DerefMut};

/// Raw ticket lock without `spin` dep — matches `house_spinlock_t`.
#[repr(C)]
pub struct RawSpinLock {
    pub v: UnsafeCell<u32>,
}

// SAFETY: RawSpinLock is `Sync` when used per C `house_spinlock_t` protocol (single owner via LDAXR/STXR).
unsafe impl Sync for RawSpinLock {}
unsafe impl Send for RawSpinLock {}

impl RawSpinLock {
    pub const fn new() -> Self {
        Self {
            v: UnsafeCell::new(0),
        }
    }

    /// Acquire — `ldaxr; cbnz; stxr; dmb sy` (matches `spinlock.h`).
    #[inline]
    pub fn lock(&self) {
        // SAFETY: LDAXR/STXR loop with DMB SY matches C spinlock.h; `v` is identity-mapped.
        unsafe {
            let ptr = self.v.get();
            core::arch::asm!(
                "1: ldaxr {tmp:w}, [{ptr}]",
                "   cbnz {tmp:w}, 1b",
                "   mov {res:w}, #1",
                "   stxr {tmp:w}, {res:w}, [{ptr}]",
                "   cbnz {tmp:w}, 1b",
                "   dmb sy",
                ptr = in(reg) ptr,
                tmp = out(reg) _,
                res = out(reg) _,
                options(nostack),
            );
        }
    }

    #[inline]
    pub fn unlock(&self) {
        // SAFETY: `stlr` + `dmb sy` matches `house_spin_unlock`.
        unsafe {
            let ptr = self.v.get();
            core::arch::asm!(
                "dmb sy",
                "stlr wzr, [{ptr}]",
                "dmb sy",
                ptr = in(reg) ptr,
                options(nostack),
            );
        }
    }
}

/// Generic spinlock — minimal `SpinLock<T>` for HAL metadata.
pub struct SpinLock<T> {
    lock: RawSpinLock,
    data: UnsafeCell<T>,
}

unsafe impl<T: Send> Sync for SpinLock<T> {}
unsafe impl<T: Send> Send for SpinLock<T> {}

impl<T> SpinLock<T> {
    pub const fn new(data: T) -> Self {
        Self {
            lock: RawSpinLock {
                v: UnsafeCell::new(0),
            },
            data: UnsafeCell::new(data),
        }
    }

    #[inline]
    pub fn lock(&self) -> SpinLockGuard<'_, T> {
        self.lock.lock();
        SpinLockGuard {
            lock: &self.lock,
            data: self.data.get(),
        }
    }
}

pub struct SpinLockGuard<'a, T> {
    lock: &'a RawSpinLock,
    data: *mut T,
}

impl<T> Deref for SpinLockGuard<'_, T> {
    type Target = T;
    fn deref(&self) -> &T {
        // SAFETY: guard holds lock, data is valid.
        unsafe { &*self.data }
    }
}

impl<T> DerefMut for SpinLockGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        // SAFETY: guard holds lock, exclusive access.
        unsafe { &mut *self.data }
    }
}

impl<T> Drop for SpinLockGuard<'_, T> {
    fn drop(&mut self) {
        self.lock.unlock();
    }
}
