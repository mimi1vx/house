#!/bin/sh
# nm audit for rust/crates/house-el0-tiny.
# Runs INSIDE the linux/arm64 container (needs the cross archive + GNU nm).
# Asserts the crate's own object exports exactly the helper set plus the
# EXIT(1) panic handler, with no undefined symbols: EL0 binaries then stay
# at asm scale under --gc-sections (hello is 227B either way).
# B1 shared flavour: `ld.lld -shared` from this object (cdylib is dropped as
# unsupported on `aarch64-unknown-none`) carries the same set for GHC
# rebuilds; `nm -D` must match the recorded allowlist with no U.
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
cat >"$tmpdir/allowlist" <<'EOF'
__assert_fail
__errno_location
_Exit
_exit
abort
exit
fflush
fprintf
fputc
fputs
freelocale
fwrite
memchr
memcmp
memcpy
memmove
memset
newlocale
nl_langinfo
printf
putchar
puts
setlocale
snprintf
sprintf
strcasecmp
strcat
strchr
strcmp
strcpy
strlen
strnlen
strncmp
strncpy
strrchr
uselocale
vfprintf
vprintf
vsnprintf
EOF
LC_ALL=C sort -o "$tmpdir/allowlist" "$tmpdir/allowlist"
while IFS= read -r sym; do
	if ! echo "$T" | grep -qx "$sym"; then
		echo "el0tiny: missing T $sym" >&2
		exit 1
	fi
done <"$tmpdir/allowlist"
if ! echo "$T" | grep -q "rust_begin_unwind"; then
	echo "el0tiny: missing T rust_begin_unwind" >&2
	exit 1
fi
if [ "$(echo "$T" | wc -l)" -ne 40 ]; then
	echo "el0tiny: T set drift (want 39 + unwind = 40)" >&2
	exit 1
fi
echo "el0tiny-check: static ok (39 helpers + unwind, no U)"
UNWIND=$(nm "$tmpdir/$M" | awk '$2 == "T" && $3 ~ /rust_begin_unwind$/ {print $3}')
[ -n "$UNWIND" ] || {
	echo "el0tiny: missing rust_begin_unwind export" >&2
	exit 1
}
{
	echo "{"
	echo "  global:"
	while IFS= read -r sym; do
		printf '    %s;\n' "$sym"
	done <"$tmpdir/allowlist"
	printf '    %s;\n' "$UNWIND"
	echo "  local:"
	echo "    *;"
	echo "};"
} >"$tmpdir/exports.map"
SO="$tmpdir/libc-house.so.0"
ld.lld -shared --gc-sections --fatal-warnings \
	--soname="libc-house.so.0" --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	--version-script="$tmpdir/exports.map" \
	-o "$SO" "$tmpdir/$M"
readelf -hW "$SO" | grep -q 'Type:.*DYN' || {
	echo "el0tiny: $SO is not ET_DYN" >&2
	exit 1
}
readelf -hW "$SO" | grep -q 'Machine:.*AArch64' || {
	echo "el0tiny: $SO is not AArch64" >&2
	exit 1
}
nm -D --defined-only --format=posix "$SO" | awk '{print $1}' | LC_ALL=C sort >"$tmpdir/so-defined"
n_unwind=$(grep -c 'rust_begin_unwind$' "$tmpdir/so-defined" || true)
if [ "$n_unwind" != 1 ]; then
	echo "el0tiny: want exactly one rust_begin_unwind export in $SO" >&2
	exit 1
fi
grep -v 'rust_begin_unwind$' "$tmpdir/so-defined" >"$tmpdir/so-stable" || true
if ! cmp -s "$tmpdir/allowlist" "$tmpdir/so-stable"; then
	echo "el0tiny: dynamic export-set drift in $SO" >&2
	diff -u "$tmpdir/allowlist" "$tmpdir/so-stable" >&2 || true
	exit 1
fi
nm -D --undefined-only --format=posix "$SO" 2>/dev/null | awk 'NF {print $1}' | LC_ALL=C sort >"$tmpdir/so-undefined"
if [ -s "$tmpdir/so-undefined" ]; then
	echo "el0tiny: unexpected U in $SO:" >&2
	cat "$tmpdir/so-undefined" >&2
	exit 1
fi
echo "el0tiny-check: shared ok (ET_DYN aarch64, 39 + unwind, no U)"
echo "el0tiny-check: ok (39 helpers + unwind, no U)"
rm -rf "$tmpdir"
trap - EXIT
