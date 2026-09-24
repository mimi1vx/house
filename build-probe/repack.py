#!/usr/bin/env python3
"""Repackage linked AArch64 ELF files for the House bounded ELF loader.

Static ET_EXEC inputs retain the historical byte-for-byte output. Dynamic
ET_DYN inputs use standard low relative virtual addresses, zero-filled BSS,
SysV hash/dynamic symbols, relative PLT relocation tables, eager symbol
relocations, bind-now, and RELRO. The validation contract mirrors
Kernel.Userspace.Loader; unknown or unsupported metadata fails closed.
"""

import struct
import sys
from typing import NoReturn

MAX_ELF_BYTES = 1024 * 1024
MAX_PHNUM = 8
MAX_SEG_MEM = 256 * 1024
MAX_PAGES = 64
MAX_INTERP = 256
MAX_DYN_STR = 64 * 1024
MAX_NEEDED = 8
MAX_RELA = 4096
MAX_DYN_ENT = 64
MAX_NEEDED_NAME = 128
MAX_HASH_BUCKETS = 4096
MAX_SYMBOLS = 4096
MAX_SYMBOL_NAME = 256
MIN_EXEC_VADDR = 0x01000000
MAX_VADDR = 0xFFFFFFFF
LD_HOUSE = "/lib/ld-house.so.0"
PAGE_SIZE = 4096
STACK_PAGE = 0x3FFFD000
ALLOWED_ALIGN = (0, 4096, 8192, 16384, 32768, 65536)

PT_LOAD = 1
PT_DYNAMIC = 2
PT_INTERP = 3
PT_TLS = 7
PT_GNU_RELRO = 0x6474E552
PF_W = 2

DT_NULL = 0
DT_NEEDED = 1
DT_PLTRELSZ = 2
DT_PLTGOT = 3
DT_HASH = 4
DT_STRTAB = 5
DT_SYMTAB = 6
DT_RELA = 7
DT_RELASZ = 8
DT_RELAENT = 9
DT_STRSZ = 10
DT_SYMENT = 11
DT_INIT = 12
DT_FINI = 13
DT_SONAME = 14
DT_REL = 17
DT_RELSZ = 18
DT_RELENT = 19
DT_PLTREL = 20
DT_DEBUG = 21
DT_TEXTREL = 22
DT_JMPREL = 23
DT_BIND_NOW = 24
DT_INIT_ARRAY = 25
DT_FINI_ARRAY = 26
DT_INIT_ARRAYSZ = 27
DT_FINI_ARRAYSZ = 28
DT_RUNPATH = 29
DT_FLAGS = 30
DT_PREINIT_ARRAY = 32
DT_PREINIT_ARRAYSZ = 33
DT_PREINIT_ARRAYSZ_ENT = 34
DT_RELR = 36
DT_RELRSZ = 35
DT_RELRENT = 37
DT_RELA_COUNT = 0x6FFFFFF9
DT_GNU_HASH = 0x6FFFFEF5
DT_FLAGS_1 = 0x6FFFFFFB
DT_VERSYM = 0x6FFFFFF0
DT_VERDEF = 0x6FFFFFFC
DT_VERNEED = 0x6FFFFFFE
DT_TLS_DESCRIPTOR_PLT = 0x6FFFFEF6
DT_TLS_DESCRIPTOR_GOT = 0x6FFFFEF7
DT_TLSMODULE = 0x6FFFFEF9
DT_TLSLO = 0x6FFFFEFA
DT_TLSHI = 0x6FFFFEFB

DF_BIND_NOW = 0x8
DF_TEXTREL = 0x4
DF_1_NOW = 0x1
STT_TLS = 6
R_GLOB_DAT = 1025
R_JUMP_SLOT = 1026
R_RELATIVE = 1027
R_TLS_FIRST = 1028
R_IRELATIVE = 1037


def fail(reason: str) -> NoReturn:
    print(reason, file=sys.stderr)
    sys.exit(1)


def u16(buf: bytes, off: int) -> int:
    if off < 0 or off > len(buf) - 2:
        fail("Truncated")
    return struct.unpack_from("<H", buf, off)[0]


def u32(buf: bytes, off: int) -> int:
    if off < 0 or off > len(buf) - 4:
        fail("Truncated")
    return struct.unpack_from("<I", buf, off)[0]


def u64(buf: bytes, off: int) -> int:
    if off < 0 or off > len(buf) - 8:
        fail("Truncated")
    return struct.unpack_from("<Q", buf, off)[0]


