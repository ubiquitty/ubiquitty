#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Checks conformance-runner policy selection without launching a terminal."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


class EsctestSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ubq-esctest-policy-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = Path(__file__).resolve().parent.parent
        self.scripts = self.root / "Scripts"
        self.scripts.mkdir()
        for name in ("run-esctest.sh", "run-esctest-linux.sh", "library-scripts.sh"):
            shutil.copyfile(self.repository / "Scripts" / name, self.scripts / name)
        config = self.root / "Tests" / "Esctest" / "clipboard-read.toml"
        config.parent.mkdir(parents=True)
        shutil.copyfile(self.repository / "Tests" / "Esctest" / config.name, config)
        self.suite = self.root / "suite"
        (self.suite / "esctest").mkdir(parents=True)
        (self.suite / "esctest" / "esctest.py").write_text("# fixture\n")
        self.user_config = self.root / "user-config"
        (self.user_config / "ubiquitty").mkdir(parents=True)
        self.user_document = self.user_config / "ubiquitty" / "config.toml"
        self.user_document.write_text('[security]\nclipboard_read = "deny"\n')
        self.report = self.root / "report.json"
        self.commands = self.root / "commands"
        self.commands.mkdir()
        for name in ("defaults", "sysctl", "sw_vers"):
            self.executable(self.commands / name, "#!/bin/sh\nprintf 'fixture\\n'\n")
        # A root the caller exported would point the planted scripts at a real
        # library instead of the planted tree.
        self.environment = {name: value for name, value in os.environ.items()
                            if name not in ("UBQ_CORE_ROOT", "UBQ_KIT_ROOT")}
        self.environment.update(
            PATH=str(self.commands) + os.pathsep + os.environ["PATH"],
            XDG_CONFIG_HOME=str(self.user_config),
            UBIQUITTY_UNATTENDED="1",
            UBIQUITTY_ESCTEST=str(self.suite),
            ESC_FIXTURE_REPORT=str(self.report),
            # The planted tree stands for every repository: its fixtures are the
            # scripts a checkout would take from the libraries it carries.
            UBIQUITTY_CORE_SOURCE_DIR=str(self.root),
            UBIQUITTY_KIT_SOURCE_DIR=str(self.root),
        )
        self.app = self.root / "Fixture.app"
        binary = self.app / "Contents" / "MacOS" / "Ubiquitty"
        binary.parent.mkdir(parents=True)
        self.executable(binary, f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
configuration = pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "ubiquitty" / "config.toml"
pathlib.Path(os.environ["ESC_FIXTURE_REPORT"]).write_text(json.dumps({
    "arguments": sys.argv[1:],
    "configuration": str(configuration),
    "document": configuration.read_text(),
    "override": os.environ.get("UBIQUITTY_UNATTENDED"),
}))
log = next(argument.split("=", 1)[1] for argument in sys.argv if argument.startswith("--logfile="))
pathlib.Path(log).write_text("1 tests passed\\n")
''')
        self.build = self.root / "build"
        self.container = self.build / "linux-container"
        linux_binary = self.container / "linux" / "ubiquitty-linux"
        linux_binary.parent.mkdir(parents=True)
        self.executable(linux_binary, "#!/bin/sh\nexit 99\n")
        (self.scripts / "build-root.sh").write_text(f"UBQ_BUILD_ROOT={shlex.quote(str(self.build))}\n")
        self.environment["ESC_FIXTURE_BUILD"] = str(self.container)
        self.executable(self.scripts / "run-linux.sh", f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
assignments = dict(argument.split("=", 1) for argument in sys.argv[1:] if argument.startswith("ESC_"))
configuration = assignments["ESC_TEST_CONFIG"]
build = pathlib.Path(os.environ["ESC_FIXTURE_BUILD"])
document = (build / configuration.removeprefix("/src/build/")).read_text() if configuration else None
pathlib.Path(os.environ["ESC_FIXTURE_REPORT"]).write_text(json.dumps({
    "assignments": assignments,
    "configuration": configuration,
    "document": document,
    "override": os.environ.get("UBIQUITTY_UNATTENDED"),
    "runner": (build / "run-esctest-inner.sh").read_text(),
}))
(build / "esctest-linux.log").write_text("*** 1 tests passed\\n")
''')

    @staticmethod
    def executable(path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_wrapper(self, platform, *arguments):
        if platform == "macos":
            command = ["bash", str(self.scripts / "run-esctest.sh"), "--app", str(self.app), "--esctest", str(self.suite)]
        else:
            command = ["bash", str(self.scripts / "run-esctest-linux.sh")]
        completed = subprocess.run(command + list(arguments), env=self.environment, capture_output=True, text=True, timeout=15)
        self.assertEqual(self.user_document.read_text(), '[security]\nclipboard_read = "deny"\n')
        return completed

    def successful_report(self, platform, *arguments):
        completed = self.run_wrapper(platform, *arguments)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        report = json.loads(self.report.read_text())
        self.assertIsNone(report["override"])
        return report

    def assert_clipboard_only(self, report):
        settings = [line.strip() for line in report["document"].splitlines() if line.strip() and not line.lstrip().startswith("#")]
        self.assertEqual(settings, ["[security]", 'clipboard_read = "allow"'])

    def test_macos_default_keeps_user_policy_and_arguments(self):
        report = self.successful_report("macos", "--", "--include", "DECRQM")
        self.assertEqual(report["configuration"], str(self.user_document))
        self.assertEqual(report["arguments"][-2:], ["--include", "DECRQM"])
        self.assertIn("normal policy", (self.root / "BuildEsctest" / "esctest-provenance.txt").read_text())

    def test_macos_opt_in_is_isolated_and_clipboard_read_only(self):
        report = self.successful_report("macos", "--allow-clipboard-read")
        self.assertNotEqual(report["configuration"], str(self.user_document))
        self.assert_clipboard_only(report)
        self.assertNotIn("--allow-clipboard-read", report["arguments"])
        self.assertIn(report["configuration"], (self.root / "BuildEsctest" / "esctest-provenance.txt").read_text())

    def test_macos_malformed_opt_in_does_not_launch(self):
        completed = self.run_wrapper("macos", "--allow-clipboard-read=all")
        self.assertEqual(completed.returncode, 2)
        self.assertFalse(self.report.exists())

    def test_linux_default_keeps_policy_and_arguments(self):
        report = self.successful_report("linux", "--include", "DECRQM")
        self.assertEqual(report["configuration"], "")
        self.assertEqual(report["assignments"]["ESC_EXTRA"], "--include DECRQM")
        self.assertIn('binary="${ESC_BINARY:-/src/build/linux/ubiquitty-linux}"', report["runner"])
        self.assertIn('"$binary" "$@" -e', report["runner"])
        self.assertIn('if [ -n "$ESC_TEST_CONFIG" ]; then', report["runner"])
        self.assertNotIn("UBIQUITTY_UNATTENDED=1", report["runner"])

    def test_linux_opt_in_is_isolated_and_clipboard_read_only(self):
        report = self.successful_report("linux", "--allow-clipboard-read", "--include", "OSC52")
        self.assertTrue(report["configuration"].startswith("/src/build/esctest-config."))
        self.assert_clipboard_only(report)
        self.assertEqual(report["assignments"]["ESC_EXTRA"], "--include OSC52")
        self.assertIn('set -- --config "$ESC_TEST_CONFIG"', report["runner"])

    def test_linux_malformed_opt_in_does_not_launch(self):
        completed = self.run_wrapper("linux", "--allow-clipboard-read=all")
        self.assertEqual(completed.returncode, 2)
        self.assertFalse(self.report.exists())


if __name__ == "__main__":
    unittest.main()
