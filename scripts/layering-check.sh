#!/bin/sh
# Layering gate: low layers must not import drivers.
# Dmesg is a log ring (Kernel.Log.Dmesg), not a driver; Boot/Init/FileSystem/Log
# and H must stay driver-free so the microkernel dependency direction holds.
set -eu
cd "$(dirname "$0")/.."
hits=""
for p in kernel/H/ kernel/Kernel/Boot.hs kernel/Kernel/Init.hs kernel/Kernel/FileSystem/ kernel/Kernel/Log/; do
	if [ -e "$p" ]; then
		out=$(grep -rn 'import Kernel.Driver' "$p" || true)
		if [ -n "$out" ]; then
			hits="$hits$out
"
		fi
	fi
done
if [ -n "$hits" ]; then
	printf '%s' "$hits" >&2
	echo "layering-check: FAIL: driver import in low layers" >&2
	exit 1
fi
echo "layering-check: ok (no import Kernel.Driver in H/Boot/Init/FileSystem/Log)"
