#![allow(clippy::all)]
#![allow(dead_code)]
#![allow(unused_variables)]
#![allow(unused_unsafe)]
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(suspicious_runtime_symbol_definitions)]
#![allow(unused_assignments)]
#![allow(unused_mut)]
#![allow(function_casts_as_integer)]

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
const HOUSE_MAX_SMP: usize = 32;
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
pub static mut house_current_thr: [*mut HouseThread; 32] = [core::ptr::null_mut(); 32];

static mut RUN_HEAD: [*mut HouseThread; 32] = [core::ptr::null_mut(); 32];
static mut RUN_TAIL: [*mut HouseThread; 32] = [core::ptr::null_mut(); 32];
static mut NEXT_TID: i32 = 1;

#[no_mangle]
pub static mut house_thr_mode: i32 = 1;
#[no_mangle]
pub static mut house_ipi_pending: [i32; 32] = [0; 32];
#[no_mangle]
pub static mut house_sched_deferred: [i32; 32] = [0; 32];
#[no_mangle]
pub static mut sched_lock: u32 = 0;

#[allow(suspicious_runtime_symbol_definitions)]
unsafe extern "C" {
    fn malloc(n: usize) -> *mut u8;
    fn free(p: *mut u8);
    static mut house_smp_n: i32;
    static mut house_smp_online_mask: u32;
    fn house_gic_send_sgi_to_core(sgi: u32, core: u32);
    fn house_thread_switch(old: *mut HouseThread, new: *mut HouseThread);
    fn house_uptime_ns() -> u64;
    fn house_timerfd_due(fd: i32) -> i32;
    fn house_fd_pipe_readable(fd: i32) -> i32;
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
            // Drop stale run-queue links to this slot: pthread_exit never
            // unlinks self, so reuse must not inherit queue membership.
            unsafe { dequeue_specific(thr as *mut HouseThread) };
            return thr as *mut HouseThread;
        }
    }
    core::ptr::null_mut()
}

// Remove every run-queue link to `thr` (slot reuse, idempotent).
unsafe fn dequeue_specific(thr: *mut HouseThread) {
    for c in 0..HOUSE_MAX_SMP {
        let mut prev: *mut HouseThread = core::ptr::null_mut();
        let mut cur = unsafe { RUN_HEAD[c] };
        while !cur.is_null() {
            let nxt = unsafe { (*cur).next };
            if cur == thr {
                if prev.is_null() {
                    unsafe { RUN_HEAD[c] = nxt };
                } else {
                    unsafe { (*prev).next = nxt };
                }
                if unsafe { RUN_TAIL[c] } == cur {
                    unsafe { RUN_TAIL[c] = prev };
                }
                unsafe { (*cur).next = core::ptr::null_mut() };
            } else {
                prev = cur;
            }
            cur = nxt;
        }
    }
}

unsafe fn enqueue_run_core(core: i32, thr: *mut HouseThread) {
    if core < 0 || core as usize >= HOUSE_MAX_SMP {
        return;
    }
    if thr.is_null() {
        return;
    }
    // Never queue twice: a duplicate entry corrupts run-queue accounting
    // (observed: queued+RUNNING, current+RUNNABLE) and strands work behind
    // a parked thread. The running thread requeues itself on yield.
    if unsafe { queued_anywhere(thr) } {
        return;
    }
    let c = core as usize;
    unsafe {
        (*thr).next = core::ptr::null_mut();
        (*thr).state = HOUSE_THR_RUNNABLE;
        if !RUN_TAIL[c].is_null() {
            (*RUN_TAIL[c]).next = thr;
        } else {
            RUN_HEAD[c] = thr;
        }
        RUN_TAIL[c] = thr;
    }
}

#[inline]
unsafe fn live_mask() -> u32 {
    unsafe { core::ptr::read_volatile(&raw const house_smp_online_mask) }
}

#[inline]
unsafe fn first_online(mask: u32) -> i32 {
    if mask == 0 {
        return 0;
    }
    mask.trailing_zeros() as i32
}

unsafe fn enqueue_run(thr: *mut HouseThread) {
    let smp = unsafe { core::ptr::read_volatile(&raw const house_smp_n) };
    let smp = if smp <= 0 { 2 } else { smp };
    let aff = unsafe { (*thr).affinity };
    let mut core = if aff != 0 {
        aff.trailing_zeros() as i32
    } else {
        let tid = unsafe { (*thr).tid };
        (tid % smp) as i32
    };
    if core >= smp {
        core = 0;
    }
    // Follow the live mask: an offline target never runs its queue.
    let mask = unsafe { live_mask() };
    if mask != 0 {
        let bit = 1u32.checked_shl(core as u32).unwrap_or(0);
        if bit == 0 || mask & bit == 0 {
            core = unsafe { first_online(mask) };
        }
    }
    unsafe { enqueue_run_core(core, thr) };
    let cur = unsafe { cpu_id() } as i32;
    if core != cur {
        unsafe { house_sched_kick(core) };
    }
}

unsafe fn dequeue_run_core(core: i32) -> *mut HouseThread {
    if core < 0 || core as usize >= HOUSE_MAX_SMP {
        return core::ptr::null_mut();
    }
    let c = core as usize;
    unsafe {
        let thr = RUN_HEAD[c];
        if thr.is_null() {
            return core::ptr::null_mut();
        }
        RUN_HEAD[c] = (*thr).next;
        if RUN_HEAD[c].is_null() {
            RUN_TAIL[c] = core::ptr::null_mut();
        }
        (*thr).next = core::ptr::null_mut();
        thr
    }
}

