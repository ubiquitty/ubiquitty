#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Reject incomplete parallel UI runs and preserve other simulator owners."""

from contextlib import redirect_stdout
import io
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import ios_ui_cases as cases
import ios_ui_runner as runner


class CaseInventoryTests(unittest.TestCase):
    """Shared fixtures and focused selectors must retain all concrete cases."""

    def inventory(self, source):
        """Read a temporary source tree through the production catalog parser."""
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "Tests.swift").write_text(source)
            return cases.source_cases(directory)

    def testSharedFixtureFindsBothClasses(self):
        source = """class Fixture: XCTestCase {
    func helper() {}
}
final class First: Fixture {
    func testOne() {}
}
final class Second: Fixture {
    func testTwo() throws {}
}
"""
        self.assertEqual(self.inventory(source), {"First/testOne", "Second/testTwo"})

    def testDirectClassStillWorks(self):
        self.assertEqual(self.inventory("class One: XCTestCase {\n    func testOne() {}\n}\n"),
                         {"One/testOne"})

    def testEmptySuiteIsNotAPass(self):
        with self.assertRaisesRegex(ValueError, "no XCTest"):
            self.inventory("class Empty: XCTestCase {\n}\n")

    def testUnknownParentIsNotSilentlyIgnored(self):
        with self.assertRaisesRegex(ValueError, "outside XCTestCase"):
            self.inventory("class One: Missing {\n    func testOne() {}\n}\n")

    def testFixtureCannotAddDuplicatedInheritedTests(self):
        with self.assertRaisesRegex(ValueError, "inherited tests"):
            self.inventory("class Base: XCTestCase {\n    func testOne() {}\n}\nclass Child: Base {\n}\n")

    def testDuplicateMethodIsRejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate test"):
            self.inventory("class One: XCTestCase {\n    func testOne() {}\n    func testOne() {}\n}\n")

    def testClassAndCaseSelection(self):
        selected = cases.selected_cases({"One/testA", "One/testB", "Two/testC"}, "One,Two/testC")
        self.assertEqual(selected, {"One/testA", "One/testB", "Two/testC"})

    def testStaleClassSelectorFails(self):
        with self.assertRaisesRegex(ValueError, "unknown test selection"):
            cases.selected_cases({"New/testA"}, "Old/testA")


class ResultAccountingTests(unittest.TestCase):
    """Exactly one verdict for every selected identity, in either Xcode format."""

    serial = "Test Case '-[Module.One testA]' passed (0.100 seconds).\n"
    parallel = "Test case 'One.testA()' passed on 'Clone 1 of fixture' (0.100 seconds)\n"

    def testBothResultFormats(self):
        for output in (self.serial, self.parallel, self.serial + self.parallel):
            with self.subTest(output=output):
                result, problems = cases.verify({"One/testA"}, output)
                self.assertEqual(result, {"One/testA": "passed"})
                self.assertEqual(problems, [])

    def testParallelSummaryWithModule(self):
        _, problems = cases.verify({"One/testA"}, self.parallel.replace("One.test", "Module.One.test"))
        self.assertEqual(problems, [])

    def testAnExistingRuntimeSkipRemainsAccountedFor(self):
        result, problems = cases.verify({"One/testA"}, self.parallel.replace("passed", "skipped"))
        self.assertEqual(result, {"One/testA": "skipped"})
        self.assertEqual(problems, [])

    def testZeroExecutedIsRejected(self):
        _, problems = cases.verify({"One/testA"}, "Test Suite passed. Executed 0 tests.\n")
        self.assertIn("missing case: One/testA", problems)

    def testSameCountOfWrongCasesIsRejected(self):
        _, problems = cases.verify({"One/testB"}, self.parallel)
        self.assertIn("missing case: One/testB", problems)
        self.assertIn("unexpected case: One/testA", problems)

    def testDuplicateExecutionInEitherFormatIsRejected(self):
        for output in (self.serial, self.parallel):
            _, problems = cases.verify({"One/testA"}, output + output)
            self.assertIn("duplicate execution: One/testA", problems)

    def testParallelSummaryCannotEraseDetailedFailure(self):
        _, problems = cases.verify({"One/testA"}, self.serial.replace("passed", "failed") + self.parallel)
        self.assertIn("conflicting verdicts: One/testA", problems)

    def testWorkerFailureIsRejected(self):
        _, problems = cases.verify({"One/testA"}, self.parallel.replace("passed", "failed"))
        self.assertIn("failed case: One/testA", problems)

    def testMalformedResultIsRejected(self):
        _, problems = cases.verify({"One/testA"}, "Test case 'unknown' passed on 'clone'\n")
        self.assertIn("unrecognized XCTest result: unknown", problems)


