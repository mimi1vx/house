# Porting log — GHC 6.8.2/i386 → GHC 9.14.1/aarch64

Running log of deviations, discoveries and fixes. One entry per completed
phase (see `plans/ghc-9.14-aarch64-port.md` for the master plan).

## Phase 1 — build environment (2026-08-26)

- Container: `house-port:latest`, built from `Containerfile`
  (debian:12-slim, ghcup MINIMAL profile, GHC 9.14.1).
- Verified: `container image inspect` → `arm64` only; in-container
  `uname -m` → `aarch64`; `ghc --version` → 9.14.1.
- **Deviation from phase-1 doc:** apt dep is `libgmp-dev`, not `libgmp10`.
  `libgmp10` provides only the runtime `.so.10`; linking any Haskell program
  fails with `/usr/bin/ld: cannot find -lgmp`. Caught by the mounted
  compile-and-run check exactly as the risks section predicted.
- QEMU 11.1.0 installed on macOS host via Homebrew (HVF accel available);
  `qemu-system-aarch64 --version` verified.
- `CONTAINER_DEFAULT_PLATFORM` intentionally **not** set globally; every
  container/build invocation passes `--platform linux/arm64` explicitly
  (apple-container skill belt-and-braces rule).
- Legacy i386 flow untouched: `git diff` on `Makefile` shows additions only
  (`container-image`, `container-shell` targets).
