# aarch64 spike build. Runs INSIDE the linux/arm64 container
# (make -C platform/aarch64 via `make spike-build` on the host).

LIBDIR := $(shell ghc --print-libdir)
HSINC  := $(shell dirname "$(shell find "$(LIBDIR)" -name HsFFI.h | head -1)")

CC      := gcc
LD      := ld
DEFS_C  ?=
DEFS_S  ?=
SMP_N   ?= 2  # generalizes to N ≤ HOUSE_MAX_SMP (16, tested to 8)
RUST_MANIFEST := ../../rust/Cargo.toml
RUST_TARGET   := aarch64-unknown-none
RUST_BOOT_A   := ../../rust/target/$(RUST_TARGET)/debug/libhouse_boot.rlib
RUST_LIBC_A   := ../../rust/target/$(RUST_TARGET)/debug/libhouse_libc.a
RUST_HAL_A    := ../../rust/target/$(RUST_TARGET)/debug/libhouse_hal_aarch64.rlib
RUST_SYSROOT  := $(shell rustc --print sysroot)
RUST_CORE_A   := $(wildcard $(RUST_SYSROOT)/lib/rustlib/$(RUST_TARGET)/lib/libcore-*.rlib)
RUST_COMPILER_BUILTINS_A := $(wildcard $(RUST_SYSROOT)/lib/rustlib/$(RUST_TARGET)/lib/libcompiler_builtins-*.rlib)
RUST_LIBS     := $(RUST_BOOT_A) $(RUST_HAL_A) $(RUST_LIBC_A)

BOOT_O := $(RUST_BOOT_A)
$(RUST_BOOT_A) $(RUST_HAL_A) $(RUST_LIBC_A):
	HOUSE_RAM_LIMIT_BYTES=$(HOUSE_RAM_LIMIT_BYTES) cargo build --manifest-path $(RUST_MANIFEST) --target $(RUST_TARGET)

# legacy boot (RUST=0 kept for bisect until slice 6): start.S moved to start.S.legacy
build/start.o: start.S.legacy | build
	$(CC) -c $(ASFLAGS) -o $@ $<
HOUSE_SMP_LIMIT ?= $(SMP_N)
HOUSE_RAM_LIMIT_BYTES ?=
.DEFAULT_GOAL := all

ifneq ($(HOUSE_RAM_LIMIT_BYTES),)
DEFS_C += -DHOUSE_RAM_LIMIT_BYTES=$(HOUSE_RAM_LIMIT_BYTES)
endif
DEFS_C += -DHOUSE_SMP_LIMIT=$(HOUSE_SMP_LIMIT)

RUST_LIBC_A_DEPS := $(RUST_LIBC_A)
CFLAGS  := -O2 -ffreestanding -fno-builtin -fno-pic -fno-pie \
           -fno-stack-protector -Wall -Werror -I. -I$(HSINC) $(DEFS_C)
ASFLAGS := -I. $(DEFS_S) -DHOUSE_SMP_N=$(SMP_N) -DHOUSE_SMP_LIMIT=$(HOUSE_SMP_LIMIT)
HS_GHCFLAGS := -XGHC2024 -Wall -Werror -package mtl -package array -i../../kernel -ibuild -outputdir build

UNITDIR_base := $(shell ghc-pkg field base import-dirs --simple-output | awk '{print $$1}')
UNITDIR_prim := $(shell ghc-pkg field ghc-prim import-dirs --simple-output | awk '{print $$1}')
UNITDIR_bnum := $(shell ghc-pkg field ghc-bignum import-dirs --simple-output | awk '{print $$1}')
UNITDIR_gint := $(shell ghc-pkg field ghc-internal import-dirs --simple-output | awk '{print $$1}')
UNITDIR_cont := $(shell ghc-pkg field containers import-dirs --simple-output | awk '{print $$1}')
UNITDIR_pretty := $(shell ghc-pkg field pretty import-dirs --simple-output | awk '{print $$1}')
UNITDIR_mtl  := $(shell ghc-pkg field mtl import-dirs --simple-output | awk '{print $$1}')
UNITDIR_arr  := $(shell ghc-pkg field array import-dirs --simple-output | awk '{print $$1}')
UNITDIR_trans := $(shell ghc-pkg field transformers import-dirs --simple-output | awk '{print $$1}')
UNITDIR_deep := $(shell ghc-pkg field deepseq import-dirs --simple-output | awk '{print $$1}')
UNITDIR_rts  := $(shell ghc-pkg field rts library-dirs --simple-output | awk '{print $$1}')

