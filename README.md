# hOp — House on AArch64

hOp is a microkernel built on the RTS of GHC, the Glasgow Haskell Compiler, for experimenting with device drivers in Haskell.

The RTS of GHC is a standalone runtime. With the system-specific bits removed and a small freestanding layer of C and assembly, it becomes a microkernel extensible in Haskell. All of `base` outside `System` is available, including threads, communication primitives, and the foreign interface.

History: the original i386/GRUB implementation (GHC 6.8.2, 32 MB flat memory model) is preserved in git history.

## aarch64 port (GHC 9.14, QEMU virt)

A freestanding aarch64 build that runs under QEMU `virt` (`-M virt,gic-version=3`) on Apple silicon. Stock threaded RTS, no GHC patches. The freestanding constraint is "unsafe FFI only" — safe `ccall` would require scheduler-backed worker threads.

### Toolchain

* Build container `house-port:latest` (Debian 13, nightly Rust with `aarch64-unknown-none` and Miri, plus GHC 9.14.1 aarch64 via GHCup). Firmware compilation runs through `container run --platform linux/arm64 ...` (see `Containerfile`); host-side Haskell formatting, linting, and pure tests are the exception. The sole `CONTAINER_DEFAULT_PLATFORM=linux/arm64` assignment is local to the `container build` command in `Makefile`; never export it globally. Each `run` pins `--platform linux/arm64`, and `container image inspect` asserts an arm64-only image. The HAL, boot, and libc compatibility layer are Rust (`rust/crates/house-boot`, `rust/crates/house-hal-aarch64`, and `rust/crates/house-libc`); see `rust/ARCHITECTURE.md`.
* QEMU runs on the macOS host (`brew install qemu expect`, HVF acceleration). The container is build-only. `make check` also requires host GHC/Cabal, Fourmolu 0.20.1.0, and a GHC2024-capable HLint (3.10 is known to work).
* Guest RAM is auto-detected (DTB `reg` from the `x0` QEMU passes on its Linux boot path → open-ended fault probe doubling from 128M → `512M` fallback; one binary boots at `512M`/`1G`/`2G`/`4G`/`6G`/`8G`/`16G` without rebuild, hvf+tcg). QEMU only takes that path for non-ELF images, so `-kernel` boots the `objcopy -O binary` flat image (`build/*.bin`; `.elf` stays for `readelf`/`gdb`) — ELF `-kernel` boots get `x0=0` and no DTB, and the fault probe false-positives on hvf (reads beyond RAM succeed, later stores abort QEMU with `hvf_handle_exception`). `SPIKE_MEM ?= 4G` only drives QEMU `-m`. `SMP_N ?= 2` only drives QEMU `-smp` and expect args; core count is detected at runtime (DTB → PSCI/GICR max) with per-core 64 KiB stacks (`house_boot_stack_top - core*64K`, `__early_stacks` 32-entry HW reservation, HW bound 32, tested to 8). `TCR EPD1=0` split `TTBR1=kernel` / `TTBR0=user` with 8-bit ASID, `TLBI VAE1IS` + SGI 1 `VMALLE1IS` shootdown (online-only broadcast).

### What boots

