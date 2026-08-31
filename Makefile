# House/hOp — aarch64 port (QEMU virt, GHC 9.14)

IMAGE := house-port:latest

container-image:
	container builder start -c 4 -m 4G || true
	CONTAINER_DEFAULT_PLATFORM=linux/arm64 container build \
	  --platform linux/arm64 -f Containerfile -t $(IMAGE) .
	@archs=$$(container image inspect $(IMAGE) | \
	  jq -r '.[0].variants[].config.architecture' | sort -u); \
	[ "$$archs" = "arm64" ] || { echo "FAIL: variants: $$archs" >&2; exit 1; }

container-shell:
	container run --platform linux/arm64 --rm -it \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) bash

# --- aarch64 freestanding spike ---
# Guest RAM for the spike: 4G default — comfortable on 32GB dev hosts.
# The kernel is COMPILED with the same size (kernel learns it at link
# time via SPIKE_DEFS), so SPIKE_MEM and QEMU -m can never disagree.
# Small values are first-class: SPIKE_MEM=512M make spike-check works.
SPIKE_DIR := platform/aarch64
SPIKE_MEM ?= 4G

ifeq ($(findstring G,$(SPIKE_MEM)),G)
  SPIKE_RAM_BYTES := $(shell echo $$(( $(subst G,,$(SPIKE_MEM)) * 1024 * 1024 * 1024 )))
else
  SPIKE_RAM_BYTES := $(shell echo $$(( $(subst M,,$(SPIKE_MEM)) * 1024 * 1024 )))
endif
SPIKE_DEFS_C := -DHOUSE_RAM_BYTES=$(SPIKE_RAM_BYTES)ULL \
                -DHOUSE_STACK_TOP="(0x40000000ULL + $(SPIKE_RAM_BYTES)ULL - 0x200000ULL)"
SPIKE_STACK_TOP := $(shell echo $$((1073741824 + $(SPIKE_RAM_BYTES) - 2097152)))
SPIKE_DEFS_S := -DHOUSE_RAM_BYTES=$(SPIKE_RAM_BYTES) \
                -DBOOT_STACK_TOP=$(SPIKE_STACK_TOP)
SPIKE_DEFS_C += -DHOUSE_STACK_TOP="(0x40000000ULL + $(SPIKE_RAM_BYTES)ULL - 0x200000ULL)"

spike-build:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) DEFS_C='$(SPIKE_DEFS_C)' DEFS_S='$(SPIKE_DEFS_S)'

spike-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/spike.elf

spike-check:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) clean
	$(MAKE) spike-build
	expect scripts/qemu-smoke.exp $(SPIKE_DIR)/build/spike.elf \
	  'ticks-ok' 90 hvf $(SPIKE_MEM)

# --- aarch64 irq-check kernel ---
# Shares SPIKE_DEFS_C/SPIKE_DEFS_S with the spike so RAM/stack defines stay
# identical; only the Haskell entry point differs (IrqCheck vs Spike).
irq-build:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) irq DEFS_C='$(SPIKE_DEFS_C)' DEFS_S='$(SPIKE_DEFS_S)'

irq-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/irq.elf

# irq-check runs both hvf and tcg and requires vm-ok (which implies irq-ok).
irq-check:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) clean
	$(MAKE) irq-build
	expect scripts/qemu-irq.exp $(SPIKE_DIR)/build/irq.elf \
	  'vm-ok' 120 hvf $(SPIKE_MEM)
	expect scripts/qemu-irq.exp $(SPIKE_DIR)/build/irq.elf \
	  'vm-ok' 120 tcg $(SPIKE_MEM)

# --- aarch64 house kernel ---
house-build:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) house DEFS_C='$(SPIKE_DEFS_C)' DEFS_S='$(SPIKE_DEFS_S)'

house-run:
	qemu-system-aarch64 -accel hvf -cpu max -M virt,gic-version=3 \
	  -m $(SPIKE_MEM) -nographic -kernel $(SPIKE_DIR)/build/house.elf

house-check:
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C $(SPIKE_DIR) clean
	container run --platform linux/arm64 --rm \
	  -v "$(CURDIR)":/work -w /work $(IMAGE) \
	  make -C kernel clean
	$(MAKE) house-build
	expect scripts/qemu-house.exp $(SPIKE_DIR)/build/house.elf \
	  'Welcome to the House shell' 30 hvf $(SPIKE_MEM)
	expect scripts/qemu-house.exp $(SPIKE_DIR)/build/house.elf \
	  'Welcome to the House shell' 30 tcg $(SPIKE_MEM)

# Interactive shell (phase 5): prompt → help/lambda/wastemem via PL011 RX
house-shell-check:
	$(MAKE) house-build
	expect scripts/qemu-house-shell.exp $(SPIKE_DIR)/build/house.elf 30 hvf $(SPIKE_MEM)
	expect scripts/qemu-house-shell.exp $(SPIKE_DIR)/build/house.elf 30 tcg $(SPIKE_MEM)

# POSIX-ish shell + PSCI (phase 7): help descriptions, echo/clear/uname/uptime, shutdown -r/-h
house-posix-check:
	$(MAKE) house-build
	expect scripts/qemu-house-posix.exp $(SPIKE_DIR)/build/house.elf 60 hvf $(SPIKE_MEM)
	expect scripts/qemu-house-posix.exp $(SPIKE_DIR)/build/house.elf 60 tcg $(SPIKE_MEM)

# `make run` is a convenience alias for the house shell (hvf, 4G default).
# `make check` reproduces the full verification from a clean checkout:
# spike ticks, GIC dispatch + VM, house banner, and interactive shell,
# each under hvf and tcg where applicable. It is the gate used by CI
# and by "from clean clone inside container" verification.
run: house-run

check:
	$(MAKE) spike-check
	$(MAKE) irq-check
	$(MAKE) house-check
	$(MAKE) house-shell-check
	$(MAKE) house-posix-check
	@echo "== make check: all aarch64 gates passed (spike, irq+vm, house banner, shell, posix) =="

.PHONY: container-image container-shell spike-build spike-run spike-check \
        irq-build irq-run irq-check \
        house-build house-run house-check house-shell-check house-posix-check run check
