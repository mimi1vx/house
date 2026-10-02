# Toolchain (`house-port:latest`)

Build-only image with a documented resolved toolchain snapshot. QEMU runs on the
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

## Toolchains

The table records the resolved image contents. GHC is pinned in the
Containerfile and Rust to nightly-2026-09-30; refresh the table whenever
a pin moves.

| Tool | Provisioned by | Resolved version |
|------|---------------|------------------|
| GHC | `ghcup install ghc 9.14.1 --set` | 9.14.1 |
| Cabal | `ghcup install cabal --set` | 3.16.1.0 |
| rustc/cargo | `rustup` default nightly-2026-09-30, minimal profile | 1.101.0-nightly (5c543b0b8 2026-09-29) |
| clippy/rustfmt | `rustup component add` | 0.1.100 / 1.10.0-nightly (ships with the toolchain) |
| miri | `rustup component add miri` (nightly-only) | 0.1.0 (same nightly); `make miri` green: buddy lifecycle + 15 mem tests |
| fourmolu | `ghcup install fourmolu 0.20.1.0 --set` | 0.20.1.0 (matches host) |
| hlint | Debian `apt install hlint` | 3.6.1 — predates GHC2024, cannot parse `{-# LANGUAGE GHC2024 #-}`; Haskell lint stays on host hlint 3.10 until Hackage hlint builds under GHC 9.14 (see `Makefile: lint`) |
| cargo-deny | pinned musl binary, sha256-verified at build time | 0.20.2 |
| `aarch64-unknown-none` | `rustup target add` | installed (alongside `aarch64-unknown-linux-gnu`) |
| ld.lld | `lld` apt set | Debian LLD 19.1.7 |

Nightly is deliberate: Miri only ships for nightly. Build, Clippy, formatting,
and Miri use the same pinned nightly baked into the image.

## Gates

- `make lint`: container `cargo clippy --target aarch64-unknown-none
  -- -D warnings` (transliteration files carry per-lint `#![allow]`
  with a `reason` in both the `clippy::` and rustc namespaces — syscall-ABI
  casts, `no_mangle` signatures, C-mirror control flow, and raw-static C
  globals trip default correctness/style lints; `--all-targets`
  excluded, no `test` crate on bare metal)
  + `cargo fmt --check`, plus host
  `fourmolu -m check` + `hlint` over the full tree.
