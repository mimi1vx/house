#![no_std]
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(static_mut_refs)]
#![allow(unused_variables)]
#![allow(dead_code)]
#![allow(clippy::all)]
#![allow(clippy::pedantic)]
#![allow(clippy::nursery)]

//! Phase 3: aarch64 HAL — transliteration of `platform/aarch64/*.c`.
//! Single panic handler owner is `house-libc`.

pub mod buddy;
pub mod detect;
pub mod dtb;
pub mod gic;
pub mod ipc;
pub mod irq;
pub mod mm;
pub mod mmio;
pub mod mmu;
pub mod probe;
pub mod psci;
pub mod spinlock;
pub mod svc;
pub mod timer;
pub mod uart;
pub mod userspace;
pub mod virtio_blk;
pub mod virtio_net;
pub mod virtio_probe;
pub mod virtio_transport;
