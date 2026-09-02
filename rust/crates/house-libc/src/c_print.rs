#![allow(clippy::all)]
#[no_mangle]
pub unsafe extern "C" fn c_print(s: *const u8) {
    if s.is_null() {
        return;
    }
    extern "C" {
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
