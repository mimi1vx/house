# kernel/Makefile — closure build for HouseA64
# Runs INSIDE the linux/arm64 container.
#
#   make -C kernel        # compile only (ghc --make -no-link)
#   make -C kernel clean
#
# The ghc --make driver follows imports from HouseA64.hs.
# HouseA64 is the reduced Main (help/lambda/preempt/wastemem + PL011 console).

GHC      ?= ghc
BUILD    := build

# Packages needed by the closure (H layer + console + parsers + Set)
PKGS := -package mtl -package array -package containers -package pretty

# GHC2024 language standard; replaces the legacy
# -fglasgow-exts -fallow-undecidable-instances set. Verified that the closure
# compiles with -XGHC2024 alone (FlexibleContexts/FlexibleInstances/
# ScopedTypeVariables/KindSignatures/GeneralisedNewtypeDeriving rankNTypes are
# covered; MultiParam/FunctionalDependencies/Undecidable/ImplicitParams/
# ExistentialQuantification/PatternGuards are unused; FFI is default-on).
EXTS := -XGHC2024

GHCFLAGS := -O1 -outputdir $(BUILD) -i. $(PKGS) $(EXTS) -Wall -Werror

# Default: compile-only check (no link). Mirrors platform Makefile idiom for
# verifying the closure compiles under stock GHC 9.14.
all:
	@mkdir -p $(BUILD)
	ghc --make -no-link HouseA64.hs $(GHCFLAGS)

# Force recompilation from scratch
force:
	@mkdir -p $(BUILD)
	ghc --make -no-link HouseA64.hs $(GHCFLAGS) -fforce-recomp

clean:
	rm -rf $(BUILD)

.PHONY: all force clean
