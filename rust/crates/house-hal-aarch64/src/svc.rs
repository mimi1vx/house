//! Supervisor calls — `svc.c` transliteration.

const HOUSE_SVC_YIELD: u32 = 0x00;
const HOUSE_SVC_WRITE: u32 = 0x01;
const HOUSE_SVC_EXIT: u32 = 0x02;
const HOUSE_SVC_BRK: u32 = 0x03;
// Track O fd/fork numbers (Haskell Fd table + forkProc land first; EL0 trap
// delegation ring wires them next -- same pattern as the IPC slice).
const HOUSE_SVC_OPEN: u32 = 0x04;
const HOUSE_SVC_READ: u32 = 0x05;
const HOUSE_SVC_WRITE_FD: u32 = 0x06;
const HOUSE_SVC_CLOSE: u32 = 0x07;
const HOUSE_SVC_FORK: u32 = 0x08;
const HOUSE_SVC_WAIT: u32 = 0x09;
const HOUSE_SVC_SEEK: u32 = 0x0A;
// EL0 exec replaces the image under the same pid (path VA in x0,
// NUL-terminated, like OPEN). Rides the delegation ring.
const HOUSE_SVC_EXEC: u32 = 0x0B;
const HOUSE_SVC_IPC_SEND: u32 = 0x10;
const HOUSE_SVC_IPC_RECV: u32 = 0x11;
const HOUSE_SVC_IPC_CALL: u32 = 0x12;
const HOUSE_SVC_IPC_REPLY: u32 = 0x13;
const HOUSE_SVC_IPC_GRANT_MAP: u32 = 0x14;

static mut HOUSE_USER_EXITED: i32 = 0;
static mut HOUSE_USER_EXIT_CODE: i32 = 0;

// Per-pid EL0 exit table: fixed 64-slot array keyed by
// pdir pointer, lock-free (single-copy 64-bit field accesses). Trap context
// (`house_set_exit` / `house_el0_park` from `c_handle_sync`) must never take
// locks, so all lookup/update paths are bounded linear scans with no allocation.
// `save` holds the 896B trap frame for parked-syscall resume; `elr` is the
// ELR as-delivered (already past the trapped `svc` on hvf+tcg — resume must
// NOT add 4, see the trap-resume audit in `c_start.rs`).
const EL0_N: usize = 64;

// Park request codes (svc #imm that parks instead of completing inline).
// YIELD + BRK + fd 0x04..0x07/0x0A + fork 0x08/wait 0x09/exec 0x0B +
// IPC 0x10..0x13 ride the delegation ring (validate-then-park in
// `c_handle_sync`); GRANT_MAP 0x14 stays inline ENOSYS
// until the grant-transfer slice.
const EL0_REQ_YIELD: u32 = 0x00;
const EL0_REQ_BRK: u32 = 0x03;
const EL0_REQ_OPEN: u32 = 0x04;
const EL0_REQ_READ: u32 = 0x05;
const EL0_REQ_WRITE_FD: u32 = 0x06;
const EL0_REQ_CLOSE: u32 = 0x07;
const EL0_REQ_FORK: u32 = 0x08;
const EL0_REQ_WAIT: u32 = 0x09;
const EL0_REQ_SEEK: u32 = 0x0A;
const EL0_REQ_EXEC: u32 = 0x0B;
const EL0_REQ_IPC_SEND: u32 = 0x10;
const EL0_REQ_IPC_RECV: u32 = 0x11;
const EL0_REQ_IPC_CALL: u32 = 0x12;
const EL0_REQ_IPC_REPLY: u32 = 0x13;

#[derive(Clone, Copy)]
struct El0Slot {
    pdir: u64,
    save: [u64; 112],
    elr: u64,
    sp_el0: u64,
    req: u32,
    parked: i32,
    exit_code: i32,
    exited: i32,
}

const EL0_FREE: El0Slot = El0Slot {
    pdir: 0,
    save: [0; 112],
    elr: 0,
    sp_el0: 0,
    req: 0,
    parked: 0,
    exit_code: 0,
    exited: 0,
};

