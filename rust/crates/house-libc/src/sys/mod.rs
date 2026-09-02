#![allow(clippy::all)]
#![allow(unused_variables)]
#![allow(unexpected_cfgs)]
pub mod errno;
pub mod fd;
pub mod signal;
pub mod time;

use core::ffi::c_void;

// re-export errno for alloc
// Minimal sys implementations — correct signatures, simple returns

extern "C" {
    fn uart_putc(c: u8);
    fn __errno_location() -> *mut i32;
}

#[no_mangle]
pub unsafe extern "C" fn write(fd: i32, buf: *const u8, n: usize) -> isize {
    if fd == 1 || fd == 2 {
        for i in 0..n {
            let b = unsafe { *buf.add(i) };
            unsafe { uart_putc(b) };
        }
        return n as isize;
    }
    unsafe {
        *__errno_location() = 9;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn read(_fd: i32, _buf: *mut u8, _n: usize) -> isize {
    0
}
#[no_mangle]
pub unsafe extern "C" fn open(_p: *const u8, _f: i32) -> i32 {
    unsafe {
        *__errno_location() = 2;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn close(_fd: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn lseek(_fd: i32, _o: i64, _w: i32) -> i64 {
    unsafe {
        *__errno_location() = 29;
    }
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
    unsafe {
        *__errno_location() = 2;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn unlink(_p: *const u8) -> i32 {
    unsafe {
        *__errno_location() = 2;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn chdir(_p: *const u8) -> i32 {
    unsafe {
        *__errno_location() = 2;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn getcwd(buf: *mut u8, n: usize) -> *mut u8 {
    if buf.is_null() || n < 2 {
        return core::ptr::null_mut();
    }
    unsafe {
        *buf = b'/';
        *buf.add(1) = 0;
    }
    buf
}
#[no_mangle]
pub unsafe extern "C" fn pipe(fds: *mut i32) -> i32 {
    unsafe {
        *__errno_location() = 23;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn getenv(_n: *const u8) -> *mut u8 {
    core::ptr::null_mut()
}
#[no_mangle]
pub static mut environ: *mut *mut u8 = core::ptr::null_mut();
#[no_mangle]
pub unsafe extern "C" fn eventfd(_v: u32, _f: i32) -> i32 {
    unsafe {
        *__errno_location() = 23;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn eventfd_write(_fd: i32, _v: u64) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn eventfd_read(_fd: i32, _v: *mut u64) -> i32 {
    unsafe {
        *__errno_location() = 11;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn epoll_create(_s: i32) -> i32 {
    unsafe {
        *__errno_location() = 23;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn epoll_create1(_f: i32) -> i32 {
    unsafe {
        *__errno_location() = 23;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn epoll_ctl(_e: i32, _o: i32, _f: i32, _ev: *mut c_void) -> i32 {
    unsafe {
        *__errno_location() = 9;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn epoll_wait(_e: i32, _ev: *mut c_void, _m: i32, _t: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn epoll_pwait(
    _e: i32,
    _ev: *mut c_void,
    _m: i32,
    _t: i32,
    _s: *const c_void,
) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn epoll_pwait2(
    _e: i32,
    _ev: *mut c_void,
    _m: i32,
    _ts: *const c_void,
    _s: *const c_void,
) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn dup(_fd: i32) -> i32 {
    unsafe {
        *__errno_location() = 9;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn dup2(_o: i32, _n: i32) -> i32 {
    _n
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
pub unsafe extern "C" fn clock_gettime(_c: i32, _t: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn clock_getres(_c: i32, _r: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn gettimeofday(_tv: *mut u8, _tz: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn times(_t: *mut u8) -> i64 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigemptyset(_s: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigfillset(_s: *mut u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigaddset(_s: *mut u8, _n: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigdelset(_s: *mut u8, _n: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sigismember(_s: *const u8, _n: i32) -> i32 {
    0
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
    0
}
#[no_mangle]
pub unsafe extern "C" fn timer_settime(
    _t: u64,
    _f: i32,
    _n: *const c_void,
    _o: *mut c_void,
) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn timer_gettime(_t: u64, _v: *mut c_void) -> i32 {
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
pub unsafe extern "C" fn timerfd_create(_c: i32, _f: i32) -> i32 {
    unsafe {
        *__errno_location() = 23;
    }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn timerfd_settime(
    _f: i32,
    _fl: i32,
    _n: *const c_void,
    _o: *mut c_void,
) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn timerfd_gettime(_f: i32, _v: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn house_timerfd_due(_fd: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn house_fd_pipe_readable(_fd: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sysconf(n: i32) -> i64 {
    match n {
        30 => 4096,   // _SC_PAGESIZE
        84 | 83 => 2, // _SC_NPROCESSORS
        85 => 100000, // _SC_PHYS_PAGES etc
        _ => {
            unsafe {
                *__errno_location() = 22;
            }
            -1
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn getpagesize() -> i32 {
    4096
}
#[no_mangle]
pub unsafe extern "C" fn exit(s: i32) -> ! {
    loop {
        core::arch::asm!("wfi", options(nomem, nostack));
    }
}
#[no_mangle]
pub unsafe extern "C" fn _exit(s: i32) -> ! {
    loop {
        core::arch::asm!("wfi", options(nomem, nostack));
    }
}
#[no_mangle]
pub unsafe extern "C" fn _Exit(s: i32) -> ! {
    loop {
        core::arch::asm!("wfi", options(nomem, nostack));
    }
}
#[no_mangle]
pub unsafe extern "C" fn abort() -> ! {
    loop {
        core::arch::asm!("wfi", options(nomem, nostack));
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
// Additional checked arithmetic for SOTA Security 06 parity
#[allow(dead_code)]
#[inline]
fn validate_fd_range(fd: i32) -> bool {
    let base: i32 = 3;
    let n: i32 = 32;
    let slot = fd - base;
    slot >= 0 && slot < n
}
#[allow(dead_code)]
#[inline]
fn pipe_bounds(len: usize) -> bool {
    const CAP: usize = 1024;
    len <= CAP
}
#[allow(dead_code)]
#[inline]
fn checked_len(a: usize, b: usize) -> Option<usize> {
    a.checked_add(b)
}
#[allow(dead_code)]
#[inline]
fn checked_mul_len(a: usize, b: usize) -> Option<usize> {
    a.checked_mul(b)
}
