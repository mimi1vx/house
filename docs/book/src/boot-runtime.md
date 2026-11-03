# Boot & runtime

How the flat image enters, detects the machine, and reaches the shell.
For build commands see [Build & run](build-run.md); for host setup see
[Host QEMU](host-qemu.md); for the layer map see
[Architecture overview](architecture.md).

## Flat image, not ELF

Boot the FLAT image: `-kernel platform/aarch64/build/*.bin` (NOT the ELF;
ELF boot leaves `x0=0`, no DTB, false RAM probe under HVF).

QEMU takes non-ELF aarch64 `-kernel` images through its Linux boot path,
which passes the DTB pointer in `x0`. The `.elf` next to the `.bin` stays
for `readelf`/`gdb` only. Guest entry `_start` at `0x40080000`; DTB pointer
in `x0`.

## Detect, don't configure

RAM and core count are detected at boot: DTB `reg` via `x0`, then an
open-ended fault probe doubling from 128M, then a `512M` fallback. One
binary boots wherever QEMU puts it.

`SPIKE_MEM` (default `4G`; 512M/1G/2G/4G/6G/8G/16G valid) only drives
QEMU `-m`. `SMP_N` (default `2`, tested to `8`) only drives QEMU `-smp`.
Neither is a build-time limit, so do not introduce build-time RAM or CPU
knobs.

## hvf vs tcg

HVF is the host fast path. Harnesses use TCG where required, notably EL0
tests, and as the reference when hvf and tcg disagree. Linux CI runs
TCG-only (`make check-tcg`); the dynamic-root gate needs QEMU 11+ and
stays local-only. The per-change gate is `make check` (hvf+tcg); CI runs
`make check-tcg`.

## initrd in ten lines

QEMU `-initrd build/initramfs.cpio` supplies a cpio newc archive via
`chosen/linux,initrd-start|end`, unpacked at boot into the default VFS
namespace. Caps: archive 8 MiB, 512 files, names 255 chars, files 1 MiB;
`..`/absolute/NUL names rejected. RamFS enforces a 10%-of-RAM page quota
(16 MiB floor). After unpack, `/sbin/init` spawns and the shell serves
`/bin/*` from the same namespace. See the shell/initrd sections of the
[Build & run](build-run.md) flow and `scripts/qemu-initramfs.exp`.
