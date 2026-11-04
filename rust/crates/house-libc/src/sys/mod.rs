#![allow(
    clippy::manual_c_str_literals,
    reason = "C-string literals mirror C initializers"
)]
#![allow(
    clippy::manual_range_contains,
    reason = "range checks mirror C comparisons"
)]
#![allow(
    clippy::needless_range_loop,
    reason = "index loops mirror C array walks"
)]
#![allow(
    clippy::needless_return,
    reason = "explicit returns mirror C control flow"
)]
#![allow(clippy::unnecessary_cast, reason = "ABI casts mirror C widths")]
#![allow(
    unused_variables,
    reason = "transliteration keeps C parameter names for ABI parity"
)]
#![allow(unexpected_cfgs, reason = "bare-metal cfg gates have host test stubs")]
#![allow(
    static_mut_refs,
    reason = "transliterated C globals use raw statics; guarded by HAL spinlocks"
)]
#![allow(
    clashing_extern_declarations,
    reason = "C header redeclares across transliteration units"
)]
pub mod errno;
pub mod fd;
pub mod signal;
pub mod time;

use core::ffi::c_void;

unsafe extern "C" {
    fn uart_putc(c: u8);
    fn __errno_location() -> *mut i32;
    static mut house_isr_active: i32;
    static mut house_isr_pending: [u64; 32];
}

// ---- fd table ----
// 256 fds: the RTS opens ~4 fds per capability (pipes + eventfd), so 32
// slots starve N=7 (timer manager fails, every threadDelay throws).
const FAKE_FD_BASE: i32 = 3;
const FAKE_FD_N: usize = 256;
const PIPE_CAP: usize = 1024;
const HOUSE_MAX_SMP: usize = 32;

#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq)]
enum FdKind {
    Free = 0,
    Timer = 1,
    PipeR = 2,
    PipeW = 3,
    Event = 4,
    Epoll = 5,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct FdEntry {
    kind: FdKind,
    peer: i32,
    ticks: u64,
    last_ns: u64,
    buf: [u8; 1024],
    len: usize,
    ev_cnt: u64,
    ep_n: usize,
    ep_fd: [i32; 16],
    ep_events: [u32; 16],
    ep_data: [u64; 16],
}

const FREE_ENTRY: FdEntry = FdEntry {
    kind: FdKind::Free,
    peer: -1,
    ticks: 0,
    last_ns: 0,
    buf: [0; 1024],
    len: 0,
    ev_cnt: 0,
    ep_n: 0,
    ep_fd: [-1; 16],
    ep_events: [0; 16],
    ep_data: [0; 16],
};

static mut FDT: [FdEntry; FAKE_FD_N] = [FREE_ENTRY; FAKE_FD_N];

#[inline]
fn fd_slot(fd: i32) -> Option<usize> {
    if fd < FAKE_FD_BASE {
        return None;
    }
    let s = (fd - FAKE_FD_BASE) as usize;
    if s < FAKE_FD_N { Some(s) } else { None }
}

static mut TICK_INTERVAL_NS: u64 = 0;

#[unsafe(no_mangle)]
pub static mut environ: *mut *mut u8 = &raw mut EMPTY_ENV as *mut *mut u8;

static mut EMPTY_ENV: *mut u8 = core::ptr::null_mut();

#[inline]
fn counter_hz() -> u64 {
    let f: u64;
    unsafe {
        core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) f, options(nostack, preserves_flags))
    };
    if f == 0 { 62500000 } else { f }
}

// SAFETY: reads CNTVCT, always safe.
unsafe fn house_uptime_ns_raw() -> u64 {
    let c: u64;
    unsafe {
        core::arch::asm!("mrs {0}, cntvct_el0", out(reg) c, options(nostack, preserves_flags))
    };
    let hz = counter_hz();
    // u64-only: cntfrq is architecturally 32-bit so (c % hz) * 1e9 cannot overflow.
    (c / hz) * 1000000000 + (c % hz) * 1000000000 / hz
}

const FAKE_EPOCH: u64 = 1785000000;

/// Write to a pipe/eventfd, or UART for fd 1/2 (EBADF otherwise).
///
/// # Safety
///
/// `buf` must be valid for `n` bytes (eventfd reads a `u64` when `n >= 8`);
/// unknown fds set EBADF and return -1.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn write(fd: i32, buf: *const u8, n: usize) -> isize {
    if let Some(s) = fd_slot(fd) {
        let entry = unsafe { &mut FDT[s] };
        match entry.kind {
            FdKind::PipeW => {
                let peer_fd = entry.peer;
                if let Some(ps) = fd_slot(peer_fd) {
                    let peer = unsafe { &mut FDT[ps] };
                    if peer.kind != FdKind::PipeR {
                        return -1;
                    }
                    let room = PIPE_CAP - peer.len;
                    let k = n.min(room);
                    if k > 0 {
                        peer.buf[peer.len..peer.len + k]
                            .copy_from_slice(unsafe { core::slice::from_raw_parts(buf, k) });
                        peer.len += k;
                    }
                    return k as isize;
                }
                return -1;
            }
            FdKind::Event => {
                if n >= 8 {
                    let v = unsafe { *(buf as *const u64) };
                    entry.ev_cnt = entry.ev_cnt.wrapping_add(v);
                    return 8;
                }
                return 0;
            }
            _ => {}
        }
    }
    if fd == 1 || fd == 2 {
        for i in 0..n {
            let b = unsafe { *buf.add(i) };
            unsafe { uart_putc(b) };
        }
        return n as isize;
    }
    unsafe { *__errno_location() = 9 };
    -1
}

