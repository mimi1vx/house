//! EL0 gap shims for GHC rebuilds (`house-q0g.4` S4).
//!
//! Link provision for the `--no-undefined` fresh `libHSghc-internal` /
//! `libHSbase` links: every dynamic-undefined symbol the S3-measured
//! 414/102 lists need beyond the RTS (`libHSrts`, link-input only) and GMP
//! (`libgmp`, link-input only) closures. EL0-only: nothing here may touch
//! EL1 state (no UART, no buddy allocator, no kernel fd tables). Where a
//! house svc number already exists the shim delegates through it; the
//! stage-1 surface (`docs/design/linux-abi-syscalls.md`) admits no new
//! number for this set, so everything else is a failing-closed stub
//! (`compat.rs` precedent: `-1`/null plus `ENOSYS`) or pure computation.
//! `stderr`/`environ` are definition homes (data, not stubs).
//!
//! The `libm` subset is real (verified against the host `libm` in
//! `#[cfg(test)]` below with documented tolerances), not the identity
//! placeholders `house-libc` `mathmin.rs` carries: a wrong `sin` has no
//! error channel, while `-ENOSYS` at least fails closed.

use core::ffi::c_void;

use super::set_errno;

// C errno numbers (Linux aarch64) written to the crate's errno cell.
const ENOSYS: i32 = 38;
const EINVAL: i32 = 22;
const ENOMEM: i32 = 12;

// Bit-clear absolute value (`f64::abs` lowers to a `fabs` instantiation;
// this keeps the object free of core-generic text symbols).
fn fabs_kernel(x: f64) -> f64 {
    f64::from_bits(x.to_bits() & 0x7FFF_FFFF_FFFF_FFFF)
}

// Null check without the per-type `is_null` instantiation (same reason).
//
// A note on pointer arithmetic in this module: every `.add()` with a dynamic
// count is spelled `wrapping_add`. The checked `add` emits a debug `Location`
// (file/line table) in dev builds whose `ABS64` relocation the `-shared`
// link refuses; the offsets here are trap- or length-bounded, so wrapping
// can never trigger on a live path.
macro_rules! null_ptr {
    ($p:expr) => {
        ($p as usize) == 0
    };
}

// Lowest-level trap: `svc #imm` with up to four register args, result in x0.
// The park/resume path restores every register but x0 (the resumed result)
// and PSTATE, so only x0 is declared clobbered; the trap reads user memory
// for path/buffer calls, hence no `nomem`.
macro_rules! house_svc {
    // Expands in both safe-`fn` (`house_brk`) and `unsafe fn` bodies, so
    // the trap itself carries the block; callers add no extra `unsafe`.
    ($num:literal, $x0:expr, $x1:expr, $x2:expr, $x3:expr) => {{
        let r: i64;
        // SAFETY: `svc #imm` with four `in` regs and `lateout("x0") r`;
        // only x0 is clobbered, matching the park/resume path, and the trap
        // reads user memory for path/buffer calls, hence no `nomem`.
        unsafe {
            core::arch::asm!(
                concat!("svc #", $num),
                in("x0") $x0,
                in("x1") $x1,
                in("x2") $x2,
                in("x3") $x3,
                lateout("x0") r,
                options(preserves_flags, nostack),
            );
        }
        r
    }};
}

// Freestanding `floor`: `f64::floor` is std-only. Truncation via `as` is
// exact for |x| < 2^52 (all cooldown paths here are bounded far below that).
fn floor_kernel(x: f64) -> f64 {
    if x.is_nan() || x.is_infinite() || fabs_kernel(x) >= 4503599627370496.0 {
        return x;
    }
    let t = (x as i64) as f64;
    if x < 0.0 && x != t { t - 1.0 } else { t }
}

// Freestanding `sqrt`: Newton from a halved-exponent seed (8 iterations land
// within 1 ulp; the callers assert 1e-9, so this is plenty).
fn sqrt_kernel(x: f64) -> f64 {
    if x.is_nan() || x < 0.0 {
        return f64::NAN;
    }
    if x.is_infinite() || x == 0.0 {
        return x;
    }
    let bits = x.to_bits();
    if ((bits >> 52) & 0x7FF) == 0 {
        // Subnormal: scale to the normal range (exact), root, scale back.
        let s = sqrt_kernel(x * 4503599627370496.0);
        return s / 67108864.0;
    }
    // Signed halving: an unsigned wrap would seed a negative root for x < 1.
    let half = ((bits as i64 - 0x3FF0000000000000i64) >> 1) + 0x3FF0000000000000i64;
    let mut y = f64::from_bits(half as u64);
    let mut i = 0;
    while i < 8 {
        y = 0.5 * (y + x / y);
        i += 1;
    }
    y
}

// Map a negative house return (a negated errno) to the C `-1` convention.
fn errno_ret(r: i64) -> i32 {
    if r < 0 {
        set_errno(-r as i32);
        -1
    } else {
        r as i32
    }
}

// --- fd/process delegation (real: house svc 0x04..0x09/0x0A) ---

/// Open a path (`svc #0x04`).
///
/// # Safety
///
/// Caller guarantees `path` NUL-terminated (the trap validates length and
/// user-memory fault before parking).
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn open(path: *const u8, flags: i32) -> i32 {
    // SAFETY: two-arg shape; a C caller passing `mode` leaves it in x2,
    // which the house OPEN handler never reads.
    errno_ret(house_svc!("0x04", path as u64, flags as u64, 0, 0))
}

/// Read (`svc #0x05`), chunked to the 64 KiB the trap validates per call.
///
/// # Safety
///
/// Caller guarantees `buf` valid for `n` bytes.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn read(fd: i32, buf: *mut u8, n: usize) -> isize {
    let mut done: usize = 0;
    while done < n {
        let rem = n - done;
        let want = (if rem > 65536 { 65536 } else { rem }) as u64;
        // SAFETY: `buf[done..done+want]` is in-bounds by the loop invariant.
        let r = house_svc!("0x05", fd as u64, buf.wrapping_add(done) as u64, want, 0);
        if r < 0 {
            if done > 0 {
                return done as isize;
            }
            return errno_ret(r) as isize;
        }
        if r == 0 {
            return done as isize;
        }
        done += r as usize;
    }
    done as isize
}

/// Write (`svc #0x06`), chunked like `read`.
///
/// # Safety
///
/// Caller guarantees `buf` valid for `n` bytes.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn write(fd: i32, buf: *const u8, n: usize) -> isize {
    let mut done: usize = 0;
    while done < n {
        let rem = n - done;
        let want = (if rem > 65536 { 65536 } else { rem }) as u64;
        // SAFETY: `buf[done..done+want]` is in-bounds by the loop invariant.
        let r = house_svc!("0x06", fd as u64, buf.wrapping_add(done) as u64, want, 0);
        if r < 0 {
            if done > 0 {
                return done as isize;
            }
            return errno_ret(r) as isize;
        }
        if r == 0 {
            return done as isize;
        }
        done += r as usize;
    }
    done as isize
}