BASE_A := $(shell ls $(UNITDIR_base)/libHSbase-*.a | head -1)
PRIM_A := $(shell ls $(UNITDIR_prim)/libHSghc-prim-*.a | head -1)
BNUM_A := $(shell ls $(UNITDIR_bnum)/libHSghc-bignum-*.a | head -1)
GINT_A := $(shell ls $(UNITDIR_gint)/libHSghc-internal-*.a | head -1)
CONT_A := $(shell ls $(UNITDIR_cont)/libHScontainers-*.a | head -1)
PRETTY_A := $(shell ls $(UNITDIR_pretty)/libHSpretty-*.a | head -1)
MTL_A  := $(shell ls $(UNITDIR_mtl)/libHSmtl-*.a 2>/dev/null | head -1)
ARRAY_A:= $(shell ls $(UNITDIR_arr)/libHSarray-*.a | head -1)
TRANS_A:= $(shell ls $(UNITDIR_trans)/libHStransformers-*.a | head -1)
DEEP_A := $(shell ls $(UNITDIR_deep)/libHSdeepseq-*.a | head -1)
RTS_A  := $(shell ls $(UNITDIR_rts)/libHSrts-*.a | grep thr | grep -v debug | grep -v eventlog | head -1)
FFI_A  := $(UNITDIR_rts)/libCffi.a

TINY := tinylibc/mem.c tinylibc/alloc.c tinylibc/sys.c \
          tinylibc/stdio.c tinylibc/getopt.c tinylibc/compat.c \
          tinylibc/mathmin.c tinylibc/c_print.c \
          tinylibc/threads.c tinylibc/tls.c

TINY_ASM := tinylibc/switch.S tinylibc/tls_desc.S

TINY_OBJS := $(addprefix build/tiny-,$(notdir $(TINY:.c=.o))) $(addprefix build/tiny-,$(notdir $(TINY_ASM:.S=.o)))
# Pure Rust HAL — C tinylibc kept for hs_init until Rust tinylibc fully stable
HAL_O := $(RUST_HAL_A)

VM_HS := H/AdHocMem H/Utils H/Mutable H/Unsafe Util/Word12 \
         H/Concurrency Kernel/Types/Console Kernel/Console Kernel/Debug \
         H/Pages H/PhysicalMemory H/VirtualMemory
VM_OBJS := $(addprefix build/,$(addsuffix .o,$(VM_HS)))

# Pure Rust HAL + C tinylibc for hs_init (hybrid until slice 4c complete)
COMMON_OBJS := $(BOOT_O) $(TINY_OBJS)
OBJS := $(COMMON_OBJS) $(HAL_O) build/Spike.o
OBJS_IRQ := $(COMMON_OBJS) $(HAL_O) build/IrqCheck.o build/H/Monad.o build/H/Interrupts.o $(VM_OBJS)
OBJS_HOUSE_DEPS := $(COMMON_OBJS) $(HAL_O)

all: build/spike.elf
	@readelf -h build/spike.elf | grep -E 'Entry|Machine'

irq: build/irq.elf
	@readelf -h build/irq.elf | grep -E 'Entry|Machine'

house: build/house.elf
	@readelf -h build/house.elf | grep -E 'Entry|Machine'

house-hs:
	$(MAKE) -C ../../kernel

build/house.elf: house-hs $(OBJS_HOUSE_DEPS) build/aarch64.ld
	$(LD) --allow-multiple-definition --build-id=none --gc-sections -T build/aarch64.ld -o $@ \
	  $(filter-out $(RUST_HAL_A) $(RUST_BOOT_A),$(OBJS_HOUSE_DEPS)) $$(find ../../kernel/build -name '*.o') \
	  --start-group $(RUST_HAL_A) $(RUST_BOOT_A) $(RUST_LIBC_A) $(RUST_CORE_A) $(RUST_COMPILER_BUILTINS_A) \
	    $(PRIM_A) $(BNUM_A) $(GINT_A) $(CONT_A) $(PRETTY_A) $(MTL_A) $(ARRAY_A) $(TRANS_A) $(DEEP_A) $(BASE_A) $(RTS_A) $(FFI_A) \
	    /usr/lib/aarch64-linux-gnu/libgmp.a --end-group \
	  $(shell $(CC) -print-libgcc-file-name)

