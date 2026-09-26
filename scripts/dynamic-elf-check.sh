#!/bin/sh
# M2.0/M2.1/M2.2 dynamic-ELF compatibility, packaging, and runtime-artifact gate.
# Runs inside house-port:latest on linux/arm64. It builds the pinned dynamic
# artifacts twice, checks Loader/repacker parity, exercises failure cases, and
# verifies the minimized dynamic set staged into initramfs.
set -eu

cd "$(dirname "$0")/.."
WORK=build/dynamic-probe/check
SONAME=libc-house.so.0
MID_SONAME=libmid-house.so.0
MISSING_SONAME=libc-missing.so.0
DEEP_MAIN=hello-dyn-deep
INTERP=/lib/ld-house.so.0
ARTIFACTS="$SONAME $MID_SONAME $MISSING_SONAME hello-dyn $DEEP_MAIN hello-dyn-missing exec-dyn"
EXPECTED_SONAME_SHA=ebcc38e958debe4eb18caec30ca5302c3a649aa25741bbb137d0dcbec86f8cbe
EXPECTED_MID_SONAME_SHA=60f5ec18e338e678b75bce377f8f9b51cfe2ff7214ce3b21a7474fa8df8b6a9a
EXPECTED_HELLO_SHA=26e1f4265882441b717bfc5a963295c65ff962cf9fdef20d21b6b325e8503fe7
EXPECTED_DEEP_MAIN_SHA=62c71320f772008535f616955dee29ce01c66c909625d70bc3f877a95f7e0960
EXPECTED_MISSING_SONAME_SHA=abc7acfa562c5b2dfbda2ea943da70ad29a15590c33fedb0b6f400bf938b8b55
EXPECTED_MISSING_HELLO_SHA=50725e3a1cfe6344666ada25b5cd7d0c0502deab329f21fb89dece4834f1a943
EXPECTED_EXEC_SHA=f251fec290c2899d03d57be6e687a230566a1de2d87eda3d736d1d224223edf3

cleanup() {
	rm -rf initramfs-staging/bin initramfs-staging/lib
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"
sh scripts/mk-userspace.sh >/dev/null

sh scripts/mk-dynamic-probe.sh build-a
sh scripts/mk-dynamic-probe.sh build-b
A=build/dynamic-probe/build-a
B=build/dynamic-probe/build-b

for name in $ARTIFACTS; do
	hash_a=$(sha256sum "$A/$name" | cut -d' ' -f1)
	hash_b=$(sha256sum "$B/$name" | cut -d' ' -f1)
	if [ "$hash_a" != "$hash_b" ]; then
		echo "dynamic-elf-check: $name is not reproducible" >&2
		exit 1
	fi
	case "$name" in
	"$SONAME") expected_sha=$EXPECTED_SONAME_SHA ;;
	"$MID_SONAME") expected_sha=$EXPECTED_MID_SONAME_SHA ;;
	"$MISSING_SONAME") expected_sha=$EXPECTED_MISSING_SONAME_SHA ;;
	hello-dyn) expected_sha=$EXPECTED_HELLO_SHA ;;
	"$DEEP_MAIN") expected_sha=$EXPECTED_DEEP_MAIN_SHA ;;
	hello-dyn-missing) expected_sha=$EXPECTED_MISSING_HELLO_SHA ;;
	exec-dyn) expected_sha=$EXPECTED_EXEC_SHA ;;
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

printf '%s\n' house_pad house_len >"$WORK/expected-exports-mid"
LC_ALL=C sort -o "$WORK/expected-exports-mid" "$WORK/expected-exports-mid"
: >"$WORK/expected-undefined-none"
printf '%s\n' strlen >"$WORK/expected-undefined-mid"

# $2 and $3 name the files holding that artifact's exact defined and undefined
# dynamic symbol sets. An artifact with no entry here falls through to the libc
# sets, so an unlisted export or import still fails.
audit_symbols() {
	artifact=$1
	expected=${2:-$WORK/expected-exports}
	expected_undefined=${3:-$WORK/expected-undefined-none}
	nm -D --undefined-only --format=posix "$artifact" 2>/dev/null |
		awk 'NF {print $1}' | LC_ALL=C sort >"$WORK/actual-undefined"
	if ! cmp -s "$expected_undefined" "$WORK/actual-undefined"; then
		echo "dynamic-elf-check: undefined-symbol drift in $artifact" >&2
		diff -u "$expected_undefined" "$WORK/actual-undefined" >&2 || true
		return 1
	fi
	nm -D --defined-only --format=posix "$artifact" | awk '{print $1}' | LC_ALL=C sort >"$WORK/actual-exports"
	if ! cmp -s "$expected" "$WORK/actual-exports"; then
		echo "dynamic-elf-check: export-set drift in $artifact" >&2
		diff -u "$expected" "$WORK/actual-exports" >&2 || true
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
	if readelf -dW "$artifact" | grep -Eq 'GNU_HASH|TEXTREL|\(TLS'; then
		echo "dynamic-elf-check: $artifact has rejected dynamic metadata" >&2
		exit 1
	fi
}

