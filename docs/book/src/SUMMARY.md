# Summary

[Introduction](index.md)

# User guide

- [Installation & quickstart](installation.md)
- [Build & run](build-run.md)
- [Toolchain](toolchain.md)
- [Host QEMU](host-qemu.md)
- [Console shell & getty](console-shell-getty.md)

# Architecture

- [Architecture overview](architecture.md)
- [Rust workspace](rust-architecture.md)
- [Boot & runtime](boot-runtime.md)
- [Stable C ABI map](c-abi.md)

# Dynamic linking

- [Dynamic linking residue](dynamic-linking.md)

# Design notes

- [DSO GOT slot / AAPCS](design/dso-got-slot-aapcs.md)
- [Park/resume capability pinning](design/park-resume-capability-pinning.md)
- [Shared page ownership](design/shared-page-ownership.md)
- [TLB shootdown protocol](design/tlb-shootdown-protocol.md)
- [Linux-ABI syscall emulation (M4 row 0 proposal)](design/linux-abi-syscalls.md)
- [Haskell EL0 decision (stock GHC output is not a target)](design/haskell-el0-decision.md)
- [Gate flake policy](design/gate-flake-policy.md)