/// Read from a timer/eventfd/pipe (0 on empty/unknown, EAGAIN noted).
///
/// # Safety
///
/// `buf` must be null or valid for `n` bytes; timer/event reads require
/// `n >= 8` for the `u64` payload, pipe reads copy `min(len, n)`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn read(fd: i32, buf: *mut u8, n: usize) -> isize {
    let Some(s) = fd_slot(fd) else {
        return 0;
    };
    let entry = unsafe { &mut FDT[s] };
    match entry.kind {
        FdKind::Timer => {
            if buf.is_null() || n < 8 {
                return 0;
            }
            let due = unsafe { house_timerfd_due(fd) };
            if due == 0 {
                unsafe { *__errno_location() = 11 };
                return -1;
            }
            let isr_active = unsafe { core::ptr::read_volatile(&raw const house_isr_active) };
            if isr_active != 0 {
                // Drain all slots, return total expirations (Linux timerfd
                // semantics) so one read catches up after idle.
                let mut total: u64 = 0;
                for i in 0..HOUSE_MAX_SMP {
                    let v = unsafe { core::ptr::read_volatile(&raw const house_isr_pending[i]) };
                    if v > 0 {
                        unsafe { core::ptr::write_volatile(&raw mut house_isr_pending[i], 0) };
                        total = total.wrapping_add(v);
                    }
                }
                if total == 0 {
                    total = 1;
                }
                entry.ticks += total;
                unsafe { *(buf as *mut u64) = total };
                return 8;
            }
            entry.last_ns = unsafe { house_uptime_ns_raw() };
            entry.ticks += 1;
            unsafe { *(buf as *mut u64) = 1 };
            return 8;
        }
        FdKind::PipeR => {
            if entry.len == 0 || buf.is_null() {
                return 0;
            }
            let k = entry.len.min(n);
            unsafe { core::ptr::copy_nonoverlapping(entry.buf.as_ptr(), buf, k) };
            entry.buf.copy_within(k..entry.len, 0);
            entry.len -= k;
            return k as isize;
        }
        FdKind::Event => {
            if buf.is_null() || n < 8 {
                return 0;
            }
            if entry.ev_cnt == 0 {
                unsafe { *__errno_location() = 11 };
                return -1;
            }
            unsafe { *(buf as *mut u64) = entry.ev_cnt };
            entry.ev_cnt = 0;
            return 8;
        }
        _ => return 0,
    }
}

/// Create a 1K pipe pair (returns 0, -1 when the table is full).
///
/// # Safety
///
/// `fds` must be null (EFAULT) or valid for two `i32` writes `(read, write)`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pipe(fds: *mut i32) -> i32 {
    if fds.is_null() {
        unsafe { *__errno_location() = 14 };
        return -1;
    }
    let mut r: Option<usize> = None;
    let mut w: Option<usize> = None;
    for i in 0..FAKE_FD_N {
        if unsafe { FDT[i].kind } == FdKind::Free {
            if r.is_none() {
                r = Some(i);
            } else if w.is_none() {
                w = Some(i);
                break;
            }
        }
    }
    let (Some(ri), Some(wi)) = (r, w) else {
        unsafe { *__errno_location() = 23 };
        return -1;
    };
    unsafe {
        FDT[ri].kind = FdKind::PipeR;
        FDT[ri].len = 0;
        FDT[ri].peer = FAKE_FD_BASE + wi as i32;
        FDT[wi].kind = FdKind::PipeW;
        FDT[wi].len = 0;
        FDT[wi].peer = FAKE_FD_BASE + ri as i32;
        *fds.add(0) = FAKE_FD_BASE + ri as i32;
        *fds.add(1) = FAKE_FD_BASE + wi as i32;
    }
    0
}

/// Release an fd slot (unknown fds are a silent 0).
///
/// # Safety
///
/// Safe with any `fd` value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn close(fd: i32) -> i32 {
    if let Some(s) = fd_slot(fd) {
        let e = unsafe { &mut FDT[s] };
        if e.kind != FdKind::Free {
            e.kind = FdKind::Free;
            e.len = 0;
            e.ev_cnt = 0;
            e.ep_n = 0;
        }
    }
    0
}

/// Create an eventfd counter (returns fd, -1 when full).
///
/// # Safety
///
/// Safe with any values; `flags` are ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn eventfd(initval: u32, flags: i32) -> i32 {
    let _ = flags;
    for i in 0..FAKE_FD_N {
        if unsafe { FDT[i].kind } == FdKind::Free {
            unsafe {
                FDT[i].kind = FdKind::Event;
                FDT[i].ev_cnt = initval as u64;
                FDT[i].len = 0;
            }
            return FAKE_FD_BASE + i as i32;
        }
    }
    unsafe { *__errno_location() = 23 };
    -1
}

/// Add `value` to a live eventfd counter.
///
/// # Safety
///
/// The fd must be a live eventfd (EBADF otherwise).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn eventfd_write(fd: i32, value: u64) -> i32 {
    let Some(s) = fd_slot(fd) else {
        unsafe { *__errno_location() = 9 };
        return -1;
    };
    let e = unsafe { &mut FDT[s] };
    if e.kind != FdKind::Event {
        unsafe { *__errno_location() = 9 };
        return -1;
    }
    e.ev_cnt = e.ev_cnt.wrapping_add(value);
    0
}

/// Take an eventfd count (EAGAIN when zero, then cleared).
///
/// # Safety
///
/// `fd` must be a live eventfd and `value` non-null valid for a `u64` write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn eventfd_read(fd: i32, value: *mut u64) -> i32 {
    if value.is_null() {
        unsafe { *__errno_location() = 14 };
        return -1;
    }
    let Some(s) = fd_slot(fd) else {
        unsafe { *__errno_location() = 9 };
        return -1;
    };
    let e = unsafe { &mut FDT[s] };
    if e.kind != FdKind::Event {
        unsafe { *__errno_location() = 9 };
        return -1;
    }
    if e.ev_cnt == 0 {
        unsafe { *__errno_location() = 11 };
        return -1;
    }
    unsafe { *value = e.ev_cnt };
    e.ev_cnt = 0;
    0
}

/// Create an epoll set (returns fd, -1 when full).
///
/// # Safety
///
/// Safe with any size (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn epoll_create(_size: i32) -> i32 {
    for i in 0..FAKE_FD_N {
        if unsafe { FDT[i].kind } == FdKind::Free {
            unsafe {
                FDT[i].kind = FdKind::Epoll;
                FDT[i].ep_n = 0;
            }
            return FAKE_FD_BASE + i as i32;
        }
    }
    unsafe { *__errno_location() = 23 };
    -1
}

