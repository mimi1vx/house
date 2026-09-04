# hOp — House on AArch64

hOp is a microkernel built on the RTS of GHC, the Glasgow Haskell Compiler, for experimenting with device drivers in Haskell.

The RTS of GHC is a standalone runtime. With the system-specific bits removed and a small freestanding layer of C and assembly, it becomes a microkernel extensible in Haskell. All of `base` outside `System` is available, including threads, communication primitives, and the foreign interface.

History: the original i386/GRUB implementation (GHC 6.8.2, 32 MB flat memory model) is preserved in git history.

## aarch64 port (GHC 9.14, QEMU virt)

A freestanding aarch64 build that runs under QEMU `virt` (`-M virt,gic-version=3`) on Apple silicon. Stock threaded RTS, no GHC patches. The freestanding constraint is "unsafe FFI only" — safe `ccall` would require scheduler-backed worker threads.

### Toolchain

* Build container `house-port:latest` (Debian 13, Rust stable `aarch64-unknown-none` + GHC 9.14.1 aarch64 via ghcup). Every Haskell/Rust/C compilation runs `container run --platform linux/arm64 ...` (see `Containerfile`); single sanctioned `CONTAINER_DEFAULT_PLATFORM=linux/arm64` on the `container build` line only (`Makefile`), never exported globally — each `run` pins `--platform linux/arm64` and `container image inspect` asserts `arm64` only. The HAL and boot are Rust (`rust/crates/house-boot` `global_asm!` + `rust/crates/house-hal-aarch64` + `rust/crates/house-libc`); see `rust/ARCHITECTURE.md`. `make rust-check` = `cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none -- -D warnings` + `cargo fmt --check`.
* QEMU on the macOS host (`brew install qemu expect`, HVF acceleration). The container is build-only; QEMU never runs inside it.
 * Guest RAM is auto-detected (DTB `reg` from the `x0` QEMU passes on its Linux boot path → open-ended fault probe doubling from 128M → `512M` fallback; one binary boots at `512M`/`1G`/`2G`/`4G`/`6G`/`8G`/`16G` without rebuild, hvf+tcg). QEMU only takes that path for non-ELF images, so `-kernel` boots the `objcopy -O binary` flat image (`build/*.bin`; `.elf` stays for `readelf`/`gdb`) — ELF `-kernel` boots get `x0=0` and no DTB, and the fault probe false-positives on hvf (reads beyond RAM succeed, later stores abort QEMU with `hvf_handle_exception`). `SPIKE_MEM ?= 4G` only drives QEMU `-m`. `SMP_N ?= 2` only drives QEMU `-smp` and expect args; core count is detected at runtime (DTB → PSCI/GICR max) with per-core 64 KiB stacks (`house_boot_stack_top - core*64K`, `__early_stacks` 32-entry HW reservation, HW bound 32, tested to 8). `TCR EPD1=0` split `TTBR1=kernel` / `TTBR0=user` with 8-bit ASID, `TLBI VAE1IS` + SGI 1 `VMALLE1IS` shootdown (online-only broadcast).

### What boots

