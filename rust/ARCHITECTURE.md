# Rust workspace architecture

## Workspace map

```text
rust/
  Cargo.toml              # members = [house-hal, house-hal-aarch64, house-libc, house-boot]
  ARCHITECTURE.md         # this file
  c-abi.md                # frozen #[no_mangle] extern "C" map (nm-auditable)
  .cargo/config.toml      # [build] target = "aarch64-unknown-none"
  crates/
    house-hal/            # arch-agnostic trait extension point (#![no_std], rlib)
      src/lib.rs          # pub use arch::{HalGic/HalMmu/HalTimer/HalPsci/HalUart, Hal} + Mmio + PhysAddr
      src/arch.rs         # unsafe trait HalGic/HalMmu/... + Hal blanket
      src/mmio.rs         # trait Mmio { unsafe fn r32/w32 } (aarch64 owns volatile)
      src/spinlock.rs     # RawSpinLock (LDAXR/STXR + dmb sy) + SpinLock<T>
    house-hal-aarch64/    # aarch64 impl (rlib, no panic_handler, extern __stack_chk_guard)
      build.rs            # cargo:rustc-cfg=house_arch="aarch64"|"riscv64" per feature
      src/lib.rs          # pub struct AArch64Hal; impl Hal* for AArch64Hal { #[inline(always)] -> free fn }
      src/{uart,mmu,buddy,gic,timer,psci,dtb,detect,probe,irq,userspace,svc,virtio_*,mmio,spinlock}.rs
    house-boot/           # global_asm! _start/vectors/secondary_entry/house_enter_el0 (rlib)
    house-libc/           # libc compatibility layer (staticlib+rlib, single #[panic_handler], __stack_chk_guard)
```

Link: `platform/aarch64/aarch64.ld` → `build/aarch64.ld` via `cc -E -P` (no `-DHOUSE_*`).
Globals `__heap_base 0x42000000` / `__early_stacks_*` / `__rela_start` remain `ld`-defined.

Toolchain: `rust-toolchain.toml` selects nightly with `aarch64-unknown-none`,
Clippy, rustfmt, and Miri. The Containerfile installs the same floating nightly;
`docs/TOOLCHAIN.md` records the resolved image version.
Every `container run --platform linux/arm64` per `apple-container` skill;
single sanctioned `CONTAINER_DEFAULT_PLATFORM=linux/arm64` on the
`container build` line only (`Makefile`), never exported globally;
the Containerfile checks `uname -m == aarch64`, and `make container-image`
asserts that the image contains only an arm64 variant.

`house-hal` is `unsafe` + `#[inline(always)]` in impl — compile-time
monomorphized, not vtable (avoids ISR overhead, preserves `dmb sy`/`dsb sy`/
`dc cvac`/`tlbi vmalle1is` ordering). Free functions stay `#[no_mangle] pub
unsafe extern "C"` per `rust/c-abi.md`; trait is adapter grouper.

The workspace targets only AArch64 QEMU `virt`. Dormant `riscv64` cfg and
feature names remain compatibility stubs; they do not define or promise a
supported architecture port.

## HAL ordering guarantees

Trait methods forward to free functions that keep exact sequences:
`msr mair_el1/tcr_el1/ttbr0_el1`; `dsb ish; tlbi vmalle1is; dsb ish; isb`;
`dc cvac` before DMA, `dc ivac` on RX. Flush covers only touched ranges
(64 B lines over `[pa, pa+len)`, `checked_add`-guarded, `dsb sy` after);
invalidate-before-read on RX, flush-before-notify on TX. `make rust-check`
runs Clippy and rustfmt, `make lint` adds Cargo Deny, and `make miri` exercises
pure logic with assembly and MMIO isolated under `cfg(miri)`. Exported symbols
remain auditable against `rust/c-abi.md`.
