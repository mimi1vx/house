# hOp — House on AArch64

hOp is a microkernel built on the GHC runtime, retargeted to AArch64.
It runs only under QEMU `virt` (`-M virt,gic-version=3`), developed on Apple silicon hosts.

The Haskell kernel, Rust boot/HAL/libc, and EL0 userspace boot from a flat binary with an interactive shell, VFS, virtio drivers, and IPC.

- [User guide](installation.md): install, build, toolchain, and host QEMU setup.
- [Architecture](architecture.md): overview, boot and runtime, and the stable C ABI map.
- [Dynamic linking](dynamic-linking.md): residue and provenance branch status.
- [Design notes](design/shared-page-ownership.md): GOT layout, capability pinning, page ownership, TLB shootdown.
