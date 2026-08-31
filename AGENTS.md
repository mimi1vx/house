# AGENTS.md — house/hOp aarch64 OS / microkernel

GHC RTS-based operating system and microkernel (Haskell + tinylibc C wrapper), aarch64-only, runs freestanding under QEMU `virt` on Apple silicon. No GHC patches — stock threaded RTS (-N1, cooperative green threads via tinylibc/threads.c); freestanding constraint "unsafe FFI only" (safe ccall would need scheduler-backed worker threads).

## Layout

- `kernel/` — Haskell kernel closure rooted at `HouseA64.hs` (`H/`, `Kernel/`, `Monad/`, `Util/`; import roots preserved). `kernel/Makefile` is `ghc --make -no-link` only.
- `platform/aarch64/` — freestanding C/asm + `tinylibc/` + `aarch64.ld` + entry Haskell (`Spike.hs`, `IrqCheck.hs`). Link via `ld --build-id=none --gc-sections -T aarch64.ld` against bindist archives. `build/` gitignored.
- `scripts/` — 5 `expect` harnesses (`qemu-smoke.exp`, `qemu-irq.exp`, `qemu-house.exp`, `qemu-house-shell.exp`, `qemu-house-posix.exp`). ELF path is argv.
- `plans/` — untracked local notes (not gitignored, not committed).
- Root `Makefile` — aarch64-only orchestration; `Containerfile` — build image.

## Commands (run from repo root on macOS host)

```sh
make container-image          # build linux/arm64 image (pinned, asserts arm64-only)
make container-shell          # interactive shell inside image (binds $PWD -> /work)

SPIKE_MEM=4G make spike-build && make spike-run     # 512M/1G/2G/4G all valid; default 4G
SPIKE_MEM=512M make spike-check                      # clean+build+ expect hvf

make irq-build / irq-run / irq-check                # irq-check = hvf+tcg, asserts vm-ok
make house-build / house-run / house-check          # banner "Welcome to the House shell" hvf+tcg
make house-shell-check        # prompt + help->Usage + lambda + wastemem 10->55 hvf+tcg
make house-posix-check        # help -- descriptions, echo/uname/uptime, shutdown -r (reboot) / -h (halt)
make check                    # CI gate: spike-check + irq-check + house-check + house-shell-check + house-posix-check
make run                      # alias for house-run (hvf, $SPIKE_MEM)
```

Inside container (or via `make container-shell`):
```sh
make -C kernel                # ghc --make -no-link HouseA64.hs -O1 -package mtl,array,containers,pretty + EXTS
make -C platform/aarch64 house DEFS_C='...' DEFS_S='...'   # ld --build-id=none
```

## Toolchain quirks

- **Container is build-only; QEMU never runs inside it.** Host needs `brew install qemu expect`; QEMU uses `-accel hvf` (macOS) or `tcg`, `-M virt,gic-version=3`, `-cpu max`.
- **Every `container` invocation must pin `--platform linux/arm64`** — `CONTAINER_DEFAULT_PLATFORM` is not set globally. `Containerfile:5` fails if `uname -m != aarch64`; root `Makefile:9` asserts `image inspect` arch == `arm64` (no Rosetta/amd64 fallback).
- **RAM is compiled in.** `SPIKE_MEM` (default `4G`) computes `SPIKE_RAM_BYTES` + `BOOT_STACK_TOP`/`HOUSE_RAM_BYTES`/`HOUSE_STACK_TOP` in `Makefile:22-35` and drives both `DEFS_C/S` and QEMU `-m`. `SPIKE_MEM` and QEMU `-m` can never disagree. Small values (512M) are first-class.
- **Stock RTS seam:** `platform/aarch64/tinylibc/sys.c` fakes `timerfd`/`signal`/`pipe`/`mmap`; `tick.h` + `timer.c` feeds `house_rts_tick()` from the ARM generic timer (PPI 27/30) — not wall-clock. `house_isr_active` switches `house_timerfd_due` to `house_isr_pending` counter.
- **Boot:** `platform/aarch64/start.S` handles EL3→EL2→EL1 drop, enables `ICC_SRE_EL2`, enables FP/SIMD (`cpacr_el1`), applies `R_AARCH64_RELATIVE` relocs, clears BSS, installs VBAR, calls `house_mmu_early` (identity-maps RAM `0x40000000` + `HOUSE_RAM_BYTES`) before `c_start`. Guest entry `_start` at `0x40080000` (`aarch64.ld:12`).
- **GICv3** (`gic.c`): `GICD 0x08000000`, `GICR 0x080A0000`; wake `GICR_WAKER`, mark PPIs 27/29/30 Group1, enable via `ICC_PMR/IGRPEN1/BPR1`. `H.Interrupts` maps `ppiVirtTimer=27`, `ppiPhysTimer=30`, `spi n = 32+n`.
- **Link:** `platform/aarch64/Makefile:28-39` locates `HsFFI.h` + `libHS{rts,base,ghc-prim,ghc-bignum,ghc-internal,containers,pretty,mtl,array,transformers,deepseq,Cffi}.a` via `ghc --print-libdir`/`ghc-pkg field`; `rts` is threaded (`grep thr`); archives + `libgmp.a` + `libgcc` linked `--start-group/--end-group`. `readelf -h` gate checks `ENTRY(_start)` / `Machine: AArch64`.
- **Haskell exts** pinned in `kernel/Makefile:20-32`: `MultiParamTypeClasses FunctionalDependencies FlexibleInstances FlexibleContexts UndecidableInstances ImplicitParams ExistentialQuantification ScopedTypeVariables Rank2Types KindSignatures PatternGuards ForeignFunctionInterface GeneralizedNewtypeDeriving` (`-O1 -Wall`; `OverlappingInstances` is per-instance `OVERLAPPING`, not global).
- **PSCI:** `psci.c` via `hvc #0` (`SYSTEM_OFF`/`SYSTEM_RESET`); QEMU `virt` pins `psci-conduit=hvc`. `timer.c` records `CNTVCT_EL0` at boot for `house_uptime_secs`.
- **Shell:** `HouseA64.hs:88-119` — `help`/`echo`/`clear`/`uname` (`House/hOp 0.8.93 aarch64 GHC-9.14.1 QEMU-virt`)/`uptime`/`shutdown [-h|-r]` (xor semantics; both/neither → `usage: shutdown [-h|-r]`) + `lambda`/`preempt`/`wastemem`. UART via `Kernel.Driver.PL011` (`Chan ConsoleCommand -> uart_putc`, `uart_getc_nonblock -> Chan KeyPress -> LineEditor`).

## Verification order

- Always `make -C platform/aarch64 clean` (and `make -C kernel clean` for house) before a `*-check` — `*-check` targets do this themselves; don't skip when running `*-build` manually.
- Expect signature: `expect scripts/<harness>.exp <elf> <marker> [timeout] [accel] [mem]` — marker strings: `ticks-ok` (spike), `vm-ok` (irq implies `irq-ok`), `Welcome to the House shell` (house).
- No `npm`/`cargo`/`pytest`/`ruff`/`biome` — only `make check` + `expect`.

## Conventions

- Do not add `CONTAINER_DEFAULT_PLATFORM` globally; keep per-invocation `--platform linux/arm64`.
- Keep aarch64-only — no x86/i386 paths.
- `plans/` stays untracked (intentional); `.gitignore` only covers `kernel/build/` + `platform/aarch64/build/`.
