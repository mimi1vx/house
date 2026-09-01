# AGENTS.md — house/hOp aarch64 OS

GHC RTS microkernel (Haskell + tinylibc), aarch64-only, QEMU `virt` on Apple silicon. Stock threaded RTS (`-N=SMP_N`), unsafe FFI only.

## Layout
- `kernel/` — Haskell closure rooted at `HouseA64.hs` (`H/`, `Kernel/`, `Monad/`, `Util/`). `kernel/Makefile` is `ghc --make -no-link` only.
- `platform/aarch64/` — freestanding C/asm, `tinylibc/`, `spinlock.h`, `aarch64.ld`, entry Haskell `Spike.hs`/`IrqCheck.hs`. `build/` gitignored.
- `scripts/` — `expect` harnesses `qemu-*.exp` (ELF path is argv).
- `Makefile` — host orchestration; `Containerfile` — build image.

## Container — build only
- **All compilation runs inside `house-port:latest`** (Debian 12, GHC 9.14.1 aarch64). QEMU never runs inside the container; host needs `brew install qemu expect`.
- **Every `container` invocation must pin `--platform linux/arm64`.** Never set `CONTAINER_DEFAULT_PLATFORM` globally. `Containerfile:5` fails if `uname -m != aarch64`; `Makefile:9` asserts `image inspect` arch is `arm64` (no Rosetta/amd64 fallback).
- Host entrypoints wrap this for you — `make spike-build` / `irq-build` / `house-build` run `container run --platform linux/arm64 --rm -v $PWD:/work -w /work house-port:latest make -C platform/aarch64 ...` with `DEFS_C`/`DEFS_S`/`SMP_N`.
- One-time setup: `make container-image`
- Interactive shell: `make container-shell` → `container run --platform linux/arm64 --rm -it -v $PWD:/work -w /work house-port:latest bash`
- Inside container directly: `make -C kernel` and `make -C platform/aarch64 house SMP_N=2 DEFS_C='... -DHOUSE_SMP_N=2' DEFS_S='... -DHOUSE_SMP_N=2'`

## Commands (repo root, macOS host)
```sh
make spike-check                         # ticks-ok, hvf
make irq-check                           # vm-ok, hvf+tcg
make house-check                         # "Welcome to the House shell", hvf+tcg
make house-shell-check house-posix-check # shell + POSIX (help/echo/uname/uptime/shutdown)
make house-fs-check house-ipc-check house-driver-check
make house-virtio-transport-check house-virtio-blk-check house-virtio-net-check
make smp-check                           # default SMP_N=2; SMP_N=4 for >2 gate (needs 4G)
make check                               # CI gate: spike + irq + house + shell + posix
SPIKE_MEM=512M make spike-check          # 512M/1G/2G/4G valid, default 4G
SMP_N=4 make smp-check
```

## Gotchas
- **RAM is compiled in.** `SPIKE_MEM` (default `4G`) sets `HOUSE_RAM_BYTES`/`BOOT_STACK_TOP` via `DEFS_C`/`DEFS_S` and must match QEMU `-m`. `SMP_N` (default `2`, max `16`, tested to `8`) sets `HOUSE_SMP_N` and per-core 16K stacks. `4G` is the `SMP_N>2` working set.
- `*-check` targets run `clean` themselves. If running `*-build` manually, `make -C platform/aarch64 clean` (and `make -C kernel clean` for house) first.
- Expect signature: `expect scripts/<harness>.exp <elf> <marker> [timeout] [accel] [mem] [smp]` — markers: `ticks-ok`, `vm-ok`, `Welcome to the House shell`, `smp: N cores online`.
- No `npm`/`cargo`/`pytest` — only `make` + `expect`.

## Conventions
- Keep aarch64-only; no x86 paths.
- `plans/` is untracked local notes (intentional, not gitignored); `.gitignore` only covers `kernel/build/` + `platform/aarch64/build/`.
