#!/usr/bin/env python3
"""Repackage a linked aarch64 ELF into a minimal hello-style ELF.

Static inputs (ET_EXEC, PT_LOAD only) take the original path: one minimal
phdr per input PT_LOAD (vaddr/flags preserved, p_align=0, file offsets
packed from 120). Entry rebased relative to its LOAD. Output for static
inputs is byte-identical to the pre-dynamic-linking script.

Dynamic inputs (ET_DYN, PT_INTERP/PT_DYNAMIC/PT_GNU_RELRO) are validated
with the same asserts as Kernel.Userspace.Loader (M1, kernel-is-the-loader:
INTERP path pin, DYNAMIC bounds, RELATIVE-only RELA, RELRO-in-LOAD) and
repacked with LOAD blobs plus verbatim INTERP/DYNAMIC blobs (VAs preserved,
so DT_* VAs and RELA r_offsets need no rewriting; RELRO carries no bytes).
Every failure exits nonzero with the Loader reason-string family
(BadType/BadSegment/TooManyPhdrs/OverlapSize/NoSpace/Misaligned/
OutOfWindow/Truncated/BadDyn/UnsupportedReloc/TlsUnsupported).

Matches what Kernel.Userspace.Loader accepts (AArch64, 0x01000000 window,
align 0, filesz==memsz<=256K, pages<=64, entry in LOAD).
"""

import struct
import sys
from typing import NoReturn

LD_HOUSE = "/lib/ld-house.so.0"
PT_LOAD = 1
PT_DYNAMIC = 2
PT_INTERP = 3
PT_GNU_RELRO = 0x6474E552

DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_SYMTAB = 6
DT_RELA = 7
DT_RELASZ = 8
DT_RELAENT = 9
DT_STRSZ = 10
DT_BIND_NOW = 24
DT_FLAGS = 30

R_GLOB_DAT = 1025
R_JUMP_SLOT = 1026
R_RELATIVE = 1027
R_TLS_FIRST = 1029


def fail(reason: str) -> NoReturn:
    print(reason, file=sys.stderr)
    sys.exit(1)


def u16(b, o):
    if o < 0 or o + 2 > len(b):
        fail("Truncated")
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    if o < 0 or o + 4 > len(b):
        fail("Truncated")
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    if o < 0 or o + 8 > len(b):
        fail("Truncated")
    return struct.unpack_from("<Q", b, o)[0]


def va_to_file(segs, va):
    """Map an object VA to an input file offset via containing PT_LOAD."""
    for lvaddr, lpoff, lfilesz, _blob, _flags in segs:
        if lvaddr <= va < lvaddr + lfilesz:
            return lpoff + (va - lvaddr)
    return None


