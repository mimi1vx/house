# AGENTS.md — house/hOp aarch64 OS

GHC RTS microkernel (Haskell + Rust HAL + tinylibc), aarch64-only, QEMU `virt` on Apple silicon.
Stock threaded RTS (`-N SMP_N`), unsafe FFI only. No x86 paths.

## Layout

- `kernel/` — Haskell closure rooted at `HouseA64.hs` (`H/`, `Kernel/`, `Monad/`, `Util/`). `kernel/Makefile` does `ghc --make -no-link` only.
- `platform/aarch64/` — freestanding build, `aarch64.ld` (→ `build/aarch64.ld` via `cc -E -P`), `tinylibc/`, `Spike.hs`/`IrqCheck.hs`, `mm/`; `build/` gitignored.
- `rust/` — Cargo workspace `house-boot` (global_asm `_start`/vectors), `house-hal-aarch64`, `house-libc`; see `rust/ARCHITECTURE.md` and `rust/c-abi.md` (frozen `#[no_mangle]` map, `nm`-auditable).
- `scripts/` — `expect` harnesses `qemu-*.exp`; `ELF` path is argv.
- `Makefile` — host orchestration; `Containerfile` — build image.

## Container — build only

- **All compilation inside `house-port:latest`** (Debian 13, GHC 9.14.1 aarch64 + Rust `aarch64-unknown-none`). QEMU never inside container; host needs `brew install qemu expect`.
- **Every `container` invocation must pin `--platform linux/arm64`.** Never set `CONTAINER_DEFAULT_PLATFORM`. `Containerfile:5` fails if `uname -m != aarch64`; `Makefile:9` asserts image arch is `arm64` (no Rosetta/amd64).
- Host wrappers: `make spike-build` / `irq-build` / `house-build` → `container run --platform linux/arm64 --rm -v $PWD:/work -w /work house-port:latest make -C platform/aarch64 ...`.
- One-time: `make container-image` · Shell: `make container-shell` → `container run --platform linux/arm64 --rm -it -v $PWD:/work -w /work house-port:latest bash`.
- Inside container directly: `make -C kernel` and `make -C platform/aarch64 house SMP_N=2`.

## Commands (repo root, macOS host)

```sh
make spike-check                         # ticks-ok  hvf
make irq-check                           # vm-ok     hvf+tcg
make house-check                         # "Welcome to the House shell"  hvf+tcg
make house-shell-check house-posix-check # prompt/help/lambda/wastemem + uname/uptime/shutdown
make house-fs-check house-ipc-check house-driver-check
make house-virtio-transport-check house-virtio-blk-check house-virtio-net-check
make house-userspace-check               # run /bin/hello -> Hello from EL0  tcg only
make smp-check                           # N cores online, default SMP_N=2; SMP_N=4 needs 4G
make vm-check                            # demand paging + mprotect/munmap + ASID + shootdown  512M/2+4G/4 hvf+tcg
make rust-check                          # cargo clippy -D warnings + cargo fmt --check (inside container)
make check                               # CI gate: spike + irq + house + shell + posix

SPIKE_MEM=512M make spike-check          # 512M/1G/2G/4G/8G/16G valid, default 4G
SMP_N=4 make smp-check
```

`* -check` targets run `clean` themselves. When running `*-build` manually, `make -C platform/aarch64 clean` (and `make -C kernel clean` for house) first.

Inside-container verification of Rust alone:

```sh
cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none -- -D warnings
cargo fmt --manifest-path rust/Cargo.toml -- --check   # or `bash -c 'cd rust && cargo fmt --check'`
```

## Build details

- `kernel/Makefile`: `ghc --make -no-link HouseA64.hs -i. -outputdir build -O1 -XGHC2024 -Wall -Werror -package mtl -package array -package containers -package pretty`.
- `platform/aarch64/Makefile` finds `HsFFI.h` via `ghc --print-libdir` and `libHS{rts,base,ghc-prim,ghc-bignum,ghc-internal,containers,pretty,mtl,array,transformers,deepseq,Cffi}.a` via `ghc-pkg`; threaded RTS only. Rust `libhouse_boot.rlib` + `libhouse_hal_aarch64.rlib` + `libhouse_libc.a` plus `libcore`/`libcompiler_builtins` linked `--start-group`/`--end-group` with `libgmp.a` + `libgcc` via `ld --build-id=none --gc-sections -T build/aarch64.ld`. `readelf -h` gate checks `ENTRY(_start)` / `Machine: AArch64`.
- `build/aarch64.ld` generated from `aarch64.ld` via `cc -E -P -DHOUSE_SMP_N=<n>`; entry `_start` at `0x40080000`.
- Rust HAL is always linked (`house-boot` + `house-hal-aarch64` + `house-libc`); see `rust/ARCHITECTURE.md` for `house-hal-riscv64` extension.

## Gotchas

- **RAM auto-detected.** No `HOUSE_RAM_BYTES` limit. DTB `reg` → probe `128M→16G` → `128M` fallback; same ELF boots at any QEMU `-m` without rebuild. `SPIKE_MEM`/`HOUSE_RAM_LIMIT` (default `4G`) only drives `qemu -m` and caps via `HOUSE_RAM_LIMIT_BYTES`; `SMP_N`/`HOUSE_SMP_LIMIT` (default `2`, max `16`, tested to `8`) sets per-core 16 KiB stacks (`house_boot_stack_top - core*16K`).
- **MMU/buddy/EL0.** Split `TTBR1` kernel / `TTBR0` user `0x01000000–0xFFFFFFFF` (`TCR T1SZ=16 TG1=4K`), 8-bit ASID with `VMALLE1IS` wrap; demand pager `house_handle_user_fault` + RO perm faults via `house_is_ro_page`; shootdown `VAE1IS` + SGI 1. Buddy manages `__heap_base+64M .. house_boot_stack_top-16*16K` (see `rust/crates/house-hal-aarch64/src/buddy.rs`). EL0 via `svc #imm` (`WRITE 0x01`/`EXIT 0x02`/`IPC 0x10..0x14`), `house_enter_el0` `eret`. Shell: `free`/`mem`/`detect`/`vm` show `buddy`/`ram`/`TTBRs`/`TCR`.
- **QEMU is macOS-host only.** `qemu-system-aarch64 -M virt,gic-version=3 -smp SMP_N -m SPIKE_MEM -nographic -kernel build/*.elf` with `-accel hvf` (default) and `tcg` where harness expects it; `virtio-blk` needs `qemu-img create -f raw /tmp/house.img 64M` + `-drive`/`-device virtio-blk-device`; `virtio-net` needs `-netdev user` + `-device virtio-net-device`.
- **Expect signature:** `expect scripts/<harness>.exp <elf> <marker> [timeout] [accel] [mem] [smp]` — markers `ticks-ok`, `vm-ok`, `Welcome to the House shell`, `smp: N cores online`. Harness spawns QEMU and asserts marker; timeout and accel args are positional.
- **Toolchain:** No `npm`/`cargo`/`pytest` on host — only `make` + `expect`; `cargo` runs inside `--platform linux/arm64` container.

## Conventions

- Keep aarch64-only; no x86 paths.
- `plans/` is untracked local notes (intentional, not gitignored); `.gitignore` covers `kernel/build/`, `platform/aarch64/build/`, `rust/target/`.
- After modifying HAL/Rust, re-verify `nm` subset against `rust/c-abi.md` and run `make rust-check`.
