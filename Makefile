# House/hOp — aarch64 port (QEMU virt, GHC 9.14)

IMAGE := house-port:latest

# Named-volume container runner (house-ng pattern, plans/house-ng-adoption.md step 5).
# Sources cross on the bind mount; write-heavy caches live on volumes so only
# *.elf/*.bin cross back. house-ng mounts target at /work/target because its
# Cargo workspace is the repo root; ours is rust/, so house-target mounts at
# /work/rust/target (RUST_*_A paths in platform/aarch64/Makefile).
# Never mount over /root/.cargo: it would shadow image cargo binaries —
# cargo home lives at /cargo-home via CARGO_HOME instead.
RUN_IN_CONTAINER := container run --platform linux/arm64 --rm \
  -v "$(CURDIR)":/work \
  -v house-target:/work/rust/target \
  -v house-cabal:/root/.cabal \
  -v house-cargo:/cargo-home \
  -e CARGO_HOME=/cargo-home \
  -w /work $(IMAGE)

# Miri gets its own sizing: the sysroot build thrashes under the default
# container memory. Cache lands on the cargo volume so only the first run pays.
MIRI_IN_CONTAINER := container run --platform linux/arm64 --rm -c 4 -m 4G \
  -v "$(CURDIR)":/work \
  -v house-target:/work/rust/target \
  -v house-cabal:/root/.cabal \
  -v house-cargo:/cargo-home \
  -e CARGO_HOME=/cargo-home \
  -e XDG_CACHE_HOME=/cargo-home/cache \
  -w /work $(IMAGE)

volumes:
	-container volume create house-target >/dev/null 2>&1 || true
	-container volume create house-cabal >/dev/null 2>&1 || true
	-container volume create house-cargo >/dev/null 2>&1 || true

container-image:
	container builder start -c 4 -m 4G || true
	# Single sanctioned CONTAINER_DEFAULT_PLATFORM: `container build` line only.
	# Every `container run` below pins `--platform linux/arm64` explicitly.
	CONTAINER_DEFAULT_PLATFORM=linux/arm64 container build \
	  --platform linux/arm64 -f Containerfile -t $(IMAGE) .
	@archs=$$(container image inspect $(IMAGE) | \
	  jq -r '.[0].variants[].config.architecture' | sort -u); \
	[ "$$archs" = "arm64" ] || { echo "FAIL: variants: $$archs" >&2; exit 1; }

container-shell: volumes
	container run --platform linux/arm64 --rm -it \
	  -v "$(CURDIR)":/work -v house-target:/work/rust/target \
	  -v house-cabal:/root/.cabal -v house-cargo:/cargo-home \
	  -e CARGO_HOME=/cargo-home -w /work $(IMAGE) bash

# --- aarch64 freestanding spike ---
# Guest RAM/SMP are auto-detected at runtime (DTB via x0 → probe → fallback).
# -kernel boots the flat build/*.bin: QEMU takes non-ELF images via its Linux
# path (x0=DTB); ELF -kernel gets x0=0 and the hvf probe false-positives.
# SPIKE_MEM only drives QEMU -m (512M/1G/2G/4G/6G/8G/16G all boot from one
# .bin without rebuild). SMP_N only drives QEMU -smp and expect args.
SPIKE_DIR := platform/aarch64
SPIKE_MEM ?= 4G
SMP_N ?= 2

spike-build: volumes
	$(RUN_IN_CONTAINER) \
	  make -C $(SPIKE_DIR)

spike-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -smp $(SMP_N) -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/spike.bin

spike-check:
	$(RUN_IN_CONTAINER) \
	  make -C $(SPIKE_DIR) clean
	$(MAKE) spike-build
	expect scripts/qemu-smoke.exp $(SPIKE_DIR)/build/spike.bin \
	  'ticks-ok' 90 hvf $(SPIKE_MEM) $(SMP_N)

# --- aarch64 irq-check kernel ---
# Only entry point differs (IrqCheck vs Spike); RAM/SMP auto-detected.
irq-build: volumes
	$(RUN_IN_CONTAINER) \
	  make -C $(SPIKE_DIR) irq

irq-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -smp $(SMP_N) -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/irq.bin

# irq-check runs both hvf and tcg and requires vm-ok (which implies irq-ok).
irq-check:
	$(RUN_IN_CONTAINER) \
	  make -C $(SPIKE_DIR) clean
	$(MAKE) irq-build
	expect scripts/qemu-irq.exp $(SPIKE_DIR)/build/irq.bin \
	  'vm-ok' 120 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-irq.exp $(SPIKE_DIR)/build/irq.bin \
	  'vm-ok' 120 tcg $(SPIKE_MEM) $(SMP_N)

