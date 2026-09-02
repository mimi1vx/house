//! Virtio net — `virtio_net.c` stub.
#[no_mangle]
pub unsafe extern "C" fn virtio_net_save_queues(
    _slot: i32,
    _rxd: u64,
    _rxa: u64,
    _rxu: u64,
    _txd: u64,
    _txa: u64,
    _txu: u64,
    _qrx: u32,
    _qtx: u32,
) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn virtio_net_invalidate(_pa: u64, _len: usize) {}
#[no_mangle]
pub unsafe extern "C" fn virtio_net_probe_mac(_slot: i32, _mac: *mut u8) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn virtio_net_submit_rx(
    _slot: i32,
    _pa: u64,
    _len: u32,
    _id: *mut u32,
) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn virtio_net_submit_tx(
    _slot: i32,
    _hdr: u64,
    _pa: u64,
    _len: u32,
    _id: *mut u32,
) -> i32 {
    -1
}
#[no_mangle]
pub unsafe extern "C" fn virtio_net_poll_used(
    _slot: i32,
    _qidx: i32,
    _id: *mut u32,
    _len: *mut u32,
) -> i32 {
    -1
}