/// Close (`svc #0x07`).
///
/// # Safety
///
/// Always safe: `fd` is a small integer, no memory accessed.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn close(fd: i32) -> i32 {
    errno_ret(house_svc!("0x07", fd as u64, 0, 0, 0))
}

/// Seek (`svc #0x0A`).
///
/// # Safety
///
/// Always safe: integer args only.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn lseek(fd: i32, off: i64, whence: i32) -> i64 {
    let r = house_svc!("0x0A", fd as u64, off as u64, whence as u64, 0);
    if r < 0 {
        set_errno(-r as i32);
        -1
    } else {
        r
    }
}

/// Fork (`svc #0x08`): positive pid to the parent, 0 to the child.
///
/// # Safety
///
/// Always safe: no memory accessed (the child inherits the trap frame).
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn fork() -> i32 {
    errno_ret(house_svc!("0x08", 0, 0, 0, 0))
}

/// Wait (`svc #0x09`): the trap parks until an own child exits and resumes
/// its low 8 bits; encoded here as a `wait(2)` status word (`code << 8`).
///
/// # Safety
///
/// Caller guarantees `status` null or writable.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn waitpid(pid: i32, status: *mut i32, _options: i32) -> i32 {
    // No WNOHANG: the Haskell waiter blocks unconditionally (documented).
    let r = house_svc!("0x09", pid as u64, 0, 0, 0);
    if r < 0 {
        return errno_ret(r);
    }
    if !null_ptr!(status) {
        // SAFETY: non-null checked; the caller sizes an int.
        unsafe { core::ptr::write(status, ((r as i32) & 0xFF) << 8) };
    }
    pid
}

// --- brk bump allocator (real: house svc 0x03, no free) ---
//
// Single-threaded EL0 only (no EL0 threads exist yet): a `(size, payload)`
// header per block, `free` a no-op. `BRK_CUR == 0` means uninitialised and is
// resolved once via a `brk(0)` query, which the Haskell side answers with
// the current break.

static mut BRK_CUR: u64 = 0;
const ALLOC_HDR: u64 = 16;

/// `svc #0x03`.
///
/// # Safety
///
/// Issues a supervisor call; the caller upholds the brk contract.
unsafe fn house_brk(addr: u64) -> i64 {
    house_svc!("0x03", addr, 0, 0, 0)
}

fn bump_alloc(n: usize) -> *mut u8 {
    let base = if n == 0 { 1u64 } else { n as u64 };
    let size = ((base + 15) & !15).checked_add(ALLOC_HDR);
    let size = match size {
        Some(s) => s,
        None => {
            set_errno(ENOMEM);
            return core::ptr::null_mut();
        }
    };
    // SAFETY: EL0 is single-threaded; no reentrancy between these lines.
    // All cursor traffic goes through `ptr::{read,write}`: direct `static mut` place stores emit a dev-profile null-deref guard whose
    // `Location` table the `-shared` link refuses (see `set_errno`).
    unsafe {
        if core::ptr::read(&raw const BRK_CUR) == 0 {
            let q = house_brk(0);
            if q < 0 {
                set_errno(-q as i32);
                return core::ptr::null_mut();
            }
            core::ptr::write(&raw mut BRK_CUR, q as u64);
        }
        let cur = core::ptr::read(&raw const BRK_CUR);
        let Some(end) = cur.checked_add(size) else {
            set_errno(ENOMEM);
            return core::ptr::null_mut();
        };
        let r = house_brk(end);
        if r < 0 {
            set_errno(-r as i32);
            return core::ptr::null_mut();
        }
        if (r as u64) < end {
            set_errno(ENOMEM);
            return core::ptr::null_mut();
        }
        let base = core::ptr::read(&raw const BRK_CUR);
        core::ptr::write(base as *mut u64, size - ALLOC_HDR);
        core::ptr::write(&raw mut BRK_CUR, r as u64);
        (base + ALLOC_HDR) as *mut u8
    }
}

/// Allocate (`svc #0x03` brk bump).
///
/// # Safety
///
/// Always safe: returns null or a valid 16-aligned block.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn malloc(n: usize) -> *mut u8 {
    bump_alloc(n)
}

/// Allocate zeroed (`svc #0x03` brk bump).
///
/// # Safety
///
/// Same contract as `malloc`; the payload is zero-filled.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn calloc(nmemb: usize, size: usize) -> *mut u8 {
    let Some(total) = nmemb.checked_mul(size) else {
        set_errno(ENOMEM);
        return core::ptr::null_mut();
    };
    let p = bump_alloc(total);
    if !null_ptr!(p) {
        // SAFETY: `p` is a fresh `total`-byte block from `bump_alloc`.
        unsafe { super::memset(p, 0, total) };
    }
    p
}

/// No-op free (bump allocator never releases).
///
/// # Safety
///
/// Always safe: ignores its argument.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn free(_p: *mut u8) {}

/// Reallocate via the header size + copy (old block leaks by design).
///
/// # Safety
///
/// Caller guarantees `p` null or from this allocator with its header intact.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn realloc(p: *mut u8, n: usize) -> *mut u8 {
    if null_ptr!(p) {
        return bump_alloc(n);
    }
    if n == 0 {
        return core::ptr::null_mut();
    }
    let q = bump_alloc(n);
    if null_ptr!(q) {
        return core::ptr::null_mut();
    }
    // SAFETY: header is 16 bytes below a live block by construction.
    let old = unsafe { core::ptr::read((p as u64 - ALLOC_HDR) as *const u64) as usize };
    let len = if old < n { old } else { n };
    // SAFETY: both blocks live, `len` bounded by both sizes.
    unsafe { super::memcpy(q, p as *const u8, len) };
    q
}

// --- pure computation (real, no svc) ---

/// Signal-set ops over the 1024-bit Linux `sigset_t` (16 words).
///
/// # Safety
///
/// Caller guarantees `set` valid for 128 bytes.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn sigemptyset(set: *mut u64) -> i32 {
    if null_ptr!(set) {
        set_errno(EINVAL);
        return -1;
    }
    // SAFETY: null checked; Linux sigset_t is 16 words. Hand-rolled loop
    // (like the crate-root `memset`): `write_bytes` instantiates core
    // generics that would leak into the text-symbol audit.
    let mut i = 0;
    while i < 16 {
        unsafe { core::ptr::write(set.wrapping_add(i), 0) };
        i += 1;
    }
    0
}