# --- aarch64 house kernel ---
house-build: volumes
	$(RUN_IN_CONTAINER) \
	  make -C $(SPIKE_DIR) house

rust-check: volumes
	$(RUN_IN_CONTAINER) \
	  cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none -- -D warnings
	$(RUN_IN_CONTAINER) \
	  bash -c 'cd rust && cargo fmt --check'

rust-clean: volumes
	$(RUN_IN_CONTAINER) \
	  cargo clean --manifest-path rust/Cargo.toml

# Hygiene gates (house-ng pattern, split for the hlint/GHC-9.14 gap): Rust
# gates run in the container via _lint-inner; Haskell gates run on the host
# (same convention as haskell-check below) because container hlint 3.6.1
# predates GHC2024 and no Hackage hlint builds under GHC 9.14.1
# (hlint 3.10 needs ghc-lib-parser <9.13 which excludes base-4.22).
# Undo condition: Hackage hlint supporting ghc-lib-parser 9.14 — then move
# fourmolu+hlint+cabal back into _lint-inner and bake hlint from Hackage.
lint: volumes
	$(RUN_IN_CONTAINER) make _lint-inner
	fourmolu -m check kernel/ platform/aarch64/Spike.hs platform/aarch64/IrqCheck.hs
	hlint kernel/ platform/aarch64/Spike.hs platform/aarch64/IrqCheck.hs
# No `cabal check` here: it grades Hackage-upload suitability, which this
# firmware test suite intentionally fails (parent-dir hs-source-dirs,
# `Con` module path reserved on Windows). Build/test coverage lives in
# haskell-check (step 8), not in the fast lint gate.

_lint-inner:
	cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none -- -D warnings
	bash -c 'cd rust && cargo fmt --check'
	cargo deny --manifest-path rust/Cargo.toml check

# Miri target is a stub until step 9 adds #[cfg(miri)] isolation for asm!/MMIO.
miri: volumes
	$(MIRI_IN_CONTAINER) cargo miri test --manifest-path rust/Cargo.toml -p house-hal -p house-hal-aarch64 -p house-libc -p house-boot

house-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -smp $(SMP_N) -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/house.bin

house-check:
	$(RUN_IN_CONTAINER) \
	  make -C $(SPIKE_DIR) clean
	$(RUN_IN_CONTAINER) \
	  make -C kernel clean
	$(MAKE) house-build
	expect scripts/qemu-house.exp $(SPIKE_DIR)/build/house.bin \
	  'Welcome to the House shell' 30 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-house.exp $(SPIKE_DIR)/build/house.bin \
	  'Welcome to the House shell' 30 tcg $(SPIKE_MEM) $(SMP_N)

# Interactive shell (phase 5): prompt → help/lambda/wastemem via PL011 RX
house-shell-check:
	$(MAKE) house-build
	expect scripts/qemu-house-shell.exp $(SPIKE_DIR)/build/house.bin 30 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-house-shell.exp $(SPIKE_DIR)/build/house.bin 30 tcg $(SPIKE_MEM) $(SMP_N)

# POSIX-ish shell + PSCI (phase 7): help descriptions, echo/clear/uname/uptime, shutdown -r/-h
house-posix-check:
	$(MAKE) house-build
	expect scripts/qemu-house-posix.exp $(SPIKE_DIR)/build/house.bin 60 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-house-posix.exp $(SPIKE_DIR)/build/house.bin 60 tcg $(SPIKE_MEM) $(SMP_N)

# SMP check (phase 9): N cores online + Haskell parallel (parametrised by SMP_N, default 2)
# Use SMP_N=4 make smp-check for the >2 gate (4G working RAM, tested to 8, HW bound 32).
smp-check:
	$(RUN_IN_CONTAINER) \
	  make -C $(SPIKE_DIR) clean
	$(RUN_IN_CONTAINER) \
	  make -C kernel clean
	$(MAKE) house-build
	expect scripts/qemu-smp.exp $(SPIKE_DIR)/build/house.bin 60 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-smp.exp $(SPIKE_DIR)/build/house.bin 60 tcg $(SPIKE_MEM) $(SMP_N)

# RamFS + VFS (Track 1): volatile 2 MiB pool over H.Pages, H.FileSystem via ls/cat/write/rm/mkdir/stat + echo > /path
house-fs-check: house-build
	expect scripts/qemu-house-fs.exp $(SPIKE_DIR)/build/house.bin 30 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-house-fs.exp $(SPIKE_DIR)/build/house.bin 30 tcg $(SPIKE_MEM) $(SMP_N)

