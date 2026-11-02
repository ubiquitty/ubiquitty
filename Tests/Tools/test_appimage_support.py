#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Reject mismatched architectures and modified support libraries before packaging."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("appimage_support", Path(__file__).resolve().parents[2] / "Scripts/appimage-support.py")
support = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(support)


class SupportBundle(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.files = {}
        for name in ("runtime", "updater/bin/appimageupdatetool", "updater/lib/libexample.so", "support-sources.tar.xz"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\x7fELF\x02\x01" + b"\0" * 12 + b"\x3e\0")
            self.files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.write_manifest()

    def write_manifest(self):
        (self.root / "manifest.json").write_text(json.dumps({"architecture": "x86_64", "files": self.files}))

    def test_matches_architecture_and_content(self):
        support.verify(self.root, "x86_64")
        with self.assertRaisesRegex(ValueError, "another architecture"):
            support.verify(self.root, "aarch64")
        (self.root / "updater/lib/libexample.so").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "differs"):
            support.verify(self.root, "x86_64")

    def test_rejects_unrecorded_dependency(self):
        (self.root / "updater/lib/unrecorded.so").write_bytes(b"new library")
        with self.assertRaisesRegex(ValueError, "unrecorded"):
            support.verify(self.root, "x86_64")

    def test_rejects_missing_sources(self):
        del self.files["support-sources.tar.xz"]
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "missing"):
            support.verify(self.root, "x86_64")

    def test_rejects_escape_and_symlink(self):
        self.files["../outside"] = "0" * 64
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "escapes"):
            support.verify(self.root, "x86_64")
        del self.files["../outside"]
        self.write_manifest()
        path = self.root / "updater/lib/libexample.so"
        path.unlink()
        path.symlink_to(self.root / "runtime")
        with self.assertRaisesRegex(ValueError, "differs"):
            support.verify(self.root, "x86_64")


if __name__ == "__main__":
    unittest.main()
