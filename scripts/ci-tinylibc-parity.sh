#!/bin/sh
# ci-tinylibc-parity.sh — nm vs rust/c-abi.md + checked_* vs __builtin_*overflow gate
# Frozen per plans/replace-tinylibc-rust.md §1
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
C_ABI="$ROOT/rust/c-abi.md"
TINY_DIR="$ROOT/platform/aarch64/tinylibc"
LIBC_SRC="$ROOT/rust/crates/house-libc/src"

echo "[parity] rust/c-abi.md tinylibc table vs nm"
# Extract house-libc symbols from c-abi.md: lines with "| house-libc | Symbol |"
if [ -f "$C_ABI" ]; then
  ABI_RAW="$(grep -E '\| *`?house-libc`?' "$C_ABI" | awk -F'|' '{print $3}')"
  # split on '/' and trim backticks/spaces
  ABI_SYMS="$(echo "$ABI_RAW" | tr '/' '\n' | sed 's/`//g' | awk '{for(i=1;i<=NF;i++) print $i}' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u)"
  ABI_COUNT="$(echo "$ABI_SYMS" | grep -v '^$' | wc -l | tr -d ' ')"
  echo "[parity] documented house-libc symbols: $ABI_COUNT"
  # If tiny objects exist, compare subset (warn-only until c-abi.md fully populated)
  if ls "$ROOT/platform/aarch64/build/tiny-"*.o >/dev/null 2>&1; then
    TINY_SYMS="$(nm "$ROOT/platform/aarch64/build/tiny-"*.o 2>/dev/null | grep " T " | awk '{print $3}' | sort -u)"
    TINY_COUNT="$(echo "$TINY_SYMS" | grep -v '^$' | wc -l | tr -d ' ')"
    echo "[parity] tiny object T symbols: $TINY_COUNT"
    MISSING="$(comm -23 <(echo "$TINY_SYMS" | sort) <(echo "$ABI_SYMS" | sort) || true)"
    if [ -n "$MISSING" ]; then
      echo "[parity] WARN: tinylibc symbols not yet in c-abi.md (deferred stdio/compat/mathmin):"
      echo "$MISSING" | head -n 20
      echo "[parity] (not failing until c-abi.md updated per phase4)"
    else
      echo "[parity] tiny ⊆ c-abi.md OK"
    fi
  else
    echo "[parity] no build/tiny-*.o yet, skipping nm subset check (build first)"
  fi
  # Check libhouse_libc.a provides documented symbols (if built)
  LIBA="$ROOT/rust/target/aarch64-unknown-none/debug/libhouse_libc.a"
  if [ -f "$LIBA" ] && command -v nm >/dev/null 2>&1; then
    LIB_SYMS="$(nm "$LIBA" 2>/dev/null | grep -v " U " | awk 'NF==3{print $3} NF==2{print $2}' | sort -u)"
    LIB_COUNT="$(echo "$LIB_SYMS" | grep -v '^$' | wc -l | tr -d ' ')"
    echo "[parity] libhouse_libc.a T symbols: $LIB_COUNT"
    # filter wildcard entries like house_spin_*
    ABI_FILTERED="$(echo "$ABI_SYMS" | grep -v '\*' | grep -v '^$')"
    MISSING2="$(comm -23 <(echo "$ABI_FILTERED" | sort) <(echo "$LIB_SYMS" | sort) | grep -v '^$' || true)"
    # check wildcard prefix house_spin_* separately
    if echo "$ABI_SYMS" | grep -q "house_spin_\*"; then
      if ! echo "$LIB_SYMS" | grep -q "house_spin_"; then
        MISSING2="$MISSING2
house_spin_* (no matching prefix found)"
      fi
    fi
    if [ -n "$MISSING2" ]; then
      echo "[parity] WARN: documented symbols missing in libhouse_libc.a (stubs may be incomplete):"
      echo "$MISSING2"
      # not hard fail — warns until all modules complete
    else
      echo "[parity] libhouse_libc.a covers documented symbols OK"
    fi
  else
    echo "[parity] libhouse_libc.a not built yet, skipping"
  fi
else
  echo "[parity] missing $C_ABI"
  exit 1
fi

# checked_* vs __builtin_*overflow parity
if [ -d "$TINY_DIR" ]; then
  C_OVERFLOW="$(grep -rn "__builtin_.*overflow" "$TINY_DIR" 2>/dev/null | wc -l | tr -d ' ')"
else
  C_OVERFLOW=0
fi
if [ -d "$LIBC_SRC" ]; then
  RUST_CHECKED="$(grep -rn "checked_add\|checked_mul\|checked_sub\|try_into" "$LIBC_SRC" 2>/dev/null | wc -l | tr -d ' ')"
else
  RUST_CHECKED=0
fi
echo "[parity] C __builtin_*overflow count: $C_OVERFLOW"
echo "[parity] Rust checked_*/try_into count: $RUST_CHECKED"
if [ "$RUST_CHECKED" -lt "$C_OVERFLOW" ]; then
  echo "[parity] FAIL: Rust checked_* ($RUST_CHECKED) < C overflow builtins ($C_OVERFLOW) — SOTA Security 06"
  exit 1
fi
echo "[parity] checked_* >= __builtin_*overflow OK"

# SAFETY comment gate: every unsafe block should have // SAFETY:
UNSAFE_COUNT="$(grep -rn "unsafe" "$LIBC_SRC" --include="*.rs" 2>/dev/null | wc -l | tr -d ' ')"
SAFETY_COUNT="$(grep -rn "// SAFETY:" "$LIBC_SRC" --include="*.rs" 2>/dev/null | wc -l | tr -d ' ')"
echo "[parity] unsafe hits: $UNSAFE_COUNT, // SAFETY: $SAFETY_COUNT"
if [ "$SAFETY_COUNT" -lt 1 ]; then
  echo "[parity] WARN: no // SAFETY: comments found"
fi

# panic_handler single owner
PANIC_COUNT="$(grep -rn "panic_handler" "$ROOT/rust/crates" --include="*.rs" 2>/dev/null | wc -l | tr -d ' ')"
echo "[parity] panic_handler hits: $PANIC_COUNT (expect 1 in house-libc/src/panic.rs)"
if [ "$PANIC_COUNT" != "1" ]; then
  echo "[parity] FAIL: expected exactly 1 panic_handler"
  exit 1
fi

echo "[parity] PASS"
