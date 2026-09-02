# hOp — House on AArch64

hOp is a microkernel built on the RTS of GHC, the Glasgow Haskell Compiler, for experimenting with device drivers in Haskell.

The RTS of GHC is a standalone runtime. With the system-specific bits removed and a small freestanding layer of C and assembly, it becomes a microkernel extensible in Haskell. All of `base` outside `System` is available, including threads, communication primitives, and the foreign interface.

History: the original i386/GRUB implementation (GHC 6.8.2, 32 MB flat memory model) is preserved in git history.

## aarch64 port (GHC 9.14, QEMU virt)

A freestanding aarch64 build that runs under QEMU `virt` (`-M virt,gic-version=3`) on Apple silicon. Stock threaded RTS, no GHC patches. The freestanding constraint is "unsafe FFI only" — safe `ccall` would require scheduler-backed worker threads.

### Toolchain

* Build container `house-port:latest` (Debian 12, GHC 9.14.1 aarch64 bindist via ghcup, binutils/gcc). Every Haskell/C compilation runs `container run --platform linux/arm64 ...` (see `Containerfile`); `CONTAINER_DEFAULT_PLATFORM` is never set globally — each invocation pins `--platform linux/arm64` and `container image inspect` asserts `arm64` only.
* QEMU on the macOS host (`brew install qemu expect`, HVF acceleration). The container is build-only; QEMU never runs inside it.
 * Guest RAM is auto-detected (DTB `reg` → probe `128M→16G` → `128M` fallback; same ELF at `256M`/`512M`/`1G`/`2G`/`4G`/`8G`/`16G` without rebuild). `SPIKE_MEM ?= 4G` (now `HOUSE_RAM_LIMIT`) only drives QEMU `-m` and caps `HOUSE_RAM_LIMIT_BYTES`. `SMP_N ?= 2` (now `HOUSE_SMP_LIMIT`) compiles `HOUSE_SMP_N`/`HOUSE_SMP_LIMIT` and per-core 16 KiB stacks (`house_boot_stack_top - core*16K`, `__early_stacks_base + SMP_N*16K`); `SMP_N` scales to `HOUSE_MAX_SMP` 16 (tested to 8). `TCR EPD1=0` split `TTBR1=kernel` / `TTBR0=user` with 8-bit ASID, `TLBI VAE1IS` + SGI 1 `VMALLE1IS` shootdown.

### What boots

* `platform/aarch64/{start.S,c_start.c,mmu.c,gic.c,timer.c,irq.c,userspace.c,uart.c,psci.c,aarch64.ld}` plus `tinylibc` and `spinlock.h` for the stock threaded RTS (`-N SMP_N`, per-core run queues, SGI 0 IPI, I+D caches WB via `tinylibc/threads.c` + `spinlock.h`). Guest entry `_start` at `0x40080000` (`build/aarch64.ld:12`).
* `tinylibc/sys.c` fakes `timerfd`/`signal`/`pipe`/`mmap`; `tick.h` + `timer.c` feeds `house_rts_tick()` from the ARM generic timer (PPI 27/30) — per-core `house_isr_pending[core]` + `house_boot_ticks[core]`, `house_timer_init_secondary` per core; `house_isr_active` switches `house_timerfd_due(core)` to per-core pending. `sysconf(_SC_NPROCESSORS) = SMP_N` and `sched_getaffinity` reports `(1<<SMP_N)-1`; `sched_setaffinity`/`pthread_setaffinity_np` honor affinity. RTS defaults to `-N SMP_N` via synthesized `+RTS -Nn -RTS` when no explicit `-N` is given.
* `H.Interrupts` is GIC-native (`IntId`, `ppiVirtTimer=27`, `ppiPhysTimer=30`, `spi n = 32+n`, dispatcher `threadDelay 20ms` poll, `house_irq_push/pop`).
 * `H.VirtualMemory` is aarch64 4 KiB-granule L0→L3 over `0x01000000–0xFFFFFFFF` (4 GB TTBR0 window, `T0SZ=16 4K` single L0 + L1 0..3 demand-allocated, per-`PageMap` `TTBR0_EL1`+ASID via `userspace.c:house_handle_user_fault` demand pager that allocates 4K via `buddy` and `VAE1IS`+SGI 1 `VMALLE1IS` shootdown, `mprotect RO→perm fault DFSC 0x0C..0x0F`, `munmap→TLBI VAE1IS+SGI1`). Kernel RAM `0x40000000`+`house_ram_bytes` stays TTBR1 Normal WB Inner-shareable (`SCTLR_EL1.C/I=1`).
 * `H.FileSystem` is a volatile ramfs over `H.Pages` (now `buddy` over `__heap_base+64M .. house_boot_stack_top` plus 512-page legacy pool, 2 MiB cap) with `H.AdHocMem`/`H.Utils` backing; `sysconf(_SC_PHYS_PAGES)` = `house_ram_bytes>>12`, `freePageCount` ≈ `ram/4K`.
