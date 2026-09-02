#![allow(clippy::all)]
#![allow(dead_code)]
#![allow(unused_variables)]
#[allow(unused_imports)]
use core::ptr;

#[repr(C)]
pub struct HouseThread {
    sp: *mut u8,
    tpidr: u64,
    tid: i32,
    state: i32,
    _pad: [u8; 48],
}

static mut DUMMY_THR: HouseThread = HouseThread {
    sp: core::ptr::null_mut(),
    tpidr: 0,
    tid: 1,
    state: 2,
    _pad: [0; 48],
};

#[no_mangle]
pub unsafe extern "C" fn house_threads_init() {}
#[no_mangle]
pub unsafe extern "C" fn house_thread_init_main() {}
#[no_mangle]
pub unsafe extern "C" fn house_threads_init_secondary(_core: u32) {}
#[no_mangle]
pub unsafe extern "C" fn house_threads_rebalance() {}
#[no_mangle]
pub unsafe extern "C" fn house_thread_current() -> *mut HouseThread {
    &raw mut DUMMY_THR
}
#[no_mangle]
pub unsafe extern "C" fn house_sched_lock_acquire() {}
#[no_mangle]
pub unsafe extern "C" fn house_sched_lock_release() {}
#[no_mangle]
pub unsafe extern "C" fn house_sched_block() {}
#[no_mangle]
pub unsafe extern "C" fn house_sched_yield() {}
#[no_mangle]
pub unsafe extern "C" fn house_sched_kick(_core: i32) {}
#[no_mangle]
pub unsafe extern "C" fn house_sched_ipi_handler() {}
#[no_mangle]
pub unsafe extern "C" fn house_sched_maybe_preempt_from_isr() {}
#[no_mangle]
pub unsafe extern "C" fn house_sched_wake(_thr: *mut HouseThread) {}
#[no_mangle]
pub unsafe extern "C" fn house_tls_alloc() -> *mut u8 {
    core::ptr::null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn pthread_create(
    _thr: *mut u64,
    _a: *const u8,
    _f: *const u8,
    _arg: *mut u8,
) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_join(_t: u64, _r: *mut *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_detach(_t: u64) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_exit(_r: *mut u8) -> ! {
    loop {
        core::hint::spin_loop()
    }
}
#[no_mangle]
pub unsafe extern "C" fn pthread_self() -> u64 {
    1
}
#[no_mangle]
pub unsafe extern "C" fn pthread_kill(_t: u64, _s: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_setname_np(_t: u64, _n: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_init(_m: *mut u8, _a: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_destroy(_m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_lock(_m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_trylock(_m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_unlock(_m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_init(_c: *mut u8, _a: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_destroy(_c: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_signal(_c: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_broadcast(_c: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_wait(_c: *mut u8, _m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_timedwait(_c: *mut u8, _m: *mut u8, _t: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_condattr_init(_a: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_condattr_destroy(_a: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_condattr_setclock(_a: *mut u8, _c: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_attr_init(_a: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_attr_destroy(_a: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_attr_getstacksize(_a: *const u8, _s: *mut usize) -> i32 {
    if !_s.is_null() {
        *_s = 512 * 1024;
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_attr_setaffinity_np(
    _a: *mut u8,
    _sz: usize,
    _m: *const u8,
) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_attr_getaffinity_np(_a: *mut u8, _sz: usize, _m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_setaffinity_np(_t: u64, _sz: usize, _m: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_getaffinity_np(_t: u64, _sz: usize, _m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sched_yield() -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sched_getaffinity(_p: i32, _s: usize, _m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sched_setaffinity(_p: i32, _s: usize, _m: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_sigmask(_h: i32, _s: *const u8, _o: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn nanosleep(_r: *const u8, _m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn poll(_f: *mut u8, _n: u64, _t: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn select(
    _n: i32,
    _r: *mut u8,
    _w: *mut u8,
    _e: *mut u8,
    _t: *mut u8,
) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pause() -> i32 {
    0
}
#[no_mangle]
pub static mut sched_lock: u32 = 0;
#[no_mangle]
pub static mut house_sched_deferred: [i32; 16] = [0; 16];
#[no_mangle]
pub static mut house_thr_mode: i32 = 1;
#[no_mangle]
pub static mut house_ipi_pending: [i32; 16] = [0; 16];
#[no_mangle]
pub static mut house_current_thr: [*mut HouseThread; 16] = [core::ptr::null_mut(); 16];
// house_spin_* inline in spinlock.h but provide symbols
#[no_mangle]
pub unsafe extern "C" fn house_spin_lock(_l: *mut u32) {}
#[no_mangle]
pub unsafe extern "C" fn house_spin_unlock(_l: *mut u32) {}
#[no_mangle]
pub unsafe extern "C" fn house_spin_trylock(_l: *mut u32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn house_spin_init(_l: *mut u32) {}
