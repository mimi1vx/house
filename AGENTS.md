# AGENTS.md — house/hOp aarch64 OS / microkernel

GHC RTS-based operating system and microkernel (Haskell + tinylibc C wrapper), aarch64-only, runs freestanding under QEMU `virt` on Apple silicon. No GHC patches — stock threaded RTS (-N=SMP_N, per-core run queues, SGI 0 IPI, I+D caches WB via `tinylibc/threads.c`+`spinlock.h`); freestanding constraint "unsafe FFI only" (safe ccall would need scheduler-backed worker threads).

## Layout

- `kernel/` — Haskell kernel closure rooted at `HouseA64.hs` (`H/`, `Kernel/`, `Monad/`, `Util/`; import roots preserved). `kernel/Makefile` is `ghc --make -no-link` only.
- `platform/aarch64/` — freestanding C/asm + `tinylibc/` + `spinlock.h` + `aarch64.ld` + entry Haskell (`Spike.hs`, `IrqCheck.hs`). Link via `ld --build-id=none --gc-sections -T build/aarch64.ld` against bindist archives (SMP-aware `build/aarch64.ld` generated via `cc -E -P -DHOUSE_SMP_N`). `build/` gitignored.
- `scripts/` — 7 `expect` harnesses (`qemu-smoke.exp`, `qemu-irq.exp`, `qemu-house.exp`, `qemu-house-shell.exp`, `qemu-house-posix.exp`, `qemu-smp.exp`, `qemu-ipc.exp`). ELF path is argv.
- `plans/` — untracked local notes (not gitignored, not committed).
- Root `Makefile` — aarch64-only orchestration; `Containerfile` — build image.

## Commands (run from repo root on macOS host)

```sh
make container-image          # build linux/arm64 image (pinned, asserts arm64-only)
make container-shell          # interactive shell inside image (binds $PWD -> /work)

SPIKE_MEM=4G make spike-build && make spike-run     # 512M/1G/2G/4G all valid; default 4G
SPIKE_MEM=512M make spike-check                      # clean+build+ expect hvf
SMP_N=2 make smp-check                               # 2 cores online + Haskell parallel (hvf+tcg)
SMP_N=4 make smp-check                               # 4 cores online + Haskell parallel (hvf+tcg, 4G working set)

make irq-build / irq-run / irq-check                # irq-check = hvf+tcg, asserts vm-ok
make house-build / house-run / house-check          # banner "Welcome to the House shell" hvf+tcg
make house-shell-check        # prompt + help->Usage + lambda + wastemem 10->55 hvf+tcg
make house-posix-check        # help -- descriptions, echo/uname/uptime, shutdown -r (reboot) / -h (halt)
make house-fs-check           # ramfs: write/cat/ls/mkdir/rm + echo > /path over H.FileSystem (2 MiB pool) hvf+tcg
make house-ipc-check          # ipc: ns ls/reg + ipc ping/pl011 + grant + burst 20 over Kernel.IPC (L4 sync, copy+grant, both ns+cap, hybrid Haskell/EL0) hvf+tcg
make smp-check                # smp: N cores online + caps N + parfib 20=6765 + mvar ok hvf+tcg (default N=2; SMP_N=4 for >2 gate)
make check                    # CI gate: spike-check + irq-check + house-check + house-shell-check + house-posix-check
make run                      # alias for house-run (hvf, $SPIKE_MEM)
```

Inside container (or via `make container-shell`):
```sh
make -C kernel                # ghc --make -no-link HouseA64.hs -O1 -package mtl,array,containers,pretty + EXTS
make -C platform/aarch64 house SMP_N=2 DEFS_C='... -DHOUSE_SMP_N=2' DEFS_S='... -DHOUSE_SMP_N=2'   # ld --build-id=none
```

## Toolchain quirks

