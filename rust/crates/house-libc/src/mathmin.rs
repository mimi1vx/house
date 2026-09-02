#![allow(clippy::all)]
#[no_mangle]
pub unsafe extern "C" fn ldexp(x: f64, _e: i32) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn log(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn log2(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn exp(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn pow(a: f64, _b: f64) -> f64 {
    a
}
#[no_mangle]
pub unsafe extern "C" fn sin(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn cos(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn tan(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn sqrt(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn fabs(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn floor(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn ceil(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn trunc(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn round(x: f64) -> f64 {
    x
}
#[no_mangle]
pub unsafe extern "C" fn strtod(_n: *const u8, _e: *mut *mut u8) -> f64 {
    0.0
}
#[no_mangle]
pub unsafe extern "C" fn atanh(_x: f64) -> f64 {
    _x
}
#[no_mangle]
pub unsafe extern "C" fn atanhf(_x: f32) -> f32 {
    _x
}
#[no_mangle]
pub unsafe extern "C" fn asinh(_x: f64) -> f64 {
    _x
}
#[no_mangle]
pub unsafe extern "C" fn asinhf(_x: f32) -> f32 {
    _x
}
#[no_mangle]
pub unsafe extern "C" fn acosh(_x: f64) -> f64 {
    _x
}
#[no_mangle]
pub unsafe extern "C" fn acoshf(_x: f32) -> f32 {
    _x
}
#[no_mangle]
pub unsafe extern "C" fn cbrt(_x: f64) -> f64 {
    _x
}
#[no_mangle]
pub unsafe extern "C" fn hypot(_a: f64, _b: f64) -> f64 {
    0.0
}
#[no_mangle]
pub unsafe extern "C" fn fmax(_a: f64, _b: f64) -> f64 {
    _a
}
#[no_mangle]
pub unsafe extern "C" fn fmin(_a: f64, _b: f64) -> f64 {
    _a
}
#[no_mangle]
pub unsafe extern "C" fn fmod(_a: f64, _b: f64) -> f64 {
    0.0
}