* `HouseA64.hs` is the shell entry (`house_main`): `help` (every command carries a `-- description`), `echo <word>...`, `clear` (`ESC[2J ESC[H`), `uname [-asnrvmio] [--help]` (`House` bare, `-a` → `House house 0.8.93 #1 SMP ... aarch64 aarch64 QEMU-virt House`), `uptime` (`house_uptime_secs` via `CNTVCT_EL0`), `shutdown [-h|-r]` (PSCI `SYSTEM_OFF`/`SYSTEM_RESET` via `hvc #0`; `-r` only → reboot, `-h` only → halt, neither/both → `usage: shutdown [-h|-r]`), plus `lambda`, `preempt`, `wastemem` (all with descriptions), `smp` (`cores=N onlineMask timers PPI27+30 ipi=SGI0 caches=WB`), `caps` (`getNumCapabilities`), `parfib`, `mvar`, and the VFS commands `ls`/`cat`/`write`/`rm`/`mkdir`/`stat` plus `echo > /path` sugar over `H.FileSystem`. UART via `Kernel.Driver.PL011`. `psci.c` parks in `wfi` on failure; QEMU `virt` pins `psci-conduit=hvc`. `timer.c` records `CNTVCT_EL0` per core at boot for `house_uptime_secs()`.

### Boot

`platform/aarch64/start.S` handles the EL3→EL2→EL1 drop, enables `ICC_SRE_EL2`, enables FP/SIMD (`cpacr_el1`), applies `R_AARCH64_RELATIVE` relocations (primary only), clears BSS (primary only), installs VBAR, calls `house_mmu_early` (primary, identity-maps RAM up to `16G` for probe) or `house_mmu_enable_secondary` (secondaries, shared tables), sets per-core `sp = house_boot_stack_top - core*16K` (early `__early_stacks_top`, rebased after `house_detect_early`), then enters `c_start` vs `c_start_secondary` (secondaries via `secondary_entry` 4 KiB-aligned PSCI entry `psci_cpu_on` `0xC4000003` `hvc` with `smc` fallback). `c_start` probes `house_ram_probe` (`128M→16G`) then `house_mmu_update_alias()` rebuilds RTS alias `0x4200000000+`.

### GICv3

`gic.c`: `GICD 0x08000000`, `GICR 0x080A0000 + core*0x20000`; wake `GICR_WAKER` per core, mark PPIs 27/29/30 + SGI 0 Group1 per core, enable via `ICC_PMR/IGRPEN1/BPR1`. `house_gic_send_sgi_to_core(0, core)` via `ICC_SGI1R_EL1` Aff3/Aff2/Aff1/RS/TargetList encoding (unicast, correct for any Aff topology; mask variant loops via helper) kicks the remote core's scheduler.

### Linking

`platform/aarch64/Makefile` locates `HsFFI.h` and `libHS{rts,base,ghc-prim,ghc-bignum,ghc-internal,containers,pretty,mtl,array,transformers,deepseq,Cffi}.a` via `ghc --print-libdir` / `ghc-pkg field`; `rts` is threaded. Archives plus `libgmp.a` plus `libgcc` are linked `--start-group`/`--end-group`. `readelf -h` gate checks `ENTRY(_start)` / `Machine: AArch64`. `build/aarch64.ld` is generated via `cc -E -P -DHOUSE_SMP_N`.

## Build & run (host)

All commands run from the repository root on the macOS host:

