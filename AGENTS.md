# AGENTS.md — house/hOp aarch64 OS

GHC RTS microkernel with a Haskell kernel, Rust HAL, and tinylibc. It targets
only AArch64 QEMU `virt` on Apple silicon; do not add or assume x86 paths.

## Build Boundary

- Compile only inside the `house-port:latest` container. Run QEMU only on the
  macOS host (`brew install qemu expect`).
- Pin every container invocation to Linux arm64: `container run` uses
  `--platform linux/arm64`; image building uses the sole sanctioned
  `CONTAINER_DEFAULT_PLATFORM=linux/arm64` assignment in the root `Makefile`.
  Never export that variable globally.
- Build the image once with `make container-image`; use `make container-shell`
  for an interactive toolchain shell.
- Host build wrappers are `make spike-build`, `make irq-build`, and
  `make house-build`. When invoking platform build targets manually, clean
  `platform/aarch64` first; also clean `kernel` before a House build.
- `SMP_N` changes only QEMU `-smp`; RAM and core count are detected at boot, so
  do not introduce build-time RAM or CPU limits.

## Verification

- `make check` is the per-change CI gate: spike, IRQ, House boot, shell, POSIX,
  and Rust checks under both expected accelerators where applicable.
- Focused checks include `make spike-check`, `irq-check`, `house-check`,
  `house-shell-check`, `house-posix-check`, `house-fs-check`, `house-ipc-check`,
  `house-driver-check`, `house-virtio-transport-check`,
  `house-virtio-blk-check`, `house-virtio-net-check`, and
  `house-userspace-check`.
- SMP checks: `make smp-check` (default `SMP_N=2`),
  `SMP_N=4 make smp-check`, `make smp-hotplug-check`, and the expensive nightly
  scaling gate `make smp-check-8` (4 GiB).
- `make vm-check` is an expensive memory/MMU matrix, not part of the ordinary
  per-change gate.
- All `*-check` targets clean their own builds. Set `SPIKE_MEM` to exercise a
  different QEMU RAM size; valid values are 512M, 1G, 2G, 4G, 8G, and 16G.
- Rust-only verification is `make rust-check`. After changing Rust/HAL ABI,
  also audit exported symbols against the frozen map in `rust/c-abi.md`.

## Repository Boundaries

- `kernel/HouseA64.hs` roots the Haskell closure. `kernel/Makefile` intentionally
  uses `ghc --make -no-link`; this is not a Cabal project.
- `platform/aarch64/` owns the freestanding link, linker script, tinylibc,
  probes, and QEMU-facing platform build. `build/aarch64.ld` is preprocessed
  from `platform/aarch64/aarch64.ld`; edit the source, not generated output.
- `rust/` is the Cargo workspace for boot assembly, the AArch64 HAL, and libc.
  Keep its C ABI consistent with `rust/c-abi.md`; architecture details live in
  `rust/ARCHITECTURE.md`.
- `scripts/qemu-*.exp` are host-side Expect harnesses. Their positional API is
  `expect SCRIPT ELF MARKER [timeout] [accel] [mem] [smp]`.
- Build outputs under `kernel/build/`, `platform/aarch64/build/`, and
  `rust/target/` are generated and ignored.

## Boot And Runtime Traps

- Pass the flat `platform/aarch64/build/*.bin` to QEMU `-kernel`, not the ELF.
  The flat-image boot path supplies the DTB in `x0`; ELF boot leaves `x0=0` and
  causes false RAM probing under HVF.
- The supported machine is `qemu-system-aarch64 -M virt,gic-version=3`; HVF is
  the host default, while harnesses use TCG where required (notably EL0 tests).
- The stock threaded GHC RTS and unsafe FFI are deliberate constraints.
- `plans/` contains untracked local notes and is intentionally not ignored; do
  not treat those files as product documentation or generated artifacts.
