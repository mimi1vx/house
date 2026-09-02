#![allow(clippy::all)]
#![allow(unused_variables)]
#![allow(unexpected_cfgs)]
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
pub mod errno;
pub mod fd;
pub mod signal;
pub mod time;

use core::ffi::c_void;

extern "C" {
    fn uart_putc(c: u8);
    fn __errno_location() -> *mut i32;
    static mut house_isr_active: i32;
    static mut house_isr_pending: [u64; 16];
}

// ---- fd table ----
const FAKE_FD_BASE: i32 = 3;
const FAKE_FD_N: usize = 32;
const PIPE_CAP: usize = 1024;
const HOUSE_MAX_SMP: usize = 16;

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

static mut FDT: [FdEntry; 32] = [
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
    FdEntry {
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
    },
];

#[inline]
fn fd_slot(fd: i32) -> Option<usize> {
    if fd < FAKE_FD_BASE {
        return None;
    }
    let s = (fd - FAKE_FD_BASE) as usize;
    if s < FAKE_FD_N {
        Some(s)
    } else {
        None
    }
}

static mut TICK_INTERVAL_NS: u64 = 0;

#[no_mangle]
pub static mut environ: *mut *mut u8 = core::ptr::null_mut();

#[inline]
fn counter_hz() -> u64 {
    let f: u64;
    unsafe {
        core::arch::asm!("mrs {0}, cntfrq_el0", out(reg) f, options(nostack, preserves_flags))
    };
    if f == 0 {
        62500000
    } else {
        f
    }
}

// SAFETY: reads CNTVCT, always safe.
unsafe fn house_uptime_ns_raw() -> u64 {
    let c: u64;
    unsafe {
        core::arch::asm!("mrs {0}, cntvct_el0", out(reg) c, options(nostack, preserves_flags))
    };
    let hz = counter_hz();
    ((c as u128 * 1000000000u128) / hz as u128) as u64
}

const FAKE_EPOCH: u64 = 1785000000;

#[no_mangle]
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

#[no_mangle]
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
                for i in 0..HOUSE_MAX_SMP {
                    let v = unsafe { core::ptr::read_volatile(&raw const house_isr_pending[i]) };
                    if v > 0 {
                        unsafe { core::ptr::write_volatile(&raw mut house_isr_pending[i], v - 1) };
                        break;
                    }
                }
                entry.ticks += 1;
                unsafe { *(buf as *mut u64) = 1 };
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
pub unsafe extern "C" fn epoll_create1(flags: i32) -> i32 {
    let _ = flags;
    unsafe { epoll_create(1) }
}

#[repr(C)]
struct EpollEvent {
    events: u32,
    data: u64,
}

#[no_mangle]
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

#[no_mangle]
pub unsafe extern "C" fn epoll_wait(
    epfd: i32,
    events: *mut c_void,
    maxevents: i32,
    timeout: i32,
) -> i32 {
    return epoll_pwait(epfd, events, maxevents, timeout, core::ptr::null());
}

#[no_mangle]
pub unsafe extern "C" fn epoll_pwait(
    epfd: i32,
    events: *mut c_void,
    maxevents: i32,
    _timeout: i32,
    _sigmask: *const c_void,
) -> i32 {
    if events.is_null() || maxevents <= 0 {
        return 0;
    }
    let Some(s) = fd_slot(epfd) else {
        unsafe { *__errno_location() = 9 };
        return -1;
    };
    let ep = unsafe { &FDT[s] };
    if ep.kind != FdKind::Epoll {
        unsafe { *__errno_location() = 9 };
        return -1;
    }
    let mut n = 0;
    let out = events as *mut EpollEvent;
    for i in 0..ep.ep_n {
        if n >= maxevents as usize {
            break;
        }
        let fd = ep.ep_fd[i];
        if unsafe { fd_ready(fd) } {
            unsafe {
                (*out.add(n)).events = ep.ep_events[i];
                (*out.add(n)).data = ep.ep_data[i];
            }
            n += 1;
        }
    }
    n as i32
}

#[no_mangle]
pub unsafe extern "C" fn epoll_pwait2(
    epfd: i32,
    events: *mut c_void,
    maxevents: i32,
    _ts: *const c_void,
    sigmask: *const c_void,
) -> i32 {
    return epoll_pwait(epfd, events, maxevents, 0, sigmask);
}

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
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

#[no_mangle]
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