// SAFETY: call with sched_lock held. Spin-exit paths (cond_wait/timedwait wfi)
// can leave a RUNNABLE thread already queued; re-enqueueing duplicates the entry
// and a later dequeue may switch to a recycled slot. Scan before enqueueing.
unsafe fn queued_anywhere(thr: *mut HouseThread) -> bool {
    for c in 0..HOUSE_MAX_SMP {
        let mut q = unsafe { RUN_HEAD[c] };
        let mut k = 0;
        while !q.is_null() && k <= HOUSE_MAX_THREADS {
            if q == thr {
                return true;
            }
            q = unsafe { (*q).next };
            k += 1;
        }
    }
    false
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
    unsafe { house_sched_lock_acquire() };
    let thr = unsafe { alloc_thread() };
    if thr.is_null() {
        unsafe { house_sched_lock_release() };
        return;
    }
    // SAFETY: claim the slot while holding the lock like C init_secondary,
    // so a concurrent pthread_create cannot grab the same thread.
    unsafe { (*thr).state = HOUSE_THR_RUNNING };
    let tid = unsafe {
        let t = NEXT_TID;
        NEXT_TID += 1;
        t
    };
    unsafe { house_sched_lock_release() };
    unsafe {
        (*thr).tid = tid;
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
    unsafe { house_sched_lock_acquire() };
    let smp = unsafe { core::ptr::read_volatile(&raw const house_smp_n) };
    for i in 0..HOUSE_MAX_THREADS {
        let t = unsafe { &mut THREADS[i] as *mut HouseThread };
        unsafe {
            if (*t).state == HOUSE_THR_UNUSED {
                continue;
            }
            if (*t).tid < 2 || (*t).tid >= 10 {
                continue;
            }
            let target = (*t).tid % smp;
            let want = 1u32 << target;
            if (*t).affinity == want {
                continue;
            }
            if (*t).state == HOUSE_THR_RUNNABLE {
                let mut moved = false;
                for c in 0..smp {
                    let mut prev: *mut HouseThread = core::ptr::null_mut();
                    let mut cur = RUN_HEAD[c as usize];
                    while !cur.is_null() {
                        if cur == t {
                            if prev.is_null() {
                                RUN_HEAD[c as usize] = (*cur).next;
                            } else {
                                (*prev).next = (*cur).next;
                            }
                            if RUN_TAIL[c as usize] == cur {
                                RUN_TAIL[c as usize] = prev;
                            }
                            (*cur).next = core::ptr::null_mut();
                            enqueue_run_core(target, cur);
                            if target as u32 != cpu_id() {
                                house_sched_kick(target);
                            }
                            moved = true;
                            break;
                        }
                        prev = cur;
                        cur = (*cur).next;
                    }
                    if moved {
                        break;
                    }
                }
                if moved {
                    continue;
                }
            }
            (*t).affinity = want;
        }
    }
    unsafe { house_sched_lock_release() };
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
pub unsafe extern "C" fn house_sched_wake(thr: *mut HouseThread) {
    if thr.is_null() {
        return;
    }
    unsafe {
        house_sched_lock_acquire();
        if (*thr).state == HOUSE_THR_BLOCKED {
            enqueue_run(thr);
        }
        house_sched_lock_release();
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_ipi_handler() {
    let core = unsafe { cpu_id() } as usize;
    if core < HOUSE_MAX_SMP {
        unsafe { house_ipi_pending[core] = 1 };
    }
    unsafe { core::arch::asm!("dsb sy; sev; isb", options(nostack, preserves_flags)) };
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_kick(core: i32) {
    if core < 0 {
        return;
    }
    let smp = unsafe { core::ptr::read_volatile(&raw const house_smp_n) };
    if core >= smp {
        return;
    }
    if core >= 32 {
        return;
    }
    let mask = unsafe { core::ptr::read_volatile(&raw const house_smp_online_mask) };
    if (mask & (1u32 << core)) == 0 {
        return;
    }
    unsafe { house_gic_send_sgi_to_core(0, core as u32) };
    unsafe { core::arch::asm!("dsb sy; sev; isb", options(nostack, preserves_flags)) };
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_maybe_preempt_from_isr() {}

#[no_mangle]
pub unsafe extern "C" fn house_sched_block() {
    let core = unsafe { cpu_id() };
    let old = unsafe { house_current_thr[core as usize] };
    unsafe { house_sched_lock_acquire() };
    let mut next = unsafe { dequeue_run_core(core as i32) };
    if next.is_null() {
        unsafe { house_sched_lock_release() };
        unsafe { core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags)) };
        unsafe { core::arch::asm!("wfe", options(nostack, preserves_flags)) };
        unsafe { core::arch::asm!("msr daifset, #2", options(nostack, preserves_flags)) };
        unsafe { house_sched_lock_acquire() };
        next = unsafe { dequeue_run_core(core as i32) };
        if next.is_null() {
            unsafe { house_sched_lock_release() };
            unsafe { core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags)) };
            return;
        }
    }
    unsafe { (*next).state = HOUSE_THR_RUNNING };
    unsafe { house_current_thr[core as usize] = next };
    unsafe { house_sched_lock_release() };
    unsafe { core::arch::asm!("msr daifset, #2", options(nostack, preserves_flags)) };
    if !old.is_null() {
        unsafe { house_thread_switch(old, next) };
    }
    unsafe { core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags)) };
}