static mut EL0_TABLE: [El0Slot; 64] = [EL0_FREE; 64];

unsafe extern "C" {
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
    fn house_ipc_svc_dispatch(op: u32, x0: u64, x1: u64, x2: u64, x3: u64) -> i64;
    fn current_pdir() -> *mut u8;
    fn house_set_recorded_pdir(pdir: *mut u8);
    fn house_resume_asm(save: *const u64, elr: u64, sp_el0: u64, pdir: *mut u8, asid: u64);
}

unsafe fn translate_va(va: u64) -> usize {
    // SAFETY: walks recorded TTBR0; caller guarantees EL1 and SpinLock not needed for svc read.
    unsafe { translate_va_pdir(current_pdir(), va) }
}

// SAFETY: EL1 page-table reads against the given pdir only; caller guarantees
// EL1, the pdir outlives the call (Haskell holds `userSem` across the copy so
// `freePDir` cannot run concurrently), and no lock is needed for the read.
unsafe fn translate_va_pdir(pdir: *mut u8, va: u64) -> usize {
    unsafe {
        if pdir.is_null() || (pdir as usize & 4095) != 0 {
            return 0;
        }
        let l0 = pdir as *mut u64;
        let d0 = *l0.add(((va >> 39) & 0x1FF) as usize);
        if d0 & 1 == 0 {
            return 0;
        }
        let l1 = (d0 & !0xFFF) as *mut u64;
        let d1 = *l1.add(((va >> 30) & 0x1FF) as usize);
        if d1 & 1 == 0 {
            return 0;
        }
        let l2 = (d1 & !0xFFF) as *mut u64;
        let d2 = *l2.add(((va >> 21) & 0x1FF) as usize);
        if d2 & 1 == 0 {
            return 0;
        }
        let l3 = (d2 & !0xFFF) as *mut u64;
        let d3 = *l3.add(((va >> 12) & 0x1FF) as usize);
        if d3 & 1 == 0 {
            return 0;
        }
        ((d3 & !0xFFF) | (va & 0xFFF)) as usize
    }
}

// Word-granular user copy against an explicit pdir for the IPC ring. While a
// pid is parked the recorded `current_pdir` is the kernel root, so Haskell
// passes the pid slot's pdir and these helpers never consult the recorded
// root. Bounds: nwords <= 8 (one IPC message), 8-byte aligned VA inside the
// user window, no wrapping; every word re-translated (per-page walk).
// Returns 0 ok, -14 EFAULT, -22 EINVAL.
fn check_user_words(pdir: *mut u8, va: u64, io: *const u64, nwords: u64) -> i64 {
    if pdir.is_null() || io.is_null() {
        return -14;
    }
    if nwords > 8 {
        return -22;
    }
    if va & 7 != 0 {
        return -22;
    }
    let len = nwords * 8;
    let end = match va.checked_add(len) {
        Some(e) => e,
        None => return -14,
    };
    if va < 0x01000000 || end > 0x100000000 {
        return -14;
    }
    0
}

// SAFETY: EL1 thread context (Haskell park loop, capability free); `out` must
// hold `nwords` u64. Page-table reads + PA loads only, no locks.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_user_read(
    pdir: *mut u8,
    va: u64,
    out: *mut u64,
    nwords: u64,
) -> i32 {
    unsafe {
        let rc = check_user_words(pdir, va, out, nwords);
        if rc != 0 {
            return rc as i32;
        }
        for i in 0..nwords {
            let wva = va + i * 8;
            let pa = translate_va_pdir(pdir, wva);
            if pa == 0 {
                return -14;
            }
            // SAFETY: `pa` is an identity-mapped RAM byte; `out` holds nwords.
            *out.add(i as usize) = *(pa as *const u64);
        }
        0
    }
}

// SAFETY: EL1 thread context (Haskell park loop, capability free); `inp` must
// hold `nwords` u64. Page-table reads + PA stores only, no locks.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_user_write(
    pdir: *mut u8,
    va: u64,
    inp: *const u64,
    nwords: u64,
) -> i32 {
    unsafe {
        let rc = check_user_words(pdir, va, inp as *const u64, nwords);
        if rc != 0 {
            return rc as i32;
        }
        for i in 0..nwords {
            let wva = va + i * 8;
            let pa = translate_va_pdir(pdir, wva);
            if pa == 0 {
                return -14;
            }
            // SAFETY: `pa` is an identity-mapped RAM byte; `inp` holds nwords.
            *(pa as *mut u64) = *inp.add(i as usize);
        }
        0
    }
}

