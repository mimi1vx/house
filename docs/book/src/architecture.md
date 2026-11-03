# Architecture overview

hOp is a microkernel built on the stock threaded GHC RTS (no GHC patches),
retargeted to AArch64 QEMU `virt`. It boots one flat image containing a
Haskell kernel, a Rust boot/HAL/libc layer, and EL0 userspace.

Machine: `qemu-system-aarch64 -M virt,gic-version=3`

Guest entry `_start` at `0x40080000`; DTB pointer in `x0`.

## Layer map

- `rust/crates/house-boot`: entry, vectors, EL2-to-EL1 drop, early MMU,
  secondary-core entry, and EL0 enter/resume trampolines.
- `rust/crates/house-hal-aarch64`: MMU, GICv3, timer, IRQ ring, buddy
  allocator, DTB detect/probe, userspace page tables, SVC/IPC traps, PSCI,
  UART, and virtio transports (blk/net/con).
- `rust/crates/house-libc`: allocator, fd/pipe/eventfd/epoll/timerfd,
  threads/TLS/sched, and the `mmap` family the RTS links against.
- `kernel/HouseA64.hs`: the Haskell kernel root, built with
  `ghc --make -no-link`. Shell, VFS/RamFS, drivers, IPC/nameservice,
  virtio block/network/console, and EL0 process services live under
  `kernel/HouseA64.hs`, `kernel/H/`, and `kernel/Kernel/`.
- `userspace/`: EL0 sources (`svc #imm` programs) and the initrd staging;
  `platform/aarch64/` owns the freestanding link and linker script.

Depth lives elsewhere on purpose: [Rust workspace](rust-architecture.md)
maps the crates, [Stable C ABI map](c-abi.md) freezes every
`#[no_mangle] extern "C"` symbol `ld` and Haskell FFI may use, and
[Boot & runtime](boot-runtime.md) covers entry, DTB, RAM/SMP detection,
and the flat-image trap.

## What boots

One guest links the threaded RTS (`-N` per detected core), the Rust layer,
Haskell archives, `libgmp`, and `libgcc` via `ld.lld` into a 16 MiB-bound
image. The kernel mounts RamFS, unpacks the initrd, launches pid1, and
enters the shell loop; EL0 processes run from the VFS `/bin/*` set over
`svc #imm` traps. `virtio scan` identifies block, network, console, and
RNG devices; QEMU `virt` pins `psci-conduit=hvc` and PL011 UART.

## Trust boundary

ARP/DHCP are spoofable in the virt lab, and there is no DNSSEC/TLS in this
slice. The guest expires ARP entries after 60 s and logs DHCP xid
mismatches to `dmesg` instead of accepting them.
