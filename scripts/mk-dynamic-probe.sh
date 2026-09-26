#!/bin/sh
# Build the M2.0 dynamic-linking compatibility artifacts. Runs inside the
# linux/arm64 house-port container; all generated files stay below
# build/dynamic-probe/<name>/.
set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD
NAME=${1:-current}
case "$NAME" in
"" | *[!A-Za-z0-9._-]*)
	echo "mk-dynamic-probe: invalid output name: $NAME" >&2
	exit 1
	;;
esac

OUT="build/dynamic-probe/$NAME"
EXPECTED_RUSTC_COMMIT=6bb1652a020e80cef79332741d89e996d71933c9
EXPECTED_LLD='Debian LLD 19.1.7 (compatible with GNU linkers)'
EXPECTED_CARGO='cargo 1.100.0-nightly (495c385d0 2026-09-16)'
EXPECTED_GCC='gcc (Debian 14.2.0-19) 14.2.0'
EXPECTED_AR='GNU ar (GNU Binutils for Debian) 2.44'
EXPECTED_NM='GNU nm (GNU Binutils for Debian) 2.44'
SONAME=libc-house.so.0
MID_SONAME=libmid-house.so.0

actual_rustc_commit=$(rustc -Vv | sed -n 's/^commit-hash: //p')
[ "$actual_rustc_commit" = "$EXPECTED_RUSTC_COMMIT" ] || {
	echo "mk-dynamic-probe: rustc commit $actual_rustc_commit != $EXPECTED_RUSTC_COMMIT" >&2
	exit 1
}
actual_lld=$(ld.lld --version)
[ "$actual_lld" = "$EXPECTED_LLD" ] || {
	echo "mk-dynamic-probe: LLD version $actual_lld != $EXPECTED_LLD" >&2
	exit 1
}
actual_cargo=$(cargo --version)
[ "$actual_cargo" = "$EXPECTED_CARGO" ] || {
	echo "mk-dynamic-probe: Cargo version $actual_cargo != $EXPECTED_CARGO" >&2
	exit 1
}
actual_gcc=$(gcc --version | sed -n '1p')
[ "$actual_gcc" = "$EXPECTED_GCC" ] || {
	echo "mk-dynamic-probe: GCC version $actual_gcc != $EXPECTED_GCC" >&2
	exit 1
}
actual_ar=$(ar --version | sed -n '1p')
[ "$actual_ar" = "$EXPECTED_AR" ] || {
	echo "mk-dynamic-probe: ar version $actual_ar != $EXPECTED_AR" >&2
	exit 1
}
actual_nm=$(nm --version | sed -n '1p')
[ "$actual_nm" = "$EXPECTED_NM" ] || {
	echo "mk-dynamic-probe: nm version $actual_nm != $EXPECTED_NM" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT/obj"
export SOURCE_DATE_EPOCH=0
export LC_ALL=C
export TZ=UTC
export CARGO_TARGET_DIR="$OUT/cargo-target"

cargo build --locked --offline --manifest-path rust/Cargo.toml --target aarch64-unknown-none -p house-el0-tiny
ARCHIVE="$CARGO_TARGET_DIR/aarch64-unknown-none/debug/libhouse_el0_tiny.a"
[ -f "$ARCHIVE" ] || {
	echo "mk-dynamic-probe: missing $ARCHIVE" >&2
	exit 1
}

MEMBER=$(ar t "$ARCHIVE" | grep -E '^house_el0_tiny-.*\.rcgu\.o$' || true)
MEMBER_COUNT=$(printf '%s\n' "$MEMBER" | sed '/^$/d' | wc -l | tr -d ' ')
[ "$MEMBER_COUNT" -eq 1 ] || {
	echo "mk-dynamic-probe: expected one crate object, found $MEMBER_COUNT" >&2
	exit 1
}
(cd "$OUT/obj" && ar x "$ROOT/$ARCHIVE" "$MEMBER")
OBJ="$OUT/obj/$MEMBER"

UNWIND=$(nm "$OBJ" | awk '$2 == "T" && $3 ~ /rust_begin_unwind$/ {print $3}')
[ -n "$UNWIND" ] || {
	echo "mk-dynamic-probe: missing rust_begin_unwind export" >&2
	exit 1
}
cat >"$OUT/exports.map" <<EOF
{
  global:
    memcpy;
    memset;
    strlen;
    strncmp;
    $UNWIND;
  local:
    *;
};
EOF

ld.lld -shared --gc-sections --fatal-warnings \
	--soname="$SONAME" --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	--version-script="$OUT/exports.map" \
	-o "$OUT/$SONAME" "$OBJ"

gcc -c build-probe/hello-dyn.s -o "$OUT/hello.o"
nm "$OUT/hello.o" | awk '$1 == "U" && $2 == "strlen" {found = 1} END {exit !found}' || {
	echo "mk-dynamic-probe: hello-dyn.s does not import strlen" >&2
	exit 1
}
ld.lld -pie --gc-sections --fatal-warnings \
	--dynamic-linker=/lib/ld-house.so.0 --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	-L"$OUT" -o "$OUT/hello-dyn" "$OUT/hello.o" "-l:$SONAME"

cat >"$OUT/mid-exports.map" <<'EOF'
{
  global:
    house_pad;
    house_len;
  local:
    *;
};
EOF
gcc -c build-probe/hello-pad.s -o "$OUT/hello-pad.o"
nm "$OUT/hello-pad.o" | awk '$1 == "U" && $2 == "strlen" {found = 1} END {exit !found}' || {
	echo "mk-dynamic-probe: hello-pad.s does not import strlen" >&2
	exit 1
}
ld.lld -shared --gc-sections --fatal-warnings \
	--soname="$MID_SONAME" --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none --no-as-needed \
	--version-script="$OUT/mid-exports.map" \
	-L"$OUT" -l:"$SONAME" -o "$OUT/$MID_SONAME" "$OUT/hello-pad.o"

gcc -c build-probe/hello-dyn-deep.s -o "$OUT/hello-deep.o"
nm "$OUT/hello-deep.o" | awk '$1 == "U" && $2 == "house_pad" {found = 1} END {exit !found}' || {
	echo "mk-dynamic-probe: hello-dyn-deep.s does not import house_pad" >&2
	exit 1
}
nm "$OUT/hello-deep.o" | awk '$1 == "U" && $2 == "house_len" {found = 1} END {exit !found}' || {
	echo "mk-dynamic-probe: hello-dyn-deep.s does not import house_len" >&2
	exit 1
}
ld.lld -pie --gc-sections --fatal-warnings \
	--dynamic-linker=/lib/ld-house.so.0 --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	-L"$OUT" -o "$OUT/hello-dyn-deep" "$OUT/hello-deep.o" \
	"-l:$MID_SONAME" "-l:$SONAME"

ld.lld -shared --gc-sections --fatal-warnings \
	--soname=libc-missing.so.0 --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	--version-script="$OUT/exports.map" \
	-o "$OUT/libc-missing.so.0" "$OBJ"

ld.lld -pie --gc-sections --fatal-warnings \
	--dynamic-linker=/lib/ld-house.so.0 --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	-L"$OUT" -o "$OUT/hello-dyn-missing" "$OUT/hello.o" \
	"-l:libc-missing.so.0"

gcc -c build-probe/exec-dyn.s -o "$OUT/exec-dyn.o"
ld.lld --gc-sections --fatal-warnings --build-id=none \
	-T build-probe/exec.ld -o "$OUT/exec-dyn" "$OUT/exec-dyn.o"

printf '%s  %s\n' "$(sha256sum "$OUT/$SONAME" | cut -d' ' -f1)" "$SONAME"
printf '%s  %s\n' "$(sha256sum "$OUT/hello-dyn" | cut -d' ' -f1)" "hello-dyn"
printf '%s  %s\n' "$(sha256sum "$OUT/$MID_SONAME" | cut -d' ' -f1)" "$MID_SONAME"
printf '%s  %s\n' "$(sha256sum "$OUT/hello-dyn-deep" | cut -d' ' -f1)" "hello-dyn-deep"
printf '%s  %s\n' "$(sha256sum "$OUT/libc-missing.so.0" | cut -d' ' -f1)" "libc-missing.so.0"
printf '%s  %s\n' "$(sha256sum "$OUT/hello-dyn-missing" | cut -d' ' -f1)" "hello-dyn-missing"
printf '%s  %s\n' "$(sha256sum "$OUT/exec-dyn" | cut -d' ' -f1)" "exec-dyn"
echo "mk-dynamic-probe: $OUT"
