#!/bin/sh
# Phase 1 gate: cargo build + nm shim audit + clippy -D warnings + fmt --check
# Run inside house-port:latest: container run --platform linux/arm64 --rm -v "$PWD":/work -w /work house-port:latest sh scripts/ci-rust-phase1.sh
set -eu

echo "== cargo build =="
cargo build --manifest-path rust/Cargo.toml --target aarch64-unknown-none

echo "== nm Rust libs =="
nm rust/target/aarch64-unknown-none/debug/libhouse_libc.a | grep -E " T | R | D " | sort | head -n 100
# Must export shims
if ! nm rust/target/aarch64-unknown-none/debug/libhouse_libc.a | grep -q "__stack_chk_guard"; then
	echo "FAIL: __stack_chk_guard missing in libhouse_libc.a" >&2
	exit 1
fi
if ! nm rust/target/aarch64-unknown-none/debug/libhouse_libc.a | grep -q "__stack_chk_fail"; then
	echo "FAIL: __stack_chk_fail missing in libhouse_libc.a" >&2
	exit 1
fi
echo "shims ok: __stack_chk_guard + __stack_chk_fail present"

echo "== panic_handler single owner check =="
# exactly one definition
count=$(grep -R "\[panic_handler" rust/crates --include="*.rs" | wc -l)
if [ "$count" -ne 1 ]; then
	echo "FAIL: expected exactly 1 [panic_handler], got $count" >&2
	grep -R "\[panic_handler" rust/crates --include="*.rs" || true
	exit 1
fi
echo "panic_handler ok: exactly 1 definition"

echo "== clippy -D warnings =="
cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none -- -D warnings

echo "== fmt --check =="
# rust/.cargo/config sets default target, but fmt needs to run from workspace dir
(cd rust && cargo fmt --check)

echo "== PASS ci-rust-phase1 =="
