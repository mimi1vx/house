#!/bin/sh
# Assemble EL0 userspace into initramfs-staging/ (pid1 slice, step 1).
# Runs INSIDE the linux/arm64 container where CC is native aarch64
# (same convention as platform/aarch64/Makefile: CC := gcc, LD := ld.lld);
# CC/LD/PYTHON3 are overridable for a cross host toolchain, e.g.
#   CC=aarch64-linux-gnu-gcc LD=aarch64-linux-gnu-ld sh scripts/mk-userspace.sh
# For each prog: $CC -c prog.s + $LD -T prog.ld + build-probe/repack.py
# (hello-style minimal ELF the Loader accepts: ET_EXEC, AArch64,
# 0x01000000 window, filesz==memsz<=256K, pages<=64).
# userspace/*.s win over build-probe/*.s on collision (cat is argv-aware
# here and keeps the legacy /probe.txt default + `cat ok` trailer, so
# qemu-fd-el0.exp stays green).
set -eu
cd "$(dirname "$0")/.."
CC=${CC:-gcc}
LD=${LD:-ld}
PYTHON3=${PYTHON3:-python3}

build_one() {
	src="$1" ldfile="$2" out="$3"
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	"$CC" -c "$src" -o "$tmpdir/prog.o"
	"$LD" -T "$ldfile" -o "$tmpdir/prog.elf" "$tmpdir/prog.o"
	"$PYTHON3" build-probe/repack.py "$tmpdir/prog.elf" "$out"
	chmod +x "$out"
	rm -rf "$tmpdir"
	trap - EXIT
}

mkdir -p initramfs-staging/bin initramfs-staging/sbin

# New pid1 toolchain (userspace.ld shared; init -> sbin).
for prog in hello ls cat echo mkdir rm stat write; do
	build_one "userspace/$prog.s" userspace/userspace.ld "initramfs-staging/bin/$prog"
done
build_one userspace/init.s userspace/userspace.ld initramfs-staging/sbin/init

# Existing probes (reference sources until userspace/ supersedes them).
for prog in argenv brk exec fork ipc_pp spin yield; do
	build_one "build-probe/$prog.s" "build-probe/$prog.ld" "initramfs-staging/bin/$prog"
done

ls initramfs-staging/bin initramfs-staging/sbin