def va_to_file(
    segs: list[tuple[int, int, int, int, int]], va: int, size: int = 1
) -> int | None:
    """Translate a file-backed object VA range to an input file offset."""
    for lvaddr, lpoff, lfilesz, lmemsz, _flags in segs:
        if lvaddr <= va and va - lvaddr + size <= lfilesz:
            return lpoff + (va - lvaddr)
    return None


def va_in_segment(
    segs: list[tuple[int, int, int, int, int]],
    va: int,
    size: int = 1,
    require_writable: bool = False,
) -> bool:
    for lvaddr, _lpoff, _lfilesz, lmemsz, flags in segs:
        writable = (flags & PF_W) != 0
        if (
            lvaddr <= va
            and va - lvaddr + size <= lmemsz
            and (not require_writable or writable)
        ):
            return True
    return False


def validate_load_layout(
    loads: list[tuple[int, int, int, int, int]],
) -> None:
    pages = [
        (vaddr // PAGE_SIZE, (vaddr + memsz - 1) // PAGE_SIZE)
        for vaddr, _poff, _filesz, memsz, _flags in loads
    ]
    for index, (first, last) in enumerate(pages):
        if first <= STACK_PAGE // PAGE_SIZE <= last:
            fail("BadSegment: stack page collision")
        for other_first, other_last in pages[index + 1 :]:
            if first <= other_last and other_first <= last:
                fail("BadSegment: overlapping LOAD pages")


def printable_name(raw: bytes, label: str, limit: int) -> str:
    if any(byte < 32 or byte > 126 for byte in raw):
        fail(f"BadDyn: {label} non-printable")
    if len(raw) > limit:
        fail(f"BadDyn: {label} too long")
    return raw.decode("ascii")


def resolve_string(strtab: bytes, strsz: int, off: int, label: str, limit: int) -> str:
    if off < 0 or off >= strsz:
        fail(f"BadDyn: {label} offset")
    end = strtab.find(b"\0", off)
    if end < 0:
        fail(f"BadDyn: {label} not NUL")
    return printable_name(strtab[off:end], label, limit)


def table_count(
    label: str, address: int | None, size: int | None, entry: int | None
) -> int:
    if address is None and size is None and entry is None:
        return 0
    if address is None or size is None or entry is None:
        fail(f"BadDyn: incomplete {label} metadata")
    if entry != 24 or size % entry != 0:
        fail(f"BadDyn: {label} metadata")
    count = size // entry
    if count > MAX_RELA:
        fail("BadDyn: rela count")
    return count


def check_relocations(
    img: bytes,
    table_off: int,
    count: int,
    segs: list[tuple[int, int, int, int, int]],
    bind_now: bool,
    symbol_names: list[str],
) -> None:
    for index in range(count):
        entry_off = table_off + index * 24
        r_offset = u64(img, entry_off)
        r_info = u64(img, entry_off + 8)
        r_type = r_info & 0xFFFFFFFF
        symbol_index = r_info >> 32
        if r_type == 0:
            if symbol_index != 0:
                fail("BadDyn: R_NONE symbol index")
            continue
        if r_type == R_RELATIVE:
            if symbol_index != 0:
                fail(f"UnsupportedReloc: {r_type}")
            if not va_in_segment(segs, r_offset, 8):
                fail("BadDyn: rela outside LOAD")
        elif r_type in (R_GLOB_DAT, R_JUMP_SLOT):
            if not bind_now:
                fail("BadDyn: eager relocation without bind-now")
            if symbol_index == 0 or symbol_index >= len(symbol_names):
                fail("BadDyn: eager relocation symbol index")
            if not symbol_names[symbol_index]:
                fail("BadDyn: eager relocation symbol name")
            if not va_in_segment(segs, r_offset, 8, require_writable=True):
                fail("BadDyn: rela target not writable")
        elif r_type == R_IRELATIVE:
            fail("BadDyn: IRELATIVE unsupported")
        elif r_type >= R_TLS_FIRST:
            fail("TlsUnsupported")
        else:
            fail(f"UnsupportedReloc: {r_type}")


def check_dynamic(
    img: bytes,
    dyn_off: int,
    dyn_sz: int,
    segs: list[tuple[int, int, int, int, int]],
) -> None:
    if dyn_sz % 16 != 0:
        fail("BadDyn: dynamic size")
    entry_count = dyn_sz // 16
    if entry_count > MAX_DYN_ENT:
        fail("BadDyn: dynamic too many")

    needed_offs: list[int] = []
    soname_off: int | None = None
    strtab_va: int | None = None
    strsz = 0
    symtab_va: int | None = None
    syment: int | None = None
    hash_va: int | None = None
    rela_va: int | None = None
    relasz: int | None = None
    relaent: int | None = None
    jmprel_va: int | None = None
    pltrelsz: int | None = None
    pltrel: int | None = None
    pltgot: int | None = None
    flags = 0
    flags_1 = 0
    bind_now_tag = False
    seen: set[int] = set()
    saw_null = False

    for index in range(entry_count):
        tag = u64(img, dyn_off + index * 16)
        value = u64(img, dyn_off + index * 16 + 8)
        if tag == DT_NULL:
            saw_null = True
            break
        if tag == DT_NEEDED:
            needed_offs.append(value)
            continue
        if tag in seen:
            fail(f"BadDyn: duplicate DT_{tag}")
        seen.add(tag)

        if tag == DT_SONAME:
            soname_off = value
        elif tag == DT_STRTAB:
            strtab_va = value
        elif tag == DT_STRSZ:
            strsz = value
        elif tag == DT_SYMTAB:
            symtab_va = value
        elif tag == DT_SYMENT:
            syment = value
        elif tag == DT_HASH:
            hash_va = value
        elif tag == DT_RELA:
            rela_va = value
        elif tag == DT_RELASZ:
            relasz = value
        elif tag == DT_RELAENT:
            relaent = value
        elif tag == DT_JMPREL:
            jmprel_va = value
        elif tag == DT_PLTRELSZ:
            pltrelsz = value
        elif tag == DT_PLTREL:
            pltrel = value
        elif tag == DT_PLTGOT:
            pltgot = value
        elif tag == DT_FLAGS:
            if value & DF_TEXTREL:
                fail("BadDyn: TEXTREL unsupported")
            flags = value
        elif tag == DT_FLAGS_1:
            flags_1 = value
        elif tag == DT_BIND_NOW:
            bind_now_tag = True
        elif tag == DT_DEBUG:
            pass
        elif tag == DT_RELA_COUNT:
            fail("BadDyn: RELACOUNT unsupported")
        elif tag == DT_GNU_HASH:
            fail("BadDyn: GNU hash unsupported")
        elif tag in (DT_VERSYM, DT_VERDEF, DT_VERNEED):
            fail("BadDyn: symbol versioning unsupported")
        elif tag == DT_TEXTREL:
            fail("BadDyn: TEXTREL unsupported")
        elif tag in (DT_REL, DT_RELSZ, DT_RELENT):
            fail("BadDyn: S REL unsupported")
        elif tag in (
            DT_INIT,
            DT_FINI,
            DT_INIT_ARRAY,
            DT_FINI_ARRAY,
            DT_INIT_ARRAYSZ,
            DT_FINI_ARRAYSZ,
            DT_PREINIT_ARRAY,
            DT_PREINIT_ARRAYSZ,
            DT_PREINIT_ARRAYSZ_ENT,
        ):
            fail("BadDyn: init/fini arrays unsupported")
        elif tag in (DT_RUNPATH, 34):
            fail(f"BadDyn: unsupported DT_{tag}")
        elif tag in (DT_RELR, DT_RELRSZ, DT_RELRENT):
            fail("BadDyn: RELR unsupported")
        elif tag in (
            DT_TLS_DESCRIPTOR_PLT,
            DT_TLS_DESCRIPTOR_GOT,
            DT_TLSMODULE,
            DT_TLSLO,
            DT_TLSHI,
        ):
            fail("TlsUnsupported")
        else:
            fail(f"BadDyn: unsupported DT_{tag}")

    if not saw_null:
        fail("BadDyn: missing DT_NULL")
    if strsz > MAX_DYN_STR:
        fail("BadDyn: strsz overrun")
    if len(needed_offs) > MAX_NEEDED:
        fail("BadDyn: needed too many")

    needs_strings = (
        bool(needed_offs)
        or soname_off is not None
        or hash_va is not None
        or symtab_va is not None
        or strsz != 0
    )
    strtab = b""
    if strtab_va is not None:
        strtab_off = va_to_file(segs, strtab_va, strsz)
        if strtab_off is None or strsz > len(img) - strtab_off:
            fail("BadDyn: strtab bounds")
        strtab = img[strtab_off : strtab_off + strsz]
    elif needs_strings:
        fail("BadDyn: missing STRTAB")

    for off in needed_offs:
        name = resolve_string(strtab, strsz, off, "needed", MAX_NEEDED_NAME)
        if not name:
            fail("BadDyn: needed empty")
        if "/" in name:
            fail("BadDyn: needed slash")
    if soname_off is not None and not resolve_string(
        strtab, strsz, soname_off, "soname", MAX_SYMBOL_NAME
    ):
        fail("BadDyn: soname empty")

    symbol_names: list[str] = []
    if (hash_va is None) != (symtab_va is None):
        fail("BadDyn: incomplete symbol metadata")
    if hash_va is None and syment is not None:
        fail("BadDyn: SYMENT without symbol metadata")
    if hash_va is not None:
        if syment is not None and syment != 24:
            fail("BadDyn: syment")
        hash_head = va_to_file(segs, hash_va, 8)
        if hash_head is None:
            fail("BadDyn: hash bounds")
        buckets = u32(img, hash_head)
        symbol_count = u32(img, hash_head + 4)
        if buckets == 0 or buckets > MAX_HASH_BUCKETS:
            fail("BadDyn: hash buckets")
        if symbol_count == 0 or symbol_count > MAX_SYMBOLS:
            fail("BadDyn: symbol count")
        hash_size = 8 + 4 * (buckets + symbol_count)
        hash_off = va_to_file(segs, hash_va, hash_size)
        if hash_off is None:
            fail("BadDyn: hash bounds")
        for index in range(buckets):
            if u32(img, hash_off + 8 + 4 * index) >= symbol_count:
                fail("BadDyn: hash bucket index")
        chains_off = hash_off + 8 + 4 * buckets
        for index in range(symbol_count):
            chain = u32(img, chains_off + 4 * index)
            if chain != 0 and chain >= symbol_count:
                fail("BadDyn: hash chain index")

        sym_off = va_to_file(segs, symtab_va, symbol_count * 24)
        if sym_off is None:
            fail("BadDyn: symtab bounds")
        for index in range(symbol_count):
            entry_off = sym_off + index * 24
            name_off = u32(img, entry_off)
            info = img[entry_off + 4]
            if (info & 0x0F) == STT_TLS:
                fail("BadDyn: TLS symbol unsupported")
            symbol_names.append(
                resolve_string(strtab, strsz, name_off, "symbol", MAX_SYMBOL_NAME)
            )

    bind_now = bind_now_tag or (flags & DF_BIND_NOW) != 0 or (flags_1 & DF_1_NOW) != 0
    if pltgot is not None and not va_in_segment(segs, pltgot):
        fail("BadDyn: PLTGOT outside LOAD")

    rela_count = table_count("RELA", rela_va, relasz, relaent)
    if (rela_va is None) != (relasz is None) or (relasz is None) != (relaent is None):
        fail("BadDyn: incomplete RELA metadata")
    if (jmprel_va is None) != (pltrelsz is None) or (pltrelsz is None) != (
        pltrel is None
    ):
        fail("BadDyn: incomplete PLT relocation metadata")
    if pltrel is not None and pltrel != DT_RELA:
        fail("BadDyn: PLTREL unsupported")
    plt_count = table_count(
        "PLT", jmprel_va, pltrelsz, 24 if pltrel is not None else None
    )
    if rela_count + plt_count > MAX_RELA:
        fail("BadDyn: rela count")

    if rela_count:
        rela_off = va_to_file(segs, rela_va, rela_count * 24)
        if rela_off is None:
            fail("BadDyn: rela bounds")
        check_relocations(img, rela_off, rela_count, segs, bind_now, symbol_names)
    if plt_count:
        jmprel_off = va_to_file(segs, jmprel_va, plt_count * 24)
        if jmprel_off is None:
            fail("BadDyn: rela bounds")
        check_relocations(img, jmprel_off, plt_count, segs, bind_now, symbol_names)


def parse_raw(
    img: bytes, phoff: int, phnum: int
) -> list[tuple[int, int, int, int, int, int, int]]:
    raws = []
    for index in range(phnum):
        off = phoff + index * 56
        ptype, flags = u32(img, off), u32(img, off + 4)
        if ptype == PT_TLS:
            fail("TlsUnsupported")
        poff, vaddr = u64(img, off + 8), u64(img, off + 16)
        filesz, memsz = u64(img, off + 32), u64(img, off + 40)
        align = u64(img, off + 48)
        raws.append((ptype, flags, poff, vaddr, filesz, memsz, align))
    return raws


def repack_static(
    img: bytes,
    etype: int,
    raws: list[tuple[int, int, int, int, int, int, int]],
    dst: str,
) -> None:
    loads = []
    for ptype, flags, poff, vaddr, filesz, memsz, align in raws:
        if ptype == PT_LOAD:
            if filesz > memsz:
                fail("BadSegment: filesz > memsz")
            if filesz != memsz:
                fail("BadSegment: bss not supported")
            if filesz > 256 * 1024:
                fail("NoSpace: total pages >64 or memsz >256K")
            if align not in ALLOWED_ALIGN:
                fail("Misaligned: bad p_align or p_offset")
            if align and ((vaddr - poff) & (align - 1)):
                fail("Misaligned: bad p_align or p_offset")
            loads.append((vaddr, poff, filesz, flags))
    if not loads:
        fail("BadSegment: no PT_LOAD")
    loads.sort()
    validate_load_layout(
        [(vaddr, poff, filesz, filesz, flags) for vaddr, poff, filesz, flags in loads]
    )
    blobs = []
    new_entry = None
    entry = u64(img, 24)
    for vaddr, poff, filesz, flags in loads:
        if not (0x01000000 <= vaddr <= 0xFFFFFFFF):
            fail(f"OutOfWindow: 0x{vaddr:x}")
        if vaddr + filesz > 0x100000000:
            fail(f"OutOfWindow: 0x{vaddr + filesz:x}")
        if poff + filesz > len(img):
            fail("Truncated")
        blob = img[poff : poff + filesz]
        blobs.append((vaddr, blob, flags))
        if vaddr <= entry < vaddr + filesz:
            new_entry = vaddr + (entry - vaddr)
    if new_entry is None:
        fail("BadSegment: entry not in LOAD")
    pages = sum((len(blob) + 4095) // 4096 for _vaddr, blob, _flags in blobs)
    if pages > 64:
        fail("NoSpace: total pages >64 or memsz >256K")
    n = len(blobs)
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
    for _vaddr, blob, _flags in blobs:
        out.append(blob)
    with open(dst, "wb") as handle:
        handle.write(b"".join(out))
    print(f"entry=0x{new_entry:x} loads={len(blobs)} pages={pages} total={off}B")


def repack_dynamic(
    img: bytes,
    etype: int,
    raws: list[tuple[int, int, int, int, int, int, int]],
    dst: str,
) -> None:
    entry = u64(img, 24)
    loads: list[tuple[int, int, int, int, int]] = []
    for ptype, flags, poff, vaddr, filesz, memsz, align in raws:
        if ptype != PT_LOAD:
            continue
        if filesz > memsz:
            fail("BadSegment: filesz > memsz")
        if memsz > MAX_SEG_MEM:
            fail("NoSpace: total pages >64 or memsz >256K")
        if poff > len(img) or filesz > len(img) - poff:
            fail("Truncated")
        if align not in ALLOWED_ALIGN:
            fail("Misaligned: bad p_align or p_offset")
        if align and ((vaddr - poff) & (align - 1)):
            fail("Misaligned: bad p_align or p_offset")
        loads.append((vaddr, poff, filesz, memsz, flags))
    if not loads:
        fail("BadSegment: no PT_LOAD")
    loads.sort()
    validate_load_layout(loads)

    blobs: list[tuple[int, bytes, int]] = []
    segs: list[tuple[int, int, int, int, int]] = []
    new_entry = None
    for vaddr, poff, filesz, memsz, flags in loads:
        lower_ok = vaddr >= MIN_EXEC_VADDR if etype == 2 else vaddr >= 0
        if not lower_ok or vaddr > MAX_VADDR:
            fail(f"OutOfWindow: 0x{vaddr:x}")
        if vaddr + memsz > 0x100000000:
            fail(f"OutOfWindow: 0x{vaddr + memsz:x}")
        blob = img[poff : poff + filesz] + bytes(memsz - filesz)
        blobs.append((vaddr, blob, flags))
        segs.append((vaddr, poff, filesz, memsz, flags))
        if vaddr <= entry < vaddr + memsz:
            new_entry = entry
    if new_entry is None:
        fail("BadSegment: entry not in LOAD")
    pages = sum((len(blob) + 4095) // 4096 for _vaddr, blob, _flags in blobs)
    if pages > MAX_PAGES:
        fail("NoSpace: total pages >64 or memsz >256K")

    interps = [raw for raw in raws if raw[0] == PT_INTERP]
    interp_blob = None
    if len(interps) > 1:
        fail("BadDyn: double-interp")
    if interps:
        _ptype, _flags, poff, _vaddr, filesz, _memsz, _align = interps[0]
        if filesz > MAX_INTERP:
            fail("BadDyn: interp too long")
        if filesz == 0:
            fail("BadDyn: interp empty")
        if poff > len(img) or filesz > len(img) - poff:
            fail("Truncated")
        raw = img[poff : poff + filesz]
        if b"\0" not in raw:
            fail("BadDyn: interp not NUL-terminated")
        name, rest = raw.split(b"\0", 1)
        if rest.strip(b"\0"):
            fail("BadDyn: interp trailing bytes")
        value = printable_name(name, "interp", MAX_INTERP)
        if not value:
            fail("BadDyn: interp empty")
        if value != LD_HOUSE:
            fail("BadDyn: interp path " + value)
        interp_blob = bytes(raw)

    dynamics = [raw for raw in raws if raw[0] == PT_DYNAMIC]
    dyn_blob = None
    dyn_va = 0
    if len(dynamics) > 1:
        fail("BadDyn: double-dynamic")
    if dynamics:
        _ptype, _flags, poff, vaddr, filesz, _memsz, _align = dynamics[0]
        if poff > len(img) or filesz > len(img) - poff:
            fail("Truncated")
        check_dynamic(img, poff, filesz, segs)
        dyn_blob = img[poff : poff + filesz]
        dyn_va = vaddr

    relros = [raw for raw in raws if raw[0] == PT_GNU_RELRO]
    relro = None
    if len(relros) > 1:
        fail("BadDyn: double-relro")
    if relros:
        _ptype, _flags, _poff, vaddr, _filesz, memsz, _align = relros[0]
        if memsz:
            end = vaddr + memsz
            if end < vaddr:
                fail("OverlapSize: p_offset+p_filesz overflow or > file")
            if not any(
                start <= vaddr and end <= start + mem
                for start, _poff, _fs, mem, _flags in segs
            ):
                fail("BadDyn: relro outside LOAD")
            relro = (vaddr, end)

    phnum = (
        len(blobs)
        + (1 if interp_blob is not None else 0)
        + (1 if dyn_blob is not None else 0)
        + (1 if relro is not None else 0)
    )
    if phnum > MAX_PHNUM:
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
        phnum,
        0,
        0,
        0,
    )
    out = [ehdr]
    off = 64 + 56 * phnum
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
        relro_start, relro_end = relro
        relro_size = relro_end - relro_start
        out.append(
            struct.pack(
                "<IIQQQQQQ",
                PT_GNU_RELRO,
                0,
                0,
                relro_start,
                relro_start,
                relro_size,
                relro_size,
                1,
            )
        )
    for _vaddr, blob, _flags in blobs:
        out.append(blob)
    if interp_blob is not None:
        out.append(interp_blob)
    if dyn_blob is not None:
        out.append(dyn_blob)
    with open(dst, "wb") as handle:
        handle.write(b"".join(out))
    print(f"entry=0x{new_entry:x} loads={len(blobs)} pages={pages} total={off}B")


def main(src: str, dst: str) -> None:
    with open(src, "rb") as handle:
        img = handle.read(MAX_ELF_BYTES + 1)
    if len(img) > MAX_ELF_BYTES:
        fail("OverlapSize: p_offset+p_filesz overflow or > file")
    if img[:4] != b"\x7fELF":
        fail("BadMagic: not ELF64 LE")
    if len(img) < 64:
        fail("Truncated")
    if img[4] != 2 or img[5] != 1 or img[6] != 1:
        fail("BadMagic: not ELF64 LE")
    if u16(img, 18) != 183:
        fail("BadArch: need AArch64")
    etype = u16(img, 16)
    if etype not in (2, 3):
        fail("BadType: need ET_EXEC/ET_DYN")
    phoff = u64(img, 32)
    phentsz = u16(img, 54)
    phnum = u16(img, 56)
    if phnum > MAX_PHNUM:
        fail("TooManyPhdrs: >8")
    if phentsz not in (0, 56) and phnum > 0:
        fail("BadSegment: phentsz !=56")
    if phoff + phnum * (phentsz or 56) > len(img):
        fail("Truncated")
    raws = parse_raw(img, phoff, phnum)
    has_dynamic_metadata = any(
        raw[0] in (PT_INTERP, PT_DYNAMIC, PT_GNU_RELRO) for raw in raws
    )
    if etype == 2 and not has_dynamic_metadata:
        repack_static(img, etype, raws, dst)
    else:
        repack_dynamic(img, etype, raws, dst)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