pub(crate) unsafe fn validate_user_buffer(va: u64, len: u64) -> i32 {
    // SAFETY: EL1 page-table reads only; caller guarantees EL1 and no lock needed for svc read.
    if len == 0 {
        return 0;
    }
    if len > 65536 {
        return -1;
    }
    let end = match va.checked_add(len) {
        Some(e) => e,
        None => return -1,
    };
    if va < 0x01000000 || end > 0x100000000 {
        return -1;
    }
    let start_page = va & !4095;
    let end_page = (end - 1) & !4095;
    let mut p = start_page;
    loop {
        if unsafe { translate_va(p) } == 0 {
            return -1;
        }
        if p == end_page {
            break;
        }
        match p.checked_add(4096) {
            Some(n) => p = n,
            None => return -1,
        }
        if p < start_page {
            return -1;
        }
    }
    0
}

// Validation outcome shared by dispatch (errno inline) and the park gates.
const VALID_PARK: i64 = 1;
const EFAULT: i64 = -14;
const EINVAL: i64 = -22;
const ENOSYS: i64 = -38;

// Trap-side NUL-terminated path check against the trapping pdir
// (page-table reads only, no locks). Scans at most `max` bytes for NUL:
// 0 ok, -14 unmapped byte, -22 no NUL within `max`.
unsafe fn validate_cstring_current(va: u64, max: u64) -> i64 {
    unsafe {
        if va < 0x01000000 {
            return EFAULT;
        }
        let end = match va.checked_add(max) {
            Some(e) => e,
            None => return EFAULT,
        };
        if end > 0x100000000 {
            return EFAULT;
        }
        for i in 0..max {
            let wva = va + i;
            let pa = translate_va(wva);
            if pa == 0 {
                return EFAULT;
            }
            // SAFETY: `pa` is an identity-mapped RAM byte.
            if *(pa as *const u8) == 0 {
                return 0;
            }
        }
        EINVAL
    }
}

// Shared fd validator: VALID_PARK when the call is well-formed and should
// park for Haskell pairing, otherwise a precise errno (EFAULT/EINVAL).
// Arg convention (svc x0..x2): OPEN(path_va, flags, _), READ/WRITE(fd, buf, len),
// CLOSE(fd, _, _), SEEK(fd, off, whence). fd/flag/whence values stay
// Haskell-checked; only user-memory shape is rejected trap-side.
unsafe fn validate_fd(op: u32, x0: u64, x1: u64, x2: u64) -> i64 {
    unsafe {
        match op {
            HOUSE_SVC_OPEN => {
                let r = validate_cstring_current(x0, 256);
                if r != 0 {
                    return r;
                }
                VALID_PARK
            }
            HOUSE_SVC_READ | HOUSE_SVC_WRITE_FD => {
                if x2 > 65536 {
                    return EINVAL;
                }
                if validate_user_buffer(x1, x2) != 0 {
                    return EFAULT;
                }
                VALID_PARK
            }
            HOUSE_SVC_CLOSE | HOUSE_SVC_SEEK => VALID_PARK,
            _ => EINVAL,
        }
    }
}

// SAFETY: trap context (`c_handle_sync` park gate); integer + page-table
// validation only, no locks or allocation. Returns 1 when validated and the
// caller should park, 0 when validation failed (caller falls through to
// dispatch for the precise errno), -22 unknown op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_fd_should_park(op: u32, x0: u64, x1: u64, x2: u64) -> i32 {
    // SAFETY: delegates to the lock-free validator.
    let r = unsafe { validate_fd(op, x0, x1, x2) };
    if r == VALID_PARK {
        1
    } else if r == ENOSYS || r == EFAULT || r == EINVAL {
        0
    } else {
        -22
    }
}

