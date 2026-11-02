#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercises Sparkle download verification and cache replacement offline."""

import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOLS = ("generate_keys", "sign_update", "generate_appcast", "BinaryDelta")


class FetchSparkleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-sparkle-test.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prefix = self.root / "Sparkle cache"
        self.marker = self.prefix / ".sparkle-release"
        self.archive = self.root / "release.tar.xz"
        self.events = self.root / "downloads"
        self.script = self.root / "Scripts/fetch-sparkle.sh"
        self.script.parent.mkdir()
        self.source = (ROOT / "Scripts/fetch-sparkle.sh").read_text()
        self.version = re.search(r'^SPARKLE_VERSION="([^"]+)"$', self.source, re.MULTILINE)[1]
        (self.script.parent / "build-root.sh").write_text(': "${UBQ_BUILD_ROOT:?}"\n')
        self.make_archive()
        self.pin_fixture_archive()
        binary = self.root / "bin"
        binary.mkdir()
        curl = binary / "curl"
        curl.write_text("#!" + sys.executable + "\n" + '''
import os
import shutil
import sys

arguments = sys.argv[1:]
with open(os.environ["FETCH_SPARKLE_EVENTS"], "a") as output:
    output.write(arguments[-1] + "\\n")
shutil.copyfile(os.environ["FETCH_SPARKLE_ARCHIVE"], arguments[arguments.index("-o") + 1])
''')
        curl.chmod(0o755)
        self.environment = os.environ | {
            "UBQ_BUILD_ROOT": str(self.root / "build"),
            "FETCH_SPARKLE_ARCHIVE": str(self.archive),
            "FETCH_SPARKLE_EVENTS": str(self.events),
            "PATH": str(binary) + os.pathsep + os.environ.get("PATH", ""),
        }

    def make_archive(self, archive_prefix="./"):
        release = self.root / "release"
        framework = release / "Sparkle.framework"
        framework.mkdir(parents=True, exist_ok=True)
        (framework / "release.txt").write_text("verified fixture")
        binary = release / "bin"
        binary.mkdir(exist_ok=True)
        for name in TOOLS:
            tool = binary / name
            tool.write_text("#!/bin/sh\nexit 97\n")
            tool.chmod(0o755)
        with tarfile.open(self.archive, "w:xz") as archive:
            archive.add(framework, arcname=archive_prefix + "Sparkle.framework")
            archive.add(binary, arcname=archive_prefix + "bin")

    def pin_fixture_archive(self):
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        source, count = re.subn(r'^SPARKLE_SHA256="[0-9a-f]{64}"$',
                                'SPARKLE_SHA256="' + self.digest + '"', self.source,
                                flags=re.MULTILINE)
        self.assertEqual(count, 1)
        self.script.write_text(source)
        self.expected_marker = self.version + " " + self.digest + "\n"

    def run_fetch(self):
        return subprocess.run(["/bin/bash", str(self.script), str(self.prefix)],
                              env=self.environment, capture_output=True, text=True, timeout=20)

    def downloads(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def install_legacy_cache(self):
        framework = self.prefix / "Sparkle.framework"
        framework.mkdir(parents=True)
        (framework / "release.txt").write_text("legacy fixture")
        binary = self.prefix / "bin"
        binary.mkdir()
        for name in TOOLS:
            tool = binary / name
            tool.write_text("legacy tool")
            tool.chmod(0o755)
        (binary / "obsolete").write_text("legacy only")

    def assert_complete_cache(self):
        self.assertEqual((self.prefix / "Sparkle.framework/release.txt").read_text(), "verified fixture")
        self.assertTrue(all(os.access(self.prefix / "bin" / name, os.X_OK) for name in TOOLS))
        self.assertEqual(self.marker.read_text(), self.expected_marker)
        self.assertFalse(list(self.prefix.glob(".sparkle-stage.*")))
        self.assertFalse(list(self.prefix.glob("*.tar.xz")))

    def test_fresh_cache_installs_verified_release(self):
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete_cache()
        self.assertEqual(self.downloads(), [
            "https://github.com/sparkle-project/Sparkle/releases/download/"
            + self.version + "/Sparkle-" + self.version + ".tar.xz",
        ])

    def test_legacy_cache_is_replaced(self):
        self.install_legacy_cache()
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete_cache()
        self.assertFalse((self.prefix / "bin/obsolete").exists())
        self.assertEqual(len(self.downloads()), 1)

    def test_verified_current_cache_skips_download(self):
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.archive.unlink()
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already present", result.stdout)
        self.assert_complete_cache()
        self.assertEqual(len(self.downloads()), 1)

    def test_old_version_or_digest_marker_cannot_skip_download(self):
        self.install_legacy_cache()
        for marker in ("2.9.2 " + self.digest + "\n", self.version + " " + "0" * 64 + "\n"):
            with self.subTest(marker=marker):
                self.marker.write_text(marker)
                result = self.run_fetch()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_complete_cache()
        self.assertEqual(len(self.downloads()), 2)

    def test_missing_tool_invalidates_current_cache(self):
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.prefix / "bin/sign_update").unlink()
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete_cache()
        self.assertEqual(len(self.downloads()), 2)

    def test_corrupt_download_preserves_legacy_cache_without_certifying_it(self):
        self.install_legacy_cache()
        self.archive.write_bytes(b"corrupt download")
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertEqual((self.prefix / "Sparkle.framework/release.txt").read_text(), "legacy fixture")
        self.assertEqual((self.prefix / "bin/sign_update").read_text(), "legacy tool")
        self.assertTrue((self.prefix / "bin/obsolete").exists())
        self.assertFalse(self.marker.exists())
        self.assertFalse(list(self.prefix.glob(".sparkle-stage.*")))

    def test_incomplete_verified_archive_preserves_legacy_cache(self):
        self.install_legacy_cache()
        (self.root / "release/bin/sign_update").unlink()
        with tarfile.open(self.archive, "w:xz") as archive:
            archive.add(self.root / "release/Sparkle.framework", arcname="./Sparkle.framework")
            archive.add(self.root / "release/bin", arcname="./bin")
        self.pin_fixture_archive()
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing after extract", result.stderr)
        self.assertEqual((self.prefix / "Sparkle.framework/release.txt").read_text(), "legacy fixture")
        self.assertFalse(self.marker.exists())
        self.assertFalse(list(self.prefix.glob(".sparkle-stage.*")))

    def test_failed_install_invalidates_marker_and_can_retry(self):
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.prefix / "bin/sign_update").unlink()
        move = self.root / "bin/mv"
        move.write_text("#!/bin/sh\nexit 71\n")
        move.chmod(0o755)
        result = self.run_fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertFalse(list(self.prefix.glob(".sparkle-stage.*")))
        move.unlink()
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete_cache()
        self.assertEqual(len(self.downloads()), 3)

    def test_bare_archive_member_names_are_supported(self):
        self.make_archive(archive_prefix="")
        self.pin_fixture_archive()
        result = self.run_fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_complete_cache()


if __name__ == "__main__":
    unittest.main()
