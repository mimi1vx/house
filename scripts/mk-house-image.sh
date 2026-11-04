#!/bin/sh
# Build the House-targeted dynamic Haskell image: one fully dynamic PIE
# executable plus the transitive DT_NEEDED closure the pinned toolchain links
# against, then record the observed dynamic properties the Loader's
# accept/reject decision depends on. Runs inside the linux/arm64 house-port
# container; every generated file stays below build/dynamic-probe/.
set -eu

cd "$(dirname "$0")/.."
NAME=${1:-house-image}
case "$NAME" in
"" | *[!A-Za-z0-9._-]*)
	echo "mk-house-image: invalid output name: $NAME" >&2
	exit 1
	;;
esac

OUT="build/dynamic-probe/$NAME"
EXPECTED_GHC=9.14.1
EXPECTED_GCC='gcc (Debian 14.2.0-19) 14.2.0'
EXPECTED_LD='GNU ld (GNU Binutils for Debian) 2.44'
EXPECTED_READELF='GNU readelf (GNU Binutils for Debian) 2.44'
EXPECTED_LLD='Debian LLD 19.1.7 (compatible with GNU linkers)'
EXPECTED_NM='GNU nm (GNU Binutils for Debian) 2.44'
EXPECTED_AR='GNU ar (GNU Binutils for Debian) 2.44'
TOOLCHAIN_TOML="rust-toolchain.toml"
TOOLCHAIN_LOCK="rust/toolchain.lock"
CHANNEL=$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$TOOLCHAIN_TOML")
[ -n "$CHANNEL" ] || {
	echo "mk-house-image: missing channel in $TOOLCHAIN_TOML" >&2
	exit 1
}
LOCK_CHANNEL=$(sed -n 's/^channel *= *"\([^"]*\)".*/\1/p' "$TOOLCHAIN_LOCK")
[ -n "$LOCK_CHANNEL" ] || {
	echo "mk-house-image: missing channel in $TOOLCHAIN_LOCK" >&2
	exit 1
}
[ "$CHANNEL" = "$LOCK_CHANNEL" ] || {
	echo "mk-house-image: channel $CHANNEL != lock $LOCK_CHANNEL (update $TOOLCHAIN_LOCK with the bump)" >&2
	exit 1
}
EXPECTED_RUSTC_COMMIT=$(sed -n 's/^rustc_commit *= *"\([^"]*\)".*/\1/p' "$TOOLCHAIN_LOCK")
EXPECTED_CARGO=$(sed -n 's/^cargo_version *= *"\([^"]*\)".*/\1/p' "$TOOLCHAIN_LOCK")
[ -n "$EXPECTED_RUSTC_COMMIT" ] || {
	echo "mk-house-image: missing rustc_commit in $TOOLCHAIN_LOCK" >&2
	exit 1
}
[ -n "$EXPECTED_CARGO" ] || {
	echo "mk-house-image: missing cargo_version in $TOOLCHAIN_LOCK" >&2
	exit 1
}
INTERP=/lib/ld-house.so.0
# The three candidate flags the manifest shows taking effect; the linker emits
# neither SysV hash, nor eager binding, nor a House interp on its own.
LINK="-optl-Wl,--hash-style=sysv -optl-Wl,-z,now -optl-Wl,--dynamic-linker=$INTERP"
# Struck: --disable-new-dtags only turns DT_RUNPATH into the untolerated DT_RPATH.
# Struck: -rpath,/lib only appends to the runpath the linker always emits, and
#   runpath=1 either way, while DT_RUNPATH is a tag the Loader tolerates.
# Struck: --pack-dyn-relocs=gnu-relr is an unrecognised ld 2.44 option and no
#   flag here emits DT_RELR, so relr=0 unflagged and nothing suppresses it.

