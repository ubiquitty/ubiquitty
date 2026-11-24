#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Scripts/bundle_floor.py against fixture bundles of hand-built Mach-O headers.

The claim: a bundle passes only when no slice of any binary in it declares a
macOS minimum above the bundle's LSMinimumSystemVersion. The 0.5.0 shape, a
26.0 bundle around a 27.0 executable, is the case that must fail.
"""

from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
import bundle_floor  # noqa: E402

ARM64 = 0x0100000C
X86_64 = 0x01000007


def packed(version):
    major, minor = (int(part) for part in version.split("."))
    return major << 16 | minor << 8


def thin(cpu, minimum, legacy=False):
    """A 64-bit Mach-O header with one deployment-target load command."""
    if legacy:
        command = struct.pack("<IIII", bundle_floor.LC_VERSION_MIN_MACOSX, 16, packed(minimum), packed(minimum))
    else:
        command = struct.pack("<IIIIII", bundle_floor.LC_BUILD_VERSION, 24,
                              bundle_floor.PLATFORM_MACOS, packed(minimum), packed(minimum), 0)
    header = struct.pack("<IiiIIIII", bundle_floor.MH_MAGIC_64, cpu, 0, 2, 1, len(command), 0, 0)
    return header + command


def fat(*slices):
    offset = 4096
    table, body = b"", b""
    for cpu, data in slices:
        table += struct.pack(">iiIII", cpu, 0, offset + len(body), len(data), 12)
        body += data + b"\0" * (4096 - len(data))
    header = struct.pack(">II", bundle_floor.FAT_MAGIC, len(slices)) + table
    return header + b"\0" * (offset - len(header)) + body


def bundle(root, declared, files):
    app = root / "Fixture.app"
    contents = app / "Contents"
    contents.mkdir(parents=True)
    with open(contents / "Info.plist", "wb") as stream:
        plistlib.dump({} if declared is None else {"LSMinimumSystemVersion": declared}, stream)
    for relative, data in files.items():
        path = contents / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return app


class BundleFloorTests(unittest.TestCase):
    def test_the_0_5_0_shape_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(Path(directory), "26.0", {
                "MacOS/Fixture": thin(ARM64, "27.0"),
                "Helpers/ubq": thin(ARM64, "13.3"),
            })
            with self.assertRaisesRegex(ValueError, r"Contents/MacOS/Fixture requires macOS 27\.0"):
                bundle_floor.check(app)
            self.assertEqual(bundle_floor.main(["bundle_floor.py", str(app)]), 1)

    def test_binaries_at_or_below_the_floor_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(Path(directory), "26.0", {
                "MacOS/Fixture": thin(ARM64, "26.0"),
                "Helpers/ubq": thin(ARM64, "13.3"),
                "Frameworks/Lib.framework/Versions/B/Lib": fat((X86_64, thin(X86_64, "10.13", legacy=True)),
                                                               (ARM64, thin(ARM64, "11.0"))),
                "Resources/notes.txt": b"not a binary",
                "Resources/tiny": b"\xcf",
            })
            self.assertEqual(bundle_floor.check(app), (26, 0, 0))

    def test_one_slice_of_a_universal_binary_is_enough_to_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(Path(directory), "14.0", {
                "MacOS/Fixture": fat((X86_64, thin(X86_64, "13.0", legacy=True)), (ARM64, thin(ARM64, "15.0"))),
            })
            _, found = bundle_floor.violations(app)
            self.assertEqual(found, [("Contents/MacOS/Fixture", (15, 0, 0))])

    def test_a_bundle_that_declares_no_floor_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            app = bundle(Path(directory), None, {"MacOS/Fixture": thin(ARM64, "13.3")})
            with self.assertRaisesRegex(ValueError, "declares no LSMinimumSystemVersion"):
                bundle_floor.check(app)


if __name__ == "__main__":
    unittest.main()
