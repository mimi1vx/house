# Rust workspace architecture

## Workspace map

```
rust/
  Cargo.toml              # members = [house-hal, house-hal-aarch64, house-libc, house-boot]
  ARCHITECTURE.md         # this file
  c-abi.md                # frozen #[no_mangle] extern "C" map (nm-auditable)
  .cargo/config.toml      # [build] target = "aarch64-unknown-none"
  crates/
    house-hal/            # arch-agnostic trait extension point (#![no_std], rlib)
      src/lib.rs          # pub use arch::{HalGic/HalMmu/HalTimer/HalPsci/HalUart, Hal} + Mmio + PhysAddr
      src/arch.rs         # unsafe trait HalGic/HalMmu/... + Hal blanket, #[non_exhaustive] ready
      src/mmio.rs         # trait Mmio { unsafe fn r32/w32 } (aarch64 owns volatile)
      src/spinlock.rs     # RawSpinLock (LDAXR/STXR + dmb sy) + SpinLock<T>
    house-hal-aarch64/    # aarch64 impl (staticlib+rlib, no panic_handler, extern __stack_chk_guard)
      build.rs            # cargo:rustc-cfg=house_arch="aarch64"|"riscv64" per feature
      src/lib.rs          # pub struct AArch64Hal; impl Hal* for AArch64Hal { #[inline(always)] -> free fn }
      src/{uart,mmu,buddy,gic,timer,psci,dtb,detect,probe,irq,userspace,svc,virtio_*,mmio,spinlock}.rs
    house-boot/           # global_asm! _start/vectors/secondary_entry/house_enter_el0 (rlib)
    house-libc/           # tinylibc port (staticlib+rlib, single #[panic_handler], __stack_chk_guard)
```

Link: `platform/aarch64/aarch64.ld` → `build/aarch64.ld` via `cc -E -P -DHOUSE_SMP_N`.
Globals `__heap_base 0x42000000` / `__early_stacks_*` / `__rela_start` remain `ld`-defined.

Toolchain: `rust-toolchain.toml` `channel="stable"` + `aarch64-unknown-none` +
`Containerfile` `COPY rust-toolchain.toml` + `cargo fetch` cache.
Every `container run --platform linux/arm64` per `apple-container` skill;
single sanctioned `CONTAINER_DEFAULT_PLATFORM=linux/arm64` on the
`container build` line only (`Makefile`), never exported globally;
`Containerfile:5` `uname -m == aarch64` guard + `Makefile:9` `arm64` assert.

`house-hal` is `unsafe` + `#[inline(always)]` in impl — compile-time
monomorphized, not vtable (avoids ISR overhead, preserves `dmb sy`/`dsb sy`/
`dc cvac`/`tlbi vmalle1is` ordering). Free functions stay `#[no_mangle] pub
unsafe extern "C"` per `rust/c-abi.md`; trait is adapter grouper.

## Adding `riscv64`

SOTA Rust 01 minimal API, 03 `// SAFETY:` per `unsafe trait` discharge.

1. `cargo new --lib crates/house-hal-riscv64`
2. `impl Hal for Riscv64Hal` in new crate:
   ```rust
   pub struct Riscv64Hal;
   unsafe impl HalGic for Riscv64Hal { /* PLIC 0x0c000000 vs GICv3 0x08000000 */ }
   unsafe impl HalMmu for Riscv64Hal { /* Sv39 SATP vs TTBR0/TTBR1 T1SZ=16 */ }
   ```
   Reuse `house-libc` alloc/threads generic code; add `platform/riscv64/riscv64.ld`.
3. Workspace:
   ```toml
   # rust/Cargo.toml
   members = ["crates/house-hal", "crates/house-hal-aarch64",
              "crates/house-hal-riscv64", "crates/house-libc", "crates/house-boot"]
   # crates/house-hal-riscv64/Cargo.toml
   [features]
   riscv64 = ["house-hal/riscv64"]
   default = ["riscv64"]
   [dependencies]
   house-hal = { path = "../house-hal" }
   ```
4. Feature gate: `Cargo.toml` `features = ["riscv64"]`, `build.rs` `house_arch` cfg.
   QEMU `-M virt` vs `-M virt-riscv` (`-machine virt` PLIC vs GIC).

Verification stub (no `riscv64` ELF yet):

```sh
cargo build -p house-hal --no-default-features --features riscv64  # stub compiles
cargo metadata --manifest-path rust/Cargo.toml | jq '.packages[] | select(.name=="house-hal")'
```

aarch64 gate untouched (`cargo build --target aarch64-unknown-none` + `cargo clippy -p house-hal-aarch64`).

## HAL ordering guarantees

Trait methods forward to free functions that keep exact sequences:
`msr mair_el1/tcr_el1/ttbr0_el1`; `dsb ish; tlbi vmalle1is; dsb ish; isb`;
`dc cvac` before DMA, `dc ivac` on RX. Flush covers only touched ranges
(64 B lines over `[pa, pa+len)`, `checked_add`-guarded, `dsb sy` after);
invalidate-before-read on RX, flush-before-notify on TX. `rg "dc cvac|dsb sy|tlbi"` parity
C vs Rust `house-hal-aarch64` must match. Post-port CI split
(`scripts/`): `ci-rust.sh` (fmt + clippy + build + panic/`checked_*`/nm/dc-dsb-tlbi
parity), `ci-rust-phase1.sh` (libc shims `__stack_chk_*` + single `panic_handler`
+ clippy/fmt), `ci-rust-phase2.sh` (boot `_start`/`secondary_entry`/`__boot_dtb`/
`vectors`/`house_enter_el0` + clippy/fmt), `ci-tinylibc-parity.sh`
(`c-abi.md` table vs `nm` subset + `checked_*` >= `__builtin_*overflow` +
single `panic_handler`).
