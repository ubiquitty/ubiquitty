#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Runs the build script's signing stage with controlled tool substitutes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MacOSSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-signing-test.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Fixture App.app"
        self.events = self.root / "events.jsonl"
        (self.root / "Scripts").mkdir()
        shutil.copy2(ROOT / "Scripts/sign-sparkle.sh", self.root / "Scripts/sign-sparkle.sh")
        for name in ("ubiquitty-host", "ubq"):
            helper = self.app / "Contents/Helpers" / name
            helper.parent.mkdir(parents=True, exist_ok=True)
            helper.write_text("fixture")
        self.framework = self.app / "Contents/Frameworks/Sparkle.framework"
        version = self.framework / "Versions/B"
        for name in ("XPCServices/Downloader.xpc", "XPCServices/Installer.xpc", "Updater.app"):
            (version / name).mkdir(parents=True)
        (version / "Autoupdate").write_text("fixture")
        (self.framework / "Versions/Current").symlink_to("B")
        binary = self.root / "bin"
        binary.mkdir()
        stub = "#!" + sys.executable + "\n" + '''
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
arguments = sys.argv[1:]
with open(os.environ["SIGNING_EVENTS"], "a") as output:
    output.write(json.dumps({"tool": tool, "arguments": arguments}) + "\\n")
if tool == "security":
    print(os.environ.get("TEST_IDENTITIES", ""))
elif "--verify" in arguments:
    raise SystemExit(int(os.environ.get("FAIL_VERIFY", "0")))
elif "--sign" in arguments:
    failure = os.environ.get("FAIL_SIGN_TARGET")
    if failure and any(value.endswith("/" + failure) for value in arguments):
        raise SystemExit(31)
'''
        for tool in ("codesign", "security"):
            path = binary / tool
            path.write_text(stub)
            path.chmod(0o755)
        source = (ROOT / "Scripts/build-macos.sh").read_text()
        start = 'SIGN_ID="${UBIQUITTY_SIGN_IDENTITY:-}"\n'
        end = '\nif [ "$RUN" = "1" ]; then\n'
        self.assertEqual(source.count(start), 1)
        self.assertEqual(source.count(end), 1)
        self.stage = self.root / "signing-stage.sh"
        self.stage.write_text("#!/bin/bash\nset -euo pipefail\n" + start + source.split(start, 1)[1].split(end, 1)[0])
        self.environment = os.environ.copy()
        self.environment.pop("UBIQUITTY_SIGN_IDENTITY", None)
        self.environment.update(ROOT=str(self.root), APP=str(self.app), HELPERS_BUNDLE="1",
                                RELEASE_SIGNING="0", SIGNING_EVENTS=str(self.events),
                                PATH=str(binary) + os.pathsep + os.environ.get("PATH", ""))

    def run_stage(self, **environment):
        result = subprocess.run(["/bin/bash", str(self.stage)], env=self.environment | environment,
                                capture_output=True, text=True, timeout=20)
        events = [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []
        return result, events

    def assert_signing_order(self, events, identity):
        commands = [event["arguments"] for event in events if event["tool"] == "codesign"]
        signs = [arguments for arguments in commands if "--sign" in arguments]
        self.assertEqual(len(signs), 7)
        self.assertTrue(all(arguments[arguments.index("--sign") + 1] == identity for arguments in signs))
        self.assertEqual(signs[0][-2:], [str(self.app / "Contents/Helpers/ubiquitty-host"),
                                        str(self.app / "Contents/Helpers/ubq")])
        self.assertEqual([arguments[-1] for arguments in signs[1:]], [
            str(self.framework / "Versions/Current/XPCServices/Downloader.xpc"),
            str(self.framework / "Versions/Current/XPCServices/Installer.xpc"),
            str(self.framework / "Versions/Current/Autoupdate"),
            str(self.framework / "Versions/Current/Updater.app"),
            str(self.framework), str(self.app),
        ])
        return commands

    def test_explicit_ad_hoc_signs_inner_to_outer_without_keychain_access(self):
        result, events = self.run_stage(UBIQUITTY_SIGN_IDENTITY="ad-hoc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(event["tool"] == "security" for event in events))
        commands = self.assert_signing_order(events, "-")
        self.assertEqual(commands[-1], ["--verify", "--deep", "--strict", str(self.app)])
        self.assertIn("Signed: ad-hoc", result.stdout)

    def test_no_available_identity_uses_verified_ad_hoc_signing(self):
        result, events = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(event["tool"] == "security" for event in events))
        commands = self.assert_signing_order(events, "-")
        self.assertEqual(commands[-1], ["--verify", "--deep", "--strict", str(self.app)])

    def test_ad_hoc_component_or_outer_failure_stops_the_build(self):
        for target in ("ubiquitty-host", "Downloader.xpc", "Fixture App.app"):
            with self.subTest(target=target):
                result, _ = self.run_stage(UBIQUITTY_SIGN_IDENTITY="ad-hoc", FAIL_SIGN_TARGET=target)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Signed: ad-hoc", result.stdout)

    def test_ad_hoc_verification_failure_stops_the_build(self):
        result, _ = self.run_stage(UBIQUITTY_SIGN_IDENTITY="ad-hoc", FAIL_VERIFY="32")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Signed: ad-hoc", result.stdout)

    def test_named_development_identity_keeps_existing_flags(self):
        result, events = self.run_stage(UBIQUITTY_SIGN_IDENTITY="Fixture Developer")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.assert_signing_order(events, "Fixture Developer")
        self.assertFalse(any("--options" in arguments or "--timestamp" in arguments for arguments in commands))
        self.assertIn('Signed: "Fixture Developer"', result.stdout)

    def test_developer_id_keeps_hardened_runtime_timestamp_and_verification(self):
        identity = "Developer ID Application: Fixture Developer (EXAMPLE)"
        result, events = self.run_stage(UBIQUITTY_SIGN_IDENTITY=identity, RELEASE_SIGNING="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.assert_signing_order(events, identity)
        for arguments in commands[:-1]:
            self.assertIn("--timestamp", arguments)
            self.assertEqual(arguments[arguments.index("--options") + 1], "runtime")
        self.assertEqual(commands[-1], ["--verify", "--deep", "--strict", str(self.app)])


if __name__ == "__main__":
    unittest.main()