// SAFETY: trap context (`c_handle_sync` park gate); brk carries no user
// memory (x0 = new break), so every op == 0x03 parks and Haskell decides
// window/ENOMEM. Returns 1 park / -22 unknown op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_brk_should_park(op: u32, _x0: u64) -> i32 {
    if op == HOUSE_SVC_BRK { 1 } else { -22 }
}

// SAFETY: trap context (`c_handle_sync` park gate); fork carries no user
// memory (child inherits the parent trap frame via `house_el0_clone_slot`,
// x0 = 0 in the child, parent resumes with the child pid), so every
// op == 0x08 parks and Haskell decides pid/ENOMEM. Returns 1 park / -22
// unknown op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_fork_should_park(op: u32, _x0: u64) -> i32 {
    if op == HOUSE_SVC_FORK { 1 } else { -22 }
}

// SAFETY: trap context (`c_handle_sync` park gate); wait carries only a pid
// in x0 (Haskell validates membership, blocks until the child exits, reaps,
// and resumes with the exit code), so every op == 0x09 parks and Haskell
// decides ENOENT/EINVAL. Returns 1 park / -22 unknown op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_wait_should_park(op: u32, _x0: u64) -> i32 {
    if op == HOUSE_SVC_WAIT { 1 } else { -22 }
}

// SAFETY: trap context (`c_handle_sync` park gate); exec carries a
// NUL-terminated path in x0 (same 256B bound as OPEN, checked against the
// trapping pdir with page-table reads only, no locks). Returns 1 when
// validated and the caller should park, 0 when validation failed (caller
// falls through to dispatch for the precise errno), -22 unknown op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_exec_should_park(op: u32, x0: u64) -> i32 {
    // SAFETY: delegates to the lock-free validator.
    if op != HOUSE_SVC_EXEC {
        return -22;
    }
    let r = unsafe { validate_cstring_current(x0, 256) };
    if r == 0 { 1 } else { 0 }
}

// Byte-granular user copy against an explicit pdir for the fd ring. While a
// pid is parked the recorded `current_pdir` is the kernel root, so Haskell
// passes the pid slot's pdir. Bounds: len <= 65536, VA window, no wrapping;
// every byte re-translated (per-byte walk, page faults impossible —
// unmapped returns EFAULT). Returns 0 ok, -14 EFAULT, -22 EINVAL.
// SAFETY: EL1 thread context (Haskell park loop, capability free); `out`
// must hold `len` bytes. Page-table reads + PA loads only, no locks.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_user_read_bytes(
    pdir: *mut u8,
    va: u64,
    out: *mut u8,
    len: u64,
) -> i32 {
    unsafe {
        if pdir.is_null() || out.is_null() {
            return -14;
        }
        if len > 65536 {
            return -22;
        }
        if len == 0 {
            return 0;
        }
        let end = match va.checked_add(len) {
            Some(e) => e,
            None => return -14,
        };
        if va < 0x01000000 || end > 0x100000000 {
            return -14;
        }
        for i in 0..len {
            let pa = translate_va_pdir(pdir, va + i);
            if pa == 0 {
                return -14;
            }
            // SAFETY: `pa` is identity-mapped RAM; `out` holds `len` bytes.
            *out.add(i as usize) = *(pa as *const u8);
        }
        0
    }
}

// SAFETY: EL1 thread context (Haskell park loop, capability free); `inp`
// must hold `len` bytes. Page-table reads + PA stores only, no locks.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_user_write_bytes(
    pdir: *mut u8,
    va: u64,
    inp: *const u8,
    len: u64,
) -> i32 {
    unsafe {
        if pdir.is_null() || inp.is_null() {
            return -14;
        }
        if len > 65536 {
            return -22;
        }
        if len == 0 {
            return 0;
        }
        let end = match va.checked_add(len) {
            Some(e) => e,
            None => return -14,
        };
        if va < 0x01000000 || end > 0x100000000 {
            return -14;
        }
        for i in 0..len {
            let pa = translate_va_pdir(pdir, va + i);
            if pa == 0 {
                return -14;
            }
            // SAFETY: `pa` is identity-mapped RAM; `inp` holds `len` bytes.
            *(pa as *mut u8) = *inp.add(i as usize);
        }
        0
    }
}

