#!/bin/sh
# Phase 2 gate: cargo build + nm boot symbols + clippy -D warnings + fmt --check
# Run inside house-port:latest: container run --platform linux/arm64 --rm -v "$PWD":/work -w /work house-port:latest sh scripts/ci-rust-phase2.sh
set -eu

echo "== cargo build =="
cargo build --manifest-path rust/Cargo.toml --target aarch64-unknown-none

echo "== nm Rust boot lib =="
nm rust/target/aarch64-unknown-none/debug/libhouse_boot.rlib | grep -E " T | D | R " | sort | head -n 100

for sym in "_start" "secondary_entry" "__boot_dtb" "vectors" "house_enter_el0" "svc_exit_trampoline"; do
	if ! nm rust/target/aarch64-unknown-none/debug/libhouse_boot.rlib | grep -q "$sym"; then
		echo "FAIL: $sym missing in libhouse_boot.rlib" >&2
		exit 1
	fi
	echo "ok: $sym present"
done

echo "== nm libhouse_libc shims =="
if ! nm rust/target/aarch64-unknown-none/debug/libhouse_libc.a | grep -q "__stack_chk_guard"; then
	echo "FAIL: __stack_chk_guard missing" >&2
	exit 1
fi
if ! nm rust/target/aarch64-unknown-none/debug/libhouse_libc.a | grep -q "__stack_chk_fail"; then
	echo "FAIL: __stack_chk_fail missing" >&2
	exit 1
fi
echo "shims ok"

echo "== panic_handler single owner check =="
count=$(grep -R "\[panic_handler" rust/crates --include="*.rs" | wc -l)
if [ "$count" -ne 1 ]; then
	echo "FAIL: expected exactly 1 [panic_handler], got $count" >&2
	grep -R "\[panic_handler" rust/crates --include="*.rs" || true
	exit 1
fi
echo "panic_handler ok: exactly 1 definition ($count)"

echo "== clippy -D warnings =="
cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none -- -D warnings

echo "== fmt --check =="
(cd rust && cargo fmt --check)

echo "== PASS ci-rust-phase2 =="