# IPC microkernel (Track 1b): L4 sync rendezvous, copy+grant, ns+cap, hybrid Haskell/EL0
house-ipc-check: house-build
	expect scripts/qemu-ipc.exp $(SPIKE_DIR)/build/house.bin 30 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-ipc.exp $(SPIKE_DIR)/build/house.bin 30 tcg $(SPIKE_MEM) $(SMP_N)

# Driver framework (Track 2): registry on IPC + dmesg ring + SPI + virtio-MMIO probe 0x0a000000+i*0x200
house-driver-check: house-build
	expect scripts/qemu-driver.exp $(SPIKE_DIR)/build/house.bin 30 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-driver.exp $(SPIKE_DIR)/build/house.bin 30 tcg $(SPIKE_MEM) $(SMP_N)

# Virtio-MMIO transport (Track 3): device-agnostic split virtqueue, FEATURES_OK VIRTIO_F_VERSION_1|RING_F_EVENT_IDX, dc cvac/dsb, IRQ->Endpoint
house-virtio-transport-check: house-build
	expect scripts/qemu-virtio-transport.exp $(SPIKE_DIR)/build/house.bin 30 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-virtio-transport.exp $(SPIKE_DIR)/build/house.bin 30 tcg $(SPIKE_MEM) $(SMP_N)

# Virtio-blk (Track 4): block device on transport, virtio_blk_req, Grant pages, 4K blocks (512B sectors on wire), capacity, queue_notify, IRQ->Endpoint, 64M house.img, Q2=B
house-virtio-blk-check: house-build
	qemu-img create -f raw /tmp/house.img 64M
	expect scripts/qemu-virtio-blk.exp $(SPIKE_DIR)/build/house.bin 45 hvf $(SPIKE_MEM) $(SMP_N) -- -drive if=none,file=/tmp/house.img,format=raw,id=hd0 -device virtio-blk-device,drive=hd0
	expect scripts/qemu-virtio-blk.exp $(SPIKE_DIR)/build/house.bin 45 tcg $(SPIKE_MEM) $(SMP_N) -- -drive if=none,file=/tmp/house.img,format=raw,id=hd0 -device virtio-blk-device,drive=hd0

# Virtio-net (Track 5): virtio-net server, rx0+tx1, 12B hdr, Grant 4K, ARP/IPv4/UDP/DHCP, dc cvac/ivac/dsb, IRQ->Endpoint, user netdev 10.0.2.0/24
house-virtio-net-check: house-build
	expect scripts/qemu-virtio-net.exp $(SPIKE_DIR)/build/house.bin 20 hvf $(SPIKE_MEM) $(SMP_N) -- -netdev user,id=n0,net=10.0.2.0/24,dhcpstart=10.0.2.15 -device virtio-net-device,netdev=n0,mac=52:54:00:12:34:56
	expect scripts/qemu-virtio-net.exp $(SPIKE_DIR)/build/house.bin 180 tcg $(SPIKE_MEM) $(SMP_N) -- -netdev user,id=n0,net=10.0.2.0/24,dhcpstart=10.0.2.15 -device virtio-net-device,netdev=n0,mac=52:54:00:12:34:56

# Virtio-console (ID 3): console server, rx0+tx1, Grant 4K, full-duplex + mirror, socket chardev
house-virtio-con-check: house-build
	rm -f /tmp/house-con.sock
	expect scripts/qemu-virtio-con.exp $(SPIKE_DIR)/build/house.bin 45 hvf $(SPIKE_MEM) $(SMP_N) -- -chardev socket,path=/tmp/house-con.sock,server=on,wait=off,id=c0 -device virtio-serial-device -device virtconsole,chardev=c0,name=org.house.con0
	expect scripts/qemu-virtio-con.exp $(SPIKE_DIR)/build/house.bin 180 tcg $(SPIKE_MEM) $(SMP_N) -- -chardev socket,path=/tmp/house-con.sock,server=on,wait=off,id=c0 -device virtio-serial-device -device virtconsole,chardev=c0,name=org.house.con0

# Initramfs/initrd (cpio newc via QEMU -initrd, unpack + run /sbin/init)
house-initrd-check: house-build
	sh scripts/mkinitramfs.sh
	file build/initramfs.cpio
	expect scripts/qemu-initramfs.exp $(SPIKE_DIR)/build/house.bin 60 hvf $(SPIKE_MEM) $(SMP_N) -- -initrd build/initramfs.cpio
	expect scripts/qemu-initramfs.exp $(SPIKE_DIR)/build/house.bin 60 tcg $(SPIKE_MEM) $(SMP_N) -- -initrd build/initramfs.cpio

