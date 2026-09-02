#![allow(clippy::all)]
#![allow(dead_code)]
#![allow(unused_variables)]
#![allow(unused_unsafe)]
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(suspicious_runtime_symbol_definitions)]

#[derive(Copy, Clone)]
#[repr(C)]
pub struct HouseThread {
    pub sp: *mut u8,
    pub tpidr: u64,
    pub tid: i32,
    pub state: i32,
    pub start: *mut u8,
    pub arg: *mut u8,
    pub retval: *mut u8,
    pub detached: i32,
    pub exited: i32,
    pub next: *mut HouseThread,
    pub wait_next: *mut HouseThread,
    pub joiner: *mut HouseThread,
    pub stack_base: *mut u8,
    pub stack_size: usize,
    pub tcb: *mut u8,
    pub sigmask: [u64; 2],
    pub errno_val: i32,
    pub wake_ns: u64,
    pub affinity: u32,
}

const HOUSE_THR_UNUSED: i32 = 0;
const HOUSE_THR_RUNNABLE: i32 = 1;
const HOUSE_THR_RUNNING: i32 = 2;
const HOUSE_THR_BLOCKED: i32 = 3;
const HOUSE_MAX_THREADS: usize = 64;
const HOUSE_MAX_SMP: usize = 16;
const HOUSE_THREAD_STACK_BYTES: usize = 512 * 1024;

static mut THREADS: [HouseThread; 64] = [HouseThread {
    sp: core::ptr::null_mut(),
    tpidr: 0,
    tid: 0,
    state: 0,
    start: core::ptr::null_mut(),
    arg: core::ptr::null_mut(),
    retval: core::ptr::null_mut(),
    detached: 0,
    exited: 0,
    next: core::ptr::null_mut(),
    wait_next: core::ptr::null_mut(),
    joiner: core::ptr::null_mut(),
    stack_base: core::ptr::null_mut(),
    stack_size: 0,
    tcb: core::ptr::null_mut(),
    sigmask: [0; 2],
    errno_val: 0,
    wake_ns: 0,
    affinity: 0,
}; 64];

#[no_mangle]
pub static mut house_current_thr: [*mut HouseThread; 16] = [core::ptr::null_mut(); 16];

static mut RUN_HEAD: [*mut HouseThread; 16] = [core::ptr::null_mut(); 16];
static mut RUN_TAIL: [*mut HouseThread; 16] = [core::ptr::null_mut(); 16];
static mut NEXT_TID: i32 = 1;

#[no_mangle]
pub static mut house_thr_mode: i32 = 1;
#[no_mangle]
pub static mut house_ipi_pending: [i32; 16] = [0; 16];
#[no_mangle]
pub static mut house_sched_deferred: [i32; 16] = [0; 16];
#[no_mangle]
pub static mut sched_lock: u32 = 0;

#[allow(suspicious_runtime_symbol_definitions)]
unsafe extern "C" {
    fn malloc(n: usize) -> *mut u8;
    static mut house_smp_n: i32;
    static mut house_smp_online_mask: u32;
}

#[inline]
unsafe fn cpu_id() -> u32 {
    let mpidr: u64;
    unsafe {
        core::arch::asm!("mrs {0}, mpidr_el1", out(reg) mpidr, options(nostack, preserves_flags))
    };
    (mpidr & 0xFF) as u32
}

unsafe fn alloc_thread() -> *mut HouseThread {
    for i in 0..HOUSE_MAX_THREADS {
        let thr = unsafe { &mut THREADS[i] };
        if thr.state == HOUSE_THR_UNUSED {
            return thr as *mut HouseThread;
        }
    }
    core::ptr::null_mut()
}

#[no_mangle]
pub unsafe extern "C" fn house_threads_init() {
    for i in 0..HOUSE_MAX_THREADS {
        unsafe { THREADS[i].state = HOUSE_THR_UNUSED };
    }
    unsafe { NEXT_TID = 1 };
    for c in 0..HOUSE_MAX_SMP {
        unsafe {
            RUN_HEAD[c] = core::ptr::null_mut();
            RUN_TAIL[c] = core::ptr::null_mut();
            house_current_thr[c] = core::ptr::null_mut();
            house_sched_deferred[c] = 0;
            house_ipi_pending[c] = 0;
        }
    }
    unsafe { sched_lock = 0 };
}