```sh
# one-time: build the linux/arm64 image (pinned arm64, no Rosetta)
make container-image

# spike: Haskell -> PL011 -> ticks-ok (threadDelay 500 ms x4)
make spike-build        # container: make -C platform/aarch64 DEFS_C/S
make spike-run          # qemu hvf, -m 4G, -kernel platform/aarch64/build/spike.elf
make spike-check        # clean + build + expect hvf

# GIC + VM
make irq-build / make irq-run
make irq-check          # -> irq-ok + vm-ok, hvf and tcg

# house: welcome banner + interactive + POSIX shell + PSCI
make house-build / make house-run
make house-check        # -> "Welcome to the House shell" banner, hvf+tcg
make house-shell-check  # -> prompt, help->Usage, lambda, wastemem 10->55, hvf+tcg
make house-posix-check  # -> help descriptions (-- ), echo, uname, uptime, shutdown -r (reboot) / -h (halt), hvf+tcg
make house-fs-check     # -> ramfs: write/cat/ls/mkdir/rm + echo > /path over H.FileSystem (2 MiB pool), hvf+tcg
make smp-check          # -> N cores online + caps N + parfib 20=6765 + mvar ok, hvf+tcg (default N=2; SMP_N=4 for >2 gate)

# parametrised SMP + RAM
SPIKE_MEM=512M make spike-check                      # 512M/1G/2G/4G all valid; default 4G
SMP_N=2 make smp-check                               # 2 cores online + Haskell parallel (hvf+tcg)
SMP_N=4 make smp-check                               # 4 cores online + Haskell parallel (hvf+tcg, 4G working set)

# all gates from clean (the CI gate)
make check              # spike-check + irq-check + house-check + house-shell-check + house-posix-check
make run                # alias for house-run (hvf, $SPIKE_MEM)
```

Inside the container (via `make container-shell`):

```sh
make -C kernel                            # ghc --make -no-link HouseA64.hs
make -C platform/aarch64 house SMP_N=2    # ld --build-id=none
```

Expect harnesses live in `scripts/` (`qemu-smoke.exp`, `qemu-irq.exp`, `qemu-house.exp`, `qemu-house-shell.exp`, `qemu-house-posix.exp`, `qemu-house-fs.exp`, `qemu-smp.exp` plus `rts-symbols.sh`) — each `spawn qemu-system-aarch64 -accel hvf|tcg -M virt,gic-version=3 -smp SMP_N -m $mem -nographic -kernel $elf` and asserts its marker (`ticks-ok`, `vm-ok`, `Welcome to the House shell`, prompt/echo, ramfs round-trip, or `smp: N cores online`).

Always `make -C platform/aarch64 clean` (and `make -C kernel clean` for house) before a `*-check` — the `*-check` targets do this themselves; do not skip when running `*-build` manually.

Expect signature: `expect scripts/<harness>.exp <elf> <marker> [timeout] [accel] [mem] [smp]` — marker strings: `ticks-ok` (spike), `vm-ok` (irq implies `irq-ok`), `Welcome to the House shell` (house), `smp: 2 cores online` (smp).

## Closure & extensions

`kernel/Makefile` is the single source of truth:

```sh
ghc --make -no-link HouseA64.hs -i. -outputdir build -O1 \
  -package mtl -package array -package containers -package pretty
```

with

```
EXTS = MultiParamTypeClasses FunctionalDependencies FlexibleInstances
       FlexibleContexts UndecidableInstances ImplicitParams
       ExistentialQuantification ScopedTypeVariables Rank2Types KindSignatures
       PatternGuards ForeignFunctionInterface GeneralizedNewtypeDeriving
```

(`-O1 -Wall`; `OverlappingInstances` is per-instance `OVERLAPPING`, not a global flag). `find kernel/build -name '*.o'` plus `start/mmu/c_start/uart` and `tinylibc` are linked `ld --build-id=none --gc-sections -T aarch64.ld` against `ghc-prim/bignum/ghc-internal/containers/pretty/mtl/array/transformers/deepseq/base/rts/Cffi + libgmp + libgcc`.

## Repository layout

```
/
|-- README.md
|-- LICENSE
|-- Makefile            # aarch64-only orchestration (container, spike, irq, house, smp, fs)
|-- Containerfile
|-- .gitignore          # kernel/build/, platform/aarch64/build/
|-- kernel/             # Haskell kernel (GHC import roots H./Kernel./Monad./Util. preserved)
|   |-- Makefile        # BUILD := build
|   |-- HouseA64.hs
|   |-- H/  Kernel/  Monad/  Util/    # closure only; H/FileSystem.hs + H/Pages.hs ramfs
|   `-- build/          # gitignored
|-- platform/aarch64/   # C/asm, tinylibc, spinlock.h, aarch64.ld, Spike.hs, IrqCheck.hs, Makefile
|   `-- build/          # gitignored
|-- scripts/            # 7 expect harnesses + rts-symbols.sh (ELF path is argv)
`-- plans/              # untracked, left on disk (local dev notes)
```

`plans/` is intentionally untracked (not gitignored) — local development notes kept on disk for contributors but not committed.

## License

MIT — see `LICENSE`. Inspired by House/hOp (S. Carlier / J. Bobbio, Programatica, 2004–2005) but no verbatim original code is retained; this aarch64/GHC-9.14 port is a clean rewrite. MIT is compatible with GHC 9.14's BSD-3-Clause RTS/license.
