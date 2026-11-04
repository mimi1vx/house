/// Identity placeholder returning `x` (no freestanding scalbn).
///
/// # Safety
///
/// Safe with any `f64` value; ignores `_e`.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn ldexp(x: f64, _e: i32) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn log(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn log2(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn exp(x: f64) -> f64 {
    x
}
/// Placeholder returning `a` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` values; ignores `_b`.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn pow(a: f64, _b: f64) -> f64 {
    a
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn sin(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn cos(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn tan(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn sqrt(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn fabs(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn floor(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn ceil(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn trunc(x: f64) -> f64 {
    x
}
/// Identity placeholder returning `x` (link-only libm).
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn round(x: f64) -> f64 {
    x
}
/// Unimplemented stub returning 0.0.
///
/// # Safety
///
/// Safe with any pointer values including null (ignored); no memory is accessed.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn strtod(_n: *const u8, _e: *mut *mut u8) -> f64 {
    0.0
}
/// Identity placeholder returning its argument.
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn atanh(_x: f64) -> f64 {
    _x
}
/// Identity placeholder returning its argument.
///
/// # Safety
///
/// Safe with any `f32` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn atanhf(_x: f32) -> f32 {
    _x
}
/// Identity placeholder returning its argument.
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn asinh(_x: f64) -> f64 {
    _x
}
/// Identity placeholder returning its argument.
///
/// # Safety
///
/// Safe with any `f32` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn asinhf(_x: f32) -> f32 {
    _x
}
/// Identity placeholder returning its argument.
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn acosh(_x: f64) -> f64 {
    _x
}
/// Identity placeholder returning its argument.
///
/// # Safety
///
/// Safe with any `f32` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn acoshf(_x: f32) -> f32 {
    _x
}
/// Identity placeholder returning its argument.
///
/// # Safety
///
/// Safe with any `f64` value.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn cbrt(_x: f64) -> f64 {
    _x
}
/// Unimplemented stub returning 0.0.
///
/// # Safety
///
/// Safe with any `f64` values (ignored).
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn hypot(_a: f64, _b: f64) -> f64 {
    0.0
}
/// Placeholder returning its first argument.
///
/// # Safety
///
/// Safe with any `f64` values; ignores `_b`.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn fmax(_a: f64, _b: f64) -> f64 {
    _a
}
/// Placeholder returning its first argument.
///
/// # Safety
///
/// Safe with any `f64` values; ignores `_b`.
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn fmin(_a: f64, _b: f64) -> f64 {
    _a
}
/// Unimplemented stub returning 0.0.
///
/// # Safety
///
/// Safe with any `f64` values (ignored).
#[cfg_attr(not(test), unsafe(no_mangle))]
pub unsafe extern "C" fn fmod(_a: f64, _b: f64) -> f64 {
    0.0
}
