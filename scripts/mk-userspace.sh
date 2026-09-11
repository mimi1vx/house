#!/bin/sh
# Assemble EL0 userspace into initramfs-staging/ (pid1 slice, step 1;
# EDSL pivot slice: plans/userspace-edsl-tinylibc.md step 4).
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
#
# EDSL tools (EDSL_TOOLS): `house-gen <tool>` output must match the
# checked-in .s byte-for-byte (fail on drift); the checked-in .s stays the
# reviewable artifact that gets assembled. The link gains the tiny EL0
# archive (strlen/strncmp/memcpy/memset + EXIT(1) unwind) with
# --gc-sections, so unused helpers never reach the binary (hello stays
# 227B). build-probe/*.s keep the bare link line, untouched.
set -eu
cd "$(dirname "$0")/.."
CC=${CC:-gcc}
LD=${LD:-ld}
PYTHON3=${PYTHON3:-python3}

# Tools with a Haskell builder behind `house-gen` (parity-proven, one per
# line as step 5 migrates hello -> echo -> mkdir/rm -> ls/stat/write ->
# cat -> init/sh). assemblies for other tools skip the drift gate.
EDSL_TOOLS="hello echo mkdir rm ls stat write cat"

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

build_user_one() {
	src="$1" ldfile="$2" out="$3" tiny="$4" core="$5" cb="$6"
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	"$CC" -c "$src" -o "$tmpdir/prog.o"
	"$LD" --gc-sections -T "$ldfile" -o "$tmpdir/prog.elf" \
		"$tmpdir/prog.o" "$tiny" "$core" "$cb"
	"$PYTHON3" build-probe/repack.py "$tmpdir/prog.elf" "$out"
	chmod +x "$out"
	rm -rf "$tmpdir"
	trap - EXIT
}

mkdir -p initramfs-staging/bin initramfs-staging/sbin

# Tiny EL0 archive + sysroot rlibs for the userspace link (EL0 only).
cargo build --manifest-path rust/Cargo.toml --target aarch64-unknown-none -p house-el0-tiny
TINY_A="rust/target/aarch64-unknown-none/debug/libhouse_el0_tiny.a"
SYSROOT=$(rustc --print sysroot)
CORE_A=$(echo "$SYSROOT"/lib/rustlib/aarch64-unknown-none/lib/libcore-*.rlib)
CB_A=$(echo "$SYSROOT"/lib/rustlib/aarch64-unknown-none/lib/libcompiler_builtins-*.rlib)
[ -f "$TINY_A" ] || {
	echo "missing $TINY_A" >&2
	exit 1
}
[ -f "$CORE_A" ] || {
	echo "missing libcore rlib" >&2
	exit 1
}
[ -f "$CB_A" ] || {
	echo "missing libcompiler_builtins rlib" >&2
	exit 1
}

# house-gen binary (built once; list-bin path, never `cabal run` stdout).
cabal build exe:house-gen
GEN=$(cabal list-bin exe:house-gen 2>/dev/null | tail -1)
[ -x "$GEN" ] || {
	echo "house-gen not executable: $GEN" >&2
	exit 1
}

# New pid1 toolchain (userspace.ld shared; init -> sbin).
for prog in hello ls cat echo mkdir rm stat write; do
	case " $EDSL_TOOLS " in
	*" $prog "*)
		tmpgen=$(mktemp)
		"$GEN" "$prog" >"$tmpgen"
		if ! diff -u "userspace/$prog.s" "$tmpgen"; then
			echo "drift: house-gen $prog != userspace/$prog.s" >&2
			rm -f "$tmpgen"
			exit 1
		fi
		rm -f "$tmpgen"
		;;
	esac
	build_user_one "userspace/$prog.s" userspace/userspace.ld \
		"initramfs-staging/bin/$prog" "$TINY_A" "$CORE_A" "$CB_A"
done
build_one userspace/init.s userspace/userspace.ld initramfs-staging/sbin/init

# Existing probes (reference sources until userspace/ supersedes them).
for prog in argenv brk exec fork ipc_pp spin yield; do
	build_one "build-probe/$prog.s" "build-probe/$prog.ld" "initramfs-staging/bin/$prog"
done

ls initramfs-staging/bin initramfs-staging/sbin