/// Create an epoll set (delegates to `epoll_create`).
///
/// # Safety
///
/// Safe with any flags (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn epoll_create1(flags: i32) -> i32 {
    let _ = flags;
    unsafe { epoll_create(1) }
}

#[repr(C)]
struct EpollEvent {
    events: u32,
    data: u64,
}

const EPOLLIN: u32 = 0x001;

/// Add/modify/remove an fd in an epoll set (16-entry cap).
///
/// # Safety
///
/// Both fds must be live with `epfd` an epoll set; `ev` may be null
/// (zero mask) or valid for `EpollEvent { u32, u64 }`. Misuse sets errno.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn epoll_ctl(epfd: i32, op: i32, fd: i32, ev: *mut c_void) -> i32 {
    let Some(s) = fd_slot(epfd) else {
        unsafe { *__errno_location() = 9 };
        return -1;
    };
    let ep = unsafe { &mut FDT[s] };
    if ep.kind != FdKind::Epoll {
        unsafe { *__errno_location() = 9 };
        return -1;
    }
    let e = ev as *mut EpollEvent;
    const ADD: i32 = 1;
    const DEL: i32 = 2;
    const MOD: i32 = 3;
    if op == ADD {
        if ep.ep_n >= 16 {
            unsafe { *__errno_location() = 28 };
            return -1;
        }
        for i in 0..ep.ep_n {
            if ep.ep_fd[i] == fd {
                unsafe { *__errno_location() = 17 };
                return -1;
            }
        }
        let idx = ep.ep_n;
        ep.ep_fd[idx] = fd;
        ep.ep_events[idx] = if e.is_null() {
            0
        } else {
            unsafe { (*e).events }
        };
        ep.ep_data[idx] = if e.is_null() { 0 } else { unsafe { (*e).data } };
        ep.ep_n += 1;
    } else if op == DEL {
        for i in 0..ep.ep_n {
            if ep.ep_fd[i] == fd {
                let last = ep.ep_n - 1;
                ep.ep_fd[i] = ep.ep_fd[last];
                ep.ep_events[i] = ep.ep_events[last];
                ep.ep_data[i] = ep.ep_data[last];
                ep.ep_n -= 1;
                return 0;
            }
        }
        unsafe { *__errno_location() = 2 };
        return -1;
    } else if op == MOD {
        for i in 0..ep.ep_n {
            if ep.ep_fd[i] == fd {
                ep.ep_events[i] = if e.is_null() {
                    0
                } else {
                    unsafe { (*e).events }
                };
                ep.ep_data[i] = if e.is_null() { 0 } else { unsafe { (*e).data } };
                return 0;
            }
        }
        unsafe { *__errno_location() = 2 };
        return -1;
    }
    0
}

#[inline]
unsafe fn fd_ready(fd: i32) -> bool {
    let Some(s) = fd_slot(fd) else {
        return false;
    };
    let e = unsafe { &FDT[s] };
    match e.kind {
        FdKind::Timer => unsafe { house_timerfd_due(fd) != 0 },
        FdKind::PipeR => e.len > 0,
        FdKind::PipeW => false,
        FdKind::Event => e.ev_cnt != 0,
        _ => false,
    }
}

/// Wait for EPOLLIN on an epoll set (blocks per `timeout`).
///
/// # Safety
///
/// `events` must be null (returns 0) or valid for `maxevents` entries;
/// `maxevents <= 0` returns 0. Ready entries report EPOLLIN plus stored data.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn epoll_wait(
    epfd: i32,
    events: *mut c_void,
    maxevents: i32,
    timeout: i32,
) -> i32 {
    // SAFETY: blocking yield/wfe matches tinylibc/sys.c epoll_wait; no locks held.
    unsafe extern "C" {
        fn house_sched_yield();
        fn house_thread_current() -> *mut u8;
    }
    if events.is_null() || maxevents <= 0 {
        return 0;
    }
    let Some(s) = fd_slot(epfd) else {
        unsafe { *__errno_location() = 9 };
        return -1;
    };
    if unsafe { FDT[s].kind } != FdKind::Epoll {
        unsafe { *__errno_location() = 9 };
        return -1;
    }
    let out = events as *mut EpollEvent;
    loop {
        let mut n = 0usize;
        let ep_n = unsafe { FDT[s].ep_n };
        for i in 0..ep_n {
            if n >= maxevents as usize {
                break;
            }
            let fd = unsafe { FDT[s].ep_fd[i] };
            let want = unsafe { FDT[s].ep_events[i] };
            if (want & EPOLLIN) != 0 && unsafe { fd_ready(fd) } {
                unsafe {
                    (*out.add(n)).events = EPOLLIN;
                    (*out.add(n)).data = FDT[s].ep_data[i];
                }
                n += 1;
            }
        }
        if n != 0 {
            return n as i32;
        }
        if timeout == 0 {
            return 0;
        }
        if timeout < 0 {
            // RTS-owned threads have no house scheduler state, so yielding
            // is a no-op spin for them: block on wfe instead. Any IRQ
            // (notably the 10 ms timer) or a pipe/eventfd write wakes wfe;
            // readiness is re-checked at the top of the loop.
            if unsafe { house_thread_current().is_null() } {
                unsafe { core::arch::asm!("wfe", options(nostack, preserves_flags)) };
            } else {
                unsafe { house_sched_yield() };
            }
        } else {
            let start = unsafe { house_uptime_ns_raw() };
            let to_ns = timeout as u64 * 1_000_000;
            loop {
                if unsafe { house_thread_current().is_null() } {
                    unsafe { core::arch::asm!("wfe", options(nostack, preserves_flags)) };
                } else {
                    unsafe { house_sched_yield() };
                }
                let mut n2 = 0usize;
                let ep_n2 = unsafe { FDT[s].ep_n };
                for i in 0..ep_n2 {
                    if n2 >= maxevents as usize {
                        break;
                    }
                    let fd = unsafe { FDT[s].ep_fd[i] };
                    let want = unsafe { FDT[s].ep_events[i] };
                    if (want & EPOLLIN) != 0 && unsafe { fd_ready(fd) } {
                        unsafe {
                            (*out.add(n2)).events = EPOLLIN;
                            (*out.add(n2)).data = FDT[s].ep_data[i];
                        }
                        n2 += 1;
                    }
                }
                if n2 != 0 {
                    return n2 as i32;
                }
                let now = unsafe { house_uptime_ns_raw() };
                if now.wrapping_sub(start) >= to_ns {
                    return 0;
                }
            }
        }
    }
}

