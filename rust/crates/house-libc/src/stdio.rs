#![allow(clippy::all)]
use core::ffi::c_void;
#[no_mangle]
pub static mut stdin: *mut c_void = core::ptr::null_mut();
#[no_mangle]
pub static mut stdout: *mut c_void = core::ptr::null_mut();
#[no_mangle]
pub static mut stderr: *mut c_void = core::ptr::null_mut();
#[no_mangle]
pub unsafe extern "C" fn vfprintf(_f: *mut c_void, _fmt: *const u8, _ap: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn fprintf(_f: *mut c_void, _fmt: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn vprintf(_fmt: *const u8, _ap: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn printf(_fmt: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn vsnprintf(_b: *mut u8, _n: usize, _f: *const u8, _a: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn snprintf(_b: *mut u8, _n: usize, _f: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn sprintf(_b: *mut u8, _f: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn puts(_s: *const u8) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn fputs(_s: *const u8, _f: *mut c_void) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn putchar(_c: i32) -> i32 {
    _c
}
#[no_mangle]
pub unsafe extern "C" fn fputc(_c: i32, _f: *mut c_void) -> i32 {
    _c
}
#[no_mangle]
pub unsafe extern "C" fn fwrite(_p: *const u8, _s: usize, _c: usize, _f: *mut c_void) -> usize {
    _c
}
#[no_mangle]
pub unsafe extern "C" fn fflush(_f: *mut c_void) -> i32 {
    0
}
