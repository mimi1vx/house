# Host QEMU

QEMU runs on the macOS host, never in the toolchain image.
The image stays build-only.

## Prerequisites

```sh
export CONTAINER_DEFAULT_PLATFORM=linux/arm64   # ~/.zshrc
brew install qemu expect                        # QEMU 11.1.1, expect 5.45
qemu-system-aarch64 -accel help                 # want: hvf + tcg
```

## Build, then boot

```sh
make container-image && make check
```

`make check` rebuilds from clean in the container, then runs the host
gates: spike `ticks-ok`, irq `vm-ok` (hvf+tcg), house banner `Welcome to
the House shell` (hvf+tcg), interactive shell, POSIX shell, plus the
rust and haskell gates. Scaling legs stay out of the default gate:
`smp-check-8` (N=8 at 4G) and `vm-check` (512M/2+4G/4+6G/4+8G/4+16G/4
single-build) run on demand.

```sh
file platform/aarch64/build/house.elf
# want: ELF 64-bit LSB executable, ARM aarch64
```

## Guest RAM, SMP, and `-kernel`

Guest RAM/SMP are auto-detected at runtime (DTB via `x0` → open-ended
fault probe → 512M fallback); one `.bin` boots at any QEMU `-m` without
a rebuild. `SPIKE_MEM` (default `4G`; 512M/1G/2G/4G/8G/16G valid) only
drives `qemu -m`; `SMP_N` (default `2`, HW bound `32`, tested to `8`)
only drives `qemu -smp`.

`-kernel` must be the flat `build/*.bin` (`objcopy -O binary`): QEMU
boots non-ELF aarch64 images via its Linux path (`x0` = DTB); ELF
`-kernel` gets `x0=0`, no DTB, and the fault probe false-positives on
hvf. The `.elf` stays for `readelf`/`gdb`.

```sh
qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
  -smp 2 -m 4G -nographic -kernel platform/aarch64/build/house.bin
```

## Expect harnesses

`expect scripts/<harness>.exp <elf> <marker> [timeout] [accel] [mem]
[smp]` spawns QEMU and asserts the marker (`ticks-ok`, `vm-ok`,
`Welcome to the House shell`, `smp: N cores online`); timeout and accel
are positional. hvf is the fast path, tcg the reference when they
disagree. The smp-hotplug `up` leg is tcg-only (hvf refuses PSCI
re-`CPU_ON` after `CPU_OFF`).

virtio devices attach explicitly per check target: blk needs
`qemu-img create -f raw /tmp/house.img 64M` plus `-drive`/`-device
virtio-blk-device`; net needs `-netdev user` plus `-device
virtio-net-device`; console needs a socket chardev (see
`house-virtio-{blk,net,con}-check`).

## Volumes

Bind mounts through the Apple container VM are for sources only.
Write-heavy state lives on named volumes (`make volumes` creates them;
build targets depend on it):

- `house-target` → `/work/rust/target`
- `house-cabal` → `/root/.cabal`
- `house-cargo` → `/cargo-home` (`CARGO_HOME`; mounting over
  `/root/.cargo` would shadow the image's cargo binaries)

Only `*.elf`/`*.bin` cross back over the bind mount (`target/` lives on
the volume; a stale host `rust/target/` from pre-volume builds is safe
to delete). If a mount misbehaves, fall back to copying artifacts out:

```sh
container cp <container-id>:/work/platform/aarch64/build/house.bin \
  ./platform/aarch64/build/house.bin
```

## Debug a boot failure

```sh
qemu-system-aarch64 -M virt,gic-version=3 -cpu max -accel tcg \
  -kernel platform/aarch64/build/house.bin -nographic -d int -S -s
```

then attach `lldb -o "gdb-remote localhost:1234"`.