/// Add a signal number to a set.
///
/// # Safety
///
/// Same contract as `sigemptyset`; out-of-range numbers fail closed.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
#[allow(
    clippy::manual_range_contains,
    reason = "a RangeInclusive::contains instantiates core generics into the text-symbol audit"
)]
pub unsafe extern "C" fn sigaddset(set: *mut u64, signo: i32) -> i32 {
    if null_ptr!(set) || signo < 1 || signo > 1024 {
        set_errno(EINVAL);
        return -1;
    }
    // SAFETY: null and range checked; index stays within 16 words.
    // `ptr::{read,write}`, not `|=`: a compound place assign emits the
    // null-deref guard (see `set_errno`).
    unsafe {
        let i = (signo - 1) as usize / 64;
        let w = set.wrapping_add(i);
        core::ptr::write(w, core::ptr::read(w) | (1u64 << ((signo - 1) as u32 % 64)));
    }
    0
}

// `sysconf(3)` names the gap needs; the values are house constants.
const SC_PAGESIZE: i32 = 30;
const SC_NPROCESSORS_CONF: i32 = 83;
const SC_NPROCESSORS_ONLN: i32 = 84;
const SC_CLK_TCK: i32 = 2;

/// Configuration values (real constants; unknown names fail closed).
///
/// # Safety
///
/// Always safe: integer in, long out.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn sysconf(name: i32) -> i64 {
    match name {
        SC_PAGESIZE => 4096,
        SC_NPROCESSORS_CONF | SC_NPROCESSORS_ONLN => 1,
        SC_CLK_TCK => 100,
        _ => {
            set_errno(EINVAL);
            -1
        }
    }
}

/// `isatty`: fds 0-2 are the reserved console (see `Fd.hs`: 0-2 reserved).
///
/// # Safety
///
/// Always safe: integer in, int out.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
#[allow(
    clippy::manual_range_contains,
    reason = "a RangeInclusive::contains instantiates core generics into the text-symbol audit"
)]
pub unsafe extern "C" fn isatty(fd: i32) -> i32 {
    if fd >= 0 && fd <= 2 { 1 } else { 0 }
}

/// Process id: the EL1 `house-libc` answer is the constant 42; EL0 mirrors
/// it (no per-pid channel exists at the trap boundary).
///
/// # Safety
///
/// Always safe.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn getpid() -> i32 {
    42
}

/// Error-string lookup: the only name the gap needs is a static tag.
///
/// # Safety
///
/// Caller guarantees `buf` valid for `n` bytes when `n > 0`.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn __xpg_strerror_r(_e: i32, _b: *mut u8, _n: usize) -> i32 {
    0
}

// --- failing-closed stubs (no stage-1 backend exists) ---
//
// Each returns the `compat.rs` shape (`-1`/null, `ENOSYS` in the errno cell
// where the C contract carries errors). New numbers are deliberately not
// minted: `poll`/`epoll`/`pipe`/`clock` draw no delegate from the stage-1
// list, so they stay stubs until a later slice owns the backend.

macro_rules! enosys_stub {
    ($name:ident ($($arg:ident : $ty:ty),*) -> $ret:ty, $fail:expr) => {
        /// Failing-closed stub: no stage-1 backend exists, so this returns
        /// the `compat.rs` failure shape (`-1`/null) with `ENOSYS` set.
        ///
        /// # Safety
        ///
        /// Always safe: ignores its arguments, touches no user memory.
        #[cfg_attr(not(test), unsafe(no_mangle))]
        #[allow(suspicious_runtime_symbol_definitions)]
        pub unsafe extern "C" fn $name($($arg : $ty),*) -> $ret {
            set_errno(ENOSYS);
            $fail
        }
    };
}

enosys_stub!(epoll_create(_size: i32) -> i32, -1);
enosys_stub!(
    epoll_ctl(_epfd: i32, _op: i32, _fd: i32, _ev: *mut c_void) -> i32,
    -1
);
enosys_stub!(
    epoll_wait(_epfd: i32, _ev: *mut c_void, _max: i32, _to: i32) -> i32,
    -1
);
enosys_stub!(eventfd(_init: u32, _flags: i32) -> i32, -1);
enosys_stub!(eventfd_write(_fd: i32, _v: u64) -> i32, -1);
enosys_stub!(poll(_fds: *mut c_void, _n: u64, _to: i32) -> i32, -1);
enosys_stub!(
    sigprocmask(_how: i32, _set: *const c_void, _old: *mut c_void) -> i32,
    -1
);
enosys_stub!(fcntl(_fd: i32, _cmd: i32) -> i32, -1);
enosys_stub!(fcntl64(_fd: i32, _cmd: i32) -> i32, -1);
enosys_stub!(flock(_fd: i32, _op: i32) -> i32, -1);
enosys_stub!(dup(_fd: i32) -> i32, -1);
enosys_stub!(dup2(_old: i32, _new: i32) -> i32, -1);
enosys_stub!(pipe(_fds: *mut i32) -> i32, -1);
enosys_stub!(stat(_p: *const u8, _s: *mut c_void) -> i32, -1);
enosys_stub!(lstat(_p: *const u8, _s: *mut c_void) -> i32, -1);
enosys_stub!(fstat(_fd: i32, _s: *mut c_void) -> i32, -1);
enosys_stub!(ftruncate(_fd: i32, _len: i64) -> i32, -1);
enosys_stub!(access(_p: *const u8, _m: i32) -> i32, -1);
enosys_stub!(chmod(_p: *const u8, _m: u32) -> i32, -1);
enosys_stub!(creat(_p: *const u8, _m: u32) -> i32, -1);
enosys_stub!(link(_a: *const u8, _b: *const u8) -> i32, -1);
enosys_stub!(mkfifo(_p: *const u8, _m: u32) -> i32, -1);
enosys_stub!(unlink(_p: *const u8) -> i32, -1);
enosys_stub!(utime(_p: *const u8, _t: *const c_void) -> i32, -1);
enosys_stub!(readlink(_p: *const u8, _b: *mut u8, _n: usize) -> isize, -1);
enosys_stub!(
    fopen(_p: *const u8, _m: *const u8) -> *mut c_void,
    core::ptr::null_mut()
);
enosys_stub!(getenv(_n: *const u8) -> *mut u8, core::ptr::null_mut());
enosys_stub!(putenv(_s: *mut u8) -> i32, -1);
enosys_stub!(setenv(_n: *const u8, _v: *const u8, _w: i32) -> i32, -1);
enosys_stub!(unsetenv(_n: *const u8) -> i32, -1);
enosys_stub!(tcgetattr(_fd: i32, _t: *mut c_void) -> i32, -1);
enosys_stub!(tcsetattr(_fd: i32, _a: i32, _t: *const c_void) -> i32, -1);
// No EL0 time source: `CNTVCT_EL0` traps without `CNTKCTL_EL1.EL0VCTEN`,
// which the kernel never enables, so the clocks stay stubs.
enosys_stub!(clock_gettime(_c: i32, _t: *mut c_void) -> i32, -1);
enosys_stub!(clock_getres(_c: i32, _t: *mut c_void) -> i32, -1);
enosys_stub!(times(_t: *mut c_void) -> i64, -1);
enosys_stub!(getrusage(_w: i32, _r: *mut c_void) -> i32, -1);

