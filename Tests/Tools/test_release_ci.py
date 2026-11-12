#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""A release cannot publish incomplete bytes or hide failed revision checks."""

from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_ci", ROOT / "Scripts/release_ci.py")
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleaseTests(unittest.TestCase):
    def test_notarization_requires_one_complete_credential_set(self):
        common = {name: "fixture" for name in RELEASE.SECRETS}
        common["RELEASE_TOOLS_SSH_KEY"] = "fixture"
        self.assertTrue(RELEASE.missing_credentials(common))
        for group in RELEASE.NOTARY_CREDENTIALS:
            complete = dict(common, **{name: "fixture" for name in group})
            self.assertEqual(RELEASE.missing_credentials(complete), [])
            for name in group:
                partial = complete.copy()
                del partial[name]
                with self.subTest(missing=name):
                    self.assertTrue(RELEASE.missing_credentials(partial))
            del complete["SPARKLE_ED_PRIVATE_KEY"]
            self.assertIn("SPARKLE_ED_PRIVATE_KEY", RELEASE.missing_credentials(complete))

    def test_private_tools_require_a_reader_credential(self):
        common = {name: "fixture" for name in RELEASE.SECRETS}
        common.update({name: "fixture" for name in RELEASE.NOTARY_CREDENTIALS[0]})
        self.assertTrue(RELEASE.missing_credentials(common))
        for name in RELEASE.TOOLS_CREDENTIALS:
            with self.subTest(credential=name):
                self.assertEqual(RELEASE.missing_credentials(dict(common, **{name: "fixture"})), [])

    def test_tags_are_stable_versions_without_shell_or_path_syntax(self):
        self.assertEqual(RELEASE.version("v0.4.0"), "0.4.0")
        for tag in ("0.4.0", "v0.04.0", "v0.4.0-rc1", "v0.4.0/other", "v0.4.0\n", "$(id)"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                RELEASE.version(tag)

    def test_latest_required_checks_must_both_succeed(self):
        checks = [{"id": 1, "name": "CI", "status": "completed", "conclusion": "success"},
                  {"id": 2, "name": "gitleaks", "status": "completed", "conclusion": "success"}]
        RELEASE.required_checks({"check_runs": checks})
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", None):
            failed = {"id": 3, "name": "CI", "status": "completed", "conclusion": conclusion}
            with self.subTest(conclusion=conclusion), self.assertRaises(ValueError):
                RELEASE.required_checks({"check_runs": [failed, *checks]})
        with self.assertRaises(ValueError):
            RELEASE.required_checks({"check_runs": checks[:1]})

    def test_every_shipping_asset_is_required_and_empty_files_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            expected = RELEASE.expected_assets("0.4.0")
            for name in expected:
                (directory / name).write_bytes(b"release fixture")
            with redirect_stdout(io.StringIO()):
                RELEASE.verify_assets(directory, "0.4.0")
            self.assertEqual(len((directory / "SHA256SUMS").read_text().splitlines()), len(expected))
            for name in sorted(expected):
                with self.subTest(name=name):
                    path = directory / name
                    path.write_bytes(b"")
                    with self.assertRaises(ValueError):
                        RELEASE.verify_assets(directory, "0.4.0")
                    path.write_bytes(b"release fixture")

    def test_duplicate_downloads_cannot_overwrite_different_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for group, data in (("macos-release", b"first"), ("client-release", b"different")):
                (root / group).mkdir()
                (root / group / "composition.json").write_bytes(data)
            with patch.dict("os.environ", {"RUNNER_TEMP": str(root)}), self.assertRaisesRegex(ValueError, "conflicting"):
                RELEASE.assemble(root / "out", "0.4.0")

    def test_a_rebuilt_or_wrong_pgo_image_is_never_retagged_as_the_training_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stamp = root / RELEASE.CORE_PATH / "Support/pgo/linux-x86_64-core.trained-toolchain"
            stamp.parent.mkdir(parents=True)
            stamp.write_text(json.dumps({"image": "sha256:" + "a" * 64, "recipe": "recipe"}))
            with patch.object(RELEASE.subprocess, "run") as run, \
                    patch.object(RELEASE.subprocess, "check_output", return_value="sha256:" + "b" * 64), \
                    self.assertRaisesRegex(ValueError, "profile requires"):
                RELEASE.load_image(root, "x86_64", "ghcr.io/ubiquitty/toolchain@sha256:" + "c" * 64)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][:2], ["docker", "pull"])

    def test_mutable_pgo_image_references_are_refused_before_docker(self):
        with patch.object(RELEASE.subprocess, "run") as run, self.assertRaises(ValueError):
            RELEASE.load_image(ROOT, "x86_64", "ghcr.io/ubiquitty/toolchain:latest")
        run.assert_not_called()

    def test_ios_package_excludes_objects_and_refuses_a_missing_executable(self):
        import tarfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "ios-iphonesimulator"
            app = stage / "Ubiquitty.app"
            app.mkdir(parents=True)
            (app / "Info.plist").write_text("fixture")
            (stage / "private-object.o").write_bytes(b"must not ship")
            arguments = ["release_ci.py", "ios", "--tag", "v0.4.0", "--sdk", "iphonesimulator",
                         "--directory", str(root / "dist")]
            with patch.dict("os.environ", {"UBQ_BUILD_ROOT": str(root)}), patch("sys.argv", arguments):
                with patch("sys.stderr", io.StringIO()):
                    self.assertEqual(RELEASE.main(), 1)
                (app / "Ubiquitty").write_bytes(b"executable fixture")
                self.assertEqual(RELEASE.main(), 0)
            with tarfile.open(root / "dist/Ubiquitty-0.4.0-ios-iphonesimulator-development.tar.xz") as archive:
                self.assertIn("Ubiquitty.app/Ubiquitty", archive.getnames())
                self.assertFalse(any("private-object" in name for name in archive.getnames()))

    def test_publication_needs_every_platform_and_verifies_before_pointers(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        finalize = workflow.split("  finalize:\n", 1)[1]
        needs = finalize.split("needs:", 1)[1].splitlines()[0]
        for job in ("release", "release-linux", "release-ubq", "verify-ubq", "web", "ios", "source-packages"):
            self.assertIn(job, needs)
        self.assertLess(finalize.index('"$UBQ_RELEASE_CI" verify'), finalize.index("publish-macos-r2.py pointers"))
        self.assertLess(finalize.index('"$UBQ_RELEASE_CI" verify'), finalize.index("--draft=false"))
        self.assertIn("tags: ['v*.*.*']", workflow)
        self.assertNotIn("self-hosted", workflow)
        self.assertNotIn("--upload", workflow)


if __name__ == "__main__":
    unittest.main()