# EL0 process checks: per-pid exits + spawn/jobs/wait, 2 concurrent hellos
house-proc-check: house-build
	expect scripts/qemu-proc.exp $(SPIKE_DIR)/build/house.bin 'proc-ok' 60 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-proc.exp $(SPIKE_DIR)/build/house.bin 'proc-ok' 90 tcg $(SPIKE_MEM) $(SMP_N)

# EL0 fork/wait/exec via park ring (multiprocess step 9): fork probe
# parent/child distinct + wait reaps; exec probe replaces image w/ hello
house-fork-check: house-build
	expect scripts/qemu-fork.exp $(SPIKE_DIR)/build/house.bin 'fork-ok' 60 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-fork.exp $(SPIKE_DIR)/build/house.bin 'fork-ok' 90 tcg $(SPIKE_MEM) $(SMP_N)

# EL0 preemption via timer IRQ + baton run queue (multiprocess step 11):
# 2 CPU-bound spinners interleave on -smp 1 (smp forced to 1: the switch is
# proven by alternation, not core count), shell responsive throughout.
house-preempt-check: house-build
	expect scripts/qemu-preempt.exp $(SPIKE_DIR)/build/house.bin 'preempt-ok' 120 hvf $(SPIKE_MEM) 1
	expect scripts/qemu-preempt.exp $(SPIKE_DIR)/build/house.bin 'preempt-ok' 300 tcg $(SPIKE_MEM) 1

# Spinner + SMP hotplug (multiprocess step 12): one CPU-bound EL0 spinner
# survives `smp down 1` (hvf: down-leg only, PSCI refuses re-CPU_ON) and the
# full down/up cycle on tcg (resume migrates cores via the global run queue);
# shell responsive throughout, spinner reaped exit 0.
house-spin-hotplug-check: house-build
	expect scripts/qemu-spin-hotplug.exp $(SPIKE_DIR)/build/house.bin 'spin-hotplug-ok' 300 hvf $(SPIKE_MEM) 2
	expect scripts/qemu-spin-hotplug.exp $(SPIKE_DIR)/build/house.bin 'spin-hotplug-ok' 420 tcg $(SPIKE_MEM) 2

# EL0 fd/brk via park ring (multiprocess step 7): per-pid OPEN/READ/CLOSE cat + brk grow-touch
house-fd-el0-check: house-build
	expect scripts/qemu-fd-el0.exp $(SPIKE_DIR)/build/house.bin 'fd-el0-ok' 60 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-fd-el0.exp $(SPIKE_DIR)/build/house.bin 'fd-el0-ok' 90 tcg $(SPIKE_MEM) $(SMP_N)

# EL0 IPC ping-pong (multiprocess step 6): server RECV+REPLY + client CALL via the park ring
house-ipc-el0-check: house-build
	expect scripts/qemu-ipc-el0.exp $(SPIKE_DIR)/build/house.bin 'ipc-el0-ok' 60 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-ipc-el0.exp $(SPIKE_DIR)/build/house.bin 'ipc-el0-ok' 90 tcg $(SPIKE_MEM) $(SMP_N)

# Userspace EL0 (Track 6): ELF loader 0x01000000 window, svc write/exit/brk + IPC 0x10..0x14 via Endpoint, TTBR0/ASID/pager
house-userspace-check: house-build
	expect scripts/qemu-userspace.exp $(SPIKE_DIR)/build/house.bin "Hello from EL0" 60 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-userspace.exp $(SPIKE_DIR)/build/house.bin "Hello from EL0" 60 tcg $(SPIKE_MEM) $(SMP_N)

# SMP hotplug cycle (Tracks S+H): down/up at N=2, caps mirror, parfib each step.
# Accel split (step 6 spike): hvf refuses PSCI re-CPU_ON after CPU_OFF (call
# returns 0, core never re-enters), so up-after-down is tcg-only; hvf runs the
# down-leg (OFF + mask + caps + migrate + parfib) while tcg runs the full cycle.
smp-hotplug-check: house-build
	expect scripts/qemu-smp-hotplug-down.exp $(SPIKE_DIR)/build/house.bin 60 hvf $(SPIKE_MEM) 2
	expect scripts/qemu-smp-hotplug.exp $(SPIKE_DIR)/build/house.bin 60 tcg $(SPIKE_MEM) 2