audit_exec() {
	artifact=$1
	readelf -hW "$artifact" | grep -q 'Type:.*EXEC' || {
		echo "dynamic-elf-check: $artifact is not ET_EXEC" >&2
		exit 1
	}
	readelf -hW "$artifact" | grep -q 'Machine:.*AArch64' || {
		echo "dynamic-elf-check: $artifact is not AArch64" >&2
		exit 1
	}
	if readelf -lW "$artifact" | grep -q 'Requesting program interpreter'; then
		echo "dynamic-elf-check: $artifact unexpectedly has PT_INTERP" >&2
		exit 1
	fi
	if readelf -dW "$artifact" 2>/dev/null | grep -Eq '\(NEEDED\)|\(SONAME\)|\(HASH\)'; then
		echo "dynamic-elf-check: $artifact unexpectedly has dynamic metadata" >&2
		exit 1
	fi
	if nm -u "$artifact" | grep -q .; then
		echo "dynamic-elf-check: $artifact has undefined symbols" >&2
		exit 1
	fi
}

check_interp() {
	artifact=$1
	interp=$(readelf -lW "$artifact" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
	[ "$interp" = "$INTERP" ] || {
		echo "dynamic-elf-check: INTERP allowlist failed: $interp" >&2
		exit 1
	}
}

check_needed() {
	artifact=$1
	expected=$2
	actual=$(readelf -dW "$artifact" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
	[ "$actual" = "$expected" ] || {
		echo "dynamic-elf-check: NEEDED allowlist failed: '$actual' != '$expected'" >&2
		exit 1
	}
}

check_soname() {
	artifact=$1
	expected=$2
	expected_exports=$3
	expected_undefined=$4
	expected_needed=$5
	soname=$(readelf -dW "$artifact" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
	[ "$soname" = "$expected" ] || {
		echo "dynamic-elf-check: SONAME allowlist failed: $soname" >&2
		exit 1
	}
	check_needed "$artifact" "$expected_needed"
	if readelf -dW "$artifact" | grep -Eq 'libc\.so|libm\.so|libgcc|ld-linux|ld-house'; then
		echo "dynamic-elf-check: shared library has a forbidden dependency" >&2
		exit 1
	fi
	audit_symbols "$artifact" "$expected_exports" "$expected_undefined"
	audit_common "$artifact"
}

check_hello() {
	artifact=$1
	expected_soname=$2
	check_interp "$artifact"
	check_needed "$artifact" "$expected_soname "
	needed_count=$(readelf -dW "$artifact" | grep -c '(NEEDED)' || true)
	[ "$needed_count" -eq 1 ] || {
		echo "dynamic-elf-check: $artifact NEEDED count is $needed_count" >&2
		exit 1
	}
	if readelf -dW "$artifact" | grep -q '(SONAME)'; then
		echo "dynamic-elf-check: executable unexpectedly has SONAME" >&2
		exit 1
	fi
	readelf -rW "$artifact" | grep -q 'R_AARCH64_JUMP_SLOT.*strlen' || {
		echo "dynamic-elf-check: $artifact lacks a real strlen JUMP_SLOT" >&2
		exit 1
	}
	audit_common "$artifact"
}

# Two NEEDED entries in link order; check_hello's single-NEEDED shape does not apply.
check_deep_hello() {
	artifact=$1
	shift
	check_interp "$artifact"
	check_needed "$artifact" "$* "
	if readelf -dW "$artifact" | grep -q '(SONAME)'; then
		echo "dynamic-elf-check: executable unexpectedly has SONAME" >&2
		exit 1
	fi
	readelf -rW "$artifact" | grep -q 'R_AARCH64_JUMP_SLOT.*house_pad' || {
		echo "dynamic-elf-check: $artifact lacks a real house_pad JUMP_SLOT" >&2
		exit 1
	}
	audit_common "$artifact"
}

check_soname "$A/$SONAME" "$SONAME" "$WORK/expected-exports" "$WORK/expected-undefined-none" ""
check_soname "$A/$MID_SONAME" "$MID_SONAME" "$WORK/expected-exports-mid" "$WORK/expected-undefined-mid" "$SONAME "
check_soname "$A/$MISSING_SONAME" "$MISSING_SONAME" "$WORK/expected-exports" "$WORK/expected-undefined-none" ""
check_hello "$A/hello-dyn" "$SONAME"
check_hello "$A/hello-dyn-missing" "$MISSING_SONAME"
check_deep_hello "$A/$DEEP_MAIN" "$MID_SONAME" "$SONAME"
audit_exec "$A/exec-dyn"

for name in $ARTIFACTS; do
	loader_name=$(printf '%s' "$name" | tr '.-' '__')
	"$LOADER_CHECK" "$A/$name" >"$WORK/$loader_name.loader"
	python3 build-probe/repack.py "$A/$name" "$WORK/$loader_name.repacked" >/dev/null
	"$LOADER_CHECK" "$WORK/$loader_name.repacked" >"$WORK/$loader_name.repacked.loader"
	if [ "$name" = exec-dyn ]; then
		cmp "$WORK/$loader_name.loader" "$WORK/$loader_name.repacked.loader"
	else
		sed -E 's/ offset=[0-9]+/ offset=<file-offset>/' "$WORK/$loader_name.loader" >"$WORK/$loader_name.normalized"
		sed -E 's/ offset=[0-9]+/ offset=<file-offset>/' "$WORK/$loader_name.repacked.loader" >"$WORK/$loader_name.repacked.normalized"
		cmp "$WORK/$loader_name.normalized" "$WORK/$loader_name.repacked.normalized"
	fi
done

"$LOADER_CHECK" link "$A/hello-dyn" "$A/$SONAME" >"$WORK/link-a"
"$LOADER_CHECK" link "$B/hello-dyn" "$B/$SONAME" >"$WORK/link-b"
"$LOADER_CHECK" link "$WORK/hello_dyn.repacked" "$WORK/libc_house_so_0.repacked" >"$WORK/link-repacked"
cmp "$WORK/link-a" "$WORK/link-b"
cmp "$WORK/link-a" "$WORK/link-repacked"
cat >"$WORK/expected-link" <<'EOF'
object=main base=0x1000000 entry=0x1010290
object=libc-house.so.0 base=0x1030000 entry=0x1030000
relocation object=main provider=libc-house.so.0 symbol=strlen type=R_AARCH64_JUMP_SLOT target=0x10203f8 resolved=0x10404b4
EOF
cmp "$WORK/expected-link" "$WORK/link-a"

if "$LOADER_CHECK" link "$A/hello-dyn" >"$WORK/missing.link.out" 2>"$WORK/missing.link.err"; then
	echo "dynamic-elf-check: missing direct link dependency was not rejected" >&2
	exit 1
fi
grep -q 'DependencyMissing: libc-house.so.0' "$WORK/missing.link.err"
if "$LOADER_CHECK" link "$A/hello-dyn-missing" >"$WORK/missing-soname.link.out" 2>"$WORK/missing-soname.link.err"; then
	echo "dynamic-elf-check: missing SONAME dependency was not rejected" >&2
	exit 1
fi
grep -q 'DependencyMissing: libc-missing.so.0' "$WORK/missing-soname.link.err"

# Positive three-object graph: main + libmid-house.so.0 + libc-house.so.0.
"$LOADER_CHECK" link "$A/$DEEP_MAIN" "$A/$MID_SONAME" "$A/$SONAME" >"$WORK/link-deep-a"
"$LOADER_CHECK" link "$B/$DEEP_MAIN" "$B/$MID_SONAME" "$B/$SONAME" >"$WORK/link-deep-b"
cmp "$WORK/link-deep-a" "$WORK/link-deep-b"
object_count=$(grep -c '^object=' "$WORK/link-deep-a" || true)
[ "$object_count" -eq 3 ] || {
	echo "dynamic-elf-check: deep link plan placed $object_count objects, expected 3" >&2
	exit 1
}
bases=$(sed -n 's/^object=[^ ]* base=\([^ ]*\).*/\1/p' "$WORK/link-deep-a" | sort -u | tr '\n' ' ')
base_count=$(printf '%s' "$bases" | wc -w | tr -d ' ')
[ "$base_count" -eq 3 ] || {
	echo "dynamic-elf-check: deep link plan reuses a load base: $bases" >&2
	exit 1
}
grep -q '^relocation object=libmid-house.so.0 provider=libc-house.so.0 symbol=strlen ' "$WORK/link-deep-a" || {
	echo "dynamic-elf-check: deep link plan has no sibling-sourced relocation for libmid-house.so.0" >&2
	cat "$WORK/link-deep-a" >&2
	exit 1
}
grep -q '^relocation object=main provider=libmid-house.so.0 symbol=house_pad ' "$WORK/link-deep-a" || {
	echo "dynamic-elf-check: deep link plan does not resolve the main symbol from the deepest DSO" >&2
	cat "$WORK/link-deep-a" >&2
	exit 1
}
grep -q '^relocation object=main provider=libmid-house.so.0 symbol=house_len ' "$WORK/link-deep-a" || {
	echo "dynamic-elf-check: deep link plan does not resolve the DSO-internal strlen call target" >&2
	cat "$WORK/link-deep-a" >&2
	exit 1
}
cat >"$WORK/expected-link-deep" <<'EOF'
object=main base=0x1000000 entry=0x1010328
object=libmid-house.so.0 base=0x1030000 entry=0x1030000
object=libc-house.so.0 base=0x1060000 entry=0x1060000
relocation object=main provider=libc-house.so.0 symbol=strlen type=R_AARCH64_JUMP_SLOT target=0x1020528 resolved=0x10704b4
relocation object=main provider=libmid-house.so.0 symbol=house_pad type=R_AARCH64_JUMP_SLOT target=0x1020530 resolved=0x10402a8
relocation object=main provider=libmid-house.so.0 symbol=house_len type=R_AARCH64_JUMP_SLOT target=0x1020538 resolved=0x10402c4
relocation object=libmid-house.so.0 provider=libc-house.so.0 symbol=strlen type=R_AARCH64_JUMP_SLOT target=0x1050408 resolved=0x10704b4
EOF
cmp "$WORK/expected-link-deep" "$WORK/link-deep-a"

# Dropping either dependency must fail the plan at a named error, not silently
# plan a smaller graph.
if "$LOADER_CHECK" link "$A/$DEEP_MAIN" "$A/$MID_SONAME" >"$WORK/deep-incomplete.link.out" 2>"$WORK/deep-incomplete.link.err"; then
	echo "dynamic-elf-check: deep link without libc-house.so.0 was not rejected" >&2
	exit 1
fi
grep -q "DependencyMissing: $SONAME" "$WORK/deep-incomplete.link.err"

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
grep -q 'DependencyMissing: libleaf.so.0' "$WORK/incomplete.link.err"

cat >"$WORK/bad-u.s" <<'EOF'
.arch armv8-a
.text
.global bad_u
.type bad_u,%function
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

STAGED="initramfs-staging/bin/exec-dyn initramfs-staging/bin/hello-dyn \
initramfs-staging/bin/hello-dyn-deep initramfs-staging/bin/hello-dyn-missing \
initramfs-staging/lib/libc-house.so.0 initramfs-staging/lib/libmid-house.so.0"
for path in $STAGED; do
	[ -f "$path" ] || {
		echo "dynamic-elf-check: missing staged dynamic file $path" >&2
		exit 1
	}
done
find initramfs-staging/bin initramfs-staging/lib -type f \( \
	-name hello-dyn -o -name hello-dyn-missing -o -name hello-dyn-deep -o -name exec-dyn \
	-o -name libc-house.so.0 -o -name libmid-house.so.0 \
	\) -print | LC_ALL=C sort >"$WORK/staged.dynamic"
printf '%s\n' $STAGED >"$WORK/expected.staged.dynamic"
cmp "$WORK/expected.staged.dynamic" "$WORK/staged.dynamic"
sha256sum $STAGED >"$WORK/staged.manifest"
cmp scripts/dynamic-userspace.sha256 "$WORK/staged.manifest"
if find initramfs-staging -type f \( -name 'ld-house.so*' -o -name 'libc-missing.so*' \) -print -quit | grep -q .; then
	echo "dynamic-elf-check: forbidden negative/interpreter artifact is staged" >&2
	exit 1
fi

for name in $ARTIFACTS; do
	printf '%s  %s\n' "$(sha256sum "$A/$name" | cut -d' ' -f1)" "$name"
done
echo "dynamic-elf-check: reproducible artifacts, Loader/repacker parity, transitive link plan, negative dependency, and exact staging agree"
