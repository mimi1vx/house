#!/bin/sh
# Per-pid syscall mask gate: revoke WRITE for the svcmask probe and prove
# ENOSYS without hanging the shell.
set -eu
cd "$(dirname "$0")/.."
KERNEL="${1:-platform/aarch64/build/house.bin}"
ACCEL="${2:-tcg}"
MEM="${3:-4G}"
SMP="${4:-2}"
expect scripts/qemu-svcmask.exp "$KERNEL" 'svcmask-ok' 90 "$ACCEL" "$MEM" "$SMP"