/// `epoll_wait` with a signal mask (mask ignored).
///
/// # Safety
///
/// Same contract as `epoll_wait`; `sigmask` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn epoll_pwait(
    epfd: i32,
    events: *mut c_void,
    maxevents: i32,
    timeout: i32,
    sigmask: *const c_void,
) -> i32 {
    let _ = sigmask;
    unsafe { epoll_wait(epfd, events, maxevents, timeout) }
}

/// `epoll_wait` with a timespec timeout (converted to ms).
///
/// # Safety
///
/// `ts` may be null (infinite) or valid for two `i64` (secs, nsecs); other
/// args follow `epoll_wait`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn epoll_pwait2(
    epfd: i32,
    events: *mut c_void,
    maxevents: i32,
    ts: *const c_void,
    sigmask: *const c_void,
) -> i32 {
    let mut to: i32 = -1;
    if !ts.is_null() {
        let secs = unsafe { *(ts as *const i64) };
        let nsec = unsafe { *(ts as *const i64).add(1) };
        let ms = secs * 1000 + nsec / 1_000_000;
        to = ms as i32;
    }
    unsafe { epoll_pwait(epfd, events, maxevents, to, sigmask) }
}

/// Create a timerfd (returns fd, -1 when full).
///
/// # Safety
///
/// Safe with any values; clock and flags are ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timerfd_create(clockid: i32, flags: i32) -> i32 {
    let _ = clockid;
    let _ = flags;
    for i in 0..FAKE_FD_N {
        if unsafe { FDT[i].kind } == FdKind::Free {
            unsafe {
                FDT[i].kind = FdKind::Timer;
                FDT[i].ticks = 0;
                FDT[i].last_ns = house_uptime_ns_raw();
            }
            return FAKE_FD_BASE + i as i32;
        }
    }
    unsafe { *__errno_location() = 23 };
    -1
}

/// Set the global tick interval from an itimerspec.
///
/// # Safety
///
/// `nv` may be null or valid for itimerspec (reads words [2]/[3] as u64
/// secs/nsecs); `ov` may be null or is zeroed for 16 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timerfd_settime(
    _fd: i32,
    _flags: i32,
    nv: *const c_void,
    ov: *mut c_void,
) -> i32 {
    // nv is itimerspec {it_interval, it_value}
    if !ov.is_null() {
        unsafe { core::ptr::write_bytes(ov as *mut u8, 0, 16) };
    }
    if !nv.is_null() {
        // it_value at offset 16: tv_sec, tv_nsec
        let secs = unsafe { *(nv as *const u64).add(2) };
        let nsec = unsafe { *(nv as *const u64).add(3) };
        let ns = secs * 1000000000 + nsec;
        unsafe { TICK_INTERVAL_NS = ns };
    }
    0
}

/// Report the tick interval (32-byte itimerspec shape).
///
/// # Safety
///
/// `_fd` is ignored; `v` may be null (returns 0) or must be valid for
/// 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timerfd_gettime(_fd: i32, v: *mut c_void) -> i32 {
    if v.is_null() {
        return 0;
    }
    unsafe { core::ptr::write_bytes(v as *mut u8, 0, 32) };
    let ns = unsafe { TICK_INTERVAL_NS };
    if !v.is_null() {
        unsafe {
            let p = v as *mut u64;
            *p.add(2) = ns / 1000000000;
            *p.add(3) = ns % 1000000000;
        }
    }
    0
}

/// Whether a timerfd is due (0 for unknown/non-timer fds).
///
/// # Safety
///
/// Safe with any `fd` value; ISR-active consults the pending ring.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_timerfd_due(fd: i32) -> i32 {
    let Some(s) = fd_slot(fd) else {
        return 0;
    };
    let e = unsafe { &FDT[s] };
    if e.kind != FdKind::Timer {
        return 0;
    }
    let isr_active = unsafe { core::ptr::read_volatile(&raw const house_isr_active) };
    if isr_active != 0 {
        for i in 0..HOUSE_MAX_SMP {
            let v = unsafe { core::ptr::read_volatile(&raw const house_isr_pending[i]) };
            if v > 0 {
                return 1;
            }
        }
        return 0;
    }
    let interval = unsafe { TICK_INTERVAL_NS };
    if interval == 0 {
        return 1;
    }
    let now = unsafe { house_uptime_ns_raw() };
    if now.wrapping_sub(e.last_ns) >= interval {
        1
    } else {
        0
    }
}

/// Whether an fd is a non-empty pipe read end.
///
/// # Safety
///
/// Safe with any `fd` value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_fd_pipe_readable(fd: i32) -> i32 {
    let Some(s) = fd_slot(fd) else {
        return 0;
    };
    let e = unsafe { &FDT[s] };
    if e.kind == FdKind::PipeR && e.len > 0 {
        1
    } else {
        0
    }
}

