//! Supervisor calls — `svc.c` transliteration.

const HOUSE_SVC_WRITE: u32 = 0x01;
const HOUSE_SVC_EXIT: u32 = 0x02;
const HOUSE_SVC_BRK: u32 = 0x03;
const HOUSE_SVC_IPC_SEND: u32 = 0x10;
const HOUSE_SVC_IPC_RECV: u32 = 0x11;
const HOUSE_SVC_IPC_CALL: u32 = 0x12;
const HOUSE_SVC_IPC_REPLY: u32 = 0x13;
const HOUSE_SVC_IPC_GRANT_MAP: u32 = 0x14;

static mut HOUSE_USER_EXITED: i32 = 0;
static mut HOUSE_USER_EXIT_CODE: i32 = 0;

extern "C" {
    fn uart_puts(s: *const u8);
    fn uart_putc(c: u8);
    fn house_ipc_svc_dispatch(x0: u64, x1: u64, x2: u64, x3: u64) -> i64;
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

unsafe fn validate_user_buffer(va: u64, len: u64) -> i32 {
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

#[no_mangle]
pub unsafe extern "C" fn house_set_exit(code: i32) {
    unsafe {
        HOUSE_USER_EXIT_CODE = code;
        HOUSE_USER_EXITED = 1;
        core::arch::asm!("dsb sy; sev", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_get_exit_code() -> i32 {
    unsafe { HOUSE_USER_EXIT_CODE }
}

#[no_mangle]
pub unsafe extern "C" fn house_clear_exit() {
    unsafe {
        HOUSE_USER_EXITED = 0;
        HOUSE_USER_EXIT_CODE = 0;
        core::arch::asm!("dsb sy", options(nostack, preserves_flags));
    }
}

#[no_mangle]
pub unsafe extern "C" fn house_is_exited() -> i32 {
    unsafe { HOUSE_USER_EXITED }
}

#[no_mangle]
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
            HOUSE_SVC_IPC_SEND
            | HOUSE_SVC_IPC_RECV
            | HOUSE_SVC_IPC_CALL
            | HOUSE_SVC_IPC_REPLY
            | HOUSE_SVC_IPC_GRANT_MAP => {
                let r = house_ipc_svc_dispatch(x0, x1, x2, x3);
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
