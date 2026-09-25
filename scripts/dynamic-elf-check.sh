#!/bin/sh
# M2.0/M2.1 dynamic-ELF compatibility and pure-link gate. Runs inside
# house-port:latest on linux/arm64; builds twice, audits both artifacts, checks
# the bounded loader before and after repacking, and compares deterministic
# logical link plans without mapping or executing either object.
set -eu

cd "$(dirname "$0")/.."
WORK=build/dynamic-probe/check
SONAME=libc-house.so.0
INTERP=/lib/ld-house.so.0
EXPECTED_SONAME_SHA=ebcc38e958debe4eb18caec30ca5302c3a649aa25741bbb137d0dcbec86f8cbe
EXPECTED_HELLO_SHA=26e1f4265882441b717bfc5a963295c65ff962cf9fdef20d21b6b325e8503fe7

cleanup() {
	rm -rf initramfs-staging/bin
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"
sh scripts/mk-userspace.sh >/dev/null

sh scripts/mk-dynamic-probe.sh build-a
sh scripts/mk-dynamic-probe.sh build-b
A=build/dynamic-probe/build-a
B=build/dynamic-probe/build-b

for name in "$SONAME" hello-dyn; do
	hash_a=$(sha256sum "$A/$name" | cut -d' ' -f1)
	hash_b=$(sha256sum "$B/$name" | cut -d' ' -f1)
	if [ "$hash_a" != "$hash_b" ]; then
		echo "dynamic-elf-check: $name is not reproducible" >&2
		exit 1
	fi
	case "$name" in
	"$SONAME") expected_sha=$EXPECTED_SONAME_SHA ;;
	hello-dyn) expected_sha=$EXPECTED_HELLO_SHA ;;
	*) expected_sha= ;;
	esac
	[ -z "$expected_sha" ] || [ "$hash_a" = "$expected_sha" ] || {
		echo "dynamic-elf-check: $name hash $hash_a != pinned $expected_sha" >&2
		exit 1
	}
done

cabal build exe:house-loader-check
LOADER_CHECK=$(cabal list-bin exe:house-loader-check 2>/dev/null | tail -1)
[ -x "$LOADER_CHECK" ] || {
	echo "dynamic-elf-check: house-loader-check is not executable" >&2
	exit 1
}

cat >"$WORK/expected-exports" <<'EOF'
_RNvCshKLH2LI99iV_7___rustc17rust_begin_unwind
memcpy
memset
strlen
strncmp
EOF
LC_ALL=C sort -o "$WORK/expected-exports" "$WORK/expected-exports"

audit_symbols() {
	artifact=$1
	undefined=$(nm -D --undefined-only "$artifact" || true)
	if [ -n "$undefined" ]; then
		echo "dynamic-elf-check: unexpected undefined symbols in $artifact" >&2
		echo "$undefined" >&2
		return 1
	fi
	nm -D --defined-only --format=posix "$artifact" | awk '{print $1}' | LC_ALL=C sort >"$WORK/actual-exports"
	if ! cmp -s "$WORK/expected-exports" "$WORK/actual-exports"; then
		echo "dynamic-elf-check: export-set drift in $artifact" >&2
		diff -u "$WORK/expected-exports" "$WORK/actual-exports" >&2 || true
		return 1
	fi
}

audit_common() {
	artifact=$1
	readelf -hW "$artifact" | grep -q 'Type:.*DYN' || {
		echo "dynamic-elf-check: $artifact is not ET_DYN" >&2
		exit 1
	}
	readelf -hW "$artifact" | grep -q 'Machine:.*AArch64' || {
		echo "dynamic-elf-check: $artifact is not AArch64" >&2
		exit 1
	}
	readelf -lW "$artifact" | grep -q 'GNU_RELRO' || {
		echo "dynamic-elf-check: $artifact has no RELRO" >&2
		exit 1
	}
	if readelf -lW "$artifact" | grep -q '  TLS'; then
		echo "dynamic-elf-check: $artifact has TLS segments" >&2
		exit 1
	fi
	readelf -dW "$artifact" | grep -q 'BIND_NOW' || {
		echo "dynamic-elf-check: $artifact is not bind-now" >&2
		exit 1
	}
	readelf -dW "$artifact" | grep -q 'FLAGS_1.*NOW' || {
		echo "dynamic-elf-check: $artifact lacks DF_1_NOW" >&2
		exit 1
	}
	readelf -dW "$artifact" | grep -q '(HASH)' || {
		echo "dynamic-elf-check: $artifact lacks SysV HASH" >&2
		exit 1
	}
	if readelf -dW "$artifact" | grep -q '(GNU_HASH)\|TEXTREL\|(TLS'; then
		echo "dynamic-elf-check: $artifact has rejected dynamic metadata" >&2
		exit 1
	fi
}