// ---- remaining stubs (keep minimal) ----
#[no_mangle]
pub unsafe extern "C" fn open(_p: *const u8, _f: i32) -> i32 {
    unsafe { *__errno_location() = 2 };
    -1
}
#[no_mangle]
pub unsafe extern "C" fn lseek(_fd: i32, _o: i64, _w: i32) -> i64 {
    unsafe { *__errno_location() = 29 };
    -1
}
#[no_mangle]
pub unsafe extern "C" fn fcntl(_fd: i32, _c: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn ioctl(_fd: i32, _r: u64) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn isatty(fd: i32) -> i32 {
    if fd <= 2 {
        1
    } else {
        0
    }
}
#[no_mangle]
pub unsafe extern "C" fn fstat(_fd: i32, _st: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn stat(_p: *const u8, _st: *mut u8) -> i32 {
    unsafe { *__errno_location() = 2 };
    -1
}
#[no_mangle]
pub unsafe extern "C" fn unlink(_p: *const u8) -> i32 {
    unsafe { *__errno_location() = 2 };
    -1
}
#[no_mangle]
pub unsafe extern "C" fn chdir(_p: *const u8) -> i32 {
    unsafe { *__errno_location() = 2 };
    -1
}
#[no_mangle]
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
#[no_mangle]
pub unsafe extern "C" fn getenv(n: *const u8) -> *mut u8 {
    if n.is_null() {
        return core::ptr::null_mut();
    }
    unsafe {
        let s = core::ffi::CStr::from_ptr(n);
        if s.to_bytes() == b"LANG" || s.to_bytes() == b"LC_ALL" || s.to_bytes() == b"LC_CTYPE" {
            return b"C.UTF-8\0".as_ptr() as *mut u8;
        }
    }
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn dup(_fd: i32) -> i32 {
    unsafe { *__errno_location() = 9 };
    -1
}
#[no_mangle]
pub unsafe extern "C" fn dup2(_o: i32, n: i32) -> i32 {
    n
}
#[no_mangle]
pub unsafe extern "C" fn getpid() -> i32 {
    42
}
#[no_mangle]
pub unsafe extern "C" fn getuid() -> u32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn geteuid() -> u32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn getgid() -> u32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn getegid() -> u32 {
    0
}
#[no_mangle]
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
#[no_mangle]
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
#[no_mangle]
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
#[no_mangle]
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
#[no_mangle]
pub unsafe extern "C" fn sigemptyset(s: *mut u8) -> i32 {
    if !s.is_null() {
        unsafe { core::ptr::write_bytes(s, 0, 16) };
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigfillset(s: *mut u8) -> i32 {
    if !s.is_null() {
        unsafe { core::ptr::write_bytes(s, 0xff, 16) };
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigaddset(s: *mut u8, n: i32) -> i32 {
    if s.is_null() || n <= 0 {
        return 0;
    }
    let w = s as *mut u64;
    unsafe { *w.add(((n - 1) as usize) / 64) |= 1u64 << ((n - 1) % 64) };
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigdelset(s: *mut u8, n: i32) -> i32 {
    if s.is_null() || n <= 0 {
        return 0;
    }
    let w = s as *mut u64;
    unsafe { *w.add(((n - 1) as usize) / 64) &= !(1u64 << ((n - 1) % 64)) };
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigismember(s: *const u8, n: i32) -> i32 {
    if s.is_null() || n <= 0 {
        return 0;
    }
    let w = s as *const u64;
    unsafe { (((*w.add(((n - 1) as usize) / 64)) >> ((n - 1) % 64)) & 1) as i32 }
}
#[no_mangle]
pub unsafe extern "C" fn sigaction(_s: i32, _a: *const c_void, _o: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigprocmask(_h: i32, _s: *const c_void, _o: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn raise(_s: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn kill(_p: i32, _s: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn house_rts_tick() {}
#[no_mangle]
pub unsafe extern "C" fn setitimer(_w: i32, _n: *const c_void, _o: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn getitimer(_w: i32, _v: *mut c_void) -> i32 {
    0
}
#[no_mangle]
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
#[no_mangle]
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
#[no_mangle]
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
#[no_mangle]
pub unsafe extern "C" fn timer_getoverrun(_t: u64) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn timer_delete(_t: u64) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sysconf(n: i32) -> i64 {
    match n {
        30 => 4096,
        84 | 83 => 2,
        85 => 100000,
        _ => {
            unsafe { *__errno_location() = 22 };
            -1
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn getpagesize() -> i32 {
    4096
}
#[no_mangle]
pub unsafe extern "C" fn exit(_s: i32) -> ! {
    loop {
        unsafe { core::arch::asm!("wfi", options(nomem, nostack)) }
    }
}
#[no_mangle]
pub unsafe extern "C" fn _exit(_s: i32) -> ! {
    loop {
        unsafe { core::arch::asm!("wfi", options(nomem, nostack)) }
    }
}
#[no_mangle]
pub unsafe extern "C" fn _Exit(_s: i32) -> ! {
    loop {
        unsafe { core::arch::asm!("wfi", options(nomem, nostack)) }
    }
}
#[no_mangle]
pub unsafe extern "C" fn abort() -> ! {
    loop {
        unsafe { core::arch::asm!("wfi", options(nomem, nostack)) }
    }
}
#[no_mangle]
pub unsafe extern "C" fn strtol(_n: *const u8, _e: *mut *mut u8, _b: i32) -> i64 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn strtoul(_n: *const u8, _e: *mut *mut u8, _b: i32) -> u64 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn atoi(_n: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn strerror(_e: i32) -> *mut u8 {
    b"house error\0".as_ptr() as *mut u8
}