def check_dynamic(img, dyn_off, dyn_sz, segs):
    if dyn_sz % 16 != 0:
        fail("BadDyn: dynamic size")
    n = dyn_sz // 16
    if n > 64:
        fail("BadDyn: dynamic too many")
    needed_offs = []
    strtab_va = None
    strsz = 0
    rela_va = None
    relasz = 0
    relaent = None
    seen = set()
    for i in range(n):
        tag = u64(img, dyn_off + i * 16)
        val = u64(img, dyn_off + i * 16 + 8)
        if tag == DT_NULL:
            break
        if tag == DT_NEEDED:
            needed_offs.append(val)
        elif tag in (DT_STRTAB, DT_RELA, DT_RELASZ, DT_RELAENT, DT_STRSZ):
            if tag in seen:
                fail(f"BadDyn: duplicate DT_{tag}")
            seen.add(tag)
            if tag == DT_STRTAB:
                strtab_va = val
            elif tag == DT_RELA:
                rela_va = val
            elif tag == DT_RELASZ:
                relasz = val
            elif tag == DT_RELAENT:
                relaent = val
            else:
                strsz = val
        elif tag in (DT_SYMTAB, DT_BIND_NOW, DT_FLAGS):
            pass
        else:
            fail(f"BadDyn: unsupported DT_{tag}")
    if relaent is None:
        if rela_va is not None or relasz != 0:
            fail("BadDyn: missing RELAENT")
        relaent = 0
    if relaent not in (0, 24):
        fail("BadDyn: relaent")
    if relaent == 0 and relasz != 0:
        fail("BadDyn: relaent 0 with relasz")
    if relaent != 0 and relasz % relaent != 0:
        fail("BadDyn: relasz")
    count = 0 if relaent == 0 else relasz // relaent
    if count > 4096:
        fail("BadDyn: rela count")
    if strsz > 64 * 1024:
        fail("BadDyn: strsz overrun")
    if len(needed_offs) > 8:
        fail("BadDyn: needed too many")
    strtab = b""
    if strtab_va is not None or needed_offs or strsz != 0:
        if strtab_va is None:
            fail("BadDyn: missing STRTAB")
        soff = va_to_file(segs, strtab_va)
        if soff is None:
            fail("BadDyn: strtab outside LOAD")
        if strsz > len(img) - soff:
            fail("BadDyn: strtab bounds")
        strtab = img[soff : soff + strsz]
    for off in needed_offs:
        if off >= strsz:
            fail("BadDyn: needed off")
        end = strtab.find(b"\x00", off)
        if end < 0:
            fail("BadDyn: needed not NUL")
        name = strtab[off:end]
        if not name:
            fail("BadDyn: needed empty")
        if len(name) > 128:
            fail("BadDyn: needed too long")
        if b"/" in name:
            fail("BadDyn: needed slash")
        if any(c < 32 or c > 126 for c in name):
            fail("BadDyn: needed non-printable")
    if count > 0 and rela_va is None:
        fail("BadDyn: missing RELA")
    if rela_va is not None:
        roff = va_to_file(segs, rela_va)
        if roff is None:
            fail("BadDyn: rela outside LOAD")
        if relasz > len(img) - roff:
            fail("BadDyn: rela bounds")
        for j in range(count):
            eoff = roff + j * 24
            r_offset = u64(img, eoff)
            r_info = u64(img, eoff + 8)
            typ = r_info & 0xFFFFFFFF
            sym = r_info >> 32
            if typ == R_RELATIVE:
                if sym != 0:
                    fail(f"UnsupportedReloc: {typ}")
                if va_to_file(segs, r_offset) is None:
                    fail("BadDyn: rela outside LOAD")
            elif typ == 0:
                pass
            elif typ in (R_GLOB_DAT, R_JUMP_SLOT):
                fail(f"UnsupportedReloc: {typ}")
            elif typ >= R_TLS_FIRST:
                fail("TlsUnsupported")
            else:
                fail(f"UnsupportedReloc: {typ}")