* `rust/crates/house-boot` (`global_asm!` vectors, `_start`, `secondary_entry`, `house_enter_el0`) + `rust/crates/house-hal-aarch64` (`mmu`, `gic`, `timer`, `irq`, `buddy`, `dtb`/`detect`/`probe`, `userspace`, `svc`/`ipc`, `psci`, `uart`, `virtio_transport`/`virtio_blk`/`virtio_net`) + `rust/crates/house-libc` (`alloc`, `sys` fd/pipe/eventfd/epoll/timerfd, `threads`/`tls`/`sched`, `mm/vm`) and `platform/aarch64/aarch64.ld` support the stock threaded RTS (`-N SMP_N`, per-core run queues, SGI 0 IPI, I+D caches WB). No C tinylibc objects are linked. Guest entry `_start` is at `0x40080000`.
* `house-libc` `sys` provides `timerfd`/`signal`/`pipe`/`mmap` and the fd table; `house-hal-aarch64/timer.rs` feeds `house_rts_tick()` from the ARM generic timer (PPI 27/30) — per-core `house_isr_pending[core]` + `house_boot_ticks[core]`, `house_timer_init_secondary` per core; `house_isr_active` switches `house_timerfd_due(core)` to per-core pending. `sched_getaffinity` reports the live online mask, `sched_setaffinity` updates the current thread's affinity, and `pthread_setaffinity_np` is a success-returning compatibility stub. RTS defaults to one capability per detected core via synthesized `+RTS -Nn -RTS` when no explicit `-N` is given.
* `H.Interrupts` is GIC-native (`IntId`, `ppiVirtTimer=27`, `ppiPhysTimer=30`, `spi n = 32+n`, dispatcher `threadDelay 20ms` poll, `house_irq_push/pop`).
* `H.VirtualMemory` is AArch64 4 KiB-granule L0→L3 over the `0x01000000–0x1000000000` 64 GiB demand window. Each `PageMap` identifies a `TTBR0_EL1` root, with ASIDs tracked by the Rust HAL; `house-hal-aarch64/userspace.rs:house_handle_user_fault` allocates 4 KiB buddy pages, while permission faults, unmap, and SMP shootdown use `VAE1IS` and SGI 1 `VMALLE1IS`. Static ELF loading uses the narrower `0x01000000–0xFFFFFFFF` range. Kernel RAM at `0x40000000` + `house_ram_bytes` stays TTBR1 Normal WB Inner-shareable (`SCTLR_EL1.C/I=1`).
* `Kernel.FileSystem.Vfs` provides longest-prefix mount routing and per-process namespaces. Namespace 0 mounts volatile `RamFs` at `/`; fork inherits a namespace descriptor, and newly opened paths resolve through the process namespace. Inherited descriptors retain the namespace recorded when they were opened. `BlkFs` implements an HFS1/virtio-blk backend, while the shell's `blk sync` and `blk mount` commands persist and restore the default RamFS rather than create a live VFS mount. `H.FileSystem` remains a compatibility shim over the default namespace. RamFS starts with the 512-page legacy pool and falls back to buddy pages; it has no separate 2 MiB quota.
* `HouseA64.hs` is the shell entry (`house_main`). Commands cover POSIX-like basics (`echo`, `clear`, `uname`, `uptime`, `shutdown`), SMP and memory diagnostics, VFS operations, IPC and nameservice operations, virtio block/network/console devices, DHCP and UDP/A-record DNS, and EL0 process control (`run`, `spawn`, `jobs`, `wait`, `quantum`). `mem` reports RAM, buddy, and libc allocator live/high-water state. `virtio scan` identifies block, network, console, and RNG devices. UART is provided by `Kernel.Driver.PL011`; QEMU `virt` pins `psci-conduit=hvc`.
* Trust boundary: ARP/DHCP are spoofable in the virt lab (`10.0.2.0/24` user-mode NAT); there is no DNSSEC/TLS in this slice. The guest expires ARP entries after 60 s and logs DHCP xid mismatches to `dmesg`.

### EL0 processes and syscalls

Static AArch64 ELF programs load from the active VFS namespace into the `0x01000000–0xFFFFFFFF` user window. The embedded probes are `/bin/hello`, `/bin/argenv`, `/bin/yield`, `/bin/ipc_pp`, `/bin/cat`, `/bin/brk`, `/bin/fork`, `/bin/exec`, and `/bin/spin`.

The Haskell process layer assigns PIDs over a 64-slot Rust EL0 session table keyed by page-directory pointer. `spawn` runs a program concurrently, `jobs` lists live processes, and `wait [pid]` reaps one or all non-self processes; parent-child ownership is not enforced. Timer-driven preemption uses a 10-tick default quantum; `quantum <ticks>` changes it, with `0` selecting one tick. Fork uses copy-on-write page sharing, exec replaces the image while retaining the PID and open descriptors, and fork inherits the VFS namespace.

SVC `0x00` yields, `0x01` writes to the console, `0x02` exits, `0x03` manages the break, `0x04..0x07` provide open/read/write/close, `0x08..0x0B` provide fork/wait/seek/exec, and `0x10..0x13` provide IPC send/receive/call/reply. Blocking operations cross the trap boundary through the park/resume delegation ring. Grant-map `0x14` returns `ENOSYS`. Endpoint IDs are not authorization capabilities: any EL0 process that knows an endpoint ID can invoke it, and capability mismatches are logged but permitted.

### Boot

`rust/crates/house-boot/src/entry.rs` (`global_asm!`) preserves the DTB pointer from `x0`, handles the EL2→EL1 drop (EL3 where present), enables `ICC_SRE_EL2`, enables FP/SIMD (`cpacr_el1`), applies `R_AARCH64_RELATIVE` relocations (primary only), clears BSS (primary only), installs VBAR, calls `house_mmu_early` (primary, identity-maps RAM per TCR/L1 capacity) or `house_mmu_enable_secondary` (secondaries, shared tables), sets per-core `sp = house_boot_stack_top - core*64K` (early `__early_stacks_top`, rebased after `house_detect_early`), then enters `c_start` vs `c_start_secondary` (secondaries via `secondary_entry` 4 KiB-aligned PSCI entry `psci_cpu_on` `0xC4000003` `hvc` with `smc` fallback). `c_start` runs `house_detect_early` (DTB `reg` → fault probe → fallback, `stack_top = BASE+ram-2M` via checked math) then `house_mmu_update_alias()` rebuilds RTS alias `0x4200000000+`.

