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
SEARCH_DIRS="$CLOSURE_DIRS /lib/aarch64-linux-gnu /usr/lib"

printf 'main :: IO ()\nmain = putStrLn "Hello from House"\n' >"$OUT/build/Hello.hs"
# Compiled from inside $OUT/build so the recorded input name is the bare
# basename and cannot leak the per-build output path into the artifact.
(cd "$OUT/build" && ghc -O0 -dynamic -fPIE -pie $LINK -o house-image Hello.hs) >"$OUT/build.log" 2>&1 || {
	echo "mk-house-image: the dynamic link failed" >&2
	cat "$OUT/build.log" >&2
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
