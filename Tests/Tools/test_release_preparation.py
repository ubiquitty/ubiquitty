#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
import release_preparation as preparation


class PreparationTests(unittest.TestCase):
    def fixture(self, root):
        inputs = root / "inputs"
        inputs.mkdir()
        for name in preparation.expected_assets("0.4.0"):
            (inputs / name).write_bytes(b"fixture")
        refs = {"core": "a" * 40, "kit": "b" * 40, "ubiquitty": "c" * 40}
        (inputs / "composition.json").write_text(json.dumps({"tag": "v0.4.0", "version": "0.4.0", "repositories": refs}))
        return inputs, refs

    def test_preparation_requires_every_platform_and_matches_tagged_revisions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs, refs = self.fixture(root)
            output = root / "prepared"
            preparation.collect(inputs, output, "v0.4.0")
            preparation.verify(output, "v0.4.0", refs)
            with self.assertRaisesRegex(ValueError, "tagged Core"):
                preparation.verify(output, "v0.4.0", dict(refs, core="d" * 40))
            (output / "ubq-linux-arm64").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "checksum"):
                preparation.verify(output, "v0.4.0", refs)

    def test_a_missing_platform_and_conflicting_bytes_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs, refs = self.fixture(root)
            (inputs / "ubq-linux-arm64").unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                preparation.collect(inputs, root / "prepared", "v0.4.0")
            (inputs / "ubq-linux-arm64").write_bytes(b"client")
            (inputs / "another").mkdir()
            (inputs / "another/ubq-linux-arm64").write_bytes(b"different")
            with self.assertRaisesRegex(ValueError, "conflicting"):
                preparation.collect(inputs, root / "different", "v0.4.0")

    def test_archive_traversal_and_escaping_links_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "app.zip"
            for name in ["../outside", "/absolute", "other.app/file"]:
                with zipfile.ZipFile(archive, "w") as output:
                    output.writestr(name, b"data")
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    preparation.inspect_macos_archive(archive)
            with zipfile.ZipFile(archive, "w") as output:
                link = zipfile.ZipInfo("Ubiquitty.app/link")
                link.create_system = 3
                link.external_attr = 0o120777 << 16
                output.writestr(link, "../../outside")
            with self.assertRaisesRegex(ValueError, "escaping"):
                preparation.inspect_macos_archive(archive)
            with zipfile.ZipFile(archive, "w") as output:
                link = zipfile.ZipInfo("Ubiquitty.app/Contents/Frameworks/Sparkle.framework/Versions/Current")
                link.create_system = 3
                link.external_attr = 0o120777 << 16
                output.writestr(link, "A")
            preparation.inspect_macos_archive(archive)


if __name__ == "__main__":
    unittest.main()