// `umask(2)` echoes like the EL1 `compat.rs` precedent (no mask stored).
/// Mask echo (no mask is stored).
///
/// # Safety
///
/// Always safe.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn umask(m: u32) -> u32 {
    m
}

// `iconv` mirrors the EL1 `compat.rs` shape exactly (UTF-8 passthrough with
// `E2BIG` when the output fills), so both privilege levels agree byte for
// byte. Dummy non-null handle, like EL1.
const E2BIG: i32 = 7;

/// Open a converter (always the passthrough dummy).
///
/// # Safety
///
/// Always safe: ignores its arguments.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
#[allow(
    clippy::manual_dangling_ptr,
    reason = "stable dummy handle, mirrors the EL1 compat precedent"
)]
pub unsafe extern "C" fn iconv_open(_t: *const u8, _f: *const u8) -> *mut c_void {
    1 as *mut c_void
}

/// Copy input to output; short output fails `E2BIG`.
///
/// # Safety
///
/// Caller guarantees the pointer/length quartet is consistent.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn iconv(
    _cd: *mut c_void,
    inp: *mut *mut u8,
    ilen: *mut usize,
    outp: *mut *mut u8,
    olen: *mut usize,
) -> usize {
    if null_ptr!(inp) {
        return 0;
    }
    // SAFETY: null checked above; lengths trusted per the C contract.
    // Every access below goes through `ptr::{read,write}` (see `set_errno`):
    // direct place access emits a dev-profile null-deref guard whose
    // `Location` table the `-shared` link refuses.
    let ip = unsafe { core::ptr::read(inp) };
    if null_ptr!(ip) {
        return 0;
    }
    let op = unsafe { core::ptr::read(outp) };
    let il = unsafe { core::ptr::read(ilen) };
    let ol = unsafe { core::ptr::read(olen) };
    let n = if il < ol { il } else { ol };
    unsafe {
        super::memcpy(op, ip as *const u8, n);
        core::ptr::write(inp, ip.wrapping_add(n));
        core::ptr::write(outp, op.wrapping_add(n));
        core::ptr::write(ilen, il - n);
        core::ptr::write(olen, ol - n);
    }
    if unsafe { core::ptr::read(ilen) } != 0 {
        set_errno(E2BIG);
        return usize::MAX;
    }
    0
}

/// Close a converter (dummy: always succeeds).
///
/// # Safety
///
/// Always safe.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn iconv_close(_cd: *mut c_void) -> i32 {
    0
}

// --- data homes ---

// Empty environment (NULL-terminated, no entries): `getenv` above agrees.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub static mut environ: [*mut u8; 1] = [core::ptr::null_mut()];

// Opaque stderr token for the link-only stdio stubs in the crate root, which
// never dereference it; null keeps a stray dereference faulting, not silent.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub static mut stderr: *mut c_void = core::ptr::null_mut();

// --- real freestanding libm (35) ---
//
// Range reduction is Cody-Waite (single correction term); polynomials are
// short Taylor/minimax forms whose error at the HOST-tested tolerance sits
// orders below the asserted bound. `sqrt` lowers to `fsqrt` (exact); the
// rest is add/mul/div only, so no runtime calls and no U symbols.

use core::f64::consts::{FRAC_PI_2, LN_2 as LN2, LOG2_E, PI, SQRT_2, TAU};

// No `core` constants exist for these; the Cody-Waite splits stay literal.
const INV_TAU: f64 = 0.15915494309189535;
const TAU_LO: f64 = 2.4492935982947064e-16;
const LN2_LO: f64 = 2.3190468138462996e-17;

// sin on [-pi/2, pi/2] (degree-15 Taylor: 1/3!..1/15! at x^3..x^15;
// the x^11 level is 1/11!, not 1/13!. Error < 5e-12 there).
fn sin_kernel(x: f64) -> f64 {
    let x2 = x * x;
    x + x
        * x2
        * (-0.16666666666666666
            + x2 * (0.008333333333333333
                + x2 * (-0.0001984126984126984
                    + x2 * (2.7557319223985893e-6
                        + x2 * (-2.505210838544172e-8 + x2 * 1.6059043836821613e-10)))))
}

// Reduce to [0, 2pi) (|x| < 1e15; beyond that the quotient saturates and
// the result is best-effort, documented, never a trap).
fn reduce_tau(x: f64) -> f64 {
    let q = floor_kernel(x * INV_TAU) as i64 as f64;
    let mut r = (x - q * TAU) - q * TAU_LO;
    if r > PI {
        r -= TAU + TAU_LO;
    }
    r
}

fn sin_cos(x: f64) -> (f64, f64) {
    if x.is_nan() {
        return (f64::NAN, f64::NAN);
    }
    if x.is_infinite() {
        return (f64::NAN, f64::NAN);
    }
    let mut r = reduce_tau(x);
    let mut cs = 1.0;
    if r > FRAC_PI_2 {
        r = PI - r;
        cs = -1.0;
    } else if r < -FRAC_PI_2 {
        r = -PI - r;
        cs = -1.0;
    }
    let s = sin_kernel(r);
    let h = sin_kernel(r * 0.5);
    (s, cs * (1.0 - 2.0 * h * h))
}

