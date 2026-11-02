#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Runs Scripts/install-macos.sh against fixture bundles.

The install directory, the state directory and LaunchServices are the
fixture's; `codesign`, `open` and `ps` are stand-ins on PATH. Nothing inside a
fixture bundle is executed as a Mach-O: macOS judges a bundle whose main
executable's signature does not cover its Info.plist damaged, kills the process
and asks the person at the screen to move it to the Bin. So a "running" app is
an ordinary /bin/sleep whose pid the stand-in `ps` reports under the installed
bundle's executable path, and quitting it is killing that sleep. The claims: only
a release bundle is installed; an install keeps exactly one previous version,
out of LaunchServices; a running app is never swapped out from under itself;
--wait-for-quit installs once it quits, from a waiter that outlives the call;
and only the installed executable itself counts as running.
"""

import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "install-macos.sh"
RELEASE = "org.ubiquitty.Ubiquitty"


def program(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/bash\n" + content)
    path.chmod(0o755)


def bundle(path, identifier, marker):
    """Writes an app bundle carrying `identifier` and a marker file."""
    contents = path / "Contents"
    contents.mkdir(parents=True)
    with open(contents / "Info.plist", "wb") as plist:
        plistlib.dump({"CFBundleIdentifier": identifier}, plist)
    program(contents / "MacOS/Ubiquitty", 'exit 0\n')
    program(contents / "Helpers/ubiquitty-host", "exit 0\n")
    (contents / "marker").write_text(marker)
    return path


def marker(path):
    try:
        return (path / "Contents/marker").read_text()
    except FileNotFoundError:
        return None


@unittest.skipUnless(sys.platform == "darwin", "the installer is macOS-only (ditto, ps -o args)")
class InstallMacOS(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="ubq-install-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.applications = self.directory / "Applications"
        self.state = self.directory / "state"
        self.target = self.applications / "Ubiquitty.app"
        self.previous = self.state / "previous/Ubiquitty.app"
        self.staged = self.state / "staged/Ubiquitty.app"
        tools = self.directory / "tools"
        self.registrations = self.directory / "lsregister-calls"
        self.opened = self.directory / "open-calls"
        program(tools / "codesign", "exit 0\n")
        program(tools / "open", f'printf "%s\\n" "$*" >> "{self.opened}"\n')
        program(tools / "lsregister", f'printf "%s\\n" "$*" >> "{self.registrations}"\n')
        # `ps -axo pid=,args=` as the script asks it: the fixture's process
        # table, one "pid command" line per process.
        self.process_table = self.directory / "process-table"
        self.process_table.write_text("")
        program(tools / "ps", f'cat "{self.process_table}"\n')
        self.environment = dict(os.environ, UBIQUITTY_INSTALL_DIR=str(self.applications),
                                UBIQUITTY_INSTALL_STATE=str(self.state),
                                UBIQUITTY_LSREGISTER=str(tools / "lsregister"),
                                PATH=str(tools) + os.pathsep + os.environ.get("PATH", ""))
        self.processes = []
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait()

    def install(self, *arguments):
        return subprocess.run(["bash", str(SCRIPT), *arguments], capture_output=True, text=True,
                              env=self.environment, timeout=60)

    def registration_calls(self):
        return self.registrations.read_text().splitlines() if self.registrations.exists() else []

    def run_process_listed_as(self, command):
        """Starts a live process and lists it in the process table as `command`."""
        process = subprocess.Popen(["/bin/sleep", "60"])
        self.processes.append(process)
        with open(self.process_table, "a") as table:
            table.write(f"{process.pid:>6} {command}\n")
        return process

    def run_installed_app(self):
        """A live process the process table reports as the installed app."""
        return self.run_process_listed_as(str(self.target / "Contents/MacOS/Ubiquitty"))

    def test_a_development_bundle_is_never_installed(self):
        for identifier in (f"{RELEASE}.dev", f"{RELEASE}.uitest", ""):
            with self.subTest(identifier=identifier):
                source = bundle(self.directory / f"build-{identifier or 'none'}/Ubiquitty.app", identifier, "new")
                checked = self.install("--app", str(source))
                self.assertEqual(checked.returncode, 2, checked.stdout + checked.stderr)
                self.assertIn("Only a release build is installed or shipped", checked.stderr)
                self.assertFalse(self.target.exists())
                self.assertFalse(self.staged.exists())
                self.assertEqual(self.registration_calls(), [])

    def test_an_install_keeps_exactly_one_previous_version_out_of_launch_services(self):
        bundle(self.target, RELEASE, "installed")
        bundle(self.previous, RELEASE, "older")
        source = bundle(self.directory / "build/Ubiquitty.app", RELEASE, "new")

        checked = self.install("--app", str(source), "--open")
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(marker(self.target), "new")
        self.assertEqual(marker(self.previous), "installed", "the replaced app is the one previous version")
        self.assertFalse(self.staged.exists())
        self.assertEqual(marker(source), "new", "the build is copied, not moved")
        calls = self.registration_calls()
        self.assertIn(f"-u {self.previous}", calls)
        self.assertIn(f"-u {self.staged}", calls)
        self.assertEqual(calls[-1], f"-f {self.target}", "the installed bundle is registered last")
        self.assertEqual(self.opened.read_text().splitlines(), [str(self.target)])

    def test_a_running_app_is_never_swapped_out_from_under_itself(self):
        bundle(self.target, RELEASE, "installed")
        running = self.run_installed_app()
        source = bundle(self.directory / "build/Ubiquitty.app", RELEASE, "new")

        checked = self.install("--app", str(source))
        self.assertEqual(checked.returncode, 3, checked.stdout + checked.stderr)
        self.assertIn(f"pid {running.pid}", checked.stderr)
        self.assertEqual(marker(self.target), "installed")
        self.assertEqual(marker(self.staged), "new", "the verified build waits, staged")
        self.assertNotIn(f"-f {self.target}", self.registration_calls())
        self.assertFalse(self.opened.exists())

    def test_waiting_for_quit_installs_once_the_app_quits(self):
        bundle(self.target, RELEASE, "installed")
        running = self.run_installed_app()
        source = bundle(self.directory / "build/Ubiquitty.app", RELEASE, "new")

        checked = self.install("--app", str(source), "--wait-for-quit", "--open")
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertIn("the install happens when it quits", checked.stdout)
        time.sleep(1.5)
        self.assertEqual(marker(self.target), "installed", "nothing moves while the app runs")

        running.send_signal(signal.SIGTERM)
        running.wait()
        deadline = time.monotonic() + 15
        while marker(self.target) != "new" and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertEqual(marker(self.target), "new", (self.state / "install.log").read_text())
        self.assertEqual(marker(self.previous), "installed")
        deadline = time.monotonic() + 5
        while not self.opened.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertEqual(self.opened.read_text().splitlines(), [str(self.target)])

    def test_only_the_installed_executable_itself_counts_as_running(self):
        bundle(self.target, RELEASE, "installed")
        # A process that merely names the executable in its arguments is not it,
        # and neither is another bundle's executable that shares its prefix.
        executable = self.target / "Contents/MacOS/Ubiquitty"
        self.run_process_listed_as(f"/bin/bash -c true {executable}")
        self.run_process_listed_as(f"{executable}-helper")
        source = bundle(self.directory / "build/Ubiquitty.app", RELEASE, "new")

        checked = self.install("--app", str(source))
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(marker(self.target), "new")


if __name__ == "__main__":
    unittest.main()