#[no_mangle]
pub unsafe extern "C" fn house_sched_yield() {
    let core = unsafe { cpu_id() } as i32;
    unsafe { core::arch::asm!("msr daifset, #2", options(nostack, preserves_flags)) };
    // SPIN until trylock succeeds, with DAIF cleared + yield per tinylibc/threads.c
    loop {
        let mut tmp: u32 = 0;
        let mut res: u32 = 0;
        let mut locked: u32 = 0;
        unsafe {
            core::arch::asm!(
                "ldaxr {tmp:w}, [{ptr}]",
                "cbnz {tmp:w}, 2f",
                "mov {res:w}, #1",
                "stxr {tmp:w}, {res:w}, [{ptr}]",
                "cbnz {tmp:w}, 2f",
                "dmb sy",
                "mov {out:w}, #1",
                "b 3f",
                "2: mov {out:w}, #0",
                "3:",
                ptr = in(reg) &raw mut sched_lock as *mut u32,
                tmp = out(reg) tmp,
                res = out(reg) res,
                out = out(reg) locked,
                options(nostack),
            );
        }
        if locked != 0 {
            break;
        }
        unsafe {
            core::arch::asm!(
                "msr daifclr, #2; isb; yield; msr daifset, #2",
                options(nostack, preserves_flags)
            )
        };
    }
    let old = unsafe { house_current_thr[core as usize] };
    if old.is_null() {
        unsafe {
            core::arch::asm!("dmb sy", options(nostack, preserves_flags));
            core::arch::asm!("stlr wzr, [{ptr}]", ptr = in(reg) &raw mut sched_lock as *mut u32, options(nostack, preserves_flags));
            core::arch::asm!("dmb sy", options(nostack, preserves_flags));
            core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags));
        };
        return;
    }
    let old_state = unsafe { (*old).state };
    if old_state == HOUSE_THR_RUNNING {
        unsafe { (*old).state = HOUSE_THR_RUNNABLE };
        unsafe { enqueue_run_core(core, old) };
    } else if old_state == HOUSE_THR_RUNNABLE {
        // SAFETY: under sched_lock; spin-exit may have left old queued already.
        if !unsafe { queued_anywhere(old) } {
            unsafe { enqueue_run_core(core, old) };
        }
    }
    let mut next = unsafe { dequeue_run_core(core) };
    if next.is_null() {
        if old_state == HOUSE_THR_RUNNABLE {
            next = unsafe { dequeue_run_core(core) };
            if next.is_null() {
                next = old;
            }
        } else {
            unsafe {
                core::arch::asm!("dmb sy", options(nostack, preserves_flags));
                core::arch::asm!("stlr wzr, [{ptr}]", ptr = in(reg) &raw mut sched_lock as *mut u32, options(nostack, preserves_flags));
                core::arch::asm!("dmb sy", options(nostack, preserves_flags));
                core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags));
            };
            return;
        }
    }
    if next == old {
        unsafe { (*old).state = HOUSE_THR_RUNNING };
        unsafe {
            core::arch::asm!("dmb sy", options(nostack, preserves_flags));
            core::arch::asm!("stlr wzr, [{ptr}]", ptr = in(reg) &raw mut sched_lock as *mut u32, options(nostack, preserves_flags));
            core::arch::asm!("dmb sy", options(nostack, preserves_flags));
            core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags));
        };
        return;
    }
    unsafe { (*next).state = HOUSE_THR_RUNNING };
    unsafe { house_current_thr[core as usize] = next };
    unsafe {
        core::arch::asm!("dmb sy", options(nostack, preserves_flags));
        core::arch::asm!("stlr wzr, [{ptr}]", ptr = in(reg) &raw mut sched_lock as *mut u32, options(nostack, preserves_flags));
        core::arch::asm!("dmb sy", options(nostack, preserves_flags));
        core::arch::asm!("msr daifclr, #2", options(nostack, preserves_flags));
    };
    unsafe { house_thread_switch(old, next) };
}

#[no_mangle]
pub unsafe extern "C" fn house_tls_alloc() -> *mut u8 {
    extern "C" {
        fn buddy_alloc_page() -> *mut u8;
    }
    let p = unsafe { buddy_alloc_page() as *mut u8 };
    if !p.is_null() {
        unsafe { core::ptr::write_bytes(p, 0, 32) };
        return p;
    }
    let p = unsafe { malloc(32) };
    if p.is_null() {
        return core::ptr::null_mut();
    }
    unsafe { core::ptr::write_bytes(p, 0, 32) };
    p
}

// -- pthread stubs kept minimal --
#[no_mangle]
pub unsafe extern "C" fn pthread_create(
    thr: *mut u64,
    _a: *const u8,
    start: *mut u8,
    arg: *mut u8,
) -> i32 {
    if thr.is_null() {
        return 22;
    }
    // Allocate stack/tcb outside sched_lock to avoid holding two locks (sched->alloc)
    let stack = unsafe { malloc(HOUSE_THREAD_STACK_BYTES as usize) };
    if stack.is_null() {
        return 12;
    }
    let tcb = unsafe { house_tls_alloc() };
    if tcb.is_null() {
        unsafe { free(stack) };
        return 12;
    }
    unsafe { house_sched_lock_acquire() };
    let t = unsafe { alloc_thread() };
    if t.is_null() {
        unsafe { house_sched_lock_release() };
        unsafe { free(stack) };
        unsafe { free(tcb) };
        return 11;
    }
    let tid = unsafe {
        let v = NEXT_TID;
        NEXT_TID += 1;
        v
    };
    unsafe {
        (*t).tid = tid;
        (*t).start = start;
        (*t).arg = arg;
        (*t).retval = core::ptr::null_mut();
        (*t).detached = 0;
        (*t).exited = 0;
        (*t).stack_base = stack;
        (*t).stack_size = HOUSE_THREAD_STACK_BYTES;
        (*t).tcb = tcb;
        (*t).tpidr = tcb as u64;
        (*t).errno_val = 0;
        (*t).wake_ns = 0;
        (*t).wait_next = core::ptr::null_mut();
        (*t).joiner = core::ptr::null_mut();
        (*t).next = core::ptr::null_mut();
        let smp = core::ptr::read_volatile(&raw const house_smp_n);
        let smp = if smp <= 0 { 2 } else { smp };
        let mut target = if tid < 10 {
            0
        } else {
            let mut tgt = tid % smp;
            if tgt < 0 {
                tgt = 0;
            }
            if tgt >= smp {
                tgt = 0;
            }
            tgt as i32
        };
        // New tasks inherit the live mask: never park on an offline core.
        let mask = live_mask();
        if mask != 0 {
            let bit = 1u32.checked_shl(target as u32).unwrap_or(0);
            if bit == 0 || mask & bit == 0 {
                target = first_online(mask);
            }
        }
        (*t).affinity = 1u32.checked_shl(target as u32).unwrap_or(1);
        // SAFETY: memset sigmask 0 like C memset(&t->sigmask,0,sizeof...)
        (*t).sigmask = [0; 2];
        let top = (stack as usize + HOUSE_THREAD_STACK_BYTES) & !15;
        let top = top - 160;
        let sp = top as *mut u64;
        for i in 0..20 {
            *sp.add(i) = 0;
        }
        *sp.add(9) = house_thread_trampoline as *const () as usize as u64;
        (*t).sp = top as *mut u8;
        (*t).state = HOUSE_THR_RUNNABLE;
        enqueue_run_core(target, t);
        *thr = tid as u64;
        let cur = cpu_id() as i32;
        let need_kick = target != cur;
        house_sched_lock_release();
        if need_kick {
            house_sched_kick(target);
        }
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn house_thread_trampoline() {
    let core = cpu_id() as usize;
    let thr = if core < HOUSE_MAX_SMP {
        house_current_thr[core]
    } else {
        core::ptr::null_mut()
    };
    if thr.is_null() {
        loop {
            unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) }
        }
    }
    let start = unsafe { (*thr).start };
    let arg = unsafe { (*thr).arg };
    let ret = if !start.is_null() {
        let f: unsafe extern "C" fn(*mut u8) -> *mut u8 = unsafe { core::mem::transmute(start) };
        unsafe { f(arg) }
    } else {
        core::ptr::null_mut()
    };
    unsafe { pthread_exit(ret) };
}

