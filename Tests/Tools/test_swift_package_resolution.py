#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercise dependency fetch retries without retrying a failed compilation."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SwiftPackageResolutionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ubq-swift-resolution.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.events = self.root / "events.jsonl"
        self.cmake = shutil.which("cmake")
        self.assertIsNotNone(self.cmake)

    def make_tool(self, name, body):
        tool = self.root / name
        tool.write_text("#!" + sys.executable + "\n" + body)
        tool.chmod(0o755)
        return tool

    def calls(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()]

    def resolve(self, failures, diagnostic):
        tool = self.make_tool("fetch", f'''import json
from pathlib import Path
import sys
events = Path({str(self.events)!r})
previous = events.read_text().splitlines() if events.exists() else []
with events.open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if len(previous) < {failures}:
    print({diagnostic!r}, file=sys.stderr)
    raise SystemExit(1)
''')
        script = self.root / "resolve.cmake"
        script.write_text(
            f'include("{ROOT}/Scripts/cmake/ResolveSwiftPackage.cmake")\n'
            f'ubiquitty_resolve_swift_package("{tool}" "a path with spaces")\n')
        return subprocess.run([self.cmake, "-P", str(script)], capture_output=True, text=True, timeout=30)

    def test_transient_fetch_failure_retries_then_succeeds(self):
        result = self.resolve(1, "fatal: Could not resolve host: github.com")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [["a path with spaces"]] * 2)

    def test_repeated_network_failure_stops_after_three_attempts(self):
        result = self.resolve(10, "fatal: early EOF")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 3)
        self.assertIn("after 3 attempt(s)", result.stderr)

    def test_invalid_resolution_fails_without_retry(self):
        result = self.resolve(10, "Package.resolved is out-of-date")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)

    def test_success_needs_one_attempt(self):
        result = self.resolve(0, "")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_ios_build_keeps_pins_cache_and_job_limit_without_retrying_compilation(self):
        self.make_tool("xcrun", f'print({str(self.root / "SDK")!r})\n')
        swift = self.make_tool("swift", f'''import json
from pathlib import Path
import sys
with Path({str(self.events)!r}).open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == "build":
    print("error: deliberate compiler failure", file=sys.stderr)
    raise SystemExit(1)
''')
        cache = self.root / "package cache"
        environment = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""),
                           UBIQUITTY_SWIFTPM_CACHE=str(cache), UBQ_BUILD_JOBS="4")
        result = subprocess.run([
            self.cmake, "-DSTEP=ssh", f"-DSOURCE_DIR={ROOT}", f"-DCORE_SOURCE_DIR={ROOT}",
            f"-DKIT_SOURCE_DIR={ROOT}", f"-DBINARY_DIR={self.root / 'build'}", "-DIOS_MIN=26.0",
            "-DPLATFORM=iphonesimulator", f"-D_swift={swift}",
            "-P", str(ROOT / "Scripts/cmake/IOSPlatformStep.cmake"),
        ], env=environment, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deliberate compiler failure", result.stderr)
        calls = self.calls()
        self.assertEqual([call[0] for call in calls], ["package", "build"])
        self.assertEqual(calls[0][-1], "resolve")
        for call in calls:
            self.assertIn("--force-resolved-versions", call)
            self.assertEqual(call[call.index("--cache-path") + 1], str(cache))
        self.assertEqual(calls[1][calls[1].index("--jobs") + 1], "4")


if __name__ == "__main__":
    unittest.main()
