#![allow(clippy::all)]
//! errno dispatch per tinylibc/sys.c __errno_location

use core::ptr;

#[repr(C)]
pub struct HouseThreadOpaque {
    _sp: *mut u8,
    _tpidr: u64,
    _tid: i32,
    _state: i32,
    _start: *mut u8,
    _arg: *mut u8,
    _retval: *mut u8,
    _detached: i32,
    _exited: i32,
    _next: *mut u8,
    _wait_next: *mut u8,
    _joiner: *mut u8,
    _stack_base: *mut u8,
    _stack_size: usize,
    _tcb: *mut u8,
    _sigmask: [u64; 2],
    pub errno_val: i32,
    _wake_ns: u64,
    _affinity: u32,
}

unsafe extern "C" {
    fn house_thread_current() -> *mut HouseThreadOpaque;
    static mut house_thr_mode: i32;
}

static mut STATIC_ERRNO: i32 = 0;

#[no_mangle]
pub unsafe extern "C" fn __errno_location() -> *mut i32 {
    unsafe {
        let thr_mode = ptr::read_volatile(&raw const house_thr_mode);
        if thr_mode != 0 {
            let cur = house_thread_current();
            if !cur.is_null() {
                return &raw mut (*cur).errno_val;
            }
        }
        &raw mut STATIC_ERRNO
    }
}