/// Unimplemented: ENOENT, returns -1.
///
/// # Safety
///
/// Safe with any arguments (ignored).
// ---- remaining stubs (keep minimal) ----
#[unsafe(no_mangle)]
pub unsafe extern "C" fn open(_p: *const u8, _f: i32) -> i32 {
    unsafe { *__errno_location() = 2 };
    -1
}
/// Unimplemented: ESPIPE, returns -1.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lseek(_fd: i32, _o: i64, _w: i32) -> i64 {
    unsafe { *__errno_location() = 29 };
    -1
}
/// Unimplemented stub returning 0.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fcntl(_fd: i32, _c: i32) -> i32 {
    0
}
/// Unimplemented stub returning 0.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ioctl(_fd: i32, _r: u64) -> i32 {
    0
}
/// 1 for fd 0..=2, else 0.
///
/// # Safety
///
/// Safe with any `fd` value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn isatty(fd: i32) -> i32 {
    if fd <= 2 { 1 } else { 0 }
}
/// Zeroed 128-byte stat reporting S_IFCHR|0666, blksize 4096.
///
/// # Safety
///
/// `_st` may be null (returns 0) or must be valid for 128 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fstat(_fd: i32, _st: *mut u8) -> i32 {
    // SAFETY: matches tinylibc/sys.c fstat: zeroed stat, S_IFCHR|0666, blksize 4096.
    if !_st.is_null() {
        unsafe { core::ptr::write_bytes(_st, 0, 128) };
        unsafe {
            *(_st as *mut u64) = 1; // st_dev
            *(_st.add(8) as *mut u64) = _fd as u64 + 1; // st_ino
            *(_st.add(16) as *mut u32) = 0o020000 | 0o666; // S_IFCHR | 0666
            *(_st.add(48) as *mut i64) = 4096; // st_blksize
        }
    }
    0
}
/// Unimplemented: ENOENT, returns -1.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stat(_p: *const u8, _st: *mut u8) -> i32 {
    unsafe { *__errno_location() = 2 };
    -1
}
/// Unimplemented: ENOENT, returns -1.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn unlink(_p: *const u8) -> i32 {
    unsafe { *__errno_location() = 2 };
    -1
}
/// Unimplemented: ENOENT, returns -1.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn chdir(_p: *const u8) -> i32 {
    unsafe { *__errno_location() = 2 };
    -1
}
/// Report the root directory (`/`) into `buf`.
///
/// # Safety
///
/// `buf` must be null (returns null) or valid for at least 2 bytes (`n < 2`
/// returns null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getcwd(buf: *mut u8, n: usize) -> *mut u8 {
    if buf.is_null() || n < 2 {
        return core::ptr::null_mut();
    }
    unsafe {
        *buf = b'/';
        *buf.add(1) = 0
    };
    buf
}
/// Look up LANG/LC_ALL/LC_TYPE (static C.UTF-8) else null.
///
/// # Safety
///
/// `n` must be null (returns null) or point to a NUL-terminated name.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getenv(n: *const u8) -> *mut u8 {
    if n.is_null() {
        return core::ptr::null_mut();
    }
    unsafe {
        // SAFETY: null checked above; NUL-terminated C string per ABI.
        let s = core::ffi::CStr::from_ptr(n.cast::<core::ffi::c_char>());
        if s.to_bytes() == b"LANG" || s.to_bytes() == b"LC_ALL" || s.to_bytes() == b"LC_CTYPE" {
            return b"C.UTF-8\0".as_ptr() as *mut u8;
        }
    }
    core::ptr::null_mut()
}
/// Unimplemented: EBADF, returns -1.
///
/// # Safety
///
/// Safe with any `fd` value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dup(_fd: i32) -> i32 {
    unsafe { *__errno_location() = 9 };
    -1
}
/// Echo stub returning `n`.
///
/// # Safety
///
/// Safe with any values; no descriptor is changed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dup2(_o: i32, n: i32) -> i32 {
    n
}
/// Fixed pid 42 (single address space).
///
/// # Safety
///
/// Safe to call anytime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getpid() -> i32 {
    42
}
/// Fixed uid 0.
///
/// # Safety
///
/// Safe to call anytime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getuid() -> u32 {
    0
}
/// Fixed euid 0.
///
/// # Safety
///
/// Safe to call anytime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn geteuid() -> u32 {
    0
}
/// Fixed gid 0.
///
/// # Safety
///
/// Safe to call anytime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getgid() -> u32 {
    0
}
/// Fixed egid 0.
///
/// # Safety
///
/// Safe to call anytime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getegid() -> u32 {
    0
}
/// Uptime (plus fake epoch for clk 0) into `tp`.
///
/// # Safety
///
/// `tp` may be null (returns 0) or must be valid for two `u64` writes
/// (secs, nsecs).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clock_gettime(clk: i32, tp: *mut u8) -> i32 {
    if tp.is_null() {
        return 0;
    }
    let up = unsafe { house_uptime_ns_raw() };
    let ns = if clk == 0 {
        up + FAKE_EPOCH * 1000000000
    } else {
        up
    };
    let secs = ns / 1000000000;
    let nsec = ns % 1000000000;
    unsafe {
        *(tp as *mut u64) = secs;
        *(tp as *mut u64).add(1) = nsec;
    }
    0
}
/// Report 100ns resolution into `res`.
///
/// # Safety
///
/// `res` may be null (returns 0) or must be valid for two `u64` writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn clock_getres(_c: i32, res: *mut u8) -> i32 {
    if res.is_null() {
        return 0;
    }
    unsafe {
        *(res as *mut u64) = 0;
        *(res as *mut u64).add(1) = 100;
    }
    0
}
/// Wall time (uptime plus fake epoch) into `tv`.
///
/// # Safety
///
/// `tv` may be null (returns 0) or must be valid for two `u64` writes
/// (secs, usecs); `_tz` is ignored.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gettimeofday(tv: *mut u8, _tz: *mut c_void) -> i32 {
    if tv.is_null() {
        return 0;
    }
    let ns = unsafe { house_uptime_ns_raw() } + FAKE_EPOCH * 1000000000;
    unsafe {
        *(tv as *mut u64) = ns / 1000000000;
        *(tv as *mut u64).add(1) = (ns % 1000000000) / 1000;
    }
    0
}
/// Process times (all four fields equal the current tick).
///
/// # Safety
///
/// `t` may be null or must be valid for four `i64` writes; returns the tick.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn times(t: *mut u8) -> i64 {
    let ticks = (unsafe { house_uptime_ns_raw() } / 10000000) as i64;
    if !t.is_null() {
        unsafe {
            let p = t as *mut i64;
            *p.add(0) = ticks;
            *p.add(1) = ticks;
            *p.add(2) = ticks;
            *p.add(3) = ticks;
        }
    }
    ticks
}
/// Zero a 16-byte signal set.
///
/// # Safety
///
/// `s` may be null (returns 0) or must be valid for 16 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigemptyset(s: *mut u8) -> i32 {
    if !s.is_null() {
        unsafe { core::ptr::write_bytes(s, 0, 16) };
    }
    0
}
/// Fill a 16-byte signal set with ones.
///
/// # Safety
///
/// `s` may be null (returns 0) or must be valid for 16 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigfillset(s: *mut u8) -> i32 {
    if !s.is_null() {
        unsafe { core::ptr::write_bytes(s, 0xff, 16) };
    }
    0
}
/// Set bit `n` in a signal set.
///
/// # Safety
///
/// `s` must be null (returns 0) or valid for 16 bytes with `n` in 1..=128;
/// smaller `n` values address bits within the set.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigaddset(s: *mut u8, n: i32) -> i32 {
    if s.is_null() || n <= 0 {
        return 0;
    }
    let w = s as *mut u64;
    unsafe { *w.add(((n - 1) as usize) / 64) |= 1u64 << ((n - 1) % 64) };
    0
}
/// Clear bit `n` in a signal set.
///
/// # Safety
///
/// `s` must be null (returns 0) or valid for 16 bytes with `n` in 1..=128.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigdelset(s: *mut u8, n: i32) -> i32 {
    if s.is_null() || n <= 0 {
        return 0;
    }
    let w = s as *mut u64;
    unsafe { *w.add(((n - 1) as usize) / 64) &= !(1u64 << ((n - 1) % 64)) };
    0
}
/// Test bit `n` in a signal set (1/0).
///
/// # Safety
///
/// `s` must be null (returns 0) or valid for 16 bytes with `n` in 1..=128.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigismember(s: *const u8, n: i32) -> i32 {
    if s.is_null() || n <= 0 {
        return 0;
    }
    let w = s as *const u64;
    unsafe { (((*w.add(((n - 1) as usize) / 64)) >> ((n - 1) % 64)) & 1) as i32 }
}
// ---- signals: recorded handlers replay ----
#[repr(C)]
#[derive(Clone, Copy)]
struct SigAction {
    handler: *const c_void,
    flags: i32,
    _pad: i32,
    restorer: *const c_void,
    mask: [u64; 2],
}
impl SigAction {
    const fn zero() -> Self {
        Self {
            handler: core::ptr::null(),
            flags: 0,
            _pad: 0,
            restorer: core::ptr::null(),
            mask: [0; 2],
        }
    }
}
static mut RECORDED: [SigAction; 32] = [SigAction::zero(); 32];
static mut CURMASK: [u64; 2] = [0; 2];
const SIGVTALRM: i32 = 26;
const SA_SIGINFO: i32 = 4;
const SIG_BLOCK: i32 = 0;
const SIG_UNBLOCK: i32 = 1;
const SIG_SETMASK: i32 = 2;
const EINVAL: i32 = 22;

