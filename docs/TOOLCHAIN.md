# Toolchain (`house-port:latest`)

Build-only image: reproducible builds, nothing else. QEMU runs on the
macOS host, never inside (see `docs/HOST-QEMU.md`).

## Base

- `debian:13-slim` (arm64-only; the `Containerfile` fails loud on
  `uname -m != aarch64`, and `make container-image` asserts the built
  image holds only the `arm64` variant).
- Minimal apt set: `build-essential curl xz-utils git ca-certificates
  libgmp-dev libffi-dev libncurses-dev zlib1g-dev pkg-config llvm lld`.
- GHC floats via `ghcup install ghc latest --set`; resolved version is
  pinned in the table below on every rebuild.
- `WORKDIR /work`, default `CMD ["bash"]`.

## Toolchains (resolved 2026-09-06 — re-pin on every rebuild)

| Tool | Provisioned by | Resolved version |
|------|---------------|------------------|
| GHC | `ghcup install ghc latest --set` | 9.14.1 |
| Cabal | `ghcup install cabal --set` | 3.16.1.0 |
| rustc/cargo | `rustup` default nightly, minimal profile | 1.100.0-nightly (f248f4038 2026-09-05) |
| clippy/rustfmt | `rustup component add` | 0.1.100 / 1.10.0-nightly (ships with the toolchain) |
| miri | `rustup component add miri` (nightly-only) | 0.1.0 (same nightly); `make miri` green: buddy lifecycle + 15 mem tests |
| fourmolu | `ghcup install fourmolu 0.20.1.0 --set` | 0.20.1.0 (matches host) |
| hlint | Debian `apt install hlint` | 3.6.1 — predates GHC2024, cannot parse `{-# LANGUAGE GHC2024 #-}`; Haskell lint stays on host hlint 3.10 until Hackage hlint builds under GHC 9.14 (see `Makefile: lint`) |
| cargo-deny | pinned musl binary, sha256-verified at build time | 0.20.2 |
| `aarch64-unknown-none` | `rustup target add` | installed (alongside `aarch64-unknown-linux-gnu`) |
| ld.lld | `lld` apt set | Debian LLD 19.1.7 |

Nightly is deliberate: Miri only ships for nightly. Everything else
(build, clippy, fmt) runs on the same toolchain — one pin, no split.

## Gates

- `make lint`: container `cargo clippy --target aarch64-unknown-none
  -- -D warnings` (blanket pedantic rejected — intentional syscall-ABI
  casts trip it; `--all-targets` excluded, no `test` crate on bare metal)
  + `cargo fmt --check` + `cargo deny check`, plus host
  `fourmolu -m check` + `hlint` over the full tree.
- `make miri` (`cargo miri test -p house-hal -p house-hal-aarch64
  -p house-libc -p house-boot`, `-c 4 -m 4G`): `asm!`/MMIO stay
  QEMU-gated behind `#[cfg]` isolation (`#[cfg(miri)]` no-op spinlock
  stubs; `no_mangle` dropped and syscall modules gated out under
  `cfg(test)` so std's runtime is never interposed). Miri cache
  (`XDG_CACHE_HOME`) lives on the cargo volume so only the first run
  pays for the sysroot build.
- `make haskell-check`: full-tree fourmolu+hlint + `cabal build all
  --enable-tests` + `cabal test all` (test-only package needs the flag).
- `make check`: spike + irq + house + shell + posix + rust + haskell,
  hvf+tcg where applicable.

## Linker

Bare-metal links use `ld.lld`, not GNU `ld`
(`platform/aarch64/Makefile: LD := ld.lld`), keeping
`--allow-multiple-definition --build-id=none --gc-sections`.
`platform/aarch64/aarch64.ld` sets `ENTRY(_start)` with the image loaded
at `0x40080000`, an explicit `.tls` template + `PT_TLS` (GNU ld silently
orphans `.tbss` into the data LOAD; LLD rejects the link without it),
and asserts the loaded file-image stays under 16 MiB (`0x40080000–
0x41080000`; the transcribed 8 MiB does not fit the full threaded-RTS
closure). A `size` report prints after every link.

Measured (`size build/*.elf`, 2026-09-06, ld.lld): spike text 5951724 +
data 1752912 (~7.7 MiB file-image), house text 10868140 + data 2403024
(~13.3 MiB); `readelf -h` shows `ENTRY(_start)` / `Machine: AArch64`.

## Named volumes (created on demand by `make volumes`)

- `house-target` → `/work/rust/target` (the Cargo workspace is `rust/`,
  not the repo root)
- `house-cabal` → `/root/.cabal`
- `house-cargo` → `/cargo-home` (`CARGO_HOME`; mounting over
  `/root/.cargo` would shadow the image's cargo binaries)

Only `*.elf`/`*.bin` cross back over the `./:/work` bind mount.

## Host-side setup (not baked into the image)

```sh
export CONTAINER_DEFAULT_PLATFORM=linux/arm64   # ~/.zshrc
brew install qemu expect                        # QEMU 11.1.1, expect 5.45
container builder start -c 4 -m 4G              # 4 CPU / 4 GB floor
```

## Re-verify

```sh
container run --platform linux/arm64 --rm house-port:latest uname -m
# want: aarch64
container run --platform linux/arm64 --rm house-port:latest bash -lc \
  'ghc --version && rustc --version && cargo miri --version \
   && ld.lld --version && fourmolu --version && hlint --version \
   && cargo deny --version'
container image inspect house-port:latest | jq -r '.[0].variants[].config.architecture'
# want: arm64 only
```

## Fresh-clone flow

```sh
make container-image && make check
```

`make check` rebuilds everything from clean inside the container, then
runs the host QEMU gates. Follows this doc and `docs/HOST-QEMU.md`
verbatim.