actual_ghc=$(ghc --numeric-version)
[ "$actual_ghc" = "$EXPECTED_GHC" ] || {
	echo "mk-house-image: GHC version $actual_ghc != $EXPECTED_GHC" >&2
	exit 1
}
actual_gcc=$(gcc --version | sed -n '1p')
[ "$actual_gcc" = "$EXPECTED_GCC" ] || {
	echo "mk-house-image: GCC version $actual_gcc != $EXPECTED_GCC" >&2
	exit 1
}
actual_ld=$(ld --version | sed -n '1p')
[ "$actual_ld" = "$EXPECTED_LD" ] || {
	echo "mk-house-image: ld version $actual_ld != $EXPECTED_LD" >&2
	exit 1
}
actual_readelf=$(readelf --version | sed -n '1p')
[ "$actual_readelf" = "$EXPECTED_READELF" ] || {
	echo "mk-house-image: readelf version $actual_readelf != $EXPECTED_READELF" >&2
	exit 1
}
actual_rustc_commit=$(rustc -Vv | sed -n 's/^commit-hash: //p')
[ "$actual_rustc_commit" = "$EXPECTED_RUSTC_COMMIT" ] || {
	echo "mk-house-image: rustc commit $actual_rustc_commit != $EXPECTED_RUSTC_COMMIT" >&2
	exit 1
}
actual_cargo=$(cargo --version)
[ "$actual_cargo" = "$EXPECTED_CARGO" ] || {
	echo "mk-house-image: Cargo version $actual_cargo != $EXPECTED_CARGO" >&2
	exit 1
}
actual_lld=$(ld.lld --version)
[ "$actual_lld" = "$EXPECTED_LLD" ] || {
	echo "mk-house-image: LLD version $actual_lld != $EXPECTED_LLD" >&2
	exit 1
}
actual_nm=$(nm --version | sed -n '1p')
[ "$actual_nm" = "$EXPECTED_NM" ] || {
	echo "mk-house-image: nm version $actual_nm != $EXPECTED_NM" >&2
	exit 1
}
actual_ar=$(ar --version | sed -n '1p')
[ "$actual_ar" = "$EXPECTED_AR" ] || {
	echo "mk-house-image: ar version $actual_ar != $EXPECTED_AR" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT/build"
export SOURCE_DATE_EPOCH=0
export LC_ALL=C
export TZ=UTC

GHC_LIB_ROOT=$(dirname "$(ghc --print-libdir)")/lib
CLOSURE_DIRS=$(ls -d "$GHC_LIB_ROOT"/aarch64-linux-ghc-"$EXPECTED_GHC"-* 2>/dev/null || true)
[ "$(printf '%s\n' "$CLOSURE_DIRS" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || {
	echo "mk-house-image: expected exactly one GHC $EXPECTED_GHC dynamic package closure dir" >&2
	exit 1
}

# B2 provenance (ii): the house overlay. house-libs/ carries the objects the
# loader can already parse: libc-house.so.0 (the el0tiny shared flavour, same
# recipe and export set as mk-dynamic-probe.sh) and a rebuilt libHSghc-prim
# (the bindist archive re-linked sysv/bind-now/RELRO, NEEDED on house-libc
# plus the B3-owned internal object). libHSbase and libHSghc-internal stay
# stock: bindist archives are vanilla non-PIC objects (ld.lld refuses them
# with R_AARCH64_ADR_PREL_PG_HI21, and TEXTREL output is loader-refused), so
# their rebuild needs dynamic objects from a source-built GHC, not this
# recipe. The main link below takes -Lhouse-libs first, so the rebuilt prim
# shadows the stock file; --trace proves it in build.log.
HOUSE_LIBS="$OUT/house-libs"
HOUSE_ABS="$PWD/$HOUSE_LIBS"
mkdir -p "$HOUSE_LIBS"
export CARGO_TARGET_DIR="$OUT/cargo-target"
cargo build --locked --offline --manifest-path rust/Cargo.toml --target aarch64-unknown-none -p house-el0-tiny
TINY_A="$CARGO_TARGET_DIR/aarch64-unknown-none/debug/libhouse_el0_tiny.a"
[ -f "$TINY_A" ] || {
	echo "mk-house-image: missing $TINY_A" >&2
	exit 1
}
TINY_M=$(ar t "$TINY_A" | grep -E '^house_el0_tiny-.*\.rcgu\.o$')
[ "$(printf '%s\n' "$TINY_M" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || {
	echo "mk-house-image: expected one crate object, found: $TINY_M" >&2
	exit 1
}
mkdir -p "$OUT/tiny-obj"
TINY_ABS="$PWD/$TINY_A"
(cd "$OUT/tiny-obj" && ar x "$TINY_ABS" "$TINY_M")
TINY_UNWIND=$(nm "$OUT/tiny-obj/$TINY_M" | awk '$2 == "T" && $3 ~ /rust_begin_unwind$/ {print $3}')
[ -n "$TINY_UNWIND" ] || {
	echo "mk-house-image: missing rust_begin_unwind export" >&2
	exit 1
}
cat >"$OUT/house-exports.map" <<EOF
{
  global:
    __assert_fail;
    __errno_location;
    _Exit;
    _exit;
    abort;
    exit;
    fflush;
    fprintf;
    fputc;
    fputs;
    freelocale;
    fwrite;
    memchr;
    memcmp;
    memcpy;
    memmove;
    memset;
    newlocale;
    nl_langinfo;
    printf;
    putchar;
    puts;
    setlocale;
    snprintf;
    sprintf;
    strcasecmp;
    strcat;
    strchr;
    strcmp;
    strcpy;
    strlen;
    strnlen;
    strncmp;
    strncpy;
    strrchr;
    uselocale;
    vfprintf;
    vprintf;
    vsnprintf;
    $TINY_UNWIND;
  local:
    *;
};
EOF
ld.lld -shared --gc-sections --fatal-warnings \
	--soname="libc-house.so.0" --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	--version-script="$OUT/house-exports.map" \
	-o "$HOUSE_LIBS/libc-house.so.0" "$OUT/tiny-obj/$TINY_M"
PRIM_PKG_DIR=$(ls -d "$CLOSURE_DIRS"/ghc-prim-* 2>/dev/null || true)
[ "$(printf '%s\n' "$PRIM_PKG_DIR" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || {
	echo "mk-house-image: expected exactly one ghc-prim package dir" >&2
	exit 1
}
# First pathname matching the glob in $1, skipping profiling (_p) variants;
# fails when zero or several match. (A case pattern inside $( ) breaks the
# old bash that parses this file on some hosts, so this loops instead of
# piping ls into grep.)
first_nonprof() {
	found=""
	# shellcheck disable=SC2086
	for cand in $1; do
		[ -e "$cand" ] || continue
		[ "$cand" = "${cand%_p*}" ] || continue
		[ -n "$found" ] && return 1
		found="$cand"
	done
	[ -n "$found" ] || return 1
	printf '%s\n' "$found"
}
PRIM_A=$(first_nonprof "$PRIM_PKG_DIR/libHSghc-prim-*.a") || {
	echo "mk-house-image: expected exactly one non-profiling ghc-prim archive" >&2
	exit 1
}
PRIM_SO=$(first_nonprof "$CLOSURE_DIRS/libHSghc-prim-*-ghc$EXPECTED_GHC.so") || {
	echo "mk-house-image: expected exactly one non-profiling ghc-prim shared object" >&2
	exit 1
}
[ "$(ar t "$PRIM_A" | wc -l | tr -d ' ')" -eq 1 ] || {
	echo "mk-house-image: expected one object in the ghc-prim archive (duplicate basenames need unique-name extraction)" >&2
	exit 1
}
PRIM_SONAME=$(basename "$PRIM_SO")
INTERNAL_SO=$(first_nonprof "$CLOSURE_DIRS/libHSghc-internal-*-ghc$EXPECTED_GHC.so") || {
	echo "mk-house-image: expected exactly one non-profiling ghc-internal shared object" >&2
	exit 1
}
nm --format=posix "$PRIM_A" | awk '$2 ~ /^[TDRBGC]$/ {print $1}' | LC_ALL=C sort -u >"$OUT/prim-globals"
[ -s "$OUT/prim-globals" ] || {
	echo "mk-house-image: no global symbols in the ghc-prim archive" >&2
	exit 1
}
{
	echo "{"
	echo "  global:"
	sed 's/.*/    &;/' "$OUT/prim-globals"
	echo "  local:"
	echo "    *;"
	echo "};"
} >"$OUT/prim.map"
ld.lld -shared --gc-sections --fatal-warnings \
	--soname="$PRIM_SONAME" --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	--version-script="$OUT/prim.map" \
	--no-as-needed -L"$HOUSE_LIBS" -l:libc-house.so.0 --as-needed "$INTERNAL_SO" \
	-o "$HOUSE_LIBS/$PRIM_SONAME" --whole-archive "$PRIM_A" --no-whole-archive
# Fidelity: the dynamic scope is exactly the archive's globals (the version
# script localises the linker-synthesised symbols, which the loader refuses
# as SHN_ABS), and no novel undefined symbol appears (dead weak imports drop
# out under --gc-sections).
nm -D --defined-only "$HOUSE_LIBS/$PRIM_SONAME" | awk '{print $3}' | LC_ALL=C sort -u >"$OUT/prim-new.def"
diff "$OUT/prim-globals" "$OUT/prim-new.def" || {
	echo "mk-house-image: rebuilt prim defined-set drift" >&2
	exit 1
}
nm -D --undefined-only "$PRIM_SO" | awk '{print $1 $2}' | LC_ALL=C sort >"$OUT/prim-old.u"
nm -D --undefined-only "$HOUSE_LIBS/$PRIM_SONAME" | awk '{print $1 $2}' | LC_ALL=C sort >"$OUT/prim-new.u"
comm -23 "$OUT/prim-new.u" "$OUT/prim-old.u" >"$OUT/prim-novel.u"
[ ! -s "$OUT/prim-novel.u" ] || {
	echo "mk-house-image: rebuilt prim gains undefined symbols:" >&2
	cat "$OUT/prim-novel.u" >&2
	exit 1
}
# Note: lld emits RELA/RELASZ/RELAENT but not the DT_RELACOUNT ornament that
# GNU ld adds, so the manifest relacount field reads 0 on house-linked
# objects. The loader skips that tag (Loader.hs SkipRelocationHint) and
# counts from RELASZ/RELAENT instead.
SEARCH_DIRS="$HOUSE_LIBS $CLOSURE_DIRS /lib/aarch64-linux-gnu /usr/lib"

printf 'main :: IO ()\nmain = putStrLn "Hello from House"\n' >"$OUT/build/Hello.hs"
# -L puts the overlay first so every libHS name resolves there; -rpath-link
# covers the overlay's own DT_NEEDED at link time without recording a runpath.
LINK="$LINK -optl-Wl,-rpath-link,$HOUSE_ABS -optl-Wl,--trace"
# Compiled from inside $OUT/build so the recorded input name is the bare
# basename and cannot leak the per-build output path into the artifact.
(cd "$OUT/build" && ghc -O0 -dynamic -fPIE -pie $LINK -L"$HOUSE_ABS" -o house-image Hello.hs) >"$OUT/build.log" 2>&1 || {
	echo "mk-house-image: the dynamic link failed" >&2
	cat "$OUT/build.log" >&2
	exit 1
}
grep -q "house-libs/$PRIM_SONAME" "$OUT/build.log" || {
	echo "mk-house-image: the main link did not take the rebuilt $PRIM_SONAME from the overlay" >&2
	exit 1
}
# The house probe: a minimal PIE main whose only import is one prim data
# symbol, so its closure is exactly {probe, rebuilt prim, house-libc}. The
# symbol name embeds the bindist package hash, so it is read off the rebuilt
# object rather than spelled here.
PRIM_SYM=$(nm -D --defined-only "$HOUSE_LIBS/$PRIM_SONAME" | awk '$2 == "D" {print $3}' | LC_ALL=C sort | head -1)
[ -n "$PRIM_SYM" ] || {
	echo "mk-house-image: no data symbol in the rebuilt $PRIM_SONAME" >&2
	exit 1
}
cat >"$OUT/build/house-probe.s" <<EOF
	.arch armv8-a
	.text
	.global _start
	.type _start, %function
_start:
	adrp	x0, :got:$PRIM_SYM
	ldr	x0, [x0, :got_lo12:$PRIM_SYM]
	mov	x0, #0
	svc	#0x02
	.section .note.GNU-stack,"",%progbits
EOF
gcc -c "$OUT/build/house-probe.s" -o "$OUT/build/house-probe.o"
ld.lld -pie --gc-sections --fatal-warnings \
	--dynamic-linker=$INTERP --hash-style=sysv \
	-z now -z relro -z noseparate-code \
	--no-undefined --build-id=none \
	-L"$HOUSE_LIBS" -o "$OUT/build/house-probe" "$OUT/build/house-probe.o" \
	"-l:$PRIM_SONAME" "-l:libc-house.so.0"
PROBE_NEEDED=$(readelf -dW "$OUT/build/house-probe" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
[ "$PROBE_NEEDED" = "$PRIM_SONAME libc-house.so.0 " ] || {
	echo "mk-house-image: probe NEEDED is '$PROBE_NEEDED', expected '$PRIM_SONAME libc-house.so.0 '" >&2
	exit 1
}
readelf -rW "$OUT/build/house-probe" | grep -q "R_AARCH64_GLOB_DAT.*$PRIM_SYM" || {
	echo "mk-house-image: probe lacks a GLOB_DAT relocation for $PRIM_SYM" >&2
	exit 1
}
MAIN="$OUT/build/house-image"
[ -f "$MAIN" ] || {
	echo "mk-house-image: missing $MAIN" >&2
	exit 1
}

elf_type() {
	readelf -hW "$1" | sed -n 's/^  Type: *\([A-Z]*\).*/\1/p'
}

elf_phnum() {
	readelf -hW "$1" | sed -n 's/.*Number of program headers: *//p'
}

elf_interp() {
	rec_interp=$(readelf -lW "$1" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
	printf '%s' "${rec_interp:--}"
}

# 1 when the dynamic section carries the named tag, 0 when it does not.
dyn_flag() {
	readelf -dW "$1" | grep -q "($2)" && printf 1 || printf 0
}

# DT_<name> byte count, 0 when the tag is absent.
dyn_bytes() {
	rec_bytes=$(readelf -dW "$1" | sed -n "s/.*($2) *\([0-9][0-9]*\).*/\1/p")
	printf '%s' "${rec_bytes:-0}"
}

dyn_needed() {
	readelf -dW "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ',' | sed 's/,$//'
}

dyn_bindnow() {
	readelf -dW "$1" |
		grep -Eq '\(BIND_NOW\)|\(FLAGS\) +BIND_NOW|\(FLAGS_1\) +Flags:.*NOW' && printf 1 || printf 0
}

elf_hash() {
	rec_dyn=$(readelf -dW "$1")
	if printf '%s\n' "$rec_dyn" | grep -q '(HASH)'; then
		printf sysv
	elif printf '%s\n' "$rec_dyn" | grep -q '(GNU_HASH)'; then
		printf gnu
	else
		printf none
	fi
}

elf_relro() {
	# 1 only when PT_GNU_RELRO is present and lies inside a PT_LOAD, which is
	# the shape the Loader accepts.
	readelf -lW "$1" | awk '
		$1 == "LOAD" { nload++; lov[nload] = hx($3); loi[nload] = hx($3) + hx($6) }
		$1 == "GNU_RELRO" { found = 1; rov = hx($3); roi = hx($3) + hx($5) }
		END {
			if (found && roi > rov) {
				for (i = 1; i <= nload; i++)
					if (rov >= lov[i] && rov < loi[i] && roi <= loi[i] && roi > lov[i]) {
						printf "1\n"
						exit
					}
			}
			printf "0\n"
		}
		function hx(s, i, c, v) {
			sub(/^0[xX]/, "", s)
			v = 0
			for (i = 1; i <= length(s); i++) {
				c = tolower(substr(s, i, 1))
				v = v * 16 + index("0123456789abcdef", c) - 1
			}
			return v
		}'
}

elf_tls() {
	if readelf -lW "$1" | grep -q '^  TLS'; then
		printf 1
		return
	fi
	readelf -dW "$1" | grep -Eq '\(TLS' && printf 1 || printf 0
}

elf_rela_count() {
	readelf -rW "$1" | awk '
		/^Relocation section/ { in_dyn = ($3 ~ /\.rela\.dyn/); in_plt = ($3 ~ /\.rela\.plt/); next }
		(in_dyn || in_plt) && /^[0-9a-f]+ +[0-9a-f]+ +R_/ { n++ }
		END { printf "%d\n", n + 0 }'
}

elf_reloc_types() {
	readelf -rW "$1" | awk '/^[0-9a-f]+ +[0-9a-f]+ +R_/ { print $3 }' |
		LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//'
}

elf_dynsyms() {
	readelf --dyn-syms -W "$1" | awk '/^ +[0-9]+: / { n++ } END { printf "%d\n", n + 0 }'
}

# The Loader's per-object page budget counts PT_LOAD pages, so the manifest
# records the same sum rather than the raw segment count. The ceil is per
# segment: int() truncates each term, so the fractions cannot carry.
elf_load_pages() {
	readelf -lW "$1" | awk '
		$1 == "LOAD" { fsz = hx($5); total += int((fsz + 4095) / 4096) }
		END { printf "%d\n", total + 0 }
		function hx(s, i, c, v) {
			sub(/^0[xX]/, "", s)
			v = 0
			for (i = 1; i <= length(s); i++) {
				c = tolower(substr(s, i, 1))
				v = v * 16 + index("0123456789abcdef", c) - 1
			}
			return v
		}'
}

record() {
	rec_name=$1
	rec_path=$2
	printf '%s\t' "$rec_name"
	printf 'type=%s,' "$(elf_type "$rec_path")"
	printf 'phnum=%s,' "$(elf_phnum "$rec_path")"
	printf 'interp=%s,' "$(elf_interp "$rec_path")"
	printf 'needed=%s,' "$(dyn_needed "$rec_path")"
	printf 'hash=%s,' "$(elf_hash "$rec_path")"
	printf 'bindnow=%s,' "$(dyn_bindnow "$rec_path")"
	printf 'relro=%s,' "$(elf_relro "$rec_path")"
	printf 'tls=%s,' "$(elf_tls "$rec_path")"
	printf 'init=%s,' "$(dyn_flag "$rec_path" INIT)"
	printf 'fini=%s,' "$(dyn_flag "$rec_path" FINI)"
	printf 'init_array=%s,' "$(dyn_bytes "$rec_path" INIT_ARRAYSZ)"
	printf 'fini_array=%s,' "$(dyn_bytes "$rec_path" FINI_ARRAYSZ)"
	printf 'verneed=%s,' "$(dyn_flag "$rec_path" VERNEED)"
	printf 'versym=%s,' "$(dyn_flag "$rec_path" VERSYM)"
	printf 'runpath=%s,' "$(dyn_flag "$rec_path" RUNPATH)"
	printf 'relacount=%s,' "$(dyn_flag "$rec_path" RELACOUNT)"
	printf 'relr=%s,' "$(dyn_flag "$rec_path" RELR)"
	printf 'textrel=%s,' "$(dyn_flag "$rec_path" TEXTREL)"
	printf 'rela_count=%s,' "$(elf_rela_count "$rec_path")"
	printf 'reloc_types=%s,' "$(elf_reloc_types "$rec_path")"
	printf 'dynsyms=%s,' "$(elf_dynsyms "$rec_path")"
	printf 'load_pages=%s\n' "$(elf_load_pages "$rec_path")"
}

resolve() {
	for rec_dir in $SEARCH_DIRS; do
		if [ -f "$rec_dir/$1" ]; then
			printf '%s\n' "$rec_dir/$1"
			return 0
		fi
	done
	echo "mk-house-image: unresolved DT_NEEDED $1" >&2
	exit 1
}

# Breadth-first from the main object, in DT_NEEDED order, so the record order
# is a property of the link and not of directory listing order.
: >"$OUT/seen"
printf 'main\t%s\n' "$MAIN" >"$OUT/pending"
: >"$OUT/manifest"
: >"$OUT/objects"
while [ -s "$OUT/pending" ]; do
	: >"$OUT/next"
	while IFS="$(printf '\t')" read -r rec_name rec_path; do
		record "$rec_name" "$rec_path" >>"$OUT/manifest"
		printf '%s\t%s\n' "$rec_name" "$rec_path" >>"$OUT/objects"
		readelf -dW "$rec_path" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' >"$OUT/needed"
		while read -r rec_soname; do
			[ -n "$rec_soname" ] || continue
			grep -qxF "$rec_soname" "$OUT/seen" && continue
			printf '%s\n' "$rec_soname" >>"$OUT/seen"
			printf '%s\t%s\n' "$rec_soname" "$(resolve "$rec_soname")" >>"$OUT/next"
		done <"$OUT/needed"
	done <"$OUT/pending"
	cp "$OUT/next" "$OUT/pending"
done
rm -f "$OUT/pending" "$OUT/next" "$OUT/needed" "$OUT/seen"

cat "$OUT/manifest"
printf '%s  %s\n' "$(sha256sum "$MAIN" | cut -d' ' -f1)" house-image
echo "mk-house-image: $OUT"