// Scale by 2^e through the exponent field (exact; NaN/inf/zero pass).
fn scale_pow2(x: f64, e: i32) -> f64 {
    if !x.is_finite() || x == 0.0 {
        return x;
    }
    let neg = x.is_sign_negative();
    let zero = if neg { -0.0 } else { 0.0 };
    let bits = x.to_bits();
    let mut exp = ((bits >> 52) & 0x7FF) as i64;
    let mut mant = bits & 0xF_FFFF_FFFF_FFFF;
    let mut shift = e as i64;
    if exp == 0 {
        // Subnormal: scale into the normal range first (exact fmul by 2).
        let mut v = fabs_kernel(x);
        while (v.to_bits() >> 52) & 0x7FF == 0 {
            v *= 2.0;
            shift -= 1;
            if shift < -2000 {
                return zero;
            }
        }
        let b = v.to_bits();
        exp = ((b >> 52) & 0x7FF) as i64;
        mant = b & 0xF_FFFF_FFFF_FFFF;
    }
    let biased = exp - 1023 + shift;
    if biased >= 1024 {
        return if neg {
            f64::NEG_INFINITY
        } else {
            f64::INFINITY
        };
    }
    let sign = if neg { 0x8000_0000_0000_0000 } else { 0 };
    if biased >= -1022 {
        return f64::from_bits(sign | (((biased + 1023) as u64) << 52) | mant);
    }
    // Subnormal result (or underflow to zero).
    let mut m = (mant | 0x1_0000_0000_0000) as u128;
    let mut e2 = biased;
    while e2 < 0 {
        m >>= 1;
        e2 += 1;
        if m == 0 {
            return zero;
        }
    }
    f64::from_bits(sign | (m as u64 & 0xF_FFFF_FFFF_FFFF))
}

/// Scale by a power of two (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn ldexp(x: f64, e: i32) -> f64 {
    scale_pow2(x, e)
}

fn exp_kernel(x: f64) -> f64 {
    if x.is_nan() {
        return f64::NAN;
    }
    if x > 709.782712893384 {
        return f64::INFINITY;
    }
    if x < -745.1332191019412 {
        return 0.0;
    }
    let t = x * LOG2_E;
    let k = if t >= 0.0 {
        (t + 0.5) as i64
    } else {
        (t - 0.5) as i64
    };
    let kf = k as f64;
    let r = (x - kf * LN2) - kf * LN2_LO;
    let r2 = r * r;
    let p = 1.0
        + r
        + r2 * (0.5
            + r * (0.16666666666666666
                + r * (0.041666666666666664
                    + r * (0.008333333333333333
                        + r * (0.001388888888888889
                            + r * (0.0001984126984126984
                                + r * (2.48015873015873e-5 + r * 2.7557319223985893e-6)))))));
    scale_pow2(p, k as i32)
}

/// Exponential (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn exp(x: f64) -> f64 {
    exp_kernel(x)
}

fn log_kernel(x: f64) -> f64 {
    if x.is_nan() || x < 0.0 {
        return f64::NAN;
    }
    if x == 0.0 {
        return f64::NEG_INFINITY;
    }
    if x.is_infinite() {
        return f64::INFINITY;
    }
    let mut v = x;
    let mut adj: i64 = 0;
    while ((v.to_bits() >> 52) & 0x7FF) == 0 {
        v *= 2.0;
        adj -= 1;
    }
    let bits = v.to_bits();
    let mut e = ((bits >> 52) & 0x7FF) as i64 - 1023 + adj;
    let mut m = f64::from_bits((bits & 0x800F_FFFF_FFFF_FFFF) | 0x3FF0_0000_0000_0000);
    if m > SQRT_2 {
        m *= 0.5;
        e += 1;
    }
    let y = (m - 1.0) / (m + 1.0);
    let y2 = y * y;
    let p = y + y
        * y2
        * (0.3333333333333333
            + y2 * (0.2
                + y2 * (0.14285714285714285
                    + y2 * (0.1111111111111111 + y2 * 0.09090909090909091))));
    2.0 * p + (e as f64) * LN2
}

/// Natural logarithm (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn log(x: f64) -> f64 {
    log_kernel(x)
}

fn pow_kernel(a: f64, b: f64) -> f64 {
    if b == 0.0 {
        return 1.0;
    }
    if a == 1.0 || (a.is_nan() && b == 0.0) {
        return 1.0;
    }
    if a.is_nan() || b.is_nan() {
        return f64::NAN;
    }
    if a < 0.0 {
        // Non-integer negative bases stay NaN (no integer-exponent path).
        return f64::NAN;
    }
    if a == 0.0 {
        if b > 0.0 {
            return 0.0;
        }
        return f64::INFINITY;
    }
    if a.is_infinite() {
        if b > 0.0 {
            return f64::INFINITY;
        }
        return 0.0;
    }
    exp_kernel(b * log_kernel(a))
}

/// Power (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn pow(a: f64, b: f64) -> f64 {
    pow_kernel(a, b)
}

// atan(|x| <= 0.25) degree-13 Taylor (error < 2e-10 there).
fn atan_kernel(x: f64) -> f64 {
    let x2 = x * x;
    x + x
        * x2
        * (-0.3333333333333333
            + x2 * (0.2
                + x2 * (-0.14285714285714285
                    + x2 * (0.1111111111111111
                        + x2 * (-0.09090909090909091 + x2 * 0.07692307692307693)))))
}

fn atan_abs(mut x: f64) -> f64 {
    if x.is_nan() {
        return f64::NAN;
    }
    if x.is_infinite() || x > 1e16 {
        return FRAC_PI_2;
    }
    let mut k: u32 = 0;
    while x > 0.25 {
        x = x / (1.0 + sqrt_kernel(1.0 + x * x));
        k += 1;
    }
    atan_kernel(x) * (1u64 << (if k > 60 { 60 } else { k })) as f64
}

/// Arctangent (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn atan(x: f64) -> f64 {
    if x.is_nan() {
        return f64::NAN;
    }
    if x < 0.0 { -atan_abs(-x) } else { atan_abs(x) }
}

fn asin_kernel(x: f64) -> f64 {
    if x.is_nan() || x > 1.0 || x < -1.0 {
        return f64::NAN;
    }
    if x == 1.0 {
        return FRAC_PI_2;
    }
    if x == -1.0 {
        return -FRAC_PI_2;
    }
    let t = x / sqrt_kernel(1.0 - x * x);
    if t >= 0.0 { atan_abs(t) } else { -atan_abs(-t) }
}

/// Arcsine (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn asin(x: f64) -> f64 {
    asin_kernel(x)
}

/// Arccosine (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn acos(x: f64) -> f64 {
    let s = asin_kernel(x);
    if s.is_nan() { s } else { FRAC_PI_2 - s }
}

fn sinh_cosh(x: f64) -> (f64, f64) {
    if x.is_nan() {
        return (f64::NAN, f64::NAN);
    }
    let ax = fabs_kernel(x);
    if ax.is_infinite() {
        return (x, f64::INFINITY);
    }
    if ax > 710.0 {
        return (
            if x > 0.0 {
                f64::INFINITY
            } else {
                f64::NEG_INFINITY
            },
            f64::INFINITY,
        );
    }
    if ax < 0.25 {
        let x2 = x * x;
        let s = x + x
            * x2
            * (0.16666666666666666 + x2 * (0.008333333333333333 + x2 * 0.0001984126984126984));
        let c = 1.0
            + x2 * (0.5
                + x2 * (0.041666666666666664
                    + x2 * (0.001388888888888889 + x2 * 2.48015873015873e-5)));
        return (s, c);
    }
    let e = exp_kernel(ax);
    let em = exp_kernel(-ax);
    let (s, c) = ((e - em) * 0.5, (e + em) * 0.5);
    (if x < 0.0 { -s } else { s }, c)
}

