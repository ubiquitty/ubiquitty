#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""A release cannot publish incomplete bytes or hide failed revision checks."""

from contextlib import redirect_stdout
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import struct
import tempfile
import textwrap
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_ci", ROOT / "Scripts/release_ci.py")
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class ReleaseTests(unittest.TestCase):
    def release_source_bootstrap(self, version="0.4.0", identity="01234567", failed_field=""):
        action = (ROOT / ".github/actions/release-source/action.yml").read_text()
        script = textwrap.dedent(action.split("      run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            product = directory / "product"
            tools = directory / "bin"
            tools.mkdir()
            helper = product / "Libraries/ubiquitty-kit/Libraries/ubiquitty-core/Scripts/build-version.sh"
            helper.parent.mkdir(parents=True)
            helper.write_text('#!/bin/sh\n'
                              '[ "$1" != "$FAILED_FIELD" ] || exit 23\n'
                              'case "$1" in\n'
                              'version) printf "%s\\n" "$FIXTURE_VERSION" ;;\n'
                              'identity) printf "%s\\n" "$FIXTURE_IDENTITY" ;;\n'
                              'esac\n')
            helper.chmod(0o755)
            for name in ("cmake", "ninja", "ccache", "brew"):
                tool = tools / name
                tool.write_text('#!/bin/sh\n' + ('printf "%s\\n" "$*" >> "$BREW_LOG"\n' if name == "brew" else 'exit 0\n'))
                tool.chmod(0o755)
            output = directory / "environment"
            brew_log = directory / "brew.log"
            environment = {**os.environ, "PATH": str(tools), "RUNNER_OS": "macOS",
                           "RUNNER_WORKSPACE": str(directory), "RUNNER_TEMP": str(directory),
                           "GITHUB_WORKSPACE": str(directory), "GITHUB_ENV": str(output),
                           "RELEASE_SOURCE_TAG": "v0.4.0", "BREW_LOG": str(brew_log),
                           "FIXTURE_VERSION": version, "FIXTURE_IDENTITY": identity,
                           "FAILED_FIELD": failed_field}
            checked = subprocess.run(["/bin/bash", "-c", script], cwd=product, env=environment,
                                     text=True, capture_output=True, timeout=10)
            return (checked, output.read_text() if output.exists() else "",
                    brew_log.read_text() if brew_log.exists() else "")

    def test_release_source_installs_go_and_exports_verified_metadata(self):
        checked, environment, installed = self.release_source_bootstrap()
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(installed, "install go\n")
        self.assertIn("UBIQUITTY_BUILD_VERSION=0.4.0\n", environment)
        self.assertIn("UBIQUITTY_BUILD_IDENTITY=01234567\n", environment)

    def test_failed_or_empty_version_queries_cannot_export_release_metadata(self):
        for options in ({"failed_field": "version"}, {"failed_field": "identity"},
                        {"version": ""}, {"identity": ""}, {"version": "0.4.1"}):
            with self.subTest(options=options):
                checked, environment, _ = self.release_source_bootstrap(**options)
                self.assertNotEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                self.assertEqual(environment, "")

    def collect_linux_hosts(self, damage=""):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Collect Linux host binaries\n", 1)[1].split("      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        core_root = ROOT / RELEASE.CORE_PATH
        spec = importlib.util.spec_from_file_location("release_host_artifact_fixture", core_root / "Scripts/linux-host-artifact.py")
        artifact = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(artifact)
        with tempfile.TemporaryDirectory(prefix="ubq-host-artifact-") as temporary:
            directory = Path(temporary)
            product = directory / "product with spaces"
            nested_core = product / RELEASE.CORE_PATH
            nested_core.parent.mkdir(parents=True)
            nested_core.symlink_to(core_root, target_is_directory=True)
            inputs = directory / "host-cross-artifacts"
            image = next(line.removeprefix("host=") for line in (core_root / "Scripts/linux-images.txt").read_text().splitlines() if line.startswith("host="))
            for arch in ("x86_64", "arm64"):
                binary = inputs / arch / ("ubiquitty-host-linux-" + arch)
                binary.parent.mkdir(parents=True)
                data = bytearray(120)
                data[:7] = b"\x7fELF\x02\x01\x01"
                struct.pack_into("<HH", data, 16, 2, artifact.MACHINES[arch])
                struct.pack_into("<Q", data, 32, 64)
                struct.pack_into("<HH", data, 54, 56, 1)
                struct.pack_into("<I", data, 64, 1)
                binary.write_bytes(data)
                key = artifact.source_key(core_root, arch, image, "ON", "0.4.0", "release-fixture")
                manifest = {"format": 1, "key": key, "sha256": hashlib.sha256(data).hexdigest()}
                artifact.manifest_path(binary).write_text(json.dumps(manifest))
            binary = inputs / "arm64/ubiquitty-host-linux-arm64"
            if damage == "missing manifest":
                artifact.manifest_path(binary).unlink()
            elif damage == "changed binary":
                binary.write_bytes(binary.read_bytes() + b"changed")
            elif damage == "wrong source":
                metadata = json.loads(artifact.manifest_path(binary).read_text())
                metadata["key"] = "0" * 64
                artifact.manifest_path(binary).write_text(json.dumps(metadata))
            environment = {**os.environ, "RUNNER_TEMP": str(directory), "UBQ_BUILD_ROOT": str(directory / "build"),
                           "UBIQUITTY_SOURCE_ROOT": str(product), "UBIQUITTY_BUILD_VERSION": "0.4.0",
                           "UBIQUITTY_BUILD_IDENTITY": "release-fixture"}
            checked = subprocess.run(["/bin/bash", "-c", script], env=environment, text=True,
                                     capture_output=True, timeout=30)
            output = directory / "build/host-cross"
            return checked, sorted(path.name for path in output.iterdir())

    def test_macos_collection_preserves_both_linux_hosts_and_provenance(self):
        checked, names = self.collect_linux_hosts()
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(names, sorted("ubiquitty-host-linux-" + arch + suffix
                                      for arch in ("x86_64", "arm64") for suffix in ("", ".json")))

    def test_macos_collection_rejects_missing_changed_or_wrong_source_hosts(self):
        for damage in ("missing manifest", "changed binary", "wrong source"):
            with self.subTest(damage=damage):
                checked, _ = self.collect_linux_hosts(damage)
                self.assertNotEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_dispatch_passes_the_product_tag_to_the_packager(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Build + package the AppImage\n", 1)[1].split("      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        package = (ROOT / "Scripts/package-linux-appimage.sh").read_text()
        start = package.index('if [ -n "${GITHUB_REF_NAME:-}" ]')
        guard = package[start:package.index("\nfi", start) + 4]
        for tag in ("v0.4.0", "v0.4.1"):
            with self.subTest(tag=tag), tempfile.TemporaryDirectory(prefix="ubq-release-dispatch-") as temporary:
                product = Path(temporary)
                image = product / RELEASE.CORE_PATH / "Scripts/ci-linux-image.sh"
                image.parent.mkdir(parents=True)
                image.write_text('#!/bin/sh\nexec "$@"\n')
                image.chmod(0o755)
                packager = product / "Scripts/package-linux-appimage.sh"
                packager.parent.mkdir()
                packager.write_text('#!/bin/sh\nVERSION=0.4.0\n' + guard + '\nprintf "%s\\n" "$GITHUB_REF_NAME"\n')
                packager.chmod(0o755)
                environment = {**os.environ, "PRODUCT_TAG": tag, "GITHUB_REF_NAME": "main", "UBQ_PGO_LLVM": ""}
                checked = subprocess.run(["/bin/bash", "-c", script], cwd=product, env=environment,
                                         text=True, capture_output=True, timeout=10)
                if tag == "v0.4.0":
                    self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                    self.assertEqual(checked.stdout.strip(), tag)
                else:
                    self.assertNotEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                    self.assertIn("the built version", checked.stderr)

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

    def test_ci_prepares_every_platform_without_signing_or_publishing(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        prepare = workflow.split("  prepare:\n", 1)[1]
        needs = prepare.split("needs:", 1)[1].splitlines()[0]
        for job in ("release", "release-linux", "release-ubq", "verify-ubq", "web", "ios", "source-packages"):
            self.assertIn(job, needs)
        action = (ROOT / ".github/actions/release-source/action.yml").read_text()
        for text in (workflow, action):
            for forbidden in ("secrets.", "contents: write", "packages: write", "notarytool", "security import",
                              "release-macos.sh", "publish-", "gh release", "--upload", "self-hosted"):
                self.assertNotIn(forbidden, text)
        self.assertIn("tags: ['v*.*.*']", workflow)
        self.assertIn('UBIQUITTY_SIGN_IDENTITY: ad-hoc', workflow)
        self.assertIn('name: release-preparation', prepare)
        for job in ("preflight", "source-packages"):
            definition = workflow.split("  " + job + ":\n", 1)[1].split("    steps:", 1)[0]
            self.assertIn("checks: read", definition)


if __name__ == "__main__":
    unittest.main()