def main(src, dst):
    with open(src, "rb") as f:
        img = f.read()
    if img[:4] != b"\x7fELF":
        fail("BadMagic: not ELF64 LE")
    if len(img) < 64:
        fail("Truncated")
    if img[4] != 2 or img[5] != 1:
        fail("BadMagic: not ELF64 LE")
    if u16(img, 18) != 183:
        fail("BadArch: need AArch64")
    etype = u16(img, 16)
    if etype not in (2, 3):
        fail("BadType: need ET_EXEC/ET_DYN")
    entry = u64(img, 24)
    phoff = u64(img, 32)
    phentsz = u16(img, 54)
    phnum = u16(img, 56)
    if phnum > 8:
        fail("TooManyPhdrs: >8")
    if phentsz != 56 and phnum > 0:
        fail("BadSegment: phentsz !=56")
    if phoff + phnum * (phentsz or 56) > len(img):
        fail("Truncated")
    raws = []
    for i in range(phnum):
        o = phoff + i * 56
        ptype, flags = u32(img, o), u32(img, o + 4)
        poff, vaddr = u64(img, o + 8), u64(img, o + 16)
        filesz, memsz = u64(img, o + 32), u64(img, o + 40)
        align = u64(img, o + 48)
        raws.append((ptype, flags, poff, vaddr, filesz, memsz, align))
    loads = []
    for ptype, flags, poff, vaddr, filesz, memsz, _a in raws:
        if ptype == PT_LOAD:
            if filesz > memsz:
                fail("BadSegment: filesz > memsz")
            if filesz != memsz:
                fail("BadSegment: bss not supported")
            if filesz > 256 * 1024:
                fail("NoSpace: total pages >64 or memsz >256K")
            loads.append((vaddr, poff, filesz, flags))
    if not loads:
        fail("BadSegment: no PT_LOAD")
    loads.sort()
    blobs = []
    segs = []
    new_entry = None
    for vaddr, poff, filesz, flags in loads:
        if not (0x01000000 <= vaddr <= 0xFFFFFFFF):
            fail(f"OutOfWindow: 0x{vaddr:x}")
        if vaddr + filesz > 0x100000000:
            fail(f"OutOfWindow: 0x{vaddr + filesz:x}")
        if poff + filesz > len(img):
            fail("Truncated")
        blob = img[poff : poff + filesz]
        blobs.append((vaddr, blob, flags))
        segs.append((vaddr, poff, filesz, blob, flags))
        if vaddr <= entry < vaddr + filesz:
            new_entry = vaddr + (entry - vaddr)
    if new_entry is None:
        fail("BadSegment: entry not in LOAD")
    pages = sum((len(b) + 4095) // 4096 for _, b, _ in blobs)
    if pages > 64:
        fail("NoSpace: total pages >64 or memsz >256K")
    # PT_INTERP record-only: at most one, len<=256, NUL, path pin.
    interps = [r for r in raws if r[0] == PT_INTERP]
    interp_blob = None
    if len(interps) > 1:
        fail("BadDyn: double-interp")
    if interps:
        (_t, _f, poff, _v, filesz, _m, _a) = interps[0]
        if filesz > 256:
            fail("BadDyn: interp too long")
        if filesz == 0:
            fail("BadDyn: interp empty")
        if poff + filesz > len(img):
            fail("Truncated")
        raw = img[poff : poff + filesz]
        if b"\x00" not in raw:
            fail("BadDyn: interp not NUL-terminated")
        name, rest = raw.split(b"\x00", 1)
        if rest.strip(b"\x00"):
            fail("BadDyn: interp trailing bytes")
        if not name:
            fail("BadDyn: interp empty")
        if any(c < 32 or c > 126 for c in name):
            fail("BadDyn: interp non-printable")
        s = name.decode("ascii")
        if s != LD_HOUSE:
            fail("BadDyn: interp path " + s)
        interp_blob = bytes(raw)
    # PT_DYNAMIC parse (bounds + allowlist + RELA caps).
    dyns = [r for r in raws if r[0] == PT_DYNAMIC]
    dyn_blob = None
    dyn_va = 0
    if len(dyns) > 1:
        fail("BadDyn: double-dynamic")
    if dyns:
        (_t, _f, poff, vaddr, filesz, _m, _a) = dyns[0]
        if poff + filesz > len(img):
            fail("Truncated")
        check_dynamic(img, poff, filesz, segs)
        dyn_blob = img[poff : poff + filesz]
        dyn_va = vaddr
    # PT_GNU_RELRO record-only: at most one, inside one LOAD.
    relros = [r for r in raws if r[0] == PT_GNU_RELRO]
    relro = None
    if len(relros) > 1:
        fail("BadDyn: double-relro")
    if relros:
        (_t, _f, _o, vaddr, _fs, memsz, _a) = relros[0]
        if memsz != 0:
            end = vaddr + memsz
            if end < vaddr:
                fail("OverlapSize: p_offset+p_filesz overflow or > file")
            ok = any(lv <= vaddr and end <= lv + len(lb) for (lv, lb, _fl) in blobs)
            if not ok:
                fail("BadDyn: relro outside LOAD")
            relro = (vaddr, end)
    n = (
        len(blobs)
        + (1 if interp_blob is not None else 0)
        + (1 if dyn_blob is not None else 0)
        + (1 if relro is not None else 0)
    )
    if n > 8:
        fail("TooManyPhdrs: >8")
    ehdr = struct.pack(
        "<16sHHIQQQIHHHHHH",
        bytes([0x7F]) + b"ELF" + bytes([2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        etype,
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
                "<IIQQQQQQ", PT_LOAD, flags, off, vaddr, vaddr, len(blob), len(blob), 0
            )
        )
        off += len(blob)
    if interp_blob is not None:
        out.append(
            struct.pack(
                "<IIQQQQQQ",
                PT_INTERP,
                0,
                off,
                0,
                0,
                len(interp_blob),
                len(interp_blob),
                1,
            )
        )
        off += len(interp_blob)
    if dyn_blob is not None:
        out.append(
            struct.pack(
                "<IIQQQQQQ",
                PT_DYNAMIC,
                0,
                off,
                dyn_va,
                dyn_va,
                len(dyn_blob),
                len(dyn_blob),
                8,
            )
        )
        off += len(dyn_blob)
    if relro is not None:
        (rs, re) = relro
        out.append(
            struct.pack("<IIQQQQQQ", PT_GNU_RELRO, 0, 0, rs, rs, re - rs, re - rs, 1)
        )
    for _, blob, _ in blobs:
        out.append(blob)
    if interp_blob is not None:
        out.append(interp_blob)
    if dyn_blob is not None:
        out.append(dyn_blob)
    with open(dst, "wb") as f:
        f.write(b"".join(out))
    print(f"entry=0x{new_entry:x} loads={len(blobs)} pages={pages} total={off}B")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
