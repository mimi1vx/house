# Installation & quickstart

Get from zero to a booting guest. All commands run from the repository root.
`Makefile` targets are the stable interface; this page names the six you need
first and links the canonical references for the rest.

## Host prerequisites

macOS (Apple silicon) is the dev host; Linux CI covers the TCG subset.

```sh
brew install qemu expect socat
qemu-system-aarch64 -accel help
```

You also need Apple's `container` CLI, `jq`, and a SHA-256 checker
(`shasum` is stock on macOS). The Haskell quality gate runs on the host
because the image's HLint cannot parse GHC2024, so install GHC/Cabal,
Fourmolu 0.20.1.0, and a GHC2024-capable HLint (3.10 is known to work).
See [Toolchain](toolchain.md) for the pinned snapshot and
[Host QEMU](host-qemu.md) for the full host setup.

## Toolchain image

Build the `linux/arm64` image once, then use it for every firmware build:

```sh
make container-image
```

`make container-image` builds the image; `make container-shell` opens an
interactive toolchain shell. Every run pins `--platform linux/arm64`
(`$(RUNNER)` selects Apple `container` on macOS, Docker on Linux).
Never export `CONTAINER_DEFAULT_PLATFORM` globally; the root `Makefile`
scopes it to the Apple `container build` line only.

Firmware never builds on the host: `make spike-build`, `make irq-build`,
and `make house-build` wrap the container invocation. Host builds are
limited to formatting, lint, and Cabal tests.

## Verify your setup

```sh
make doctor
qemu-system-aarch64 -accel help
container run --platform linux/arm64 --rm house-port:latest uname -m
```

Want: `aarch64` from the container probe, `hvf` + `tcg` in the accel list,
and a clean `doctor` (checks `socat`, `qemu-img`, and a SHA-256 tool).

## First boot

```sh
make spike-check
```

This builds the Spike probe and boots it under QEMU
(`qemu-system-aarch64 -M virt,gic-version=3`). Next try
`make house-check`, then browse [Build & run](build-run.md) for the
six most-used targets. The per-change gate is `make check` (hvf+tcg);
CI runs `make check-tcg`.
