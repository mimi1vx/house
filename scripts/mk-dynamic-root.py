#!/usr/bin/env python3
"""Build the deterministic HFS1 image used by the mounted-root dynamic probe."""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
from pathlib import Path

MAX_IMAGE_BYTES = 2 * 1024 * 1024
ROOT_IMAGE_BYTES = 64 * 1024 * 1024
MAGIC = b"HFS1"
VERSION = 2


def u16(value: int) -> bytes:
    return struct.pack("<H", value)


def u32(value: int) -> bytes:
    return struct.pack("<I", value)


def entry(path: str, content: bytes) -> bytes:
    encoded = path.encode("latin-1")
    return u16(len(encoded)) + encoded + u32(len(content)) + content


def encode_image(files: list[tuple[str, bytes]]) -> bytes:
    body = b"".join(entry(path, content) for path, content in files)
    total = 4 + 1 + 4 + 4 + 4 + len(body)
    if total > MAX_IMAGE_BYTES:
        raise ValueError("dynamic root image exceeds HFS1 limit")
    return MAGIC + bytes([VERSION]) + u32(0) + u32(total) + u32(len(files)) + body


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("dso", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    dso = args.dso.read_bytes()
    if not dso:
        raise ValueError("dynamic root DSO is empty")

    image = encode_image(
        [
            ("/lib/libc-house.so.0", b"not-an-elf"),
            ("/lib/libc-missing.so.0", dso),
        ]
    )
    if len(image) > ROOT_IMAGE_BYTES:
        raise ValueError("dynamic root image does not fit raw disk")

    payload = image + bytes(ROOT_IMAGE_BYTES - len(image))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(args.output.name + ".tmp")
    temporary.write_bytes(payload)
    os.chmod(temporary, 0o644)
    os.replace(temporary, args.output)
    print(f"{hashlib.sha256(payload).hexdigest()}  {args.output}")


if __name__ == "__main__":
    main()
