/// Write a NUL-terminated string to the UART.
///
/// # Safety
///
/// `s` must be null (returns immediately) or point to a NUL-terminated
/// string; call at EL1 with the UART initialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn c_print(s: *const u8) {
    if s.is_null() {
        return;
    }
    unsafe extern "C" {
        fn uart_putc(c: u8);
    }
    let mut p = s;
    unsafe {
        while *p != 0 {
            uart_putc(*p);
            p = p.add(1);
        }
    }
}
