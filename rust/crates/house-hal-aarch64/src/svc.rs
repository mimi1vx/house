//! Supervisor calls — `svc.c` transliteration.

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
const HOUSE_SVC_IPC_SEND: u32 = 0x10;
const HOUSE_SVC_IPC_RECV: u32 = 0x11;
const HOUSE_SVC_IPC_CALL: u32 = 0x12;
const HOUSE_SVC_IPC_REPLY: u32 = 0x13;
const HOUSE_SVC_IPC_GRANT_MAP: u32 = 0x14;

static mut HOUSE_USER_EXITED: i32 = 0;
static mut HOUSE_USER_EXIT_CODE: i32 = 0;

// Per-pid EL0 exit table: fixed 64-slot array keyed by
// pdir pointer, lock-free (single-copy 64-bit field accesses). Trap context
// (`house_set_exit` from `c_handle_sync`) must never take locks, so all
// lookup/update paths are bounded linear scans with no allocation.
// `save` reserves the 896B resume frame for future parked-syscall resume.
const EL0_N: usize = 64;

#[derive(Clone, Copy)]
struct El0Slot {
    pdir: u64,
    save: [u64; 112],
    exit_code: i32,
    exited: i32,
}

const EL0_FREE: El0Slot = El0Slot {
    pdir: 0,
    save: [0; 112],
    exit_code: 0,
    exited: 0,
};

static mut EL0_TABLE: [El0Slot; 64] = [EL0_FREE; 64];

unsafe extern "C" {
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
    fn house_ipc_svc_dispatch(op: u32, x0: u64, x1: u64, x2: u64, x3: u64) -> i64;
    fn current_pdir() -> *mut u8;
}

unsafe fn translate_va(va: u64) -> usize {
    // SAFETY: walks recorded TTBR0; caller guarantees EL1 and SpinLock not needed for svc read.
    unsafe {
        let pdir = current_pdir();
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
                return 0;
            }
        }
        for i in 0..EL0_N {
            if EL0_TABLE[i].pdir == 0 {
                EL0_TABLE[i].exit_code = 0;
                EL0_TABLE[i].exited = 0;
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
                uart_puts(b"[svc] ENOSYS brk\n\0".as_ptr());
                if !gpr.is_null() {
                    *gpr = -38i64 as u64;
                }
                -38
            }
            HOUSE_SVC_OPEN | HOUSE_SVC_READ | HOUSE_SVC_WRITE_FD | HOUSE_SVC_CLOSE
            | HOUSE_SVC_FORK | HOUSE_SVC_WAIT | HOUSE_SVC_SEEK => {
                // Track O: Haskell EL1 table lands first; the trap-safe
                // delegation ring wires EL0 next. Fail closed, never touch memory.
                uart_puts(b"[svc] ENOSYS fd/fork\n\0".as_ptr());
                if !gpr.is_null() {
                    *gpr = -38i64 as u64;
                }
                -38
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