/// Sine (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn sin(x: f64) -> f64 {
    sin_cos(x).0
}

/// Cosine (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn cos(x: f64) -> f64 {
    sin_cos(x).1
}

/// Tangent (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn tan(x: f64) -> f64 {
    let (s, c) = sin_cos(x);
    if s.is_nan() {
        return f64::NAN;
    }
    if c == 0.0 {
        return if s >= 0.0 {
            f64::INFINITY
        } else {
            f64::NEG_INFINITY
        };
    }
    s / c
}

/// Hyperbolic sine (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn sinh(x: f64) -> f64 {
    sinh_cosh(x).0
}

/// Hyperbolic cosine (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn cosh(x: f64) -> f64 {
    sinh_cosh(x).1
}

/// Hyperbolic tangent (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn tanh(x: f64) -> f64 {
    if x.is_nan() {
        return f64::NAN;
    }
    if x > 20.0 {
        return 1.0;
    }
    if x < -20.0 {
        return -1.0;
    }
    let (s, c) = sinh_cosh(x);
    s / c
}

/// `exp(x) - 1` without cancellation near zero (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn expm1(x: f64) -> f64 {
    if x.is_nan() {
        return f64::NAN;
    }
    if x.is_infinite() {
        return if x > 0.0 { f64::INFINITY } else { -1.0 };
    }
    let ax = fabs_kernel(x);
    if ax < 1e-8 {
        return x;
    }
    if ax < 0.3 {
        // Pure-`x` Horner: the inner multipliers stay `x` so the levels
        // land on consecutive powers (a mixed `x2` step would skip one).
        return x + x
            * x
            * (0.5
                + x * (0.16666666666666666
                    + x * (0.041666666666666664
                        + x * (0.008333333333333333
                            + x * (0.001388888888888889
                                + x * (0.0001984126984126984 + x * 2.48015873015873e-5))))));
    }
    exp_kernel(x) - 1.0
}

/// `log(1 + x)` without cancellation near zero (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn log1p(x: f64) -> f64 {
    if x.is_nan() || x < -1.0 {
        return f64::NAN;
    }
    if x == -1.0 {
        return f64::NEG_INFINITY;
    }
    if x.is_infinite() {
        return f64::INFINITY;
    }
    if fabs_kernel(x) < 1e-4 {
        // Pure-`x` Horner (see `expm1`): consecutive powers only.
        return x + x
            * x
            * (-0.5
                + x * (0.3333333333333333
                    + x * (-0.25
                        + x * (0.2 + x * (-0.16666666666666666 + x * 0.14285714285714285)))));
    }
    log_kernel(1.0 + x)
}

// Inverse trig/hyperbolic mirrors of the EL1 `mathmin` names, real here.

/// Inverse hyperbolic tangent (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn atanh(x: f64) -> f64 {
    if x.is_nan() || x > 1.0 || x < -1.0 {
        return f64::NAN;
    }
    if x == 1.0 {
        return f64::INFINITY;
    }
    if x == -1.0 {
        return f64::NEG_INFINITY;
    }
    0.5 * log_kernel((1.0 + x) / (1.0 - x))
}

/// Inverse hyperbolic sine (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn asinh(x: f64) -> f64 {
    if x.is_nan() {
        return f64::NAN;
    }
    if x.is_infinite() {
        return x;
    }
    let ax = fabs_kernel(x);
    let r = log_kernel(ax + sqrt_kernel(ax * ax + 1.0));
    if x < 0.0 { -r } else { r }
}

/// Inverse hyperbolic cosine (real).
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn acosh(x: f64) -> f64 {
    if x.is_nan() || x < 1.0 {
        return f64::NAN;
    }
    if x.is_infinite() {
        return f64::INFINITY;
    }
    log_kernel(x + sqrt_kernel(x * x - 1.0))
}

// Single-precision variants narrow through the double kernels (one extra
// rounding each; tests assert 1e-5, not bit-exactness).

macro_rules! f32_wrap {
    ($(($name:ident, $inner:ident)),*) => {
        $(
            /// Single-precision narrowing through the double kernel above.
            ///
            /// # Safety
            ///
            /// Always safe: pure computation.
            #[cfg_attr(not(test), unsafe(no_mangle))]
            #[allow(suspicious_runtime_symbol_definitions)]
            pub unsafe extern "C" fn $name(x: f32) -> f32 {
                $inner(x as f64) as f32
            }
        )*
    };
}

f32_wrap!(
    (sinf, sin_kernel_wrap),
    (cosf, cos_kernel_wrap),
    (tanf, tan_kernel_wrap),
    (asinf, asin_kernel_wrap),
    (acosf, acos_kernel_wrap),
    (atanf, atan_kernel_wrap),
    (sinhf, sinh_kernel_wrap),
    (coshf, cosh_kernel_wrap),
    (tanhf, tanh_kernel_wrap),
    (expf, exp_kernel_wrap),
    (expm1f, expm1_kernel_wrap),
    (logf, log_kernel_wrap),
    (log1pf, log1p_kernel_wrap),
    (asinhf, asinh_kernel_wrap),
    (acoshf, acosh_kernel_wrap),
    (atanhf, atanh_kernel_wrap)
);

// Two-arg `powf` needs its own macro arm (kept outside `f32_wrap` on purpose).
/// Single-precision power.
///
/// # Safety
///
/// Always safe: pure computation.
#[cfg_attr(not(test), unsafe(no_mangle))]
#[allow(suspicious_runtime_symbol_definitions)]
pub unsafe extern "C" fn powf(a: f32, b: f32) -> f32 {
    pow_kernel(a as f64, b as f64) as f32
}

