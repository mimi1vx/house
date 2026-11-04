#!/bin/sh
# nm audit for rust/crates/house-el0-tiny.
# Runs INSIDE the linux/arm64 container (needs the cross archive + GNU nm).
# Asserts the crate's own object exports exactly the helper set (the 39
# original helpers plus the house-q0g.4 EL0 gap shims) plus the EXIT(1)
# panic handler, with no undefined symbols: EL0 binaries then stay at asm
# scale under --gc-sections. Data homes (`environ`, `stderr`) are global
# BSS/DATA, not text, and are audited separately.
# B1 shared flavour: `ld.lld -shared` from this object (cdylib is dropped as
# unsupported on `aarch64-unknown-none`) carries the same set for GHC
# rebuilds; `nm -D` must match the recorded allowlists with no U.
# Dead core-generic instantiations (`_RINv*4core*`, e.g. an unreferenced
# `fabs`): tolerated in the object T count and echoed, never pinned by
# name (the mangling embeds a toolchain disambiguator); `--gc-sections`
# drops them from every link, and the DSO dynamic set below stays exact.
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
access
acoshf
asinf
atanf
putenv
__errno_location
__xpg_strerror_r
_Exit
_exit
abort
acos
acosh
acosf
asin
asinh
asinhf
atan
atanh
atanhf
calloc
chmod
clock_getres
clock_gettime
close
cos
cosf
cosh
coshf
creat
dup
dup2
epoll_create
epoll_ctl
epoll_wait
eventfd
eventfd_write
exit
exp
expf
expm1
expm1f
fcntl
fcntl64
fflush
flock
fopen
fork
fprintf
fputc
fputs
free
freelocale
fstat
ftruncate
fwrite
getenv
getpid
getrusage
iconv
iconv_close
iconv_open
isatty
ldexp
link
log
log1p
log1pf
logf
lseek
lstat
malloc
memchr
memcmp
memcpy
memmove
memset
mkfifo
newlocale
nl_langinfo
open
pipe
poll
pow
powf
printf
putchar
puts
read
readlink
realloc
setenv
setlocale
sigaddset
sigemptyset
sigprocmask
sin
sinf
sinh
sinhf
snprintf
sprintf
stat
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
sysconf
tan
tanf
tanh
tanhf
tcgetattr
tcsetattr
times
umask
unlink
unsetenv
uselocale
utime
vfprintf
vprintf
vsnprintf
waitpid
write
EOF
LC_ALL=C sort -o "$tmpdir/allowlist" "$tmpdir/allowlist"
# Data homes live in BSS/DATA, not text: separate allowlist, same pinning.
cat >"$tmpdir/allowlist-data" <<'EOF'
environ
stderr
EOF
while IFS= read -r sym; do
	if ! echo "$T" | grep -qx "$sym"; then
		echo "el0tiny: missing T $sym" >&2
		exit 1
	fi
done <"$tmpdir/allowlist"
while IFS= read -r sym; do
	if ! nm "$tmpdir/$M" | grep -qE " [BDR] $sym\$"; then
		echo "el0tiny: missing global data $sym" >&2
		exit 1
	fi
done <"$tmpdir/allowlist-data"
if ! echo "$T" | grep -q "rust_begin_unwind"; then
	echo "el0tiny: missing T rust_begin_unwind" >&2
	exit 1
fi
# No real-symbol drift: every text symbol is either allowlisted, the unwind
# handler, or a dead core-generic instantiation (dropped at link).
echo "$T" >"$tmpdir/t-all"
CORE_IGNORED=$(comm -23 "$tmpdir/t-all" "$tmpdir/allowlist" | grep -E '^_RINv.*4core' || true)
UNEXPECTED=$(comm -23 "$tmpdir/t-all" "$tmpdir/allowlist" | grep -vE '^_RINv.*4core' | grep -v 'rust_begin_unwind$' || true)
if [ -n "$UNEXPECTED" ]; then
	echo "el0tiny: unexpected T symbols:" >&2
	echo "$UNEXPECTED" >&2
	exit 1
fi
if [ -n "$CORE_IGNORED" ]; then
	echo "el0tiny: ignoring dead core-generic text (dropped at link):"
	echo "$CORE_IGNORED"
fi
echo "el0tiny-check: static ok (131 helpers + 2 data + unwind, no U)"
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
	while IFS= read -r sym; do
		printf '    %s;\n' "$sym"
	done <"$tmpdir/allowlist-data"
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
cat "$tmpdir/allowlist" "$tmpdir/allowlist-data" | LC_ALL=C sort >"$tmpdir/expected-stable"
if ! cmp -s "$tmpdir/expected-stable" "$tmpdir/so-stable"; then
	echo "el0tiny: dynamic export-set drift in $SO" >&2
	diff -u "$tmpdir/expected-stable" "$tmpdir/so-stable" >&2 || true
	exit 1
fi
nm -D --undefined-only --format=posix "$SO" 2>/dev/null | awk 'NF {print $1}' | LC_ALL=C sort >"$tmpdir/so-undefined"
if [ -s "$tmpdir/so-undefined" ]; then
	echo "el0tiny: unexpected U in $SO:" >&2
	cat "$tmpdir/so-undefined" >&2
	exit 1
fi
echo "el0tiny-check: shared ok (ET_DYN aarch64, 131 + 2 data + unwind, no U)"
echo "el0tiny-check: ok (131 helpers + 2 data + unwind, no U)"
rm -rf "$tmpdir"
trap - EXIT