soname=$(readelf -dW "$A/$SONAME" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
[ "$soname" = "$SONAME" ] || {
	echo "dynamic-elf-check: SONAME allowlist failed: $soname" >&2
	exit 1
}
needed_count=$(readelf -dW "$A/$SONAME" | grep -c '(NEEDED)' || true)
[ "$needed_count" -eq 0 ] || {
	echo "dynamic-elf-check: shared library has NEEDED entries" >&2
	exit 1
}
if readelf -dW "$A/$SONAME" | grep -Eq 'libc\.so|libm\.so|libgcc|ld-linux|ld-house'; then
	echo "dynamic-elf-check: shared library has a forbidden dependency" >&2
	exit 1
fi
audit_symbols "$A/$SONAME"
audit_common "$A/$SONAME"

interp=$(readelf -lW "$A/hello-dyn" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
[ "$interp" = "$INTERP" ] || {
	echo "dynamic-elf-check: INTERP allowlist failed: $interp" >&2
	exit 1
}
needed=$(readelf -dW "$A/hello-dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
[ "$needed" = "$SONAME" ] || {
	echo "dynamic-elf-check: NEEDED allowlist failed: $needed" >&2
	exit 1
}
needed_count=$(readelf -dW "$A/hello-dyn" | grep -c '(NEEDED)' || true)
[ "$needed_count" -eq 1 ] || {
	echo "dynamic-elf-check: hello-dyn NEEDED count is $needed_count" >&2
	exit 1
}
if readelf -dW "$A/hello-dyn" | grep -q '(SONAME)'; then
	echo "dynamic-elf-check: executable unexpectedly has SONAME" >&2
	exit 1
fi
readelf -rW "$A/hello-dyn" | grep -q 'R_AARCH64_JUMP_SLOT.*strlen' || {
	echo "dynamic-elf-check: hello-dyn lacks a real strlen JUMP_SLOT" >&2
	exit 1
}
audit_common "$A/hello-dyn"

"$LOADER_CHECK" "$A/$SONAME" >"$WORK/libc.loader"
"$LOADER_CHECK" "$A/hello-dyn" >"$WORK/hello.loader"
python3 build-probe/repack.py "$A/$SONAME" "$WORK/libc-house.repacked"
python3 build-probe/repack.py "$A/hello-dyn" "$WORK/hello-dyn.repacked"
"$LOADER_CHECK" "$WORK/libc-house.repacked" >"$WORK/libc.repacked.loader"
"$LOADER_CHECK" "$WORK/hello-dyn.repacked" >"$WORK/hello.repacked.loader"
cmp "$WORK/libc.loader" "$WORK/libc.repacked.loader"
sed -E 's/ offset=[0-9]+/ offset=<file-offset>/' "$WORK/hello.loader" >"$WORK/hello.normalized"
sed -E 's/ offset=[0-9]+/ offset=<file-offset>/' "$WORK/hello.repacked.loader" >"$WORK/hello.repacked.normalized"
cmp "$WORK/hello.normalized" "$WORK/hello.repacked.normalized"

"$LOADER_CHECK" link "$A/hello-dyn" "$A/$SONAME" >"$WORK/link-a"
"$LOADER_CHECK" link "$B/hello-dyn" "$B/$SONAME" >"$WORK/link-b"
"$LOADER_CHECK" link "$WORK/hello-dyn.repacked" "$WORK/libc-house.repacked" >"$WORK/link-repacked"
cmp "$WORK/link-a" "$WORK/link-b"
cmp "$WORK/link-a" "$WORK/link-repacked"
cat >"$WORK/expected-link" <<'EOF'
object=main base=0x1000000 entry=0x1010290
object=libc-house.so.0 base=0x1030000 entry=0x1030000
relocation object=main provider=libc-house.so.0 symbol=strlen type=R_AARCH64_JUMP_SLOT target=0x10203f8 resolved=0x10404b4
EOF
cmp "$WORK/expected-link" "$WORK/link-a"

printf 'not an elf\n' >"$WORK/malformed"
if "$LOADER_CHECK" link "$WORK/malformed" >"$WORK/malformed.link.out" 2>"$WORK/malformed.link.err"; then
	echo "dynamic-elf-check: malformed link input was not rejected" >&2
	exit 1
fi
grep -q 'Truncated' "$WORK/malformed.link.err"
if "$LOADER_CHECK" link "$A/hello-dyn" >"$WORK/missing.link.out" 2>"$WORK/missing.link.err"; then
	echo "dynamic-elf-check: missing link dependency was not rejected" >&2
	exit 1
fi
grep -q 'missing dependency libc-house.so.0' "$WORK/missing.link.err"

cat >"$WORK/leaf.s" <<'EOF'
.arch armv8-a
.text
.global leaf
.type leaf,%function
leaf:
    ret
.section .note.GNU-stack,"",%progbits
EOF
cat >"$WORK/mid.s" <<'EOF'
.arch armv8-a
.text
.global strlen
.type strlen,%function
strlen:
    bl leaf
    ret
.section .note.GNU-stack,"",%progbits
EOF
gcc -fPIC -c "$WORK/leaf.s" -o "$WORK/leaf.o"
gcc -fPIC -c "$WORK/mid.s" -o "$WORK/mid.o"
SOURCE_DATE_EPOCH=0 ld.lld -shared --soname=libleaf.so.0 --hash-style=sysv \
	-z now -z relro -z noseparate-code --build-id=none \
	-o "$WORK/libleaf.so.0" "$WORK/leaf.o"
SOURCE_DATE_EPOCH=0 ld.lld -shared --soname="$SONAME" --hash-style=sysv \
	-z now -z relro -z noseparate-code --build-id=none --no-as-needed \
	-L"$WORK" -l:libleaf.so.0 -o "$WORK/libmid.so.0" "$WORK/mid.o"
readelf -dW "$WORK/libmid.so.0" | grep -q '(NEEDED).*libleaf.so.0'
if "$LOADER_CHECK" link "$A/hello-dyn" "$WORK/libmid.so.0" >"$WORK/incomplete.link.out" 2>"$WORK/incomplete.link.err"; then
	echo "dynamic-elf-check: incomplete transitive link was not rejected" >&2
	exit 1
fi
grep -q 'missing dependency libleaf.so.0' "$WORK/incomplete.link.err"

cat >"$WORK/bad-u.s" <<'EOF'
.arch armv8-a
.text
.global bad_u
bad_u:
    bl uart_putc
    ret
.section .note.GNU-stack,"",%progbits
EOF
gcc -c "$WORK/bad-u.s" -o "$WORK/bad-u.o"
SOURCE_DATE_EPOCH=0 ld.lld -shared --soname="$SONAME" --hash-style=sysv \
	-z now -z relro -z noseparate-code --build-id=none \
	-o "$WORK/bad-u.so" "$WORK/bad-u.o"
if audit_symbols "$WORK/bad-u.so" >/dev/null 2>&1; then
	echo "dynamic-elf-check: injected U uart_putc was not rejected" >&2
	exit 1
fi

dd if=/dev/zero of="$WORK/oversized" bs=1 count=0 seek=1048577 >/dev/null 2>&1
if "$LOADER_CHECK" "$WORK/oversized" >/dev/null 2>&1; then
	echo "dynamic-elf-check: oversized Loader input was not rejected" >&2
	exit 1
fi
if python3 build-probe/repack.py "$WORK/oversized" "$WORK/oversized.repacked" >/dev/null 2>&1; then
	echo "dynamic-elf-check: oversized repacker input was not rejected" >&2
	exit 1
fi
if "$LOADER_CHECK" link "$WORK/oversized" "$A/$SONAME" >"$WORK/oversized.link.out" 2>"$WORK/oversized.link.err"; then
	echo "dynamic-elf-check: oversized link input was not rejected" >&2
	exit 1
fi
grep -q 'file exceeds maxElfBytes' "$WORK/oversized.link.err"

if find initramfs-staging -type f \( -name 'ld-house.so*' -o -name 'libc-house.so*' -o -name 'hello-dyn*' \) -print -quit | grep -q .; then
	echo "dynamic-elf-check: M2.1 must not ship dynamic probe/library files" >&2
	exit 1
fi

printf '%s  %s\n' "$(sha256sum "$A/$SONAME" | cut -d' ' -f1)" "$SONAME"
printf '%s  %s\n' "$(sha256sum "$A/hello-dyn" | cut -d' ' -f1)" "hello-dyn"
echo "dynamic-elf-check: reproducible artifacts, bounded parser, repacker, and pure link plan agree"
