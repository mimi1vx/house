//! VM mmap — `mm/vm.c` stub.

#[no_mangle]
pub unsafe extern "C" fn house_vm_mmap(
    _addr: *mut u8,
    _len: usize,
    _prot: i32,
    _flags: i32,
    _fd: i32,
    _off: i64,
) -> *mut u8 {
    core::ptr::null_mut()
}
#[no_mangle]
pub unsafe extern "C" fn house_vm_munmap(_a: *mut u8, _len: usize) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn house_vm_mprotect(_a: *mut u8, _len: usize, _prot: i32) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn house_vm_demand_single() -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn house_vm_demand_100() -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn house_puts_after() {
    // stub for Haskell HouseA64.o reference; no-op.
}
