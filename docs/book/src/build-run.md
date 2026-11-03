# Build & run

All commands run from the repository root on the macOS host.
`Makefile` targets are the stable interface; see the
[Toolchain](toolchain.md) and [Host QEMU](host-qemu.md) pages for setup.

```sh
make container-image
make spike-build
make spike-check
make house-check
make check
make check-tcg
```

`make container-image` builds the `linux/arm64` toolchain image once;
`make spike-check` is the first boot to try afterwards.
`make check` is the per-change gate (hvf+tcg);
CI runs the TCG-only subset via `make check-tcg`.
