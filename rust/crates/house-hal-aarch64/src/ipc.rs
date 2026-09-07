//! IPC — `ipc.c` transliteration.
//!
//! EL0 `svc #0x10..0x14` validation layer. Trap context cannot block on the
//! EL1 Haskell `Kernel.IPC.Endpoint` rendezvous (`QSem+MVar`), so dispatch
//! validates every EL0-controlled field (op, word count, user-VA window,
//! grant alignment/perm) with precise errnos and returns `-38` (ENOSYS) once
//! validation passes — the queue itself stays Haskell-owned until a future
//! trap-safe delegation ring lands. Unknown `op` returns `-22`, never traps.
//!
//! Errno mapping once the ring lands (mirrors `Kernel.Userspace.Syscall` and
//! `Kernel.IPC.Types`): unknown/freed endpoint id → `NoSuchEndpoint` (-2,
//! `ENOENT`; the `nsLookupChecked` miss path, dmesg-logged); capability
//! mismatch → `NotOwner` (-1, `EPERM`; log-only in this slice via `checkCap`);
//! full queue → `QueueFull` (`EAGAIN`); `callTimeout` expiry → `WouldBlock`.
//! Capability tokens are minted in `newEndpoint`; the trap boundary keeps
//! non-blocking try semantics so a hostile EL0 caller cannot wedge the queue.
//!
//! Arg convention: SEND/CALL/REPLY take `(ep, va, nwords, tag)`; RECV takes
//! `(ep, va, nwords, _)` with `(0, 0)` meaning no reply buffer; GRANT_MAP
//! takes `(ep, page_va, perm, _)` with `perm` 0 = RO, 1 = RW.

use crate::svc::validate_user_buffer;

const IPC_SEND: u32 = 0x10;
const IPC_RECV: u32 = 0x11;
const IPC_CALL: u32 = 0x12;
const IPC_REPLY: u32 = 0x13;
const IPC_GRANT_MAP: u32 = 0x14;

// Mirrors Haskell `maxMsgWords` (8 inline words); bulk moves go via grants.
const IPC_MAX_WORDS: u64 = 8;
// Single-page cap for `house_ipc_copy_msg` (grant moves are page-sized).
const IPC_MAX_COPY: usize = 4096;
// TTBR0 user window (see `svc.rs` `validate_user_buffer`).
const USER_LO: u64 = 0x01000000;
const USER_HI: u64 = 0x1000000000;

const EFAULT: i64 = -14;
const EINVAL: i64 = -22;
const ENOSYS: i64 = -38;

unsafe fn inline_words_ok(va: u64, nwords: u64) -> i64 {
    // SAFETY: integer-only pre-check; page-table walk via `validate_user_buffer`.
    unsafe {
        if nwords > IPC_MAX_WORDS {
            return EINVAL;
        }
        let nbytes = nwords * 8;
        if nbytes == 0 {
            return 0;
        }
        if validate_user_buffer(va, nbytes) != 0 {
            return EFAULT;
        }
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_ipc_svc_dispatch(
    op: u32,
    x0: u64,
    x1: u64,
    x2: u64,
    _x3: u64,
) -> i64 {
    // SAFETY: trap context; integer validation plus page-table reads only,
    // never blocks on the Haskell rendezvous; unknown `op` returns an error.
    let _ep = x0;
    // SAFETY: validator contract (page-table reads only).
    let r = unsafe { validate_ipc(op, x1, x2) };
    if r == VALID_PARK {
        return ENOSYS;
    }
    r
}

// Validation outcome shared by dispatch (errno inline) and the park gate.
const VALID_PARK: i64 = 1;

// SAFETY: integer validation plus EL1 page-table reads only; no locks,
// no allocation, never blocks on the Haskell rendezvous.
unsafe fn validate_ipc(op: u32, x1: u64, x2: u64) -> i64 {
    // Integer validation plus page-table reads only; no locks, no blocking.
    match op {
        IPC_SEND | IPC_CALL | IPC_REPLY => {
            // SAFETY: validator contract (page-table reads only).
            let r = unsafe { inline_words_ok(x1, x2) };
            if r != 0 {
                return r;
            }
            VALID_PARK
        }
        IPC_RECV => {
            if x1 == 0 && x2 == 0 {
                return VALID_PARK;
            }
            // SAFETY: validator contract (page-table reads only).
            let r = unsafe { inline_words_ok(x1, x2) };
            if r != 0 {
                return r;
            }
            VALID_PARK
        }
        IPC_GRANT_MAP => {
            if x2 > 1 {
                return EINVAL;
            }
            if x1 & 0xFFF != 0 {
                return EINVAL;
            }
            // SAFETY: page-table reads only.
            if unsafe { validate_user_buffer(x1, 4096) } != 0 {
                return EFAULT;
            }
            // Grant page transfer has no Haskell pairing yet: stay inline
            // ENOSYS (handled by the dispatch wrapper, never parked).
            ENOSYS
        }
        _ => EINVAL,
    }
}

// SAFETY: trap context (`c_handle_sync` park gate); same integer + page-table
// validation as dispatch, no locks or allocation. Returns 1 when the call
// validated and should park for Haskell pairing, 0 when validation failed
// (caller falls through to dispatch for the precise errno), -22 unknown op.
// GRANT_MAP always returns 0 (inline ENOSYS until the grant-transfer slice).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_ipc_should_park(op: u32, x1: u64, x2: u64) -> i32 {
    // SAFETY: delegates to the lock-free validator.
    let r = unsafe { validate_ipc(op, x1, x2) };
    if r == VALID_PARK {
        1
    } else if r == ENOSYS || r == EFAULT || r == EINVAL {
        0
    } else {
        -22
    }
}

fn range_in_window(ptr: u64, end: u64) -> bool {
    if ptr < USER_HI {
        ptr >= USER_LO && end <= USER_HI && end >= ptr
    } else {
        end >= ptr
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_ipc_copy_msg(src: *const u8, dst: *mut u8, len: usize) {
    if src.is_null() || dst.is_null() {
        return;
    }
    if len == 0 || len > IPC_MAX_COPY {
        return;
    }
    let s = src as u64;
    let d = dst as u64;
    let n = len as u64;
    let s_end = match s.checked_add(n) {
        Some(e) => e,
        None => return,
    };
    let d_end = match d.checked_add(n) {
        Some(e) => e,
        None => return,
    };
    if !range_in_window(s, s_end) || !range_in_window(d, d_end) {
        return;
    }
    // SAFETY: non-null, `len <= IPC_MAX_COPY`, no wrap on `+len`, both ranges
    // inside the user window (or kernel-high with no wrap); byte copy needs no
    // overlap precondition and `dmb ish` ordering is preserved.
    unsafe {
        core::arch::asm!("dmb ish", options(nostack, preserves_flags));
        // manual byte copy to avoid `copy_nonoverlapping` precondition on null
        for i in 0..len {
            *dst.add(i) = *src.add(i);
        }
        core::arch::asm!("dmb ish", options(nostack, preserves_flags));
    }
}
