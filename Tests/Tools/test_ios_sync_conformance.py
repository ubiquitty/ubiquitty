#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Exercise the simulator driver without booting a real device."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TESTS = ["test_sync_frame_catalog", "test_sync_wire_refusal", "test_quicbootstrap",
         "test_quic_bootstrap_reader", "test_sync_envelope", "test_sync_history_wire"]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["SIM_FIXTURE"])
args = sys.argv[1:]
state = root / "state"
def event(value):
    with (root / "events").open("a") as stream: stream.write(value + "\n")
if args[-1:] == ["--show-sdk-path"]:
    print(root / "sdk")
elif args[:1] == ["clang++"]:
    binary = pathlib.Path(args[args.index("-o") + 1])
    event("compile " + binary.name)
    state.write_text("Shutdown")
    if binary.name == os.environ.get("FAIL_COMPILE"): sys.exit(1)
    binary.write_text("#!/bin/sh\nexit 0\n")
    binary.chmod(0o700)
elif args[:3] == ["simctl", "list", "devices"]:
    print(json.dumps({"devices": {"fixture-runtime": [{"name": "ubq-ios-test-conformancefixture", "udid": "fixture-device", "state": state.read_text(), "isAvailable": True}]}}))
elif args[:3] == ["simctl", "list", "runtimes"]:
    print(json.dumps({"runtimes": [{"name": "iOS 27", "identifier": "fixture-runtime", "isAvailable": True, "supportedDeviceTypes": [{"name": "iPhone 18 Pro"}]}]}))
elif args[:2] == ["simctl", "bootstatus"]:
    event("boot"); state.write_text("Booted")
elif args[:2] == ["simctl", "shutdown"]:
    event("shutdown"); state.write_text("Shutdown")
elif args[:2] == ["simctl", "spawn"]:
    event("spawn " + pathlib.Path(args[3]).name)
    if state.read_text() != "Booted":
        print("device is not booted", file=sys.stderr); sys.exit(1)
    sys.exit(subprocess.call(args[3:]))
else:
    print("unexpected simulator command", args, file=sys.stderr); sys.exit(2)
'''


class DriverTests(unittest.TestCase):
    def run_driver(self, failed_compile=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "build-conformancefixture"
            ios = build / "ios-iphonesimulator"
            ios.mkdir(parents=True)
            (ios / "libubiquitty-core-ios.a").touch()
            crypto = root / "quic/iphonesimulator/lib"
            crypto.mkdir(parents=True)
            (crypto / "libcrypto.a").touch()
            (ios / "CMakeCache.txt").write_text(
                "CMAKE_OSX_DEPLOYMENT_TARGET:STRING=27.0\n"
                f"UBIQUITTY_QUIC_PREFIX:PATH={root / 'quic'}\n")
            (root / "state").write_text("Shutdown")
            (root / "events").touch()
            binary = root / "bin/xcrun"
            binary.parent.mkdir()
            binary.write_text(MOCK)
            binary.chmod(0o700)
            source = Path(os.environ.get("UBQ_IOS_SYNC_DRIVER", ROOT / "Scripts/run-ios-sync-conformance.sh"))
            script = source.read_text().replace(
                'ROOT="$(cd "$(dirname "$0")/.." && pwd)"',
                "ROOT=" + shlex.quote(str(ROOT)), 1)
            driver = root / "driver.sh"
            driver.write_text(script)
            environment = dict(os.environ, UBQ_BUILD_ROOT=str(build), SIM_FIXTURE=str(root),
                               HOME=str(root / "home"), PATH=str(binary.parent) + os.pathsep + os.environ["PATH"])
            if failed_compile:
                environment["FAIL_COMPILE"] = failed_compile
            result = subprocess.run(["bash", str(driver)], env=environment, text=True,
                                    capture_output=True, timeout=30)
            return result, (root / "events").read_text().splitlines()

    def test_all_wire_tests_compile_before_the_simulator_is_acquired(self):
        result, events = self.run_driver()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertCountEqual([e.removeprefix("spawn ") for e in events if e.startswith("spawn ")], TESTS)
        self.assertLess(max(i for i, e in enumerate(events) if e.startswith("compile ")), events.index("boot"))
        self.assertEqual(events[-1], "shutdown")

    def test_a_compile_failure_still_fails_the_suite(self):
        result, events = self.run_driver(TESTS[0])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(TESTS[0] + " (did not compile for iOS)", result.stdout)
        self.assertCountEqual([e.removeprefix("spawn ") for e in events if e.startswith("spawn ")], TESTS[1:])


if __name__ == "__main__":
    unittest.main()