* `rust/crates/house-boot` (`global_asm!` vectors, `_start`, `secondary_entry`, `house_enter_el0`) + `rust/crates/house-hal-aarch64` (`mmu`, `gic`, `timer`, `irq`, `buddy`, `dtb`/`detect`/`probe`, `userspace`, `svc`/`ipc`, `psci`, `uart`, `virtio_transport`/`virtio_blk`/`virtio_net`) + `rust/crates/house-libc` (`alloc`, `sys` fd/pipe/eventfd/epoll/timerfd, `threads`/`tls`/`sched`, `mm/vm`) plus `platform/aarch64/tinylibc` (`mem`, `stdio`, `compat`, `threads` `switch.S`/`tls_desc.S`, `spinlock.h`) and `platform/aarch64/aarch64.ld` for the stock threaded RTS (`-N SMP_N`, per-core run queues, SGI 0 IPI, I+D caches WB). Guest entry `_start` at `0x40080000` (`build/aarch64.ld:12`).
* `house-libc` `sys` provides `timerfd`/`signal`/`pipe`/`mmap` and the fd table; `tick.h` + `house-hal-aarch64/timer.rs` feeds `house_rts_tick()` from the ARM generic timer (PPI 27/30) — per-core `house_isr_pending[core]` + `house_boot_ticks[core]`, `house_timer_init_secondary` per core; `house_isr_active` switches `house_timerfd_due(core)` to per-core pending. `sysconf(_SC_NPROCESSORS) = SMP_N` and `sched_getaffinity` reports `(1<<SMP_N)-1`; `sched_setaffinity`/`pthread_setaffinity_np` honor affinity. RTS defaults to `-N SMP_N` via synthesized `+RTS -Nn -RTS` when no explicit `-N` is given.
* `H.Interrupts` is GIC-native (`IntId`, `ppiVirtTimer=27`, `ppiPhysTimer=30`, `spi n = 32+n`, dispatcher `threadDelay 20ms` poll, `house_irq_push/pop`).
 * `H.VirtualMemory` is aarch64 4 KiB-granule L0→L3 over `0x01000000–0xFFFFFFFF` (4 GB TTBR0 window, `T0SZ=16 4K` single L0 + L1 0..3 demand-allocated, per-`PageMap` `TTBR0_EL1`+ASID via `house-hal-aarch64/userspace.rs:house_handle_user_fault` demand pager that allocates 4K via `buddy` and `VAE1IS`+SGI 1 `VMALLE1IS` shootdown, `mprotect RO→perm fault DFSC 0x0C..0x0F`, `munmap→TLBI VAE1IS+SGI1`). Kernel RAM `0x40000000`+`house_ram_bytes` stays TTBR1 Normal WB Inner-shareable (`SCTLR_EL1.C/I=1`).
 * `H.FileSystem` is a volatile ramfs over `H.Pages` (now `buddy` over `__heap_base+64M .. house_boot_stack_top` plus 512-page legacy pool, 2 MiB cap) with `H.AdHocMem`/`H.Utils` backing; `sysconf(_SC_PHYS_PAGES)` = `house_ram_bytes>>12`, `freePageCount` ≈ `ram/4K`.
* `HouseA64.hs` is the shell entry (`house_main`): `help` (every command carries a `-- description`), `echo <word>...`, `clear` (`ESC[2J ESC[H`), `uname [-asnrvmio] [--help]` (`House` bare, `-a` → `House house 0.8.93 #1 SMP ... aarch64 aarch64 QEMU-virt House`), `uptime` (`house_uptime_secs` via `CNTVCT_EL0`), `shutdown [-h|-r]` (PSCI `SYSTEM_OFF`/`SYSTEM_RESET` via `hvc #0`; `-r` only → reboot, `-h` only → halt, neither/both → `usage: shutdown [-h|-r]`), plus `lambda`, `preempt`, `wastemem` (all with descriptions), `smp` (`cores=N onlineMask timers PPI27+30 ipi=SGI0 caches=WB`), `caps` (`getNumCapabilities`), `parfib`, `mvar`, VFS commands `ls`/`cat`/`write`/`rm`/`mkdir`/`stat` plus `echo > /path` sugar over `H.FileSystem`, IPC `ns`/`ipc ping`/`ipc grant`, driver `lsdev`/`dmesg`/`virtio`/`blk`/`net`/`ifconfig`/`ping`/`udpecho`/`arp`, and `free`/`mem`/`detect`/`vm`/`palloc`/`run /bin/hello` (EL0). UART via `Kernel.Driver.PL011`. `psci` parks in `wfi` on failure; QEMU `virt` pins `psci-conduit=hvc`. `timer` records `CNTVCT_EL0` per core at boot for `house_uptime_secs()`.

### Boot