### GICv3

`rust/crates/house-hal-aarch64/src/gic.rs`: `GICD 0x08000000`, `GICR 0x080A0000 + core*0x20000`; wake `GICR_WAKER` per core, mark PPIs 27/29/30 + SGI 0 Group1 per core, enable via `ICC_PMR/IGRPEN1/BPR1`. `house_gic_send_sgi_to_core(0, core)` via `ICC_SGI1R_EL1` Aff3/Aff2/Aff1/RS/TargetList encoding (unicast, correct for any Aff topology; mask variant loops via helper) kicks the remote core's scheduler.

### Linking

`platform/aarch64/Makefile` locates `HsFFI.h` and `libHS{rts,base,ghc-prim,ghc-bignum,ghc-internal,containers,pretty,mtl,array,transformers,deepseq,Cffi}.a` via `ghc --print-libdir` / `ghc-pkg field`; `rts` is threaded. `rust/crates/house-boot` (`libhouse_boot.rlib`), `house-hal-aarch64` (`libhouse_hal_aarch64.rlib`), `house-libc` (`libhouse_libc.a`) plus `libcore`/`libcompiler_builtins`, Haskell archives, `libgmp.a`, and `libgcc` are linked by `ld.lld` with `--allow-multiple-definition --build-id=none --gc-sections`. The linker script defines explicit TLS/PT_TLS layout, sets `ENTRY(_start)`, and rejects loaded images larger than 16 MiB. The build prints the ELF entry and machine fields with `readelf -h`. `build/aarch64.ld` is generated via `cc -E -P` from `platform/aarch64/aarch64.ld`.

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
make irq-build irq-run
make irq-check          # -> vm-ok, hvf and tcg

# house: welcome banner + interactive + POSIX shell + PSCI
make house-build house-run
make house-check        # -> "Welcome to the House shell" banner, hvf+tcg
make house-shell-check  # -> prompt, help->Usage, lambda, wastemem 10->55, hvf+tcg
make house-posix-check  # -> help descriptions (-- ), echo, uname, uptime, shutdown -r (reboot) / -h (halt), hvf+tcg
make house-fs-check     # -> VFS/RamFS: write/cat/ls/mkdir/rm + echo > /path, hvf+tcg
make smp-check          # -> N cores online + caps N + parfib 20=6765 + mvar ok, hvf+tcg (default N=2; SMP_N=4 for >2 gate)
make smp-check-8        # -> smp-check at SMP_N=8/SPIKE_MEM=4G (scaling gate, ceiling 32; nightly, N=2 per-commit)
make smp-hotplug-check  # -> smp down 1/up 1 cycle at N=2, caps mirror, parfib each step (hvf+tcg)
make vm-check           # -> demand 100 pages + mprotect RO + munmap + isolate + asid + smp shootdown, one build booted at 512M/2+4G/4+6G/4+8G/4+16G/4 + mem buddy free/total at each geometry (`house-vm-check` alias)
make house-ipc-check house-driver-check
make house-virtio-transport-check house-virtio-blk-check house-virtio-net-check house-virtio-con-check
make house-userspace-check  # -> run /bin/hello -> Hello from EL0, TTBR0/ASID/pager, argv+env on EL0 stack (hvf+tcg)
make house-proc-check       # -> concurrent spawn/jobs/wait with per-PID exits, hvf+tcg
make house-fd-el0-check house-ipc-el0-check house-fork-check
make house-preempt-check    # -> two CPU-bound EL0 tasks interleave at SMP_N=1, hvf+tcg
make house-spin-hotplug-check
make rust-check         # -> cargo clippy + cargo fmt --check inside linux/arm64
make haskell-check      # -> host Fourmolu/HLint + Cabal build/test
make lint               # -> Rust clippy/fmt/deny in container + host Fourmolu/HLint
make miri               # -> Rust pure-logic tests in a 4-CPU/4-GiB container

# parametrised SMP + RAM
SPIKE_MEM=512M make spike-check                      # 512M/1G/2G/4G/6G/8G/16G valid; default 4G
SMP_N=2 make smp-check                               # 2 cores online + Haskell parallel (hvf+tcg)
SMP_N=4 make smp-check                               # 4 cores online + Haskell parallel (hvf+tcg, 4G working set)