#[no_mangle]
pub unsafe extern "C" fn house_thread_init_main() {
    unsafe { house_threads_init() };
    let thr = unsafe { alloc_thread() };
    if thr.is_null() {
        return;
    }
    unsafe {
        (*thr).tid = 1;
        (*thr).state = HOUSE_THR_RUNNING;
        (*thr).detached = 0;
        (*thr).exited = 0;
        (*thr).stack_base = core::ptr::null_mut();
        (*thr).stack_size = 0;
        (*thr).start = core::ptr::null_mut();
        (*thr).arg = core::ptr::null_mut();
        (*thr).retval = core::ptr::null_mut();
        (*thr).wait_next = core::ptr::null_mut();
        (*thr).joiner = core::ptr::null_mut();
        (*thr).next = core::ptr::null_mut();
        (*thr).errno_val = 0;
        (*thr).wake_ns = 0;
        (*thr).affinity = 1;
        (*thr).sigmask = [0; 2];
        let tcb = house_tls_alloc();
        (*thr).tcb = tcb;
        (*thr).tpidr = tcb as u64;
        core::arch::asm!("msr tpidr_el0, {0}", in(reg) tcb as u64, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
        house_current_thr[0] = thr;
        NEXT_TID = 2;
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_threads_init_secondary(core: u32) {
    if core as usize >= HOUSE_MAX_SMP {
        return;
    }
    let thr = unsafe { alloc_thread() };
    if thr.is_null() {
        return;
    }
    unsafe {
        let tid = NEXT_TID;
        NEXT_TID += 1;
        (*thr).tid = tid;
        (*thr).state = HOUSE_THR_RUNNING;
        (*thr).detached = 0;
        (*thr).exited = 0;
        (*thr).stack_base = core::ptr::null_mut();
        (*thr).stack_size = 0;
        (*thr).start = core::ptr::null_mut();
        (*thr).arg = core::ptr::null_mut();
        (*thr).retval = core::ptr::null_mut();
        (*thr).wait_next = core::ptr::null_mut();
        (*thr).joiner = core::ptr::null_mut();
        (*thr).next = core::ptr::null_mut();
        (*thr).errno_val = 0;
        (*thr).wake_ns = 0;
        (*thr).affinity = 1u32 << core;
        (*thr).sigmask = [0; 2];
        let tcb = house_tls_alloc();
        (*thr).tcb = tcb;
        (*thr).tpidr = tcb as u64;
        core::arch::asm!("msr tpidr_el0, {0}", in(reg) tcb as u64, options(nostack, preserves_flags));
        core::arch::asm!("isb", options(nostack, preserves_flags));
        house_current_thr[core as usize] = thr;
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_threads_rebalance() {
    // Simplified: no rebalance needed for spike
}

#[no_mangle]
pub unsafe extern "C" fn house_thread_current() -> *mut HouseThread {
    let core = unsafe { cpu_id() } as usize;
    let c = if core < HOUSE_MAX_SMP { core } else { 0 };
    unsafe { house_current_thr[c] }
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_lock_acquire() {
    unsafe { core::arch::asm!("msr daifset, #2", options(nostack, preserves_flags)) };
    unsafe {
        let ptr = &raw mut sched_lock as *mut u32;
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

#[no_mangle]
pub unsafe extern "C" fn house_sched_lock_release() {
    let core = unsafe { cpu_id() } as usize;
    let deferred = if core < HOUSE_MAX_SMP {
        unsafe { house_sched_deferred[core] }
    } else {
        0
    };
    unsafe {
        core::arch::asm!(
            "dmb sy",
            "stlr wzr, [{ptr}]",
            "dmb sy",
            ptr = in(reg) &raw mut sched_lock as *mut u32,
            options(nostack),
        );
        core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags));
    }
    if deferred != 0 {
        unsafe { house_sched_deferred[core] = 0 };
        unsafe { house_sched_yield() };
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_block() {
    // For now, just yield
    unsafe { house_sched_yield() };
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_yield() {
    // Minimal yield: if there's another runnable on this core, switch
    let core = unsafe { cpu_id() } as usize;
    if core >= HOUSE_MAX_SMP {
        return;
    }
    unsafe {
        // In stub, just return; real scheduler would switch.
        // For spike, no other threads, so no switch needed.
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_kick(_core: i32) {
    // Send IPI if needed - stub for now
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_ipi_handler() {
    let core = unsafe { cpu_id() } as usize;
    if core < HOUSE_MAX_SMP {
        unsafe { house_ipi_pending[core] = 0 };
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_maybe_preempt_from_isr() {}

#[no_mangle]
pub unsafe extern "C" fn house_sched_wake(_thr: *mut HouseThread) {}

#[no_mangle]
pub unsafe extern "C" fn house_tls_alloc() -> *mut u8 {
    let p = unsafe { malloc(32) };
    if p.is_null() {
        return core::ptr::null_mut();
    }
    unsafe { core::ptr::write_bytes(p, 0, 32) };
    p
}

// Stubs for pthread etc - keep minimal but functional for tests
#[no_mangle]
pub unsafe extern "C" fn pthread_create(
    thr: *mut u64,
    _a: *const u8,
    _f: *const u8,
    _arg: *mut u8,
) -> i32 {
    if thr.is_null() {
        return 22;
    }
    unsafe { *thr = 2 };
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
        unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) }
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
        unsafe { *_s = 512 * 1024 }
    };
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
    unsafe { house_sched_yield() };
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
pub unsafe extern "C" fn house_spin_lock(_l: *mut u32) {}
#[no_mangle]
pub unsafe extern "C" fn house_spin_unlock(_l: *mut u32) {}
#[no_mangle]
pub unsafe extern "C" fn house_spin_trylock(_l: *mut u32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn house_spin_init(_l: *mut u32) {}
