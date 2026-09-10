#!/bin/sh
# Build build/initramfs.cpio (cpio newc) from initramfs-staging/.
# Host-side only: sorted for reproducibility, no absolute paths.
# sbin/init is the embedded hello ELF (kernel/HouseA64.hs helloBytes).
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
(cd initramfs-staging && find . -mindepth 1 | sort | cpio -o -H newc) >build/initramfs.cpio