// NUL-terminated string length against an explicit pdir for OPEN path
// resolution. Scans at most `max` bytes; on success `*out_len` holds the
// length excluding NUL. Returns 0 ok, -14 fault, -22 no NUL within max.
// SAFETY: EL1 thread context (Haskell park loop); `out_len` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_user_strlen(
    pdir: *mut u8,
    va: u64,
    max: u64,
    out_len: *mut u64,
) -> i32 {
    unsafe {
        if pdir.is_null() || out_len.is_null() {
            return -14;
        }
        if max == 0 || max > 4096 {
            return -22;
        }
        let end = match va.checked_add(max) {
            Some(e) => e,
            None => return -14,
        };
        if va < 0x01000000 || end > 0x100000000 {
            return -14;
        }
        for i in 0..max {
            let pa = translate_va_pdir(pdir, va + i);
            if pa == 0 {
                return -14;
            }
            // SAFETY: `pa` is identity-mapped RAM.
            if *(pa as *const u8) == 0 {
                *out_len = i;
                return 0;
            }
        }
        -22
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_set_exit(code: i32) {
    unsafe {
        // SAFETY: trap-safe lock-free routing; unregistered pdirs fall back
        // to the legacy global so pre-per-pid sessions keep working.
        let cur = current_pdir() as u64;
        let mut routed = false;
        if cur != 0 {
            for i in 0..EL0_N {
                if EL0_TABLE[i].pdir == cur {
                    EL0_TABLE[i].exit_code = code;
                    EL0_TABLE[i].exited = 1;
                    routed = true;
                    break;
                }
            }
        }
        if !routed {
            HOUSE_USER_EXIT_CODE = code;
            HOUSE_USER_EXITED = 1;
        }
        core::arch::asm!("dsb sy; sev", options(nostack, preserves_flags));
    }
}

// SAFETY: EL1 thread context (Haskell FFI); lock-free slot claim, `pdir`
// published last so a concurrent trap scan never sees a half-claimed slot.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_el0_register(pdir: *mut u8) -> i32 {
    unsafe {
        if pdir.is_null() {
            return -22;
        }
        let key = pdir as u64;
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == key {
                EL0_TABLE[i].exit_code = 0;
                EL0_TABLE[i].exited = 0;
                EL0_TABLE[i].parked = 0;
                EL0_TABLE[i].req = 0;
                return 0;
            }
        }
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == 0 {
                EL0_TABLE[i].exit_code = 0;
                EL0_TABLE[i].exited = 0;
                EL0_TABLE[i].parked = 0;
                EL0_TABLE[i].req = 0;
                EL0_TABLE[i].elr = 0;
                EL0_TABLE[i].sp_el0 = 0;
                EL0_TABLE[i].pdir = key;
                return 0;
            }
        }
        -28
    }
}

// SAFETY: EL1 thread context (Haskell FFI); `pdir` retracted first so a
// concurrent trap scan stops routing to the freed slot.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_el0_unregister(pdir: *mut u8) {
    unsafe {
        if pdir.is_null() {
            return;
        }
        let key = pdir as u64;
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == key {
                EL0_TABLE[i].pdir = 0;
                EL0_TABLE[i].exited = 0;
                EL0_TABLE[i].exit_code = 0;
                EL0_TABLE[i].parked = 0;
                EL0_TABLE[i].req = 0;
                return;
            }
        }
    }
}

// SAFETY: EL1 thread context (Haskell FFI); returns 1 with `*code_out` set
// when the pid exited, 0 when still live/unknown, negative errno on bad args.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_el0_exit_status(pdir: *mut u8, code_out: *mut i32) -> i32 {
    unsafe {
        if pdir.is_null() || code_out.is_null() {
            return -14;
        }
        let key = pdir as u64;
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == key {
                if EL0_TABLE[i].exited != 0 {
                    *code_out = EL0_TABLE[i].exit_code;
                    return 1;
                }
                return 0;
            }
        }
        0
    }
}