`rust/crates/house-boot/src/entry.rs` (`global_asm!`) preserves the DTB pointer from `x0`, handles the EL2→EL1 drop (EL3 where present), enables `ICC_SRE_EL2`, enables FP/SIMD (`cpacr_el1`), applies `R_AARCH64_RELATIVE` relocations (primary only), clears BSS (primary only), installs VBAR, calls `house_mmu_early` (primary, identity-maps RAM per TCR/L1 capacity) or `house_mmu_enable_secondary` (secondaries, shared tables), sets per-core `sp = house_boot_stack_top - core*64K` (early `__early_stacks_top`, rebased after `house_detect_early`), then enters `c_start` vs `c_start_secondary` (secondaries via `secondary_entry` 4 KiB-aligned PSCI entry `psci_cpu_on` `0xC4000003` `hvc` with `smc` fallback). `c_start` runs `house_detect_early` (DTB `reg` → fault probe → fallback, `stack_top = BASE+ram-2M` via checked math) then `house_mmu_update_alias()` rebuilds RTS alias `0x4200000000+`.

### GICv3

`rust/crates/house-hal-aarch64/src/gic.rs`: `GICD 0x08000000`, `GICR 0x080A0000 + core*0x20000`; wake `GICR_WAKER` per core, mark PPIs 27/29/30 + SGI 0 Group1 per core, enable via `ICC_PMR/IGRPEN1/BPR1`. `house_gic_send_sgi_to_core(0, core)` via `ICC_SGI1R_EL1` Aff3/Aff2/Aff1/RS/TargetList encoding (unicast, correct for any Aff topology; mask variant loops via helper) kicks the remote core's scheduler.

### Linking

`platform/aarch64/Makefile` locates `HsFFI.h` and `libHS{rts,base,ghc-prim,ghc-bignum,ghc-internal,containers,pretty,mtl,array,transformers,deepseq,Cffi}.a` via `ghc --print-libdir` / `ghc-pkg field`; `rts` is threaded. `rust/crates/house-boot` (`libhouse_boot.rlib`), `house-hal-aarch64` (`libhouse_hal_aarch64.rlib`), `house-libc` (`libhouse_libc.a`) plus `libcore`/`libcompiler_builtins` and Haskell archives plus `libgmp.a` plus `libgcc` are linked `--start-group`/`--end-group`. `readelf -h` gate checks `ENTRY(_start)` / `Machine: AArch64`. `build/aarch64.ld` is generated via `cc -E -P` (no `-DHOUSE_*`; `HOUSE_MAX_SMP=32` HW reservation lives in `aarch64.ld`).

## Build & run (host)

All commands run from the repository root on the macOS host:

```sh
# one-time: build the linux/arm64 image (pinned arm64, no Rosetta)
make container-image

# spike: Haskell -> PL011 -> ticks-ok (threadDelay 500 ms x4)
make spike-build        # container: make -C platform/aarch64 DEFS_C/S
make spike-run          # qemu hvf, -m 4G, -kernel platform/aarch64/build/spike.bin
make spike-check        # clean + build + expect hvf

# GIC + VM
make irq-build / make irq-run
make irq-check          # -> vm-ok, hvf and tcg

# house: welcome banner + interactive + POSIX shell + PSCI
make house-build / make house-run
make house-check        # -> "Welcome to the House shell" banner, hvf+tcg
make house-shell-check  # -> prompt, help->Usage, lambda, wastemem 10->55, hvf+tcg
make house-posix-check  # -> help descriptions (-- ), echo, uname, uptime, shutdown -r (reboot) / -h (halt), hvf+tcg
make house-fs-check     # -> ramfs: write/cat/ls/mkdir/rm + echo > /path over H.FileSystem (2 MiB pool), hvf+tcg
make smp-check          # -> N cores online + caps N + parfib 20=6765 + mvar ok, hvf+tcg (default N=2; SMP_N=4 for >2 gate)
make smp-check-8        # -> smp-check at SMP_N=8/SPIKE_MEM=4G (scaling gate, ceiling 32; nightly, N=2 per-commit)
make smp-hotplug-check  # -> smp down 1/up 1 cycle at N=2, caps mirror, parfib each step (hvf+tcg)
make vm-check           # -> demand 100 pages + mprotect RO + munmap + isolate + asid + smp shootdown, one build booted at 512M/2+4G/4+6G/4+8G/4+16G/4 + mem buddy free/total at each geometry
make house-ipc-check house-driver-check
make house-virtio-transport-check house-virtio-blk-check house-virtio-net-check house-virtio-con-check
make house-userspace-check  # -> run /bin/hello -> Hello from EL0, TTBR0/ASID/pager, argv+env on EL0 stack (hvf+tcg)
make rust-check         # -> cargo clippy + cargo fmt --check inside linux/arm64

# parametrised SMP + RAM
SPIKE_MEM=512M make spike-check                      # 512M/1G/2G/4G all valid; default 4G
SMP_N=2 make smp-check                               # 2 cores online + Haskell parallel (hvf+tcg)
SMP_N=4 make smp-check                               # 4 cores online + Haskell parallel (hvf+tcg, 4G working set)

# all gates from clean (the CI gate)
make check              # spike-check + irq-check + house-check + house-shell-check + house-posix-check + rust-check
make run                # alias for house-run (hvf, $SPIKE_MEM)
```