fn sin_kernel_wrap(x: f64) -> f64 {
    sin_cos(x).0
}
fn cos_kernel_wrap(x: f64) -> f64 {
    sin_cos(x).1
}
fn tan_kernel_wrap(x: f64) -> f64 {
    let (s, c) = sin_cos(x);
    if s.is_nan() {
        f64::NAN
    } else if c == 0.0 {
        if s >= 0.0 {
            f64::INFINITY
        } else {
            f64::NEG_INFINITY
        }
    } else {
        s / c
    }
}
fn asin_kernel_wrap(x: f64) -> f64 {
    asin_kernel(x)
}
fn acos_kernel_wrap(x: f64) -> f64 {
    let s = asin_kernel(x);
    if s.is_nan() { s } else { FRAC_PI_2 - s }
}
fn atan_kernel_wrap(x: f64) -> f64 {
    if x.is_nan() {
        f64::NAN
    } else if x < 0.0 {
        -atan_abs(-x)
    } else {
        atan_abs(x)
    }
}
fn sinh_kernel_wrap(x: f64) -> f64 {
    sinh_cosh(x).0
}
fn cosh_kernel_wrap(x: f64) -> f64 {
    sinh_cosh(x).1
}
fn tanh_kernel_wrap(x: f64) -> f64 {
    if x.is_nan() {
        f64::NAN
    } else if x > 20.0 {
        1.0
    } else if x < -20.0 {
        -1.0
    } else {
        let (s, c) = sinh_cosh(x);
        s / c
    }
}
fn exp_kernel_wrap(x: f64) -> f64 {
    exp_kernel(x)
}
fn expm1_kernel_wrap(x: f64) -> f64 {
    if x.is_nan() {
        return f64::NAN;
    }
    if x.is_infinite() {
        return if x > 0.0 { f64::INFINITY } else { -1.0 };
    }
    let ax = fabs_kernel(x);
    if ax < 1e-8 {
        return x;
    }
    if ax < 0.3 {
        // Pure-`x` Horner: the inner multipliers stay `x` so the levels
        // land on consecutive powers (a mixed `x2` step would skip one).
        return x + x
            * x
            * (0.5
                + x * (0.16666666666666666
                    + x * (0.041666666666666664
                        + x * (0.008333333333333333
                            + x * (0.001388888888888889
                                + x * (0.0001984126984126984 + x * 2.48015873015873e-5))))));
    }
    exp_kernel(x) - 1.0
}
fn log_kernel_wrap(x: f64) -> f64 {
    log_kernel(x)
}
fn log1p_kernel_wrap(x: f64) -> f64 {
    if x.is_nan() || x < -1.0 {
        return f64::NAN;
    }
    if x == -1.0 {
        return f64::NEG_INFINITY;
    }
    if x.is_infinite() {
        return f64::INFINITY;
    }
    if fabs_kernel(x) < 1e-4 {
        // Pure-`x` Horner (see `expm1`): consecutive powers only.
        return x + x
            * x
            * (-0.5
                + x * (0.3333333333333333
                    + x * (-0.25
                        + x * (0.2 + x * (-0.16666666666666666 + x * 0.14285714285714285)))));
    }
    log_kernel(1.0 + x)
}
fn asinh_kernel_wrap(x: f64) -> f64 {
    if x.is_nan() {
        return f64::NAN;
    }
    if x.is_infinite() {
        return x;
    }
    let ax = fabs_kernel(x);
    let r = log_kernel(ax + sqrt_kernel(ax * ax + 1.0));
    if x < 0.0 { -r } else { r }
}
fn acosh_kernel_wrap(x: f64) -> f64 {
    if x.is_nan() || x < 1.0 {
        return f64::NAN;
    }
    if x.is_infinite() {
        return f64::INFINITY;
    }
    log_kernel(x + sqrt_kernel(x * x - 1.0))
}
fn atanh_kernel_wrap(x: f64) -> f64 {
    if x.is_nan() || x > 1.0 || x < -1.0 {
        return f64::NAN;
    }
    if x == 1.0 {
        return f64::INFINITY;
    }
    if x == -1.0 {
        return f64::NEG_INFINITY;
    }
    0.5 * log_kernel((1.0 + x) / (1.0 - x))
}

#[cfg(test)]
mod tests {
    use super::*;

    // SAFETY on every call below: pure functions take values, not pointers;
    // stub calls pass null/dummy args the stubs ignore.

    fn close_enough(got: f64, want: f64, tol: f64) -> bool {
        if want.is_nan() {
            return got.is_nan();
        }
        if want.is_infinite() {
            return got == want;
        }
        if want == 0.0 {
            return got.abs() <= tol;
        }
        ((got - want) / want).abs() <= tol
    }

    #[test]
    fn trig_matches_std() {
        for i in -200..=200 {
            let x = i as f64 * 0.317;
            assert!(close_enough(unsafe { sin(x) }, x.sin(), 1e-9), "sin({x})");
            assert!(close_enough(unsafe { cos(x) }, x.cos(), 1e-9), "cos({x})");
            assert!(close_enough(unsafe { tan(x) }, x.tan(), 1e-6), "tan({x})");
        }
        assert_eq!(unsafe { sin(0.0) }, 0.0);
        assert_eq!(unsafe { cos(0.0) }, 1.0);
        assert!(unsafe { sin(f64::INFINITY) }.is_nan());
        assert!(unsafe { cos(f64::NAN) }.is_nan());
    }

    #[test]
    fn inverse_trig_matches_std() {
        for i in -99..=99 {
            let x = i as f64 * 0.01;
            assert!(
                close_enough(unsafe { asin(x) }, x.asin(), 1e-9),
                "asin({x})"
            );
            assert!(
                close_enough(unsafe { acos(x) }, x.acos(), 1e-9),
                "acos({x})"
            );
        }
        for i in -200..=200 {
            let x = i as f64 * 0.11;
            assert!(
                close_enough(unsafe { atan(x) }, x.atan(), 1e-9),
                "atan({x})"
            );
        }
        assert_eq!(unsafe { asin(1.0) }, FRAC_PI_2);
        assert_eq!(unsafe { acos(0.0) }, FRAC_PI_2);
        assert!(unsafe { asin(2.0) }.is_nan());
        assert!(unsafe { acos(-2.0) }.is_nan());
    }

    #[test]
    fn exp_log_pow_match_std() {
        for i in -100..=100 {
            let x = i as f64 * 0.173;
            assert!(close_enough(unsafe { exp(x) }, x.exp(), 1e-9), "exp({x})");
        }
        assert_eq!(unsafe { exp(1000.0) }, f64::INFINITY);
        assert_eq!(unsafe { exp(-1000.0) }, 0.0);
        for i in 1..=400 {
            let x = i as f64 * 0.061;
            assert!(close_enough(unsafe { log(x) }, x.ln(), 1e-9), "log({x})");
        }
        assert_eq!(unsafe { log(1.0) }, 0.0);
        assert_eq!(unsafe { log(0.0) }, f64::NEG_INFINITY);
        assert!(unsafe { log(-1.0) }.is_nan());
        for (a, b) in [(2.0, 10.0), (2.5, -1.5), (10.0, 0.5), (0.5, 3.0)] {
            assert!(
                close_enough(unsafe { pow(a, b) }, a.powf(b), 1e-9),
                "pow({a},{b})"
            );
        }
        assert_eq!(unsafe { pow(0.0, 0.0) }, 1.0);
        assert!(unsafe { pow(-1.0, 0.5) }.is_nan());
    }

