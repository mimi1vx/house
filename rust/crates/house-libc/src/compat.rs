#![allow(clippy::all)]
#![allow(unused_variables)]
use core::ffi::c_void;

#[no_mangle]
pub unsafe extern "C" fn getauxval(_t: u64) -> u64 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn __getauxval(_t: u64) -> u64 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn stat64(_p: *const u8, _s: *mut c_void) -> i32 {
    extern "C" {
        fn stat(p: *const u8, s: *mut c_void) -> i32;
    }
    unsafe { stat(_p, _s) }
}
#[no_mangle]
pub unsafe extern "C" fn fstat64(_f: i32, _s: *mut c_void) -> i32 {
    extern "C" {
        fn fstat(f: i32, s: *mut c_void) -> i32;
    }
    unsafe { fstat(_f, _s) }
}
#[no_mangle]
pub unsafe extern "C" fn lstat64(_p: *const u8, _s: *mut c_void) -> i32 {
    extern "C" {
        fn lstat(p: *const u8, s: *mut c_void) -> i32;
    }
    unsafe { lstat(_p, _s) }
}
#[no_mangle]
pub unsafe extern "C" fn dlopen(_f: *const u8, _fl: i32) -> *mut c_void {
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn dlsym(_h: *mut c_void, _n: *const u8) -> *mut c_void {
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn dlclose(_h: *mut c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn dlerror() -> *mut u8 {
    b"no dl\0".as_ptr() as *mut u8
}
#[no_mangle]
pub unsafe extern "C" fn dlinfo(_h: *mut c_void, _r: i32, _v: *mut c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn dl_iterate_phdr(_cb: *const c_void, _d: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn __xpg_strerror_r(_e: i32, _b: *mut u8, _n: usize) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn fopen(_p: *const u8, _m: *const u8) -> *mut c_void {
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn fclose(_f: *mut c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn fread(_b: *mut c_void, _s: usize, _n: usize, _f: *mut c_void) -> usize {
    0
}
#[no_mangle]
pub unsafe extern "C" fn fgets(_b: *mut u8, _n: i32, _f: *mut c_void) -> *mut u8 {
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn feof(_f: *mut c_void) -> i32 {
    1
}
#[no_mangle]
pub unsafe extern "C" fn fseek(_f: *mut c_void, _o: i64, _w: i32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn ftell(_f: *mut c_void) -> i64 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn getc(_f: *mut c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn getline(_b: *mut *mut u8, _n: *mut usize, _f: *mut c_void) -> isize {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn __isoc99_sscanf(_s: *const u8, _fmt: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn setmntent(_f: *const u8, _m: *const u8) -> *mut c_void {
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn endmntent(_f: *mut c_void) -> i32 {
    1
}
#[no_mangle]
pub unsafe extern "C" fn hasmntopt(_e: *mut c_void, _o: *const u8) -> *mut u8 {
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn getmntent_r(
    _f: *mut c_void,
    _m: *mut c_void,
    _b: *mut u8,
    _n: i32,
) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn memfd_create(_n: *const u8, _fl: u32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn mkstemp(_t: *mut u8) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn access(_p: *const u8, _m: i32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn ftruncate(_fd: i32, _len: i64) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn qsort(_base: *mut c_void, _nm: usize, _sz: usize, _cmp: *const c_void) {}
#[no_mangle]
pub unsafe extern "C" fn statfs(_p: *const u8, _b: *mut c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn __fprintf_chk(_f: *mut c_void, _fl: i32, _fmt: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn __printf_chk(_fl: i32, _fmt: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn __memcpy_chk(_d: *mut u8, _s: *const u8, _n: usize, _l: usize) -> *mut u8 {
    _d
}
#[no_mangle]
pub unsafe extern "C" fn __memmove_chk(
    _d: *mut u8,
    _s: *const u8,
    _n: usize,
    _l: usize,
) -> *mut u8 {
    _d
}
#[no_mangle]
pub unsafe extern "C" fn __memset_chk(_d: *mut u8, _c: i32, _n: usize, _l: usize) -> *mut u8 {
    _d
}
#[no_mangle]
pub unsafe extern "C" fn __assert_fail(_a: *const u8, _f: *const u8, _l: u32, _fn: *const u8) -> ! {
    loop {
        core::arch::asm!("wfi", options(nomem, nostack));
    }
}
#[no_mangle]
pub unsafe extern "C" fn getrlimit(_r: i32, _rl: *mut c_void) -> i32 {
    // SAFETY: matches C compat.c getrlimit: generous 1TB limits.
    if !_rl.is_null() {
        unsafe {
            *(_rl as *mut u64) = 1u64 << 40;
            *(_rl as *mut u64).add(1) = 1u64 << 40;
        }
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn getrusage(_w: i32, _r: *mut c_void) -> i32 {
    // SAFETY: matches C compat.c getrusage: zeroed rusage with uptime + maxrss.
    extern "C" {
        fn house_uptime_ns() -> u64;
    }
    if _r.is_null() {
        return 0;
    }
    let ns = unsafe { house_uptime_ns() };
    unsafe {
        core::ptr::write_bytes(_r as *mut u8, 0, 144);
        let p = _r as *mut i64;
        *p.add(0) = (ns / 1000000000) as i64;
        *p.add(1) = ((ns / 1000) % 1000000) as i64;
        *p.add(2) = (ns / 1000000000) as i64;
        *p.add(3) = ((ns / 1000) % 1000000) as i64;
        *p.add(4) = 1 << 16; // ru_maxrss
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn clock_getcpuclockid(_p: i32, _c: *mut i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn time(_t: *mut i64) -> i64 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn ctime_r(_t: *const i64, _b: *mut u8) -> *mut u8 {
    _b
}
#[no_mangle]
pub unsafe extern "C" fn dirname(_p: *mut u8) -> *mut u8 {
    _p
}
#[no_mangle]
pub unsafe extern "C" fn stpcpy(_d: *mut u8, _s: *const u8) -> *mut u8 {
    _d
}
#[no_mangle]
pub unsafe extern "C" fn regcomp(_p: *mut c_void, _pat: *const u8, _f: i32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn regexec(
    _p: *const c_void,
    _s: *const u8,
    _n: usize,
    _m: *mut c_void,
    _f: i32,
) -> i32 {
    1
}
#[no_mangle]
pub unsafe extern "C" fn regfree(_p: *mut c_void) {}
#[no_mangle]
pub unsafe extern "C" fn newlocale(_m: i32, _n: *const u8, _b: *mut c_void) -> *mut c_void {
    _b
}
#[no_mangle]
pub unsafe extern "C" fn freelocale(_l: *mut c_void) {}
#[no_mangle]
pub unsafe extern "C" fn uselocale(_l: *mut c_void) -> *mut c_void {
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn setlocale(_c: i32, _n: *const u8) -> *mut u8 {
    b"C.UTF-8\0".as_ptr() as *mut u8
}
#[no_mangle]
pub unsafe extern "C" fn __ctype_b_loc() -> *mut *const u16 {
    static mut TABLE: *const u16 = core::ptr::null();
    &raw mut TABLE as *mut *const u16
}
#[no_mangle]
pub unsafe extern "C" fn iconv_open(_t: *const u8, _f: *const u8) -> *mut c_void {
    1 as *mut c_void
}
#[no_mangle]
pub unsafe extern "C" fn iconv(
    _cd: *mut c_void,
    _in: *mut *mut u8,
    _il: *mut usize,
    _out: *mut *mut u8,
    _ol: *mut usize,
) -> usize {
    // SAFETY: byte copy passthrough like C compat.c iconv.
    extern "C" {
        fn __errno_location() -> *mut i32;
    }
    if _in.is_null() || unsafe { (*_in).is_null() } {
        return 0;
    }
    let il = unsafe { *_il };
    let ol = unsafe { *_ol };
    let n = if il < ol { il } else { ol };
    unsafe {
        core::ptr::copy_nonoverlapping(*_in, *_out, n);
        *_in = (*_in).add(n);
        *_out = (*_out).add(n);
        *_il -= n;
        *_ol -= n;
    }
    if unsafe { *_il } != 0 {
        unsafe { *__errno_location() = 7 };
        return usize::MAX;
    }
    0
}
#[no_mangle]
pub unsafe extern "C" fn iconv_close(_cd: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn nl_langinfo(_i: i32) -> *mut u8 {
    b"UTF-8\0".as_ptr() as *mut u8
}
#[no_mangle]
pub unsafe extern "C" fn link(_a: *const u8, _b: *const u8) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn creat(_p: *const u8, _m: u32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn chmod(_p: *const u8, _m: u32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn umask(_m: u32) -> u32 {
    _m
}
#[no_mangle]
pub unsafe extern "C" fn mkfifo(_p: *const u8, _m: u32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn utime(_p: *const u8, _t: *const c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn lstat(_p: *const u8, _s: *mut c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn waitpid(_p: i32, _s: *mut i32, _o: i32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn fork() -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn getppid() -> i32 {
    1
}
#[no_mangle]
pub unsafe extern "C" fn atexit(_f: *const c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn syscall(_n: i64) -> i64 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn madvise(_a: *mut c_void, _l: usize, _a2: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn mkdir(_p: *const u8, _m: u32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn mknod(_p: *const u8, _m: u32, _d: u64) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn ftruncate64(_f: i32, _l: i64) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn tcgetattr(_fd: i32, _t: *mut core::ffi::c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn tcsetattr(_fd: i32, _a: i32, _t: *const core::ffi::c_void) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn strtoull(_n: *const u8, _e: *mut *mut u8, _b: i32) -> u64 {
    0
}
