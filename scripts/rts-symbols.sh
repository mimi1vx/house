#!/bin/sh
# rts-symbols.sh — audit RTS archives for undefined symbols and TLS relocs
# Usage: ./scripts/rts-symbols.sh [rts_dir]
# Prints delta between thr and non-thr, TLS reloc counts, and any new
# tinylibc-side undefineds.

set -e
RTS_DIR=${1:-$(ghc-pkg field rts library-dirs --simple-output 2>/dev/null | awk '{print $1}')}
if [ -z "$RTS_DIR" ]; then
	echo "rts dir not found" >&2
	exit 1
fi
NON_THR=$(ls "$RTS_DIR"/libHSrts-*.a | grep -v thr | grep -v debug | grep -v eventlog | head -1)
THR=$(ls "$RTS_DIR"/libHSrts-*.a | grep thr | grep -v debug | grep -v eventlog | head -1)
echo "non-thr: $NON_THR"
echo "thr:     $THR"
echo "--- undefined diff (thr - non-thr) external ---"
nm -u "$THR" | sort -u >/tmp/thr_u
nm -u "$NON_THR" | sort -u >/tmp/non_u
comm -23 /tmp/thr_u /tmp/non_u | grep -v " U _" | head -n 100
echo "--- TLS relocs ---"
for a in "$THR" "$NON_THR"; do
	cnt=0
	for f in $(ar t "$a"); do
		c=$(ar p "$a" "$f" 2>/dev/null | readelf -r - 2>/dev/null | grep -c TLSDESC || true)
		cnt=$((cnt + c))
	done
	echo "$(basename "$a"): $cnt TLSDESC"
done
echo "--- final ELF TLSDESC (if built) ---"
for elf in platform/aarch64/build/*.elf; do
	[ -f "$elf" ] && echo "$elf: $(readelf -r "$elf" 2>/dev/null | grep -c TLSDESC || echo 0) TLSDESC"
done
