//! Virtio blk — `virtio_blk.c` stub.
#[no_mangle]
pub unsafe extern "C" fn virtio_blk_save_queue(
    _slot: i32,
    _desc: u64,
    _avail: u64,
    _used: u64,
    _qsize: u32,
) {
}
#[no_mangle]
pub unsafe extern "C" fn virtio_blk_reset_slot(_slot: i32) {}
#[no_mangle]
pub unsafe extern "C" fn virtio_blk_invalidate(_pa: u64, _len: usize) {}
#[no_mangle]
pub unsafe extern "C" fn virtio_blk_probe_capacity(_slot: i32, _cap: *mut u64) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn virtio_blk_submit_read(
    _slot: i32,
    _lba: u64,
    _pa: u64,
    _n: u32,
    _id: *mut u32,
) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn virtio_blk_submit_write(
    _slot: i32,
    _lba: u64,
    _pa: u64,
    _n: u32,
    _id: *mut u32,
) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn virtio_blk_poll_used(_slot: i32, _id: *mut u32, _status: *mut u8) -> i32 {
    -1
}
