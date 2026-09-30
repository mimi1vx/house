#!/bin/sh
# Frozen C ABI symbol baseline: emit + check.
# Runs on host or in linux/arm64 (needs only grep/sed/awk/sort).
set -eu
cd "$(dirname "$0")/.."
BASE="rust/c-abi.symbols"
ABI="rust/c-abi.md"

rust_exports() {
  grep -rn --include="*.rs" -E '^[[:space:]]*#\[.*no_mangle' rust/crates 2>/dev/null | cut -d: -f1,2 | while IFS=: read -r f ln; do
    i=1
    while [ "$i" -le 6 ]; do
      line=$(sed -n "$((ln+i))p" "$f")
      trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
      case "$trimmed" in
        '') i=$((i+1)); continue ;;
        '#['*) i=$((i+1)); continue ;;
      esac
      fn=$(printf '%s' "$line" | grep -o -E 'fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | head -1 | awk '{print $2}' || true)
      if [ -n "$fn" ]; then printf '%s\n' "$fn"; break; fi
      st=$(printf '%s' "$line" | grep -o -E 'static[[:space:]]+(mut[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*' | head -1 | awk '{print $NF}' || true)
      if [ -n "$st" ] && [ "$st" != "mut" ]; then printf '%s\n' "$st"; break; fi
      break
    done
  done
}

asm_labels() {
  grep -h '\.global' rust/crates/house-boot/src/entry.rs rust/crates/house-boot/src/exception.rs rust/crates/house-libc/src/threads/switch.rs 2>/dev/null | awk '{print $2}' | LC_ALL=C sort -u
}

linker_globals() {
  awk '/^## Globals resolved/{flag=1;next} /^## Audit notes/{flag=0} flag' "$ABI" | grep -o '`__[^`]*`' | tr -d '`' | tr '/' '\n' | sed 's/^ *//;s/ *$//' | grep -E '^__[A-Za-z0-9_]+$' | LC_ALL=C sort -u
}

doc_symbols() {
  grep -E '^\|' "$ABI" | awk -F'|' '{print $3}' | tr -d '`' | tr '/' '\n' | sed 's/^ *//;s/ *$//' | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | grep -vx 'Symbol' | LC_ALL=C sort -u
}

current_symbols() {
  { rust_exports; asm_labels; } | LC_ALL=C sort -u
}

cmd="${1:-check}"
case "$cmd" in
  emit)
    current_symbols
    ;;
  check)
    tmp_cur=$(mktemp)
    tmp_base=$(mktemp)
    tmp_doc=$(mktemp)
    tmp_link=$(mktemp)
    trap 'rm -f "$tmp_cur" "$tmp_base" "$tmp_doc" "$tmp_link"' EXIT
    current_symbols >"$tmp_cur"
    if [ ! -f "$BASE" ]; then
      echo "abi-symbols: missing $BASE" >&2
      exit 1
    fi
    LC_ALL=C sort -u "$BASE" -o "$tmp_base"
    if ! cmp -s "$tmp_base" "$tmp_cur"; then
      echo "abi-symbols: baseline drift" >&2
      echo "--- added (+current -baseline):" >&2
      comm -13 "$tmp_base" "$tmp_cur" | sed 's/^/+1 /' >&2 || true
      echo "--- removed (-baseline +current):" >&2
      comm -23 "$tmp_base" "$tmp_cur" | sed 's/^/-1 /' >&2 || true
      exit 1
    fi
    doc_symbols >"$tmp_doc"
    linker_globals >"$tmp_link" || true
    if [ -s "$tmp_link" ]; then
      tmp_doc_filt=$(mktemp)
      grep -vxF -f "$tmp_link" "$tmp_doc" >"$tmp_doc_filt" || true
      mv "$tmp_doc_filt" "$tmp_doc"
    fi
    if ! cmp -s "$tmp_base" "$tmp_doc"; then
      echo "abi-symbols: c-abi.md table drift vs $BASE" >&2
      echo "--- in tables but not baseline:" >&2
      comm -23 "$tmp_doc" "$tmp_base" | sed 's/^/+1 /' >&2 || true
      echo "--- in baseline but not tables:" >&2
      comm -13 "$tmp_doc" "$tmp_base" | sed 's/^/-1 /' >&2 || true
      exit 1
    fi
    if [ -s "$tmp_link" ]; then
      tmp_rust=$(mktemp)
      rust_exports | LC_ALL=C sort -u >"$tmp_rust"
      bad=$(grep -xF -f "$tmp_link" "$tmp_rust" || true)
      if [ -n "$bad" ]; then
        echo "abi-symbols: linker global defined in Rust (must stay ld-only):" >&2
        echo "$bad" >&2
        exit 1
      fi
      rm -f "$tmp_rust"
    fi
    echo "abi-symbols: ok ($(wc -l <"$tmp_base" | tr -d ' ') symbols)"
    ;;
  *)
    echo "usage: $0 {emit|check}" >&2
    exit 1
    ;;
esac