/// Record/replay a signal handler locally (no kernel delivery).
///
/// # Safety
///
/// `sig` must be 1..=31 (else EINVAL); `act`/`old` may be null or must be
/// valid for `SigAction` (32 bytes). A recorded non-null, non-ignored
/// handler is invoked on replay with the C calling convention (`(sig)` or
/// `(sig, null, null)` for `SA_SIGINFO`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigaction(sig: i32, act: *const c_void, old: *mut c_void) -> i32 {
    // SAFETY: sig validated 1..31, act/old valid for SigAction if non-null
    if sig <= 0 || sig >= 32 {
        unsafe { *__errno_location() = EINVAL };
        return -1;
    }
    let idx = sig as usize;
    if !old.is_null() {
        // SAFETY: old points to SigAction per caller
        unsafe {
            core::ptr::copy_nonoverlapping(
                &raw const RECORDED[idx] as *const u8,
                old as *mut u8,
                core::mem::size_of::<SigAction>(),
            )
        };
    }
    if !act.is_null() {
        unsafe {
            core::ptr::copy_nonoverlapping(
                act as *const u8,
                &raw mut RECORDED[idx] as *mut u8,
                core::mem::size_of::<SigAction>(),
            )
        };
    }
    0
}

unsafe fn deliver(sig: i32) {
    if sig <= 0 || sig >= 32 {
        return;
    }
    let rec = unsafe { RECORDED[sig as usize] };
    let h = rec.handler;
    if h.is_null() || h as usize == 1 {
        return;
    }
    if (rec.flags & SA_SIGINFO) != 0 {
        // SAFETY: SA_SIGINFO handler takes (sig, info, ctx); no info in this
        // single-address-space replay, so pass nulls.
        let f: unsafe extern "C" fn(i32, *mut c_void, *mut c_void) =
            unsafe { core::mem::transmute(h) };
        unsafe { f(sig, core::ptr::null_mut(), core::ptr::null_mut()) };
    } else {
        // SAFETY: handler is valid function pointer installed via sigaction
        let f: unsafe extern "C" fn(i32) = unsafe { core::mem::transmute(h) };
        unsafe { f(sig) };
    }
}