- **Container is build-only; QEMU never runs inside it.** Host needs `brew install qemu expect`; QEMU uses `-accel hvf` (macOS) or `tcg`, `-M virt,gic-version=3`, `-cpu max`, `-smp SMP_N`.
- **Every `container` invocation must pin `--platform linux/arm64`** — `CONTAINER_DEFAULT_PLATFORM` is not set globally. `Containerfile:5` fails if `uname -m != aarch64`; root `Makefile:9` asserts `image inspect` arch == `arm64` (no Rosetta/amd64 fallback).
- **RAM is compiled in.** `SPIKE_MEM` (default `4G`) computes `SPIKE_RAM_BYTES` + `BOOT_STACK_TOP`/`HOUSE_RAM_BYTES`/`HOUSE_STACK_TOP` in `Makefile:22-35` and drives both `DEFS_C/S` and QEMU `-m`. `SPIKE_MEM` and QEMU `-m` can never disagree. `SMP_N` (default `2`, ≤`HOUSE_MAX_SMP` `16`, tested to `8`) computes `HOUSE_SMP_N` and per-core 16K stacks (`BOOT_STACK_TOP - core*16K`, `__early_stacks_base + SMP_N*16K`); `SPIKE_MEM`+`SMP_N` together must fit (512M+2 stacks is smallest gate). `4G` is the `SMP>2` working set; `512M` stays valid for `N=2` regression only. Small values are first-class.
- **Stock RTS seam:** `platform/aarch64/tinylibc/sys.c` fakes `timerfd`/`signal`/`pipe`/`mmap`; `tick.h` + `timer.c` feeds `house_rts_tick()` from the ARM generic timer (PPI 27/30) — per-core `house_isr_pending[core]` + `house_boot_ticks[core]`, `house_timer_init_secondary` per core; `house_isr_active` switches `house_timerfd_due(core)` to per-core pending. `sysconf(_SC_NPROCESSORS)=SMP_N` and `sched_getaffinity` reports `(1<<SMP_N)-1`; `sched_setaffinity`/`pthread_setaffinity_np` honor affinity. RTS defaults to `-N SMP_N` via synthesized `+RTS -Nn -RTS` if no explicit `-N`.
- **Boot:** `platform/aarch64/start.S` handles EL3→EL2→EL1 drop, enables `ICC_SRE_EL2`, enables FP/SIMD (`cpacr_el1`), applies `R_AARCH64_RELATIVE` relocs (primary only), clears BSS (primary only), installs VBAR, calls `house_mmu_early` (primary, identity-maps RAM `0x40000000` + `HOUSE_RAM_BYTES` as Normal WB Inner-shareable, `SCTLR.C/I=1` with TLB/ICI/DCISW maintenance) or `house_mmu_enable_secondary` (secondaries, shared tables), per-core `sp = BOOT_STACK_TOP - core*16K`, then `c_start` vs `c_start_secondary` (secondary via `secondary_entry` 4K-aligned PSCI entry `psci_cpu_on` `0xC4000003` `hvc` with `smc` fallback). Guest entry `_start` at `0x40080000` (`build/aarch64.ld:12`).
- **GICv3** (`gic.c`): `GICD 0x08000000`, `GICR 0x080A0000 + core*0x20000`; wake `GICR_WAKER` per core, mark PPIs 27/29/30 + SGI 0 Group1 per core, enable via `ICC_PMR/IGRPEN1/BPR1`. `house_gic_send_sgi_to_core(0, core)` via `ICC_SGI1R_EL1` Aff3/Aff2/Aff1/RS/TargetList encoding (unicast, correct for any Aff topology; mask variant loops via helper) kicks remote core's scheduler. `H.Interrupts` maps `ppiVirtTimer=27`, `ppiPhysTimer=30`, `spi n = 32+n`.
- **Link:** `platform/aarch64/Makefile:28-39` locates `HsFFI.h` + `libHS{rts,base,ghc-prim,ghc-bignum,ghc-internal,containers,pretty,mtl,array,transformers,deepseq,Cffi}.a` via `ghc --print-libdir`/`ghc-pkg field`; `rts` is threaded (`grep thr`); archives + `libgmp.a` + `libgcc` linked `--start-group/--end-group`. `readelf -h` gate checks `ENTRY(_start)` / `Machine: AArch64`.
- **Haskell exts** pinned in `kernel/Makefile:20-32`: `MultiParamTypeClasses FunctionalDependencies FlexibleInstances FlexibleContexts UndecidableInstances ImplicitParams ExistentialQuantification ScopedTypeVariables Rank2Types KindSignatures PatternGuards ForeignFunctionInterface GeneralizedNewtypeDeriving` (`-O1 -Wall`; `OverlappingInstances` is per-instance `OVERLAPPING`, not global).
- **PSCI:** `psci.c` via `hvc #0` (`SYSTEM_OFF`/`SYSTEM_RESET`/`CPU_ON 0xC4000003`/`CPU_OFF`/`AFFINITY_INFO`) with `smc` fallback; QEMU `virt` pins `psci-conduit=hvc`. `timer.c` records `CNTVCT_EL0` per core at boot for `house_uptime_secs`.
- **Shell:** `HouseA64.hs` — `help`/`echo`/`clear`/`uname` (`House/hOp 0.8.93 aarch64 GHC-9.14.1 QEMU-virt`)/`uptime`/`shutdown [-h|-r]` (xor semantics; both/neither → `usage: shutdown [-h|-r]`) + `lambda`/`preempt`/`wastemem` + `smp` (`cores=N onlineMask timers PPI27+30 ipi=SGI0 caches=WB`)/`caps` (`getNumCapabilities`)/`parfib`/`mvar` + `ls`/`cat`/`write`/`rm`/`mkdir`/`stat` + `echo > /path` via `H.FileSystem` ramfs (volatile 2 MiB pool over `H.Pages` 512×4K) + `ns ls/reg` + `ipc ping/pl011` + `ipc grant` via `Kernel.IPC` (L4 sync rendezvous, copy+grant, both ns+cap, hybrid Haskell/EL0). UART via `Kernel.Driver.PL011`.

## Verification order

- Always `make -C platform/aarch64 clean` (and `make -C kernel clean` for house) before a `*-check` — `*-check` targets do this themselves; don't skip when running `*-build` manually.
- Expect signature: `expect scripts/<harness>.exp <elf> <marker> [timeout] [accel] [mem] [smp]` — marker strings: `ticks-ok` (spike), `vm-ok` (irq implies `irq-ok`), `Welcome to the House shell` (house), `smp: 2 cores online` (smp).
- No `npm`/`cargo`/`pytest`/`ruff`/`biome` — only `make check` + `expect`.

## Conventions

- Do not add `CONTAINER_DEFAULT_PLATFORM` globally; keep per-invocation `--platform linux/arm64`.
- Keep aarch64-only — no x86/i386 paths.
- `plans/` stays untracked (intentional); `.gitignore` only covers `kernel/build/` + `platform/aarch64/build/`.