# SMP-8 scaling gate (Track D): 8 cores online at 4G, ceiling 32.
# Status 2026-09-04: the RTS-interactive flake at 7-8 caps is fixed —
# (a) the 32-slot fd table starved N=7 (RTS opens ~4 fds/capability, so the
# timer manager's eventfd failed ENFILE and every threadDelay threw), now
# FAKE_FD_N=256; (b) the N=5 hs_init hang was a scheduler stall (parked
# waiter ignoring locally queued work, no preemption) plus duplicate
# run-queue entries, now guarded in enqueue_run_core with stale-link purge
# on slot reuse and yield-after-wakeup in the cond/join park loops.
# 1-8 cores pass hvf+tcg (16/16). Policy: default N=2 per-commit; N=8 stays
# a nightly/scaling gate.
smp-check-8:
	$(MAKE) smp-check SMP_N=8 SPIKE_MEM=4G

# Buddy/MM pressure leg (Track D + memory-6g): one `house-build`, then N
# expects from the same `.bin` — DTB-first detect reports truthful ram at
# every geometry. The qemu-vm.exp harness asserts `vm-ok` plus `mem` buddy
# free/total, so pressure is recorded without a new allocator.
vm-check: house-build
	expect scripts/qemu-vm.exp $(SPIKE_DIR)/build/house.bin 'vm-ok' 90 hvf 512M 2
	expect scripts/qemu-vm.exp $(SPIKE_DIR)/build/house.bin 'vm-ok' 90 tcg 512M 2
	expect scripts/qemu-vm.exp $(SPIKE_DIR)/build/house.bin 'vm-ok' 90 hvf 4G 4
	expect scripts/qemu-vm.exp $(SPIKE_DIR)/build/house.bin 'vm-ok' 90 tcg 4G 4
	expect scripts/qemu-vm.exp $(SPIKE_DIR)/build/house.bin 'vm-ok' 120 hvf 6G 4
	expect scripts/qemu-vm.exp $(SPIKE_DIR)/build/house.bin 'vm-ok' 180 tcg 6G 4
	expect scripts/qemu-vm.exp $(SPIKE_DIR)/build/house.bin 'vm-ok' 120 hvf 8G 4
	expect scripts/qemu-vm.exp $(SPIKE_DIR)/build/house.bin 'vm-ok' 120 hvf 16G 4

house-vm-check: vm-check

# `make run` is a convenience alias for the house shell (hvf, 4G default).
# `make check` reproduces the full verification from a clean checkout:
# spike ticks, GIC dispatch + VM, house banner, interactive shell, and
# rust (clippy + fmt), each under hvf and tcg where applicable. It is the
# gate used by CI and by "from clean clone inside container" verification.
# Scaling legs (vm-check 512M/2+4G/4+6G/4+8G/4+16G/4 single-build, smp-check-8) stay out of default `check`.
run: house-run

# --- Track H: Haskell hygiene gates (host tools, full tree) ---
# fourmolu/hlint cover kernel/ plus the platform entry points (Spike,
# IrqCheck); the kernel closure itself is built with -Wall -Werror via
# house-build. cabal runs the QuickCheck + golden suite with FFI stubbed
# (never executed). Container hlint cannot parse GHC2024 (see lint above),
# so the Haskell gates stay on the host until Hackage hlint supports
# ghc-lib-parser 9.14.
haskell-check:
	fourmolu -m check kernel/ platform/aarch64/Spike.hs platform/aarch64/IrqCheck.hs
	hlint kernel/ platform/aarch64/Spike.hs platform/aarch64/IrqCheck.hs
	cd kernel/test && cabal build all --enable-tests
	cd kernel/test && cabal test all

check:
	$(MAKE) spike-check
	$(MAKE) irq-check
	$(MAKE) house-check
	$(MAKE) house-shell-check
	$(MAKE) house-posix-check
	$(MAKE) rust-check
	$(MAKE) haskell-check
	@echo "== make check: all aarch64 gates passed (spike, irq+vm, house banner, shell, posix, rust) =="

.PHONY: container-image container-shell volumes lint _lint-inner miri spike-build spike-run spike-check \
        irq-build irq-run irq-check \
        house-build house-run house-check house-shell-check house-posix-check house-proc-check house-fd-el0-check house-fork-check house-preempt-check house-spin-hotplug-check smp-check smp-check-8 smp-hotplug-check vm-check house-vm-check house-fs-check house-ipc-check house-ipc-el0-check house-driver-check house-virtio-transport-check house-virtio-blk-check house-virtio-net-check house-virtio-con-check house-userspace-check house-initrd-check rust-check rust-clean haskell-check run check