// SAFETY: trap context (`c_handle_sync` PARK path); bounded 112-word copy
// with no locks or allocation. `elr` is recorded as-delivered (already the
// next pc — resume must NOT add 4). Returns 1 when the frame was parked,
// 0 when the pdir holds no slot (caller falls through to ENOSYS).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_el0_park(elr: u64, sp_el0: u64, imm: u32, gpr: *const u64) -> i32 {
    unsafe {
        if gpr.is_null() {
            return 0;
        }
        let cur = current_pdir() as u64;
        if cur == 0 {
            return 0;
        }
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == cur {
                // SAFETY: gpr is the 896B vec_sync frame (112 u64), slot save
                // is a static 112-word field; single bounded copy, no overlap.
                core::ptr::copy_nonoverlapping(gpr, EL0_TABLE[i].save.as_mut_ptr(), 112);
                EL0_TABLE[i].elr = elr;
                EL0_TABLE[i].sp_el0 = sp_el0;
                EL0_TABLE[i].req = imm;
                EL0_TABLE[i].parked = 1;
                core::arch::asm!("dsb sy; sev", options(nostack, preserves_flags));
                return 1;
            }
        }
        0
    }
}

// SAFETY: EL1 thread context (Haskell FFI poll); lock-free read, 1 when the
// pid parked and awaits `house_resume_el0`, 0 when live/exited/unknown.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_el0_parked(pdir: *mut u8) -> i32 {
    unsafe {
        if pdir.is_null() {
            return 0;
        }
        let key = pdir as u64;
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == key {
                return if EL0_TABLE[i].parked != 0 { 1 } else { 0 };
            }
        }
        0
    }
}

// SAFETY: EL1 thread context (Haskell park loop); on 1 copies the request
// code plus the parked x0..x3 (`save[0..4]`) out. `args_out` must hold 4 u64.
// Returns 1 parked, 0 live/exited/unknown, negative errno on bad pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_el0_take_request(
    pdir: *mut u8,
    req_out: *mut u32,
    args_out: *mut u64,
) -> i32 {
    unsafe {
        if pdir.is_null() || req_out.is_null() || args_out.is_null() {
            return -14;
        }
        let key = pdir as u64;
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == key {
                if EL0_TABLE[i].parked == 0 {
                    return 0;
                }
                *req_out = EL0_TABLE[i].req;
                // SAFETY: slot save is static, args_out holds 4 u64 per contract.
                core::ptr::copy_nonoverlapping(EL0_TABLE[i].save.as_ptr(), args_out, 4);
                return 1;
            }
        }
        0
    }
}

// SAFETY: EL1 thread context (Haskell fork handler, capability free); both
// pdirs must be registered slots. Copies the parent's parked trap frame
// (896B save + ELR as-delivered + SP_EL0) into the child slot, stages the
// child x0 = 0, and marks the child parked so `house_resume_el0` can start
// it. Parent slot untouched. Returns 0 ok, -22 unknown slot.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_el0_clone_slot(parent: *mut u8, child: *mut u8) -> i32 {
    unsafe {
        if parent.is_null() || child.is_null() {
            return -22;
        }
        let pkey = parent as u64;
        let ckey = child as u64;
        let mut pi: Option<usize> = None;
        let mut ci: Option<usize> = None;
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == pkey {
                pi = Some(i);
            }
            if EL0_TABLE[i].pdir == ckey {
                ci = Some(i);
            }
        }
        match (pi, ci) {
            (Some(p), Some(c)) => {
                if EL0_TABLE[p].parked == 0 {
                    return -22;
                }
                // SAFETY: both saves are static 112-word fields; bounded copy.
                core::ptr::copy_nonoverlapping(
                    EL0_TABLE[p].save.as_ptr(),
                    EL0_TABLE[c].save.as_mut_ptr(),
                    112,
                );
                EL0_TABLE[c].elr = EL0_TABLE[p].elr;
                EL0_TABLE[c].sp_el0 = EL0_TABLE[p].sp_el0;
                EL0_TABLE[c].save[0] = 0;
                EL0_TABLE[c].req = 0;
                EL0_TABLE[c].parked = 1;
                EL0_TABLE[c].exit_code = 0;
                EL0_TABLE[c].exited = 0;
                core::arch::asm!("dsb sy", options(nostack, preserves_flags));
                0
            }
            _ => -22,
        }
    }
}