Inside the container (via `make container-shell`):

```sh
make -C kernel                            # ghc --make -no-link HouseA64.hs
make -C platform/aarch64 house SMP_N=2    # cargo build --target aarch64-unknown-none + ld --build-id=none
```

Expect harnesses live in `scripts/` (`qemu-smoke.exp`, `qemu-irq.exp`, `qemu-house.exp`, `qemu-house-shell.exp`, `qemu-house-posix.exp`, `qemu-house-fs.exp`, `qemu-smp.exp`, `qemu-vm.exp`, `qemu-ipc.exp`, `qemu-driver.exp`, `qemu-virtio-transport.exp`, `qemu-virtio-blk.exp`, `qemu-virtio-net.exp`, `qemu-userspace.exp` plus `rts-symbols.sh`) — each `spawn qemu-system-aarch64 -accel hvf|tcg -M virt,gic-version=3 -smp SMP_N -m $mem -nographic -kernel $elf` and asserts its marker (`ticks-ok`, `vm-ok`, `Welcome to the House shell`, prompt/echo, ramfs round-trip, or `smp: N cores online`).

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
EXTS = -XGHC2024
```

(`-O1 -Wall -Werror`; per-instance `OVERLAPPING` where needed). `find kernel/build -name '*.o'` plus `rust/crates/house-boot` + `house-hal-aarch64` + `house-libc` and `platform/aarch64/tinylibc` are linked `ld --build-id=none --gc-sections -T aarch64.ld` against `ghc-prim/bignum/ghc-internal/containers/pretty/mtl/array/transformers/deepseq/base/rts/Cffi + libgmp + libgcc`.

## Repository layout

```
/
|-- README.md
|-- LICENSE
|-- Makefile            # aarch64-only orchestration (container, spike, irq, house, smp, fs, vm, virtio, userspace)
|-- Containerfile
|-- .gitignore          # kernel/build/, platform/aarch64/build/, rust/target/
|-- kernel/             # Haskell kernel (GHC import roots H./Kernel./Monad./Util. preserved)
|   |-- Makefile        # BUILD := build, EXTS = -XGHC2024
|   |-- HouseA64.hs
|   |-- H/  Kernel/  Monad/  Util/    # closure only; H/FileSystem.hs + H/Pages.hs ramfs
|   `-- build/          # gitignored
|-- platform/aarch64/   # tinylibc/, spinlock.h, tick.h, aarch64.ld, Spike.hs, IrqCheck.hs, Makefile
|   `-- build/          # gitignored
|-- rust/               # Cargo workspace: house-boot, house-hal, house-hal-aarch64, house-libc
|   |-- ARCHITECTURE.md
|   |-- c-abi.md
|   `-- crates/
|-- scripts/            # 14 expect harnesses + rts-symbols.sh (ELF path is argv)
`-- plans/              # untracked, left on disk (local dev notes)
```

`plans/` is intentionally untracked (not gitignored) — local development notes kept on disk for contributors but not committed.

## License

MIT — see `LICENSE`. Inspired by House/hOp (S. Carlier / J. Bobbio, Programatica, 2004–2005) but no verbatim original code is retained; this aarch64/GHC-9.14 port is a clean rewrite. MIT is compatible with GHC 9.14's BSD-3-Clause RTS/license.
