#!/bin/sh
# nm audit for rust/crates/house-el0-tiny (plans/userspace-edsl-tinylibc.md gates).
# Runs INSIDE the linux/arm64 container (needs the cross archive + GNU nm).
# Asserts the crate's own object exports exactly the helper set plus the
# EXIT(1) panic handler, with no undefined symbols: EL0 binaries then stay
# at asm scale under --gc-sections (hello is 227B either way).
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
A="rust/target/aarch64-unknown-none/debug/libhouse_el0_tiny.a"
cargo build --manifest-path rust/Cargo.toml --target aarch64-unknown-none -p house-el0-tiny
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
M=$(ar t "$A" | grep -E '^house_el0_tiny-.*\.rcgu\.o$')
if [ -z "$M" ]; then
	echo "el0tiny: no crate object in $A" >&2
	exit 1
fi
(cd "$tmpdir" && ar x "$ROOT/$A" "$M")
T=$(nm "$tmpdir/$M" | awk '$2 == "T" {print $3}' | sort)
U=$(nm "$tmpdir/$M" | awk '$2 == "U" {print $3}' | sort || true)
echo "el0tiny T:"
echo "$T"
if [ -n "$U" ]; then
	echo "el0tiny: unexpected U symbols:"
	echo "$U"
	exit 1
fi
for sym in memcpy memset strlen strncmp; do
	if ! echo "$T" | grep -qx "$sym"; then
		echo "el0tiny: missing T $sym" >&2
		exit 1
	fi
done
if ! echo "$T" | grep -q "rust_begin_unwind"; then
	echo "el0tiny: missing T rust_begin_unwind" >&2
	exit 1
fi
if [ "$(echo "$T" | wc -l)" -ne 5 ]; then
	echo "el0tiny: T set drift (want 5)" >&2
	exit 1
fi
echo "el0tiny-check: ok (4 helpers + unwind, no U)"
rm -rf "$tmpdir"
trap - EXIT