#[no_mangle]
pub unsafe extern "C" fn pthread_join(t: u64, r: *mut *mut u8) -> i32 {
    let mut target: *mut HouseThread = core::ptr::null_mut();
    for i in 0..HOUSE_MAX_THREADS {
        let thr = unsafe { &mut THREADS[i] as *mut HouseThread };
        unsafe {
            if (*thr).tid == t as i32 && (*thr).state != HOUSE_THR_UNUSED {
                target = thr;
                break;
            }
        }
    }
    if target.is_null() {
        return 3;
    }
    let detached = unsafe { (*target).detached };
    if detached != 0 {
        return 22;
    }
    loop {
        let exited = unsafe { (*target).exited };
        if exited != 0 {
            break;
        }
        unsafe { house_sched_lock_acquire() };
        let exited2 = unsafe { (*target).exited };
        if exited2 != 0 {
            unsafe { house_sched_lock_release() };
            break;
        }
        let cur = unsafe { house_thread_current() };
        if cur.is_null() {
            unsafe { house_sched_lock_release() };
            unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) };
            continue;
        }
        unsafe { (*cur).state = HOUSE_THR_BLOCKED };
        unsafe { (*target).joiner = cur };
        let core = unsafe { cpu_id() } as usize;
        let old = cur;
        let next = unsafe { dequeue_run_core(core as i32) };
        if next.is_null() {
            unsafe { house_sched_lock_release() };
            unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) };
            // the exiter may itself be queued behind us
            unsafe { house_sched_yield() };
            continue;
        }
        unsafe { (*next).state = HOUSE_THR_RUNNING };
        unsafe { house_current_thr[core] = next };
        unsafe { house_sched_lock_release() };
        unsafe { house_thread_switch(old, next) };
    }
    if !r.is_null() {
        unsafe { *r = (*target).retval };
    }
    unsafe { house_sched_lock_acquire() };
    let stack = unsafe { (*target).stack_base };
    let tcb = unsafe { (*target).tcb };
    if !stack.is_null() {
        unsafe { free(stack) };
    }
    if !tcb.is_null() {
        unsafe { free(tcb) };
    }
    unsafe { (*target).state = HOUSE_THR_UNUSED };
    unsafe { (*target).tid = 0 };
    unsafe { house_sched_lock_release() };
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_detach(t: u64) -> i32 {
    unsafe { house_sched_lock_acquire() };
    for i in 0..HOUSE_MAX_THREADS {
        let thr = unsafe { &mut THREADS[i] as *mut HouseThread };
        unsafe {
            if (*thr).tid == t as i32 {
                (*thr).detached = 1;
                if (*thr).exited != 0 && (*thr).state != HOUSE_THR_UNUSED {
                    let stack = (*thr).stack_base;
                    let tcb = (*thr).tcb;
                    if !stack.is_null() {
                        free(stack);
                    }
                    if !tcb.is_null() {
                        free(tcb);
                    }
                    (*thr).state = HOUSE_THR_UNUSED;
                }
                house_sched_lock_release();
                return 0;
            }
        }
    }
    unsafe { house_sched_lock_release() };
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_exit(r: *mut u8) -> ! {
    let core = cpu_id() as usize;
    let cur = house_current_thr[core];
    if !cur.is_null() {
        unsafe { (*cur).retval = r };
        unsafe { (*cur).exited = 1 };
        unsafe { (*cur).state = 4 }; // EXITED
                                     // SAFETY: scheduler mutations below need sched_lock like C pthread_exit.
        unsafe { house_sched_lock_acquire() };
        // handle joiner
        let joiner = unsafe { (*cur).joiner };
        if !joiner.is_null() {
            unsafe { (*cur).joiner = core::ptr::null_mut() };
            let target = unsafe { (*joiner).affinity } as i32;
            let target = if target == 0 {
                0
            } else {
                target.trailing_zeros() as i32
            };
            unsafe { enqueue_run(joiner) };
            let cur_core = cpu_id() as i32;
            if target != cur_core {
                unsafe { house_sched_kick(target) };
            }
        }
        if unsafe { (*cur).detached } != 0 {
            let stack = unsafe { (*cur).stack_base };
            let tcb = unsafe { (*cur).tcb };
            if !stack.is_null() {
                unsafe { free(stack) };
            }
            if !tcb.is_null() {
                unsafe { free(tcb) };
            }
            unsafe { (*cur).state = HOUSE_THR_UNUSED };
        }
        let next = unsafe { dequeue_run_core(core as i32) };
        if next.is_null() {
            unsafe { house_sched_lock_release() };
            loop {
                unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) }
            }
        }
        unsafe { (*next).state = HOUSE_THR_RUNNING };
        unsafe { house_current_thr[core] = next };
        unsafe { house_sched_lock_release() };
        let old = cur;
        if !old.is_null() {
            unsafe { house_thread_switch(old, next) };
        }
        loop {
            unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) }
        }
    }
    let next = unsafe { dequeue_run_core(core as i32) };
    if next.is_null() {
        loop {
            unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) }
        }
    }
    unsafe { (*next).state = HOUSE_THR_RUNNING };
    unsafe { house_current_thr[core] = next };
    let old = cur;
    if !old.is_null() {
        unsafe { house_thread_switch(old, next) };
    }
    loop {
        unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) }
    }
}
#[no_mangle]
pub unsafe extern "C" fn pthread_self() -> u64 {
    let cur = unsafe { house_thread_current() };
    if cur.is_null() {
        1
    } else {
        unsafe { (*cur).tid as u64 }
    }
}
#[no_mangle]
pub unsafe extern "C" fn pthread_kill(_t: u64, _s: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_setname_np(_t: u64, _n: *const u8) -> i32 {
    0
}
#[repr(C)]
struct HouseMutex {
    locked: i32,
    owner: *mut HouseThread,
    wait_head: *mut HouseThread,
    wait_tail: *mut HouseThread,
}
#[repr(C)]
struct HouseCond {
    wait_head: *mut HouseThread,
    wait_tail: *mut HouseThread,
}

#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_init(m: *mut u8, _a: *const u8) -> i32 {
    // SAFETY: m points to HouseMutex per caller
    if m.is_null() {
        return 22;
    }
    let mu = m as *mut HouseMutex;
    unsafe {
        (*mu).locked = 0;
        (*mu).owner = core::ptr::null_mut();
        (*mu).wait_head = core::ptr::null_mut();
        (*mu).wait_tail = core::ptr::null_mut();
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_destroy(_m: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_lock(m: *mut u8) -> i32 {
    // SAFETY: spin_lock with dmb sy, queue wait_next + SGI0 kick mirrors tinylibc/threads.c
    if m.is_null() {
        return 22;
    }
    let mu = m as *mut HouseMutex;
    loop {
        unsafe {
            house_sched_lock_acquire();
        }
        let locked = unsafe { (*mu).locked };
        if locked == 0 {
            unsafe {
                (*mu).locked = 1;
                (*mu).owner = house_thread_current();
                house_sched_lock_release();
            }
            return 0;
        }
        let cur = unsafe { house_thread_current() };
        if cur.is_null() {
            unsafe {
                house_sched_lock_release();
            }
            return 22;
        }
        unsafe {
            (*cur).state = HOUSE_THR_BLOCKED;
            (*cur).wait_next = core::ptr::null_mut();
        }
        unsafe {
            if !(*mu).wait_tail.is_null() {
                (*(*mu).wait_tail).wait_next = cur;
            } else {
                (*mu).wait_head = cur;
            }
            (*mu).wait_tail = cur;
            house_sched_lock_release();
            house_sched_block();
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_trylock(m: *mut u8) -> i32 {
    if m.is_null() {
        return 22;
    }
    let mu = m as *mut HouseMutex;
    unsafe {
        house_sched_lock_acquire();
    }
    let locked = unsafe { (*mu).locked };
    if locked == 0 {
        unsafe {
            (*mu).locked = 1;
            (*mu).owner = house_thread_current();
            house_sched_lock_release();
        }
        0
    } else {
        unsafe {
            house_sched_lock_release();
        }
        16
    }
}
#[no_mangle]
pub unsafe extern "C" fn pthread_mutex_unlock(m: *mut u8) -> i32 {
    if m.is_null() {
        return 22;
    }
    let mu = m as *mut HouseMutex;
    unsafe {
        house_sched_lock_acquire();
    }
    unsafe {
        (*mu).locked = 0;
        (*mu).owner = core::ptr::null_mut();
    }
    let w = unsafe { (*mu).wait_head };
    if !w.is_null() {
        unsafe {
            (*mu).wait_head = (*w).wait_next;
            if (*mu).wait_head.is_null() {
                (*mu).wait_tail = core::ptr::null_mut();
            }
            (*w).wait_next = core::ptr::null_mut();
            (*w).state = HOUSE_THR_RUNNABLE;
            let aff = (*w).affinity;
            let target = if aff != 0 {
                aff.trailing_zeros() as i32
            } else {
                0
            };
            let smp = core::ptr::read_volatile(&raw const house_smp_n);
            let t = if target >= smp { 0 } else { target };
            enqueue_run_core(t, w);
            let cur = cpu_id() as i32;
            if t != cur {
                house_sched_kick(t);
            }
        }
    }
    unsafe {
        house_sched_lock_release();
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_init(c: *mut u8, _a: *const u8) -> i32 {
    if c.is_null() {
        return 22;
    }
    let cond = c as *mut HouseCond;
    unsafe {
        (*cond).wait_head = core::ptr::null_mut();
        (*cond).wait_tail = core::ptr::null_mut();
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_destroy(_c: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_signal(c: *mut u8) -> i32 {
    if c.is_null() {
        return 22;
    }
    let cond = c as *mut HouseCond;
    unsafe {
        house_sched_lock_acquire();
    }
    let w = unsafe { (*cond).wait_head };
    if !w.is_null() {
        unsafe {
            (*cond).wait_head = (*w).wait_next;
            if (*cond).wait_head.is_null() {
                (*cond).wait_tail = core::ptr::null_mut();
            }
            (*w).wait_next = core::ptr::null_mut();
            (*w).state = HOUSE_THR_RUNNABLE;
            let aff = (*w).affinity;
            let target = if aff != 0 {
                aff.trailing_zeros() as i32
            } else {
                0
            };
            let smp = core::ptr::read_volatile(&raw const house_smp_n);
            let t = if target >= smp { 0 } else { target };
            enqueue_run_core(t, w);
            if (cpu_id() as i32) != t {
                house_sched_kick(t);
            }
        }
    }
    unsafe {
        house_sched_lock_release();
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_broadcast(c: *mut u8) -> i32 {
    if c.is_null() {
        return 22;
    }
    let cond = c as *mut HouseCond;
    unsafe {
        house_sched_lock_acquire();
    }
    while unsafe { !(*cond).wait_head.is_null() } {
        let w = unsafe { (*cond).wait_head };
        unsafe {
            (*cond).wait_head = (*w).wait_next;
            (*w).wait_next = core::ptr::null_mut();
            (*w).state = HOUSE_THR_RUNNABLE;
            let aff = (*w).affinity;
            let target = if aff != 0 {
                aff.trailing_zeros() as i32
            } else {
                0
            };
            let smp = core::ptr::read_volatile(&raw const house_smp_n);
            let t = if target >= smp { 0 } else { target };
            enqueue_run_core(t, w);
            if (cpu_id() as i32) != t {
                house_sched_kick(t);
            }
        }
    }
    unsafe {
        (*cond).wait_tail = core::ptr::null_mut();
        house_sched_lock_release();
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_wait(c: *mut u8, m: *mut u8) -> i32 {
    // SAFETY: mirrors tinylibc/threads.c pthread_cond_wait with mutex handoff and queue
    if c.is_null() || m.is_null() {
        return 22;
    }
    let cond = c as *mut HouseCond;
    let mu = m as *mut HouseMutex;
    unsafe {
        house_sched_lock_acquire();
    }
    let cur = unsafe { house_thread_current() };
    if cur.is_null() {
        unsafe {
            house_sched_lock_release();
        }
        return 22;
    }
    unsafe {
        (*cur).state = HOUSE_THR_BLOCKED;
        (*cur).wait_next = core::ptr::null_mut();
    }
    unsafe {
        if !(*cond).wait_tail.is_null() {
            (*(*cond).wait_tail).wait_next = cur;
        } else {
            (*cond).wait_head = cur;
        }
        (*cond).wait_tail = cur;
        (*mu).locked = 0;
        (*mu).owner = core::ptr::null_mut();
        // wake one mutex waiter if any
        let mw = (*mu).wait_head;
        if !mw.is_null() {
            (*mu).wait_head = (*mw).wait_next;
            if (*mu).wait_head.is_null() {
                (*mu).wait_tail = core::ptr::null_mut();
            }
            (*mw).wait_next = core::ptr::null_mut();
            (*mw).state = HOUSE_THR_RUNNABLE;
            let aff = (*mw).affinity;
            let target = if aff != 0 {
                aff.trailing_zeros() as i32
            } else {
                0
            };
            let smp = core::ptr::read_volatile(&raw const house_smp_n);
            let t = if target >= smp { 0 } else { target };
            enqueue_run_core(t, mw);
            if (cpu_id() as i32) != t {
                house_sched_kick(t);
            }
        }
        let core_id = cpu_id();
        let old = cur;
        let next = dequeue_run_core(core_id as i32);
        if next.is_null() {
            house_sched_lock_release();
            // spin until signaled; run locally queued work (e.g. the
            // signaler) on each wakeup so it cannot stall behind us.
            while (*cur).state == HOUSE_THR_BLOCKED {
                core::arch::asm!("wfi", options(nostack, preserves_flags));
                if (*cur).state == HOUSE_THR_BLOCKED {
                    house_sched_yield();
                }
            }
            house_sched_lock_acquire();
        } else {
            (*next).state = HOUSE_THR_RUNNING;
            house_current_thr[core_id as usize] = next;
            house_sched_lock_release();
            house_thread_switch(old, next);
            house_sched_lock_acquire();
        }
        // reacquire mutex
        while (*mu).locked != 0 {
            (*cur).state = HOUSE_THR_BLOCKED;
            (*cur).wait_next = core::ptr::null_mut();
            if !(*mu).wait_tail.is_null() {
                (*(*mu).wait_tail).wait_next = cur;
            } else {
                (*mu).wait_head = cur;
            }
            (*mu).wait_tail = cur;
            let old2 = cur;
            let c2 = cpu_id();
            let n2 = dequeue_run_core(c2 as i32);
            if n2.is_null() {
                house_sched_lock_release();
                core::arch::asm!("wfi", options(nostack, preserves_flags));
                // who holds the mutex may itself be queued behind us
                house_sched_yield();
                house_sched_lock_acquire();
                continue;
            }
            (*n2).state = HOUSE_THR_RUNNING;
            house_current_thr[c2 as usize] = n2;
            house_sched_lock_release();
            house_thread_switch(old2, n2);
            house_sched_lock_acquire();
        }
        (*mu).locked = 1;
        (*mu).owner = house_thread_current();
        house_sched_lock_release();
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_cond_timedwait(c: *mut u8, m: *mut u8, t: *const u8) -> i32 {
    if t.is_null() {
        return unsafe { pthread_cond_wait(c, m) };
    }
    let abs_secs = unsafe { *(t as *const i64).add(0) } as u64;
    let abs_nsec = unsafe { *(t as *const i64).add(1) } as u64;
    let abs_ns = abs_secs * 1000000000 + abs_nsec;
    let now = unsafe { house_uptime_ns() };
    // handle FAKE_EPOCH adjustment like C
    let mut abs_adj = abs_ns;
    if abs_secs > 1000000000 && abs_ns >= 1785000000u64 * 1000000000 {
        abs_adj -= 1785000000u64 * 1000000000;
    }
    if abs_adj <= now {
        return 110;
    } // ETIMEDOUT
      // enqueue with timeout and block, checking wake
    let cond = c as *mut HouseCond;
    let mu = m as *mut HouseMutex;
    unsafe {
        house_sched_lock_acquire();
    }
    let cur = unsafe { house_thread_current() };
    if cur.is_null() {
        unsafe {
            house_sched_lock_release();
        }
        return 22;
    }
    unsafe {
        (*cur).wake_ns = abs_adj;
        (*cur).state = HOUSE_THR_BLOCKED;
        (*cur).wait_next = core::ptr::null_mut();
        if !(*cond).wait_tail.is_null() {
            (*(*cond).wait_tail).wait_next = cur;
        } else {
            (*cond).wait_head = cur;
        }
        (*cond).wait_tail = cur;
        (*mu).locked = 0;
        (*mu).owner = core::ptr::null_mut();
        let mw = (*mu).wait_head;
        if !mw.is_null() {
            (*mu).wait_head = (*mw).wait_next;
            if (*mu).wait_head.is_null() {
                (*mu).wait_tail = core::ptr::null_mut();
            }
            (*mw).wait_next = core::ptr::null_mut();
            (*mw).state = HOUSE_THR_RUNNABLE;
            let aff = (*mw).affinity;
            let target = if aff != 0 {
                aff.trailing_zeros() as i32
            } else {
                0
            };
            let smp = core::ptr::read_volatile(&raw const house_smp_n);
            let t2 = if target >= smp { 0 } else { target };
            enqueue_run_core(t2, mw);
            if (cpu_id() as i32) != t2 {
                house_sched_kick(t2);
            }
        }
        let core_id = cpu_id();
        let old = cur;
        let next = dequeue_run_core(core_id as i32);
        if next.is_null() {
            house_sched_lock_release();
            // busy-wait with timeout check like C wfi loop
            loop {
                let now2 = house_uptime_ns();
                if now2 >= abs_adj {
                    house_sched_lock_acquire();
                    // remove from cond queue if still queued
                    let mut prev: *mut HouseThread = core::ptr::null_mut();
                    let mut it = (*cond).wait_head;
                    while !it.is_null() {
                        if it == cur {
                            if prev.is_null() {
                                (*cond).wait_head = (*it).wait_next;
                            } else {
                                (*prev).wait_next = (*it).wait_next;
                            }
                            if (*cond).wait_tail == it {
                                (*cond).wait_tail = prev;
                            }
                            (*it).wait_next = core::ptr::null_mut();
                            if (*it).state == HOUSE_THR_BLOCKED {
                                (*it).state = HOUSE_THR_RUNNABLE;
                            }
                            break;
                        }
                        prev = it;
                        it = (*it).wait_next;
                    }
                    if (*cur).state == HOUSE_THR_BLOCKED {
                        (*cur).state = HOUSE_THR_RUNNABLE;
                        (*cur).wake_ns = 0;
                    }
                    house_sched_lock_release();
                    break;
                }
                if (*cur).state != HOUSE_THR_BLOCKED {
                    break;
                }
                core::arch::asm!("wfi", options(nostack, preserves_flags));
                // run locally queued work while waiting; it may signal us
                if (*cur).state == HOUSE_THR_BLOCKED {
                    house_sched_yield();
                }
            }
            house_sched_lock_acquire();
        } else {
            (*next).state = HOUSE_THR_RUNNING;
            house_current_thr[core_id as usize] = next;
            house_sched_lock_release();
            house_thread_switch(old, next);
            house_sched_lock_acquire();
            (*cur).wake_ns = 0;
        }
        // reacquire mutex same as wait
        while (*mu).locked != 0 {
            (*cur).state = HOUSE_THR_BLOCKED;
            (*cur).wait_next = core::ptr::null_mut();
            if !(*mu).wait_tail.is_null() {
                (*(*mu).wait_tail).wait_next = cur;
            } else {
                (*mu).wait_head = cur;
            }
            (*mu).wait_tail = cur;
            let old2 = cur;
            let c2 = cpu_id();
            let n2 = dequeue_run_core(c2 as i32);
            if n2.is_null() {
                house_sched_lock_release();
                core::arch::asm!("wfi", options(nostack, preserves_flags));
                // who holds the mutex may itself be queued behind us
                house_sched_yield();
                house_sched_lock_acquire();
                continue;
            }
            (*n2).state = HOUSE_THR_RUNNING;
            house_current_thr[c2 as usize] = n2;
            house_sched_lock_release();
            house_thread_switch(old2, n2);
            house_sched_lock_acquire();
        }
        (*mu).locked = 1;
        (*mu).owner = house_thread_current();
        let timed_out = house_uptime_ns() >= abs_adj;
        house_sched_lock_release();
        if timed_out {
            110
        } else {
            0
        }
    }
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
    // SAFETY: reports the live online mask, not (1<<SMP_N)-1.
    if !_m.is_null() && _sz >= 8 {
        let m = unsafe { live_mask() } as u64;
        unsafe { *(_m as *mut u64) = m };
        if _sz > 8 {
            unsafe { core::ptr::write_bytes(_m.add(8), 0, _sz - 8) };
        }
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_setaffinity_np(_t: u64, _sz: usize, _m: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_getaffinity_np(_t: u64, _sz: usize, _m: *mut u8) -> i32 {
    // SAFETY: live online mask like sched_getaffinity.
    if !_m.is_null() && _sz >= 8 {
        let m = unsafe { live_mask() } as u64;
        unsafe { *(_m as *mut u64) = m };
        if _sz > 8 {
            unsafe { core::ptr::write_bytes(_m.add(8), 0, _sz - 8) };
        }
    }
    0
}

/// Migrate `core`'s run queue to the first online core (hotplug down path).
///
/// # Safety
/// Call after the mask bit is cleared, with the target core OFF so its
/// queue is quiescent; takes `sched_lock`.
#[no_mangle]
pub unsafe extern "C" fn house_threads_on_core_down(core: u32) {
    if (core as usize) >= HOUSE_MAX_SMP || core == 0 {
        return;
    }
    unsafe { house_sched_lock_acquire() };
    let mask = unsafe { live_mask() };
    let dst = unsafe { first_online(mask) };
    let dst = if dst < 0 { 0 } else { dst };
    unsafe {
        let mut cur = RUN_HEAD[core as usize];
        RUN_HEAD[core as usize] = core::ptr::null_mut();
        RUN_TAIL[core as usize] = core::ptr::null_mut();
        house_current_thr[core as usize] = core::ptr::null_mut();
        while !cur.is_null() {
            let nxt = (*cur).next;
            (*cur).next = core::ptr::null_mut();
            (*cur).state = HOUSE_THR_RUNNABLE;
            let bit = 1u32.checked_shl(dst as u32).unwrap_or(1);
            (*cur).affinity = bit;
            if !RUN_TAIL[dst as usize].is_null() {
                (*RUN_TAIL[dst as usize]).next = cur;
            } else {
                RUN_HEAD[dst as usize] = cur;
            }
            RUN_TAIL[dst as usize] = cur;
            cur = nxt;
        }
        house_sched_lock_release();
        house_sched_kick(dst);
    }
}
#[no_mangle]
pub unsafe extern "C" fn sched_yield() -> i32 {
    unsafe { house_sched_yield() };
    0
}
#[no_mangle]
pub unsafe extern "C" fn sched_getaffinity(_p: i32, _s: usize, _m: *mut u8) -> i32 {
    if !_m.is_null() && _s >= 8 {
        let m = unsafe { live_mask() } as u64;
        unsafe { *(_m as *mut u64) = m };
        if _s > 8 {
            unsafe { core::ptr::write_bytes(_m.add(8), 0, _s - 8) };
        }
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn sched_setaffinity(_p: i32, _s: usize, _m: *const u8) -> i32 {
    if !_m.is_null() {
        let cur = unsafe { house_thread_current() };
        if !cur.is_null() {
            unsafe { (*cur).affinity = *(_m as *const u32) }
        };
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn pthread_sigmask(_h: i32, _s: *const u8, _o: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn nanosleep(rq: *const u8, rm: *mut u8) -> i32 {
    if rq.is_null() {
        return 0;
    }
    let ns = unsafe { *(rq as *const u64).add(0) * 1000000000 + *(rq as *const u64).add(1) };
    // Actually timespec is tv_sec, tv_nsec as i64
    let secs = unsafe { *(rq as *const i64).add(0) } as u64;
    let nsec = unsafe { *(rq as *const i64).add(1) } as u64;
    let total = secs * 1000000000 + nsec;
    if total == 0 {
        unsafe { house_sched_yield() };
        return 0;
    }
    let until = unsafe { house_uptime_ns() } + total;
    let core = unsafe { cpu_id() } as usize;
    unsafe { house_sched_lock_acquire() };
    let cur = unsafe { house_current_thr[core] };
    if cur.is_null() {
        unsafe { house_sched_lock_release() };
        unsafe { house_sched_yield() };
        return 0;
    }
    unsafe {
        (*cur).wake_ns = until;
        (*cur).state = HOUSE_THR_BLOCKED
    };
    let next = unsafe { dequeue_run_core(core as i32) };
    if next.is_null() {
        unsafe { house_sched_lock_release() };
        while unsafe { house_uptime_ns() } < until {
            unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) }
        }
        unsafe { house_sched_lock_acquire() };
        let c = unsafe { house_current_thr[core] };
        if !c.is_null() {
            unsafe {
                (*c).wake_ns = 0;
                (*c).state = HOUSE_THR_RUNNING
            };
        }
        unsafe { house_sched_lock_release() };
        return 0;
    }
    unsafe { (*next).state = HOUSE_THR_RUNNING };
    unsafe { house_current_thr[core] = next };
    let old = cur;
    unsafe { house_sched_lock_release() };
    unsafe { house_thread_switch(old, next) };
    while unsafe { house_uptime_ns() } < until {
        let rem = until - unsafe { house_uptime_ns() };
        let secs = rem / 1000000000;
        let nsec = rem % 1000000000;
        let mut tmp = [secs as i64, nsec as i64];
        let r = unsafe { nanosleep(tmp.as_ptr() as *const u8, rm) };
        if r != 0 {
            return r;
        }
        break;
    }
    if !rm.is_null() {
        unsafe {
            *(rm as *mut i64).add(0) = 0;
            *(rm as *mut i64).add(1) = 0
        };
    }
    0
}
#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}
#[no_mangle]
pub unsafe extern "C" fn poll(fds: *mut u8, nfds: u64, timeout: i32) -> i32 {
    if fds.is_null() {
        return 0;
    }
    let pfds = fds as *mut PollFd;
    for i in 0..nfds as usize {
        unsafe { (*pfds.add(i)).revents = 0 };
        let fd = unsafe { (*pfds.add(i)).fd };
        let ev = unsafe { (*pfds.add(i)).events };
        if (ev & 0x0001) != 0 {
            let ready = unsafe { house_timerfd_due(fd) != 0 || house_fd_pipe_readable(fd) != 0 };
            if ready {
                unsafe { (*pfds.add(i)).revents |= 0x0001 }
            };
        }
    }
    let mut ready = 0;
    for i in 0..nfds as usize {
        if unsafe { (*pfds.add(i)).revents } != 0 {
            ready += 1;
        }
    }
    if ready != 0 {
        return ready;
    }
    if timeout == 0 {
        return 0;
    }
    let core = unsafe { cpu_id() } as usize;
    let has_runnable = unsafe {
        house_sched_lock_acquire();
        let h = !RUN_HEAD[core].is_null();
        house_sched_lock_release();
        h
    };
    if has_runnable {
        unsafe { house_sched_yield() };
    } else {
        let start = unsafe { house_uptime_ns() };
        let timeout_ns = if timeout < 0 {
            u64::MAX
        } else {
            timeout as u64 * 1000000
        };
        loop {
            unsafe { core::arch::asm!("wfe", options(nostack, preserves_flags)) };
            let mut r = 0;
            for i in 0..nfds as usize {
                let fd = unsafe { (*pfds.add(i)).fd };
                let ev = unsafe { (*pfds.add(i)).events };
                if (ev & 0x0001) != 0 {
                    let ready =
                        unsafe { house_timerfd_due(fd) != 0 || house_fd_pipe_readable(fd) != 0 };
                    if ready {
                        unsafe { (*pfds.add(i)).revents |= 0x0001 };
                        r += 1;
                    }
                }
            }
            if r != 0 {
                return r;
            }
            if timeout > 0 && unsafe { house_uptime_ns() } - start >= timeout_ns {
                return 0;
            }
            if timeout == 0 {
                return 0;
            }
        }
    }
    let mut ready2 = 0;
    for i in 0..nfds as usize {
        unsafe { (*pfds.add(i)).revents = 0 };
        let fd = unsafe { (*pfds.add(i)).fd };
        let ev = unsafe { (*pfds.add(i)).events };
        if (ev & 0x0001) != 0 {
            let ready = unsafe { house_timerfd_due(fd) != 0 || house_fd_pipe_readable(fd) != 0 };
            if ready {
                unsafe { (*pfds.add(i)).revents |= 0x0001 };
                ready2 += 1;
            }
        }
    }
    ready2
}
#[no_mangle]
pub unsafe extern "C" fn select(
    nfds: i32,
    _r: *mut u8,
    _w: *mut u8,
    _e: *mut u8,
    tv: *mut u8,
) -> i32 {
    if tv.is_null() {
        unsafe { house_sched_yield() };
        return 0;
    }
    let secs = unsafe { *(tv as *const i64).add(0) } as u64;
    let usecs = unsafe { *(tv as *const i64).add(1) } as u64;
    let us = secs * 1000000 + usecs;
    if us == 0 {
        return 0;
    }
    let secs2 = us / 1000000;
    let nsec = (us % 1000000) * 1000;
    let mut ts = [secs2 as i64, nsec as i64];
    unsafe { nanosleep(ts.as_ptr() as *const u8, core::ptr::null_mut()) };
    unsafe {
        *(tv as *mut i64).add(0) = 0;
        *(tv as *mut i64).add(1) = 0
    };
    0
}
#[no_mangle]
pub unsafe extern "C" fn pause() -> i32 {
    let core = unsafe { cpu_id() } as usize;
    unsafe { house_sched_lock_acquire() };
    let cur = unsafe { house_current_thr[core] };
    if !cur.is_null() {
        unsafe { (*cur).state = HOUSE_THR_BLOCKED };
    }
    let next = unsafe { dequeue_run_core(core as i32) };
    if next.is_null() {
        unsafe { house_sched_lock_release() };
        loop {
            unsafe { core::arch::asm!("wfi", options(nostack, preserves_flags)) }
        }
    }
    unsafe { (*next).state = HOUSE_THR_RUNNING };
    unsafe { house_current_thr[core] = next };
    let old = cur;
    unsafe { house_sched_lock_release() };
    if !old.is_null() {
        unsafe { house_thread_switch(old, next) };
    }
    -1
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
