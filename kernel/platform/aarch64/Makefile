# aarch64 spike build. Runs INSIDE the linux/arm64 container
# (make -C kernel/platform/aarch64 via `make spike-build` on the host).

LIBDIR := $(shell ghc --print-libdir)
HSINC  := $(shell dirname "$(shell find "$(LIBDIR)" -name HsFFI.h | head -1)")

CC      := gcc
LD      := ld
CFLAGS  := -O2 -ffreestanding -fno-builtin -fno-pic -fno-pie \
           -fno-stack-protector -Wall -Werror -I. -I$(HSINC)
ASFLAGS := -I.

UNITDIR_base := $(shell ghc-pkg field base import-dirs --simple-output | awk '{print $$1}')
UNITDIR_prim := $(shell ghc-pkg field ghc-prim import-dirs --simple-output | awk '{print $$1}')
UNITDIR_bnum := $(shell ghc-pkg field ghc-bignum import-dirs --simple-output | awk '{print $$1}')
UNITDIR_gint := $(shell ghc-pkg field ghc-internal import-dirs --simple-output | awk '{print $$1}')
UNITDIR_rts  := $(shell ghc-pkg field rts library-dirs --simple-output | awk '{print $$1}')

BASE_A := $(shell ls $(UNITDIR_base)/libHSbase-*.a | head -1)
PRIM_A := $(shell ls $(UNITDIR_prim)/libHSghc-prim-*.a | head -1)
BNUM_A := $(shell ls $(UNITDIR_bnum)/libHSghc-bignum-*.a | head -1)
GINT_A := $(shell ls $(UNITDIR_gint)/libHSghc-internal-*.a | head -1)
RTS_A  := $(shell ls $(UNITDIR_rts)/libHSrts-*.a | grep -v thr | grep -v debug | grep -v eventlog | head -1)
FFI_A  := $(UNITDIR_rts)/libCffi.a

TINY := tinylibc/mem.c tinylibc/alloc.c tinylibc/sys.c \
        tinylibc/stdio.c tinylibc/getopt.c tinylibc/compat.c \
        tinylibc/mathmin.c

OBJS := build/start.o build/c_start.o build/uart.o \
        $(addprefix build/tiny-,$(notdir $(TINY:.c=.o))) \
        build/Spike.o

all: build/spike.elf
	@readelf -h build/spike.elf | grep -E 'Entry|Machine'

build:
	mkdir -p build

build/start.o: start.S | build
	$(CC) -c $(ASFLAGS) -o $@ $<

build/tiny-%.o: tinylibc/%.c | build
	$(CC) -c $(CFLAGS) -o $@ $<

build/%.o: %.c | build
	$(CC) -c $(CFLAGS) -o $@ $<

# GHC 9.x emits the foreign-export wrapper (house_spike_main) directly
# into the module object.
build/Spike.o: Spike.hs | build
	ghc -O1 -c Spike.hs -outputdir build

build/spike.elf: $(OBJS) aarch64.ld
	$(LD) --build-id=none --gc-sections -T aarch64.ld -o $@ $(OBJS) \
	  --start-group $(PRIM_A) $(BNUM_A) $(GINT_A) $(BASE_A) $(RTS_A) $(FFI_A) \
	  /usr/lib/aarch64-linux-gnu/libgmp.a --end-group \
	  $(shell $(CC) -print-libgcc-file-name)

clean:
	rm -rf build

.PHONY: all clean
