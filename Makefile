# House/hOp — aarch64 port (QEMU virt, GHC 9.14)

IMAGE := house-port:latest

container-image:
	container builder start -c 4 -m 4G || true
	# Single sanctioned CONTAINER_DEFAULT_PLATFORM: `container build` line only.
	# Every `container run` below pins `--platform linux/arm64` explicitly.
	CONTAINER_DEFAULT_PLATFORM=linux/arm64 container build \
	  --platform linux/arm64 -f Containerfile -t $(IMAGE) .
	@archs=$$(container image inspect $(IMAGE) | \
	  jq -r '.[0].variants[].config.architecture' | sort -u); \
	[ "$$archs" = "arm64" ] || { echo "FAIL: variants: $$archs" >&2; exit 1; }

container-shell:
	container run --platform linux/arm64 --rm -it \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) bash

# --- aarch64 freestanding spike ---
# Guest RAM/SMP are auto-detected at runtime (DTB via x0 → probe → fallback).
# -kernel boots the flat build/*.bin: QEMU takes non-ELF images via its Linux
# path (x0=DTB); ELF -kernel gets x0=0 and the hvf probe false-positives.
# SPIKE_MEM only drives QEMU -m (512M/1G/2G/4G/6G/8G/16G all boot from one
# .bin without rebuild). SMP_N only drives QEMU -smp and expect args.
SPIKE_DIR := platform/aarch64
SPIKE_MEM ?= 4G
SMP_N ?= 2

spike-build:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR)

spike-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -smp $(SMP_N) -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/spike.bin

spike-check:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) clean
	$(MAKE) spike-build
	expect scripts/qemu-smoke.exp $(SPIKE_DIR)/build/spike.bin \
	  'ticks-ok' 90 hvf $(SPIKE_MEM) $(SMP_N)

# --- aarch64 irq-check kernel ---
# Only entry point differs (IrqCheck vs Spike); RAM/SMP auto-detected.
irq-build:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) irq

irq-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -smp $(SMP_N) -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/irq.bin

# irq-check runs both hvf and tcg and requires vm-ok (which implies irq-ok).
irq-check:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) clean
	$(MAKE) irq-build
	expect scripts/qemu-irq.exp $(SPIKE_DIR)/build/irq.bin \
	  'vm-ok' 120 hvf $(SPIKE_MEM) $(SMP_N)
	expect scripts/qemu-irq.exp $(SPIKE_DIR)/build/irq.bin \
	  'vm-ok' 120 tcg $(SPIKE_MEM) $(SMP_N)

# --- aarch64 house kernel ---
house-build:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) house

rust-check:
	container run --platform linux/arm64 --rm -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none -- -D warnings
	container run --platform linux/arm64 --rm -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  bash -c 'cd rust && cargo fmt --check'

rust-clean:
	container run --platform linux/arm64 --rm -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  cargo clean --manifest-path rust/Cargo.toml

house-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -smp $(SMP_N) -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/house.bin

house-check:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) clean
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
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
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) clean
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
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

check:
	$(MAKE) spike-check
	$(MAKE) irq-check
	$(MAKE) house-check
	$(MAKE) house-shell-check
	$(MAKE) house-posix-check
	$(MAKE) rust-check
	@echo "== make check: all aarch64 gates passed (spike, irq+vm, house banner, shell, posix, rust) =="

.PHONY: container-image container-shell spike-build spike-run spike-check \
        irq-build irq-run irq-check \
        house-build house-run house-check house-shell-check house-posix-check smp-check smp-check-8 smp-hotplug-check vm-check house-vm-check house-fs-check house-ipc-check house-driver-check house-virtio-transport-check house-virtio-blk-check house-virtio-net-check house-userspace-check rust-check rust-clean run check
