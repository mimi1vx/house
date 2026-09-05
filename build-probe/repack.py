#!/usr/bin/env python3
"""Repackage a linked aarch64 ET_EXEC into a minimal hello-style ELF.

Keeps one minimal phdr per input PT_LOAD (vaddr/flags preserved, p_align=0,
file offsets packed from 120). Entry rebased relative to its LOAD.
Matches what Kernel.Userspace.Loader accepts (ET_EXEC, AArch64, window,
align 0, filesz==memsz<=256K, pages<=64).
"""

import struct
import sys


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def main(src, dst):
    with open(src, "rb") as f:
        img = f.read()
    assert img[:4] == b"\x7fELF", "not ELF"
    assert img[4] == 2 and img[5] == 1, "not 64-bit LE"
    assert u16(img, 18) == 183, "not AArch64"
    assert u16(img, 16) == 2, "not ET_EXEC"
    entry = u64(img, 24)
    phoff = u64(img, 32)
    phentsz = u16(img, 54)
    phnum = u16(img, 56)
    assert phentsz == 56
    loads = []
    for i in range(phnum):
        o = phoff + i * 56
        ptype, flags = u32(img, o), u32(img, o + 4)
        poff, vaddr = u64(img, o + 8), u64(img, o + 16)
        filesz, memsz = u64(img, o + 32), u64(img, o + 40)
        if ptype == 1:
            assert filesz == memsz, "bss not supported"
            assert filesz <= 256 * 1024
            loads.append((vaddr, poff, filesz, flags))
    assert loads, "no PT_LOAD"
    loads.sort()
    blobs = []
    new_entry = None
    for vaddr, poff, filesz, flags in loads:
        assert 0x01000000 <= vaddr <= 0xFFFFFFFF, f"vaddr {vaddr:#x} out of window"
        assert vaddr + filesz <= 0x100000000, "segment end out of window"
        blobs.append((vaddr, img[poff : poff + filesz], flags))
        if vaddr <= entry < vaddr + filesz:
            new_entry = vaddr + (entry - vaddr)
    assert new_entry is not None, "entry not in any LOAD"
    pages = sum((len(b) + 4095) // 4096 for _, b, _ in blobs)
    assert pages <= 64, "too many pages"
    n = len(blobs)
    ehdr = struct.pack(
        "<16sHHIQQQIHHHHHH",
        bytes([0x7F]) + b"ELF" + bytes([2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        2,
        183,
        1,
        new_entry,
        64,
        0,
        0,
        64,
        56,
        n,
        0,
        0,
        0,
    )
    out = [ehdr]
    off = 64 + 56 * n
    for vaddr, blob, flags in blobs:
        out.append(
            struct.pack(
                "<IIQQQQQQ", 1, flags, off, vaddr, vaddr, len(blob), len(blob), 0
            )
        )
        off += len(blob)
    for _, blob, _ in blobs:
        out.append(blob)
    with open(dst, "wb") as f:
        f.write(b"".join(out))
    print(f"entry=0x{new_entry:x} loads={n} pages={pages} total={off}B")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