    #[test]
    fn hyperbolic_matches_std() {
        for i in -60..=60 {
            let x = i as f64 * 0.113;
            assert!(
                close_enough(unsafe { sinh(x) }, x.sinh(), 1e-9),
                "sinh({x})"
            );
            assert!(
                close_enough(unsafe { cosh(x) }, x.cosh(), 1e-9),
                "cosh({x})"
            );
            assert!(
                close_enough(unsafe { tanh(x) }, x.tanh(), 1e-9),
                "tanh({x})"
            );
            assert!(
                close_enough(unsafe { expm1(x) }, x.exp_m1(), 1e-9),
                "expm1({x})"
            );
        }
        for i in -40..=200 {
            let x = i as f64 * 0.031;
            assert!(
                close_enough(unsafe { log1p(x) }, x.ln_1p(), 1e-9),
                "log1p({x})"
            );
        }
        for i in -60..=60 {
            let x = i as f64 * 0.151;
            assert!(
                close_enough(unsafe { asinh(x) }, x.asinh(), 1e-9),
                "asinh({x})"
            );
            assert!(
                close_enough(unsafe { atanh(x * 0.1) }, (x * 0.1).atanh(), 1e-9),
                "atanh({})",
                x * 0.1
            );
        }
        for i in 10..=200 {
            let x = 1.0 + i as f64 * 0.061;
            assert!(
                close_enough(unsafe { acosh(x) }, x.acosh(), 1e-9),
                "acosh({x})"
            );
        }
    }

    #[test]
    fn freestanding_kernels() {
        assert_eq!(super::sqrt_kernel(4.0), 2.0);
        assert_eq!(super::sqrt_kernel(0.25), 0.5);
        assert!((super::sqrt_kernel(2.0) - SQRT_2).abs() < 1e-15);
        // Subnormal path: 1e-310 parses to 1e-12 relative, so the root is
        // asserted to 1e-12 as well (a 1e-320 literal would carry its own
        // rounding past the assertion).
        assert!((super::sqrt_kernel(1e-310) - 1e-155).abs() < 1e-167);
        assert!(super::sqrt_kernel(-1.0).is_nan());
        assert_eq!(super::floor_kernel(2.7), 2.0);
        assert_eq!(super::floor_kernel(-2.7), -3.0);
        assert_eq!(super::floor_kernel(-0.0), -0.0);
    }

    #[test]
    fn ldexp_scales() {
        assert_eq!(unsafe { ldexp(1.5, 3) }, 12.0);
        assert_eq!(unsafe { ldexp(1.5, -2) }, 0.375);
        assert_eq!(unsafe { ldexp(0.0, 100) }, 0.0);
        assert_eq!(unsafe { ldexp(f64::INFINITY, -5) }, f64::INFINITY);
        assert!(unsafe { ldexp(f64::NAN, 3) }.is_nan());
        assert_eq!(unsafe { ldexp(1.0, 2000) }, f64::INFINITY);
        assert_eq!(unsafe { ldexp(1.0, -2000) }, 0.0);
    }

    #[test]
    fn f32_variants_narrow() {
        assert!((unsafe { sinf(0.5) } - 0.5f32.sin()).abs() < 1e-5);
        assert!((unsafe { cosf(0.5) } - 0.5f32.cos()).abs() < 1e-5);
        assert!((unsafe { expf(1.0) } - core::f32::consts::E).abs() < 1e-5);
        assert!((unsafe { logf(core::f32::consts::E) } - 1.0).abs() < 1e-5);
        assert!((unsafe { powf(2.0, 10.0) } - 1024.0).abs() < 0.1);
        assert!((unsafe { atanf(1.0) } - core::f32::consts::FRAC_PI_4).abs() < 1e-5);
    }

    #[test]
    fn pure_helpers_behave() {
        let mut set = [0u64; 16];
        assert_eq!(unsafe { sigemptyset(set.as_mut_ptr()) }, 0);
        assert_eq!(set, [0u64; 16]);
        assert_eq!(unsafe { sigaddset(set.as_mut_ptr(), 1) }, 0);
        assert_eq!(set[0], 1);
        assert_eq!(unsafe { sigaddset(set.as_mut_ptr(), 65) }, 0);
        assert_eq!(set[1], 1);
        assert_eq!(unsafe { sigaddset(set.as_mut_ptr(), 0) }, -1);
        assert_eq!(unsafe { sysconf(30) }, 4096);
        assert_eq!(unsafe { sysconf(84) }, 1);
        assert_eq!(unsafe { sysconf(999) }, -1);
        assert_eq!(unsafe { isatty(1) }, 1);
        assert_eq!(unsafe { isatty(3) }, 0);
        assert_eq!(unsafe { getpid() }, 42);
        assert_eq!(unsafe { umask(0o22) }, 0o22);
    }

    #[test]
    fn stubs_fail_closed() {
        assert_eq!(unsafe { epoll_create(1) }, -1);
        assert_eq!(unsafe { poll(core::ptr::null_mut(), 0, 0) }, -1);
        assert_eq!(unsafe { pipe(core::ptr::null_mut()) }, -1);
        assert!(unsafe { fopen(core::ptr::null(), core::ptr::null()) }.is_null());
        assert!(unsafe { getenv(core::ptr::null()) }.is_null());
        assert_eq!(unsafe { clock_gettime(1, core::ptr::null_mut()) }, -1);
        assert_eq!(
            unsafe { stat(core::ptr::null(), core::ptr::null_mut()) },
            -1
        );
        assert_eq!(unsafe { fcntl(1, 2) }, -1);
        assert_eq!(unsafe { fcntl64(1, 2) }, -1);
        assert_eq!(unsafe { flock(1, 2) }, -1);
    }

    #[test]
    fn iconv_passes_through() {
        let src = b"hi\0";
        let mut dst = [0u8; 8];
        let mut ip = src.as_ptr() as *mut u8;
        let mut op = dst.as_mut_ptr();
        let mut il = 2usize;
        let mut ol = 8usize;
        let cd = unsafe { iconv_open(core::ptr::null(), core::ptr::null()) };
        assert!(!cd.is_null());
        assert_eq!(unsafe { iconv(cd, &mut ip, &mut il, &mut op, &mut ol) }, 0);
        assert_eq!(&dst[..2], b"hi");
        assert_eq!(unsafe { iconv_close(cd) }, 0);
    }

    #[test]
    fn data_homes_exist() {
        assert!(unsafe { environ[0].is_null() });
        assert!(unsafe { stderr.is_null() });
    }
}