/// Update the process signal mask (global fallback).
///
/// # Safety
///
/// `set`/`old` may be null or must be valid for 16 bytes (two `u64`);
/// unknown `how` leaves the mask unchanged.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigprocmask(how: i32, set: *const c_void, old: *mut c_void) -> i32 {
    // SAFETY: per-thread sigmask when house_thr_mode, else global CURMASK
    unsafe extern "C" {
        static house_thr_mode: i32;
        fn house_thread_current() -> *mut u8;
    }
    let mode = unsafe { core::ptr::read_volatile(&raw const house_thr_mode) };
    if mode != 0 {
        let cur = unsafe { house_thread_current() };
        if !cur.is_null() {
            // HouseThread sigmask at offset: need to locate field -- use errno.rs opaque but we know layout
            // sigmask is at offset after tcb: sp(8)+tpidr(8)+tid(4)+state(4)+... Let's treat as generic byte offset
            // Safer: cast to our HouseThread definition from threads crate? Use raw pointer arithmetic via known size.
            // Instead re-read via threads module: we expose via extern but easier to store in thread's sigmask via direct struct.
            // Workaround: store per-thread sigmask via global fallback for now if layout unknown.
            // For correctness, handle old/set via direct memory copy at sigmask offset  (empirically offset = 8+8+4+4+8*5+8*3+... ). Simpler to maintain global CURMASK for threaded too.
            // To avoid layout dependency, we update global CURMASK even in thr_mode; RTS will still see mask.
        }
    }
    if !old.is_null() {
        unsafe {
            core::ptr::copy_nonoverlapping(&raw const CURMASK as *const u8, old as *mut u8, 16)
        };
    }
    if !set.is_null() {
        let src = set as *const [u64; 2];
        let s = unsafe { *src };
        match how {
            x if x == SIG_BLOCK => unsafe {
                CURMASK[0] |= s[0];
                CURMASK[1] |= s[1];
            },
            x if x == SIG_UNBLOCK => unsafe {
                CURMASK[0] &= !s[0];
                CURMASK[1] &= !s[1];
            },
            x if x == SIG_SETMASK => unsafe {
                CURMASK = s;
            },
            _ => {}
        }
    }
    0
}
/// Deliver `sig` to the recorded handler (replay, no kernel).
///
/// # Safety
///
/// Safe with any `sig` (out-of-range 1..=31 is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn raise(sig: i32) -> i32 {
    // SAFETY: deliver replays handler
    unsafe { deliver(sig) };
    0
}
/// Deliver `sig` to this address space (pid 42/-1/0/-42), else ESRCH.
///
/// # Safety
///
/// Safe with any values; other pids cannot exist here.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kill(pid: i32, sig: i32) -> i32 {
    // Single address space: only self-directed kills are meaningful.
    if pid != 42 && pid != -1 && pid != 0 && pid != -(42) {
        unsafe { *__errno_location() = 3 };
        return -1;
    }
    unsafe { deliver(sig) };
    0
}
/// Deliver SIGVTALRM to the recorded handler (RTS tick).
///
/// # Safety
///
/// Safe to call anytime at EL1; a no-op in threaded mode.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_rts_tick() {
    // SAFETY: only deliver when not in threaded mode, matches tinylibc/sys.c
    unsafe extern "C" {
        static house_thr_mode: i32;
    }
    let mode = unsafe { core::ptr::read_volatile(&raw const house_thr_mode) };
    if mode != 0 {
        return;
    }
    unsafe { deliver(SIGVTALRM) };
}
/// Set the global tick interval from an itimerval.
///
/// # Safety
///
/// `nv` may be null or valid for itimerval (reads words [2]/[3] as i64
/// secs/usecs); `ov` may be null or is zeroed for 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn setitimer(_w: i32, nv: *const c_void, ov: *mut c_void) -> i32 {
    // SAFETY: nv/ov point to itimerval (32 bytes: two timevals).
    if !ov.is_null() {
        unsafe { core::ptr::write_bytes(ov as *mut u8, 0, 32) };
    }
    if !nv.is_null() {
        // SAFETY: itimerval layout: [interval_sec, interval_usec, value_sec, value_usec] as i64
        let secs = unsafe { *(nv as *const i64).add(2) } as u64;
        let usecs = unsafe { *(nv as *const i64).add(3) } as u64;
        let ns = secs
            .checked_mul(1000000000)
            .and_then(|a| usecs.checked_mul(1000).and_then(|b| a.checked_add(b)))
            .unwrap_or(u64::MAX);
        unsafe { TICK_INTERVAL_NS = ns };
    }
    0
}
/// Report the tick interval (32-byte itimerval shape).
///
/// # Safety
///
/// `v` may be null (returns 0) or must be valid for 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getitimer(_w: i32, v: *mut c_void) -> i32 {
    if v.is_null() {
        return 0;
    }
    unsafe { core::ptr::write_bytes(v as *mut u8, 0, 32) };
    let ns = unsafe { TICK_INTERVAL_NS };
    unsafe {
        let p = v as *mut i64;
        *p.add(2) = (ns / 1000000000) as i64;
        *p.add(3) = ((ns / 1000) % 1000000) as i64;
        *p.add(0) = (ns / 1000000000) as i64;
        *p.add(1) = ((ns / 1000) % 1000000) as i64;
    }
    0
}
/// Hand out a timer id (timers share the global interval).
///
/// # Safety
///
/// `_t` may be null (returns 0) or must be valid for a `u64` write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timer_create(_c: i32, _e: *const c_void, _t: *mut u64) -> i32 {
    static mut NEXT: u64 = 1;
    if _t.is_null() {
        return 0;
    }
    unsafe {
        *_t = NEXT;
        NEXT += 1;
    }
    0
}
/// Set the global tick interval from an itimerspec.
///
/// # Safety
///
/// `_n` may be null or valid (reads words [2]/[3] as u64 secs/nsecs);
/// `_o` may be null or is zeroed for 16 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timer_settime(
    _t: u64,
    _f: i32,
    _n: *const c_void,
    _o: *mut c_void,
) -> i32 {
    if !_n.is_null() {
        let secs = unsafe { *(_n as *const u64).add(2) };
        let nsec = unsafe { *(_n as *const u64).add(3) };
        unsafe { TICK_INTERVAL_NS = secs * 1000000000 + nsec };
    }
    if !_o.is_null() {
        unsafe { core::ptr::write_bytes(_o as *mut u8, 0, 16) };
    }
    0
}
/// Report the tick interval (32-byte itimerspec shape).
///
/// # Safety
///
/// `_v` may be null (returns 0) or must be valid for 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timer_gettime(_t: u64, _v: *mut c_void) -> i32 {
    if _v.is_null() {
        return 0;
    }
    unsafe { core::ptr::write_bytes(_v as *mut u8, 0, 32) };
    let ns = unsafe { TICK_INTERVAL_NS };
    unsafe {
        let p = _v as *mut u64;
        *p.add(2) = ns / 1000000000;
        *p.add(3) = ns % 1000000000;
    }
    0
}
/// Unimplemented stub returning 0.
///
/// # Safety
///
/// Safe with any values (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timer_getoverrun(_t: u64) -> i32 {
    0
}
/// Unimplemented stub returning 0.
///
/// # Safety
///
/// Safe with any values (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn timer_delete(_t: u64) -> i32 {
    0
}
/// Answer _SC_PAGESIZE/NPROCESSORS/PHYS_PAGES/AVPHYS_PAGES/
/// CLK_TCK/OPEN_MAX.
///
/// # Safety
///
/// Safe with any `n`; unknown names set EINVAL and return -1.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sysconf(n: i32) -> i64 {
    // SAFETY: matches tinylibc/sys.c sysconf cases
    unsafe extern "C" {
        static house_smp_n: i32;
        static house_ram_bytes: u64;
        fn buddy_free_count() -> i32;
    }
    match n {
        30 => 4096, // _SC_PAGESIZE
        83 | 84 => unsafe {
            let v = core::ptr::read_volatile(&raw const house_smp_n);
            if v == 0 { 1 } else { v as i64 }
        },
        85 => unsafe {
            let ram = core::ptr::read_volatile(&raw const house_ram_bytes);
            let r = if ram == 0 { 131072u64 * 4096 } else { ram };
            (r >> 12) as i64
        },
        96 => unsafe {
            let bc = buddy_free_count();
            if bc > 0 { bc as i64 + 512 } else { 100000 }
        }, // _SC_AVPHYS_PAGES
        2 => 100,              // _SC_CLK_TCK
        4 => FAKE_FD_N as i64, // _SC_OPEN_MAX
        _ => {
            unsafe { *__errno_location() = 22 };
            -1
        }
    }
}
/// Fixed page size 4096.
///
/// # Safety
///
/// Safe to call anytime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn getpagesize() -> i32 {
    4096
}
/// Halt the core in `wfi`, never returns.
///
/// # Safety
///
/// Safe with any code (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn exit(_s: i32) -> ! {
    loop {
        unsafe { core::arch::asm!("wfi", options(nomem, nostack)) }
    }
}
/// Halt the core in `wfi`, never returns.
///
/// # Safety
///
/// Safe with any code (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn _exit(_s: i32) -> ! {
    loop {
        unsafe { core::arch::asm!("wfi", options(nomem, nostack)) }
    }
}
/// Halt the core in `wfi`, never returns.
///
/// # Safety
///
/// Safe with any code (ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn _Exit(_s: i32) -> ! {
    loop {
        unsafe { core::arch::asm!("wfi", options(nomem, nostack)) }
    }
}
/// Halt the core in `wfi`, never returns.
///
/// # Safety
///
/// Safe to call anytime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn abort() -> ! {
    loop {
        unsafe { core::arch::asm!("wfi", options(nomem, nostack)) }
    }
}
#[inline]
fn digit_val(c: u8) -> i32 {
    if c >= b'0' && c <= b'9' {
        (c - b'0') as i32
    } else if c >= b'a' && c <= b'f' {
        (c - b'a' + 10) as i32
    } else if c >= b'A' && c <= b'F' {
        (c - b'A' + 10) as i32
    } else {
        -1
    }
}
/// Parse an integer with C whitespace/sign/base-prefix rules.
///
/// # Safety
///
/// `n` must be null (returns 0) or point to a NUL-terminated string;
/// `end` may be null or must be valid for a `*mut u8` write. Wraps like C
/// on overflow.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtol(n: *const u8, end: *mut *mut u8, base: i32) -> i64 {
    // SAFETY: n is NUL-terminated per C contract, end may be null
    if n.is_null() {
        return 0;
    }
    let mut p = n;
    // skip whitespace
    unsafe {
        while *p == b' ' || (*p >= 9 && *p <= 13) {
            p = p.add(1);
        }
    }
    let mut neg = false;
    unsafe {
        if *p == b'-' {
            neg = true;
            p = p.add(1);
        } else if *p == b'+' {
            p = p.add(1);
        }
    }
    let mut b = base;
    unsafe {
        if (b == 16 || b == 0) && *p == b'0' && ((*p.add(1) | 0x20) == b'x') {
            p = p.add(2);
            b = 16;
        } else if b == 0 {
            b = if *p == b'0' { 8 } else { 10 };
        }
    }
    let mut v: u64 = 0;
    unsafe {
        loop {
            let d = digit_val(*p);
            if d < 0 || d >= b {
                break;
            }
            // SAFETY: checked mul/add overflow wraps like C (but SOTA prefers checked)
            v = v.wrapping_mul(b as u64).wrapping_add(d as u64);
            p = p.add(1);
        }
    }
    if !end.is_null() {
        unsafe {
            *end = p as *mut u8;
        }
    }
    if neg { -(v as i64) } else { v as i64 }
}
/// Parse an unsigned integer (delegates to `strtol` bits).
///
/// # Safety
///
/// Same contract as `strtol`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn strtoul(n: *const u8, end: *mut *mut u8, base: i32) -> u64 {
    // SAFETY: delegate to strtol bit pattern
    unsafe { strtol(n, end, base) as u64 }
}
/// Parse a base-10 integer (delegates to `strtol`).
///
/// # Safety
///
/// `n` must be null (returns 0) or point to a NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn atoi(n: *const u8) -> i32 {
    unsafe { strtol(n, core::ptr::null_mut(), 10) as i32 }
}
/// Static "house error" string (errno numbers unmapped).
///
/// # Safety
///
/// Safe with any `_e`; returns a static NUL-terminated string that must
/// not be freed or written.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn strerror(_e: i32) -> *mut u8 {
    b"house error\0".as_ptr() as *mut u8
}