- `make miri` runs the pure-logic suites with `cargo miri test -p house-hal
  -p house-hal-aarch64 -p house-libc -p house-boot -p house-el0-tiny` inside a
  `container run -c 4 -m 4G` invocation. `asm!`/MMIO stay
  QEMU-gated behind `#[cfg]` isolation (`#[cfg(miri)]` no-op spinlock
  stubs; `no_mangle` dropped and syscall modules gated out under
  `cfg(test)` so std's runtime is never interposed). Miri cache
  (`XDG_CACHE_HOME`) lives on the cargo volume so only the first run
  pays for the sysroot build.
- `make haskell-check`: full-tree fourmolu+hlint + `cabal build all
  --enable-tests` + `cabal test all` (test-only package needs the flag).
- `make check`: the 19 gates named by the banner (doctor, gate-coverage,
  spike, irq, house, shell, posix, initrd, pid1, dynamic userspace,
  fault budget, fault kill, ipc-el0, tls-el0, mounted-root dynamic,
  rust (clippy + fmt + deny + abi), haskell, el0tiny, dynamic ELF),
  hvf+tcg where applicable.
- `make check-tcg`: the check legs with `TCG_ONLY=1` (Linux CI has no nested
  virt, so the hvf halves are skipped), minus house-dynamic-root-check,
  which needs QEMU 11+ for virtio-mmio-transports. The remaining focused
  gates run in nightly (`house-fs/ipc/driver/virtio-*/userspace/fd-el0/
  fork/proc`, `smp-check`, `smp-hotplug-check` plus the scaling/memory/Miri legs).

## Linker

Bare-metal links use `ld.lld`, not GNU `ld`
(`platform/aarch64/Makefile: LD := ld.lld`), keeping
`--allow-multiple-definition --build-id=none --gc-sections`.
`platform/aarch64/aarch64.ld` sets `ENTRY(_start)` with the image loaded
at `0x40080000`, an explicit `.tls` template + `PT_TLS` (GNU ld silently
orphans `.tbss` into the data LOAD; LLD rejects the link without it),
and asserts the loaded file-image stays under 16 MiB (`0x40080000–
0x41080000`); the full threaded-RTS closure exceeds an 8 MiB bound. A
`size` report prints after every link.

Measured (`size build/*.elf`, 2026-09-06, ld.lld): spike text 5951724 +
data 1752912 (~7.7 MiB file-image), house text 10868140 + data 2403024
(~13.3 MiB). The linker script sets `ENTRY(_start)`; `readelf -h` shows
the numeric entry address and `Machine: AArch64`.

## Named volumes (created on demand by `make volumes`)

- `house-target` → `/work/rust/target` (the Cargo workspace is `rust/`,
  not the repo root)
- `house-cabal` → `/root/.cabal`
- `house-cargo` → `/cargo-home` (`CARGO_HOME`; mounting over
  `/root/.cargo` would shadow the image's cargo binaries)

The repository remains bind-mounted at `/work`, including `kernel/build/` and
`platform/aarch64/build/`. Cargo target output and the Cabal/Cargo homes live
on named volumes.

## Host-side setup (not baked into the image)

```sh
brew install qemu expect socat                      # QEMU 11.1.1, expect 5.45, socat for virtio-con
container builder start -c 4 -m 4G              # 4 CPU / 4 GB floor (Apple path)
```

Linux CI instead uses Docker (`$(RUNNER)` selects it) with
`sudo apt-get install -y qemu-system-arm qemu-utils socat expect jq cpio file`
plus a GHCup Haskell toolchain (GHC + Cabal via ghcup, fourmolu from its
official linux-arm64 release zip, hlint 3.10 built once with an older GHC
since it has no aarch64 binary), and runs `make check-tcg`.

## Dependency updates (Dependabot) and CI caching

- `.github/dependabot.yml` tracks `cargo` (`/rust`), `rust-toolchain`
  (`rust-toolchain.toml`), `docker` (`Containerfile` base-image digest),
  and `github-actions` weekly. Haskell/Hackage has no Dependabot
  ecosystem, so GHC/cabal `index-state`/fourmolu/hlint/cargo-deny pins
  stay manual: `.github/workflows/toolchain-check.yml` reports the latest
  upstream releases weekly, and every bump updates the table above.
- `check.yml`/`nightly.yml` cache three legs: the toolchain image via the
  Docker Buildx GHA cache backend (`load: true` exposes
  `house-port:latest` to the `make *-build` steps), the host Haskell
  toolchain (`~/.ghcup`, `~/.cabal/packages`, fourmolu/hlint binaries) plus
  the incremental Cabal store (`~/.cabal/store`, `dist-newstyle` keyed on
  `cabal.project` + `**/*.cabal`), and the container named volumes
  (`house-cargo`/`house-target`/`house-cabal`, seeded from
  `actions/cache` on `rust/Cargo.lock` + `rust-toolchain.toml`). Bump the
  `v1-`/`house-vol-v1-` cache prefixes when the corresponding pins move.

Install Apple's `container` CLI (macOS) and `jq` before using the root Makefile.
Do not export `CONTAINER_DEFAULT_PLATFORM`; the root Makefile scopes it to
the Apple `container build` and pins every run explicitly. Host-side Haskell gates also
require GHC/Cabal, Fourmolu 0.20.1.0, and a GHC2024-capable HLint (3.10 is
known to work).

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

`make check` obtains clean firmware builds through the spike, IRQ, and House
legs, runs the host QEMU gates, and then runs Rust checks in the container and
Haskell checks on the host. Focused filesystem, device, SMP, VM, and EL0
process gates run on demand.