class SimulatorOwnershipTests(unittest.TestCase):
    """Only newly created clones of the exact parent and runtime may be deleted."""

    def testOnlyNewOwnedClones(self):
        before = {"runtime": [{"udid": "parent", "name": "ubq-ios-test-fixture"},
                              {"udid": "old-clone", "name": "Clone 1 of ubq-ios-test-fixture"}]}
        after = {"runtime": before["runtime"] + [
            {"udid": "owned", "name": "Clone 2 of ubq-ios-test-fixture"},
            {"udid": "other", "name": "Clone 1 of somebody-else"},
            {"udid": "suffix", "name": "Clone 1 of ubq-ios-test-fixture-extra"},
            {"udid": "unrelated", "name": "Personal iPhone"}],
            "other-runtime": [{"udid": "other-os", "name": "Clone 2 of ubq-ios-test-fixture"}]}
        self.assertEqual(runner.new_clones(before, after, "parent"), ["owned"])

    def testNoClonesDoesNothing(self):
        before = {"runtime": [{"udid": "parent", "name": "fixture"}]}
        self.assertEqual(runner.new_clones(before, before, "parent"), [])


class RunnerLifecycleTests(unittest.TestCase):
    """A deadline stops the owned process group and leaves unrelated PIDs alone."""

    @patch.object(runner.os, "killpg")
    def testStoppedProcessNeedsNoSignal(self, kill):
        process = Mock(pid=42)
        process.poll.return_value = 0
        runner.stop(process)
        kill.assert_not_called()

    @patch.object(runner.os, "killpg")
    def testDeadlineReapsTheOwnedGroup(self, kill):
        process = Mock(pid=42)
        process.poll.return_value = None
        runner.stop(process)
        kill.assert_called_once_with(42, signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=10)

    @patch.object(runner.os, "killpg")
    def testUnresponsiveOwnedGroupIsKilled(self, kill):
        process = Mock(pid=42)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("xcodebuild", 10), 0]
        runner.stop(process)
        self.assertEqual(kill.call_args_list[0].args, (42, signal.SIGTERM))
        self.assertEqual(kill.call_args_list[1].args, (42, signal.SIGKILL))
        self.assertEqual(process.wait.call_count, 2)

    @patch.object(runner.os, "killpg", side_effect=ProcessLookupError)
    def testProcessExitingDuringShutdownIsReaped(self, kill):
        process = Mock(pid=42)
        process.poll.return_value = None
        runner.stop(process)
        process.wait.assert_called_once_with()


class RunnerProgressTests(unittest.TestCase):
    """Real child output and silence must both leave a bounded live report."""

    def observe(self, body, seconds=2):
        with tempfile.TemporaryDirectory(prefix="ubq-ios-progress-") as directory:
            log = Path(directory) / "child.log"
            result = io.StringIO()
            with log.open("w") as stream:
                process = subprocess.Popen([sys.executable, "-u", "-c", body], stdout=stream,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    with redirect_stdout(result):
                        code = runner.wait_with_progress(process, log, seconds, 2, heartbeat_seconds=0.05)
                finally:
                    runner.stop(process)
            return code, result.getvalue(), log.read_text()

    def testObservedCasesAreCountedOnceAcrossSerialAndParallelFormats(self):
        body = '''
import time
print("Test Case '-[Module.One testA]' started.")
print("Test Case '-[Module.One testA]' passed (0.100 seconds).")
print("Test case 'One.testA()' passed on 'Clone 1 of fixture' (0.100 seconds)")
print("Test Case '-[Module.Two testB]' started.")
time.sleep(0.18)
'''
        code, progress, raw = self.observe(body)
        self.assertEqual(code, 0)
        self.assertIn("1/2 completed", progress)
        self.assertNotIn("2/2 completed", progress)
        self.assertIn("active Two/testB", progress)
        self.assertIn("last Two/testB (started)", progress)
        self.assertRegex(progress, r"last output 0\.[1-9][0-9]*s ago")
        self.assertIn("passed on 'Clone 1", raw)

    def testSilentChildStillReportsWithoutInventingCases(self):
        code, progress, raw = self.observe("import time; time.sleep(0.18)")
        self.assertEqual(code, 0)
        self.assertEqual(raw, "")
        self.assertGreaterEqual(progress.count("0/2 completed"), 2)
        self.assertIn("active none reported; last none reported", progress)
        self.assertRegex(progress, r"no output for 0\.[1-9][0-9]*s")

    def testHeartbeatDoesNotExtendTheOriginalDeadline(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.observe("import time; time.sleep(5)", seconds=0.15)

    def testMainPreservesTheChildFailureAndUsesTheSelectedCount(self):
        with tempfile.TemporaryDirectory(prefix="ubq-ios-progress-main-") as directory:
            log = Path(directory) / "child.log"
            command = [sys.executable, "-c", "import sys; print(\"Test Case '-[Module.One testA]' failed (0.1 seconds).\"); sys.exit(7)"]
            argv = ["ios_ui_runner.py", "2", str(log), "parent", "1", *command]
            inventory = {"runtime": [{"udid": "parent", "name": "fixture"}]}
            progress = io.StringIO()
            with patch.object(runner.sys, "argv", argv), patch.object(runner, "inventory", return_value=inventory), \
                    redirect_stdout(progress):
                self.assertEqual(runner.main(), 7)
            self.assertIn("1/1 completed", progress.getvalue())
            self.assertIn("last One/testA (failed)", progress.getvalue())
            self.assertIn("failed", log.read_text())


if __name__ == "__main__":
    unittest.main()