// SAFETY: EL1 thread context (Haskell exec handler, capability free); pdir
// must be a registered parked slot. Redirects the session at `entry` with
// `sp`: ELR/sp_EL0 updated, general + SIMD save cleared (x0 staged by the
// following `house_resume_el0`), parked retained. Returns 0 ok, -22 unknown.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_el0_set_entry(pdir: *mut u8, entry: u64, sp: u64) -> i32 {
    unsafe {
        if pdir.is_null() {
            return -22;
        }
        let key = pdir as u64;
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == key {
                if EL0_TABLE[i].parked == 0 {
                    return -22;
                }
                EL0_TABLE[i].save = [0; 112];
                EL0_TABLE[i].elr = entry;
                EL0_TABLE[i].sp_el0 = sp;
                EL0_TABLE[i].req = 0;
                core::arch::asm!("dsb sy", options(nostack, preserves_flags));
                return 0;
            }
        }
        -22
    }
}

// SAFETY: EL1 thread context (Haskell park loop, capability free while the
// caller was blocked). Stages `res` as the resumed x0, clears parked, then
// re-enters EL0 via `house_resume_asm`; control returns here (0) on the next
// park/exit trap through the exit trampoline. Returns negative errno without
// entering when the pid holds no parked slot.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_resume_el0(pdir: *mut u8, asid: u64, res: u64) -> i32 {
    unsafe {
        if pdir.is_null() {
            return -22;
        }
        let key = pdir as u64;
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == key {
                if EL0_TABLE[i].parked == 0 {
                    return 0;
                }
                EL0_TABLE[i].save[0] = res;
                let elr = EL0_TABLE[i].elr;
                let sp = EL0_TABLE[i].sp_el0;
                let save_ptr = EL0_TABLE[i].save.as_ptr();
                EL0_TABLE[i].parked = 0;
                core::arch::asm!("dsb sy", options(nostack, preserves_flags));
                house_set_recorded_pdir(pdir);
                // SAFETY: slot fields are static; asm restores the saved frame
                // and erets to EL0, returning via the trampoline on next trap.
                house_resume_asm(save_ptr, elr, sp, pdir, asid);
                return 0;
            }
        }
        -22
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_get_exit_code() -> i32 {
    unsafe { HOUSE_USER_EXIT_CODE }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_clear_exit() {
    unsafe {
        HOUSE_USER_EXITED = 0;
        HOUSE_USER_EXIT_CODE = 0;
        core::arch::asm!("dsb sy", options(nostack, preserves_flags));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_is_exited() -> i32 {
    unsafe { HOUSE_USER_EXITED }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn house_svc_dispatch(
    imm: u32,
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    gpr: *mut u64,
) -> i64 {
    // SAFETY: EL1 sync handler calls this with valid gpr frame; we validate VA bounds.
    unsafe {
        match imm {
            HOUSE_SVC_YIELD => {
                // Registered sessions park in `c_handle_sync` before reaching
                // dispatch; this arm is the fail-closed fallback (no slot).
                if !gpr.is_null() {
                    *gpr = -38i64 as u64;
                }
                -38
            }
            HOUSE_SVC_WRITE => {
                let fd = x0 as i64;
                let va = x1;
                let len = x2;
                if fd != 1 {
                    uart_puts(b"[svc] write bad fd\n\0".as_ptr());
                    if !gpr.is_null() {
                        *gpr = -9i64 as u64;
                    }
                    return -9;
                }
                if len > 65536 {
                    if !gpr.is_null() {
                        *gpr = -22i64 as u64;
                    }
                    return -22;
                }
                if len == 0 {
                    if !gpr.is_null() {
                        *gpr = 0;
                    }
                    return 0;
                }
                if validate_user_buffer(va, len) != 0 {
                    uart_puts(b"[svc] write EFAULT\n\0".as_ptr());
                    if !gpr.is_null() {
                        *gpr = -14i64 as u64;
                    }
                    return -14;
                }
                let mut remaining = len;
                let mut cur = va;
                while remaining > 0 {
                    let page_off = cur & 0xFFF;
                    let mut chunk = 4096 - page_off;
                    if chunk > remaining {
                        chunk = remaining;
                    }
                    let pa = translate_va(cur);
                    if pa == 0 {
                        if !gpr.is_null() {
                            *gpr = -14i64 as u64;
                        }
                        return -14;
                    }
                    let src = pa as *const u8;
                    for i in 0..chunk {
                        let c = *src.add(i as usize);
                        uart_putc(c);
                    }
                    cur = cur.checked_add(chunk).unwrap_or(cur);
                    remaining -= chunk;
                }
                if !gpr.is_null() {
                    *gpr = len;
                }
                len as i64
            }
            HOUSE_SVC_EXIT => {
                let code = (x0 & 0xFF) as i32;
                house_set_exit(code);
                uart_puts(b"[svc] exit\n\0".as_ptr());
                if !gpr.is_null() {
                    *gpr = 0;
                }
                0
            }
            HOUSE_SVC_BRK => {
                // Registered sessions park in `c_handle_sync` before reaching
                // dispatch (brk carries no user memory, always validated);
                // this arm is the fail-closed fallback (no slot).
                if !gpr.is_null() {
                    *gpr = -38i64 as u64;
                }
                -38
            }
            HOUSE_SVC_OPEN | HOUSE_SVC_READ | HOUSE_SVC_WRITE_FD | HOUSE_SVC_CLOSE
            | HOUSE_SVC_SEEK => {
                // Validate-then-park: well-formed calls parked in
                // `c_handle_sync` before reaching dispatch; reaching here
                // means unregistered slot (fail closed ENOSYS) or a precise
                // trap-side errno (bad buffer/path, never parked).
                let r = validate_fd(imm, x0, x1, x2);
                if r == VALID_PARK {
                    uart_puts(b"[svc] ENOSYS fd\n\0".as_ptr());
                    if !gpr.is_null() {
                        *gpr = -38i64 as u64;
                    }
                    -38
                } else {
                    if !gpr.is_null() {
                        *gpr = r as u64;
                    }
                    r
                }
            }
            HOUSE_SVC_FORK | HOUSE_SVC_WAIT => {
                // Registered sessions park in `c_handle_sync` before reaching
                // dispatch (no user memory for fork; wait carries only a pid
                // Haskell validates); this arm is the fail-closed fallback.
                uart_puts(b"[svc] ENOSYS fork\n\0".as_ptr());
                if !gpr.is_null() {
                    *gpr = -38i64 as u64;
                }
                -38
            }
            HOUSE_SVC_EXEC => {
                // Validate-then-park like OPEN: well-formed paths park in
                // `c_handle_sync`; reaching here means unregistered slot
                // (fail closed ENOSYS) or a trap-side errno (bad path).
                let r = validate_cstring_current(x0, 256);
                if r == 0 {
                    uart_puts(b"[svc] ENOSYS exec\n\0".as_ptr());
                    if !gpr.is_null() {
                        *gpr = -38i64 as u64;
                    }
                    -38
                } else {
                    if !gpr.is_null() {
                        *gpr = r as u64;
                    }
                    r
                }
            }
            HOUSE_SVC_IPC_SEND
            | HOUSE_SVC_IPC_RECV
            | HOUSE_SVC_IPC_CALL
            | HOUSE_SVC_IPC_REPLY
            | HOUSE_SVC_IPC_GRANT_MAP => {
                let r = house_ipc_svc_dispatch(imm, x0, x1, x2, x3);
                if !gpr.is_null() {
                    *gpr = r as u64;
                }
                if r == -38 {
                    uart_puts(b"[svc] ENOSYS ipc\n\0".as_ptr());
                }
                r
            }
            _ => {
                uart_puts(b"[svc] ENOSYS imm=0x\0".as_ptr());
                if !gpr.is_null() {
                    *gpr = -38i64 as u64;
                }
                -38
            }
        }
    }
}
