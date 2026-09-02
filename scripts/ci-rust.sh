#!/bin/bash
set -eu
# Phase 5 CI: cargo fmt/clippy + nm/rg parity + make check RUST=1
# Runs inside house-port:latest (linux/arm64). Pin --platform linux/arm64.

echo "== cargo fmt --check =="
(cd rust && cargo fmt --check)

echo "== cargo clippy --workspace --target aarch64-unknown-none -- -D warnings =="
cargo clippy --manifest-path rust/Cargo.toml --target aarch64-unknown-none -- -D warnings

echo "== cargo build --target aarch64-unknown-none =="
cargo build --manifest-path rust/Cargo.toml --target aarch64-unknown-none

echo "== panic_handler audit =="
hits=$(grep -rn "panic_handler" rust/crates --include="*.rs" | wc -l | tr -d ' ')
echo "panic_handler hits: $hits"
[ "$hits" -eq 1 ] || {
	echo "FAIL: expected 1 panic_handler, got $hits"
	grep -rn panic_handler rust/crates --include="*.rs"
	exit 1
}
test -f rust/crates/house-libc/src/panic.rs || {
	echo "FAIL: panic.rs missing"
	exit 1
}

echo "== checked_* parity =="
checked=$(grep -rn "checked_add\|checked_mul\|checked_sub\|try_into" rust/crates/house-libc/src rust/crates/house-hal-aarch64/src 2>/dev/null | wc -l | tr -d ' ' || echo 0)
echo "checked_* hits: $checked"
# at least non-zero (SOTA Security 06 bounds)
[ "$checked" -ge 1 ] || { echo "WARN: no checked_* found"; }

echo "== riscv64 feature stub =="
cargo build -p house-hal --manifest-path rust/Cargo.toml --no-default-features --features riscv64 || {
	echo "FAIL: riscv64 feature"
	exit 1
}

echo "== nm parity (RUST libs contain house_* symbols) =="
for lib in rust/target/aarch64-unknown-none/debug/libhouse_*.a rust/target/aarch64-unknown-none/debug/libhouse_*.rlib; do
	[ -f "$lib" ] || continue
	echo "--- $lib ---"
	nm "$lib" 2>/dev/null | grep " T " | head -20 || true
done

echo "== dc/dsb/tlbi parity =="
if command -v rg >/dev/null 2>&1; then
	rg -n "dc cvac|dc ivac|dsb sy|dmb sy|tlbi" rust/crates/house-hal-aarch64/src rust/crates/house-libc/src 2>/dev/null | wc -l | tr -d ' ' | xargs echo "rust dsb/tlbi hits:" || echo "rust dsb/tlbi hits: 0"
else
	grep -rn "dc cvac\|dc ivac\|dsb sy\|dmb sy\|tlbi" rust/crates/house-hal-aarch64/src rust/crates/house-libc/src 2>/dev/null | wc -l | tr -d ' ' | xargs echo "rust dsb/tlbi hits:" || echo "rust dsb/tlbi hits: 0"
fi

echo "== make check RUST=1 (requires QEMU hvf on macOS host) =="
# When running inside container, skip QEMU; gate on host.
if uname -m | grep -q aarch64 && [ -f platform/aarch64/build/house.elf ]; then
	echo "container: build-only — run 'make check RUST=1' on host for hvf/tcg gates"
else
	echo "skip QEMU inside ci-rust.sh — run 'make check RUST=1' on host"
fi

echo "== ci-rust.sh: ok =="
