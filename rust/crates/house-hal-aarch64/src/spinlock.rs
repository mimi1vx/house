#![allow(dead_code)]

//! SpinLock — `spinlock.h` transliteration via LDAXR/STXR + DMB SY.
//! Avoids `core::sync::atomic` to not pull `panic_fmt` for ordering checks.

use core::cell::UnsafeCell;
use core::ops::{Deref, DerefMut};

#[repr(C)]
pub struct RawSpinLock {
    pub v: UnsafeCell<u32>,
}

// SAFETY: RawSpinLock is Sync if used correctly (like C house_spinlock_t).
unsafe impl Sync for RawSpinLock {}
unsafe impl Send for RawSpinLock {}

impl RawSpinLock {
    pub const fn new() -> Self {
        Self {
            v: UnsafeCell::new(0),
        }
    }

    #[inline]
    pub fn lock(&self) {
        // SAFETY: LDAXR/STXR loop with DMB SY matches C spinlock.h.
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
    pub fn try_lock(&self) -> bool {
        // Stub: not used in HAL hot paths; return false to avoid complex stxr.
        false
    }

    #[inline]
    pub fn unlock(&self) {
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

    #[inline]
    pub fn try_lock(&self) -> Option<SpinLockGuard<'_, T>> {
        if self.lock.try_lock() {
            Some(SpinLockGuard {
                lock: &self.lock,
                data: self.data.get(),
            })
        } else {
            None
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
        unsafe { &*self.data }
    }
}

impl<T> DerefMut for SpinLockGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        unsafe { &mut *self.data }
    }
}

impl<T> Drop for SpinLockGuard<'_, T> {
    fn drop(&mut self) {
        self.lock.unlock();
    }
}