# all gates from clean (the CI gate)
make check              # spike + irq + house + shell + POSIX + Rust + Haskell gates
make run                # alias for house-run (hvf, $SPIKE_MEM)
```

Inside the container (via `make container-shell`):

```sh
make -C kernel                            # ghc --make -no-link HouseA64.hs
make -C platform/aarch64 house SMP_N=2    # cargo build --target aarch64-unknown-none + ld.lld
```

Expect harnesses live under `scripts/qemu-*.exp`; the Make targets are their stable interface. Marker-taking harnesses use `expect SCRIPT KERNEL.bin MARKER [timeout] [accel] [mem] [smp]`. Most interactive and device harnesses omit `MARKER` and use `expect SCRIPT KERNEL.bin [timeout] [accel] [mem] [smp] [-- extra-qemu-args]`. Each launches `qemu-system-aarch64 -accel hvf|tcg -M virt,gic-version=3` with the flat image.

The aggregate `make check` gets clean firmware builds through its spike, IRQ, and House legs. Standalone focused checks generally reuse incremental artifacts. Clean `platform/aarch64` before manual platform builds, and also clean `kernel` before a manual House build.

## Initramfs (`-initrd`)

QEMU `-initrd build/initramfs.cpio` supplies a cpio newc archive via
`chosen/linux,initrd-start|end`, unpacked at boot into the default VFS
namespace as `[Word8]` bytes (text decode lives at the shell edge only).
Caps: archive ≤8 MiB, ≤512 files, names ≤255 chars, files ≤1 MiB;
`..`/absolute/NUL names are rejected. RamFS enforces a page quota of
10% of RAM (16 MiB floor) with `ENOSPC` + `dmesg` on refusal; `free`
reports `ramfs used/quota`.

```sh
sh scripts/mkinitramfs.sh          # build/initramfs.cpio from initramfs-staging/
make house-initrd-check            # unpack + /sbin/init + manifest, hvf+tcg
```

After unpack, `/sbin/init` spawns (exit logged, shell never blocks) and
`/etc/house-servers` registers `name path endpoint` lines (≤64,
`#` comments) in `ns ls` and spawns each ELF as a `runElf` child.
Without `-initrd` the embedded `/bin/*` fallback is unchanged.

## Closure & extensions

`kernel/Makefile` is the single source of truth:

```sh
ghc --make -no-link HouseA64.hs -i. -outputdir build -O1 \
  -package mtl -package array -package containers -package pretty
```

with

```makefile
EXTS = -XGHC2024
```

(`-O1 -Wall -Werror`; per-instance `OVERLAPPING` where needed). The objects under `kernel/build` plus `house-boot`, `house-hal-aarch64`, and `house-libc` are linked by `ld.lld --allow-multiple-definition --build-id=none --gc-sections -T aarch64.ld` against `ghc-prim/bignum/ghc-internal/containers/pretty/mtl/array/transformers/deepseq/base/rts/Cffi + libgmp + libgcc`.

## Repository layout

```text
/
|-- README.md
|-- LICENSE
|-- Makefile            # aarch64-only build, QEMU, lint, Miri, and test orchestration
|-- Containerfile
|-- .gitignore          # kernel/build/, platform/aarch64/build/, rust/target/
|-- kernel/             # Haskell kernel (GHC import roots H./Kernel./Monad./Util. preserved)
|   |-- Makefile        # BUILD := build, EXTS = -XGHC2024
|   |-- HouseA64.hs
|   |-- H/  Kernel/  Monad/  Util/    # kernel closure, VFS backends, drivers, and EL0 process services
|   `-- build/          # gitignored
|-- platform/aarch64/   # linker script, platform entry points, and freestanding link
|   `-- build/          # gitignored
|-- rust/               # Cargo workspace: house-boot, house-hal, house-hal-aarch64, house-libc
|   |-- ARCHITECTURE.md
|   |-- c-abi.md
|   `-- crates/
|-- scripts/            # host-side QEMU Expect harnesses and ABI checks
`-- plans/              # untracked, left on disk (local dev notes)
```

`plans/` is intentionally untracked (not gitignored) — local development notes kept on disk for contributors but not committed.

## License

MIT — see `LICENSE`. Inspired by House/hOp (S. Carlier / J. Bobbio, Programatica, 2004–2005) but no verbatim original code is retained; this aarch64/GHC-9.14 port is a clean rewrite. MIT is compatible with GHC 9.14's BSD-3-Clause RTS/license.
