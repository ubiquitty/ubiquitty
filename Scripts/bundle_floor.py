#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Refuse a Mac bundle whose code needs a newer macOS than the bundle declares.

LSMinimumSystemVersion decides which machines install the app; each Mach-O's
LC_BUILD_VERSION (or LC_VERSION_MIN_MACOSX) decides which machines can load it.
When a binary's minimum is above the bundle's, the app installs and then fails
to launch with no hint of why. Ubiquitty 0.5.0 shipped that way: the bundle
said 26.0 and the executable, linked by a swiftc given no -target on a macOS 27
build machine, said 27.0.

Every Mach-O in the bundle is read, each slice of a universal one included.
Pure Python, so it runs without Xcode and is tested on any host.

Usage: bundle_floor.py <path/to/App.app>
"""
from __future__ import annotations

from pathlib import Path
import plistlib
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE
LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1


def parse_version(text):
    parts = [int(part) for part in str(text).split(".")]
    return tuple((parts + [0, 0, 0])[:3])


def format_version(version):
    major, minor, patch = version
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def _decode_packed(packed):
    return (packed >> 16, (packed >> 8) & 0xFF, packed & 0xFF)


def _slice_minimum(data, offset):
    """The macOS minimum one thin Mach-O slice declares, or None."""
    if len(data) < offset + 28:
        return None
    magic = struct.unpack_from("<I", data, offset)[0]
    if magic == MH_MAGIC_64:
        header_size = 32
    elif magic == MH_MAGIC:
        header_size = 28
    else:
        return None
    command_count = struct.unpack_from("<I", data, offset + 16)[0]
    cursor = offset + header_size
    for _ in range(command_count):
        if len(data) < cursor + 8:
            raise ValueError("truncated load commands")
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8:
            raise ValueError("malformed load command")
        if command == LC_BUILD_VERSION:
            platform, minimum = struct.unpack_from("<II", data, cursor + 8)
            if platform == PLATFORM_MACOS:
                return _decode_packed(minimum)
        elif command == LC_VERSION_MIN_MACOSX:
            return _decode_packed(struct.unpack_from("<I", data, cursor + 8)[0])
        cursor += size
    return None


def minimums(data):
    """Each slice's declared macOS minimum; empty when `data` is not a Mach-O."""
    if len(data) < 8:
        return []
    magic = struct.unpack_from(">I", data)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        entry, layout = (32, ">iiQQI") if magic == FAT_MAGIC_64 else (20, ">iiIII")
        found = []
        for index in range(count):
            _, _, offset, _, _ = struct.unpack_from(layout, data, 8 + index * entry)
            minimum = _slice_minimum(data, offset)
            if minimum is not None:
                found.append(minimum)
        return found
    minimum = _slice_minimum(data, 0)
    return [] if minimum is None else [minimum]


def violations(app):
    """(relative path, minimum) for each binary above the bundle's declared floor."""
    app = Path(app)
    with (app / "Contents/Info.plist").open("rb") as stream:
        declared = plistlib.load(stream).get("LSMinimumSystemVersion")
    if not declared:
        raise ValueError(f"{app} declares no LSMinimumSystemVersion")
    floor = parse_version(declared)
    found = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            head = stream.read(4)
            if len(head) < 4 or struct.unpack(">I", head)[0] not in (
                    FAT_MAGIC, FAT_MAGIC_64, 0xCFFAEDFE, 0xCEFAEDFE):
                continue
            data = head + stream.read()
        for minimum in minimums(data):
            if minimum > floor:
                found.append((str(path.relative_to(app)), minimum))
    return floor, found


def check(app):
    floor, found = violations(app)
    if found:
        lines = [f"  {path} requires macOS {format_version(minimum)}" for path, minimum in found]
        raise ValueError(
            f"{Path(app).name} declares LSMinimumSystemVersion {format_version(floor)}, "
            "but macOS at that version cannot load:\n" + "\n".join(lines))
    return floor


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    try:
        floor = check(argv[1])
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Every binary in {Path(argv[1]).name} loads on macOS {format_version(floor)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