build/aarch64.ld: aarch64.ld | build
	$(CC) -E -P -x c -DHOUSE_SMP_N=$(SMP_N) -o $@ $<

build:
	mkdir -p build build/H build/Kernel/Types build/Util build/Kernel build/mm

build/tiny-%.o: tinylibc/%.c | build
	$(CC) -c $(CFLAGS) -o $@ $<

build/tiny-%.o: tinylibc/%.S | build
	$(CC) -c $(ASFLAGS) -o $@ $<

build/%.o: %.c | build
	@mkdir -p $(dir $@)
	$(CC) -c $(CFLAGS) -o $@ $<

# GHC 9.x emits the foreign-export wrapper (house_spike_main) directly
# into the module object.
build/Spike.o: Spike.hs | build
	ghc -XGHC2024 -Wall -Werror -O1 -c Spike.hs -outputdir build

# H-layer modules for IrqCheck (compiled individually; IrqCheck depends on them)
build/H/Monad.o: ../../kernel/H/Monad.hs | build
	ghc -O1 $(HS_GHCFLAGS) -c $< -o $@

build/H/Interrupts.o: ../../kernel/H/Interrupts.hs build/H/Monad.o | build
	ghc -O1 $(HS_GHCFLAGS) -c $< -o $@

# Generic pattern for VM and other Haskell modules
build/%.o: ../../kernel/%.hs | build
	ghc -O1 $(HS_GHCFLAGS) -c $< -o $@

build/IrqCheck.o: IrqCheck.hs build/H/Interrupts.o build/H/Monad.o $(VM_OBJS) | build
	ghc -O1 $(HS_GHCFLAGS) -c $< -o $@

build/spike.elf: $(OBJS) build/aarch64.ld
	$(LD) --allow-multiple-definition --build-id=none --gc-sections -T build/aarch64.ld -o $@ \
	  $(filter-out $(RUST_HAL_A) $(RUST_BOOT_A),$(OBJS)) \
	  --start-group $(RUST_HAL_A) $(RUST_BOOT_A) $(RUST_LIBC_A) $(RUST_CORE_A) $(RUST_COMPILER_BUILTINS_A) \
	    $(PRIM_A) $(BNUM_A) $(GINT_A) $(BASE_A) $(RTS_A) $(FFI_A) /usr/lib/aarch64-linux-gnu/libgmp.a --end-group \
	  $(shell $(CC) -print-libgcc-file-name)

build/irq.elf: $(OBJS_IRQ) build/aarch64.ld
	$(LD) --allow-multiple-definition --build-id=none --gc-sections -T build/aarch64.ld -o $@ \
	  $(filter-out $(RUST_HAL_A) $(RUST_BOOT_A),$(OBJS_IRQ)) \
	  --start-group $(RUST_HAL_A) $(RUST_BOOT_A) $(RUST_LIBC_A) $(RUST_CORE_A) $(RUST_COMPILER_BUILTINS_A) \
	    $(PRIM_A) $(BNUM_A) $(GINT_A) $(CONT_A) $(MTL_A) $(ARRAY_A) $(TRANS_A) $(DEEP_A) $(BASE_A) $(RTS_A) $(FFI_A) \
	    /usr/lib/aarch64-linux-gnu/libgmp.a --end-group \
	  $(shell $(CC) -print-libgcc-file-name)

clean:
	rm -rf build

cargo-build:
	cargo build --manifest-path $(RUST_MANIFEST) --target $(RUST_TARGET)

cargo-clippy:
	cargo clippy --manifest-path $(RUST_MANIFEST) --target $(RUST_TARGET) -- -D warnings

cargo-fmt:
	cd ../../rust && cargo fmt --check

cargo-clean:
	cargo clean --manifest-path $(RUST_MANIFEST)

.PHONY: all clean cargo-build cargo-clippy cargo-fmt cargo-clean
