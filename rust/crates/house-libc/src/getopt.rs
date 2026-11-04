#[cfg_attr(not(test), unsafe(no_mangle))]
pub static mut optind: i32 = 1;
#[cfg_attr(not(test), unsafe(no_mangle))]
pub static mut opterr: i32 = 0;
#[cfg_attr(not(test), unsafe(no_mangle))]
pub static mut optopt: i32 = 0;
#[cfg_attr(not(test), unsafe(no_mangle))]
pub static mut optarg: *mut u8 = core::ptr::null_mut();
/// Unimplemented stub returning -1.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn getopt(_a: i32, _v: *const *const u8, _o: *const u8) -> i32 {
    -1
}
/// Unimplemented stub returning -1.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn getopt_long(
    _a: i32,
    _v: *const *const u8,
    _o: *const u8,
    _lo: *const u8,
    _i: *mut i32,
) -> i32 {
    -1
}
/// Unimplemented stub returning -1.
///
/// # Safety
///
/// Safe with any arguments (ignored).
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn getopt_long_only(
    _a: i32,
    _v: *const *const u8,
    _o: *const u8,
    _lo: *const u8,
    _i: *mut i32,
) -> i32 {
    -1
}
