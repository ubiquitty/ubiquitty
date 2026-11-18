#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Run xcodebuild with a deadline and remove only this run's simulator clones."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

import ios_ui_cases


def inventory():
    """Snapshot CoreSimulator identities before and after the owned run."""
    result = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"],
                            check=True, capture_output=True, text=True, timeout=30)
    return json.loads(result.stdout)["devices"]


def new_clones(before, after, parent):
    """Select new clones of this run's device on its own runtime only."""
    known = {row["udid"] for rows in before.values() for row in rows}
    runtime, device = next((runtime, row) for runtime, rows in before.items()
                           for row in rows if row["udid"] == parent)
    name = re.compile(r"Clone \d+ of " + re.escape(device["name"]))
    return [row["udid"] for row in after.get(runtime, [])
            if row["udid"] not in known and name.fullmatch(row.get("name", ""))]


def stop(process):
    """Reap only the process group this runner created, including its workers."""
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def interrupted(signum, frame):
    """Unwind through owned child and clone cleanup when CI terminates the run."""
    raise InterruptedError(f"UI test runner received signal {signum}")


def wait_with_progress(process, log, seconds, expected, heartbeat_seconds=30):
    """Report observed XCTest identities without changing its deadline or verdict."""
    started = time.monotonic()
    deadline = started + seconds
    completed = {}
    active = set()
    last_case = "none reported"
    received_output = False
    pending = ""
    event = re.compile(r"^Test (?:Case|case) '([^']+)' (started|passed|failed|skipped)\b")
    objc_name = re.compile(r"-\[(?:\w+\.)?(\w+) (test\w+)\]")
    swift_name = re.compile(r"(?:\w+\.)?(\w+)\.(test\w+)\(\)")
    with Path(log).open(errors="replace") as reader:
        def report(final=False):
            nonlocal pending, last_case, received_output
            chunk = reader.read()
            received_output = received_output or bool(chunk)
            lines = (pending + chunk).splitlines(keepends=True)
            pending = ""
            if lines and not lines[-1].endswith(("\n", "\r")) and not final:
                pending = lines.pop()
            for line in lines:
                parsed, _ = ios_ui_cases.log_results(line)
                completed.update(parsed)
                match = event.match(line)
                if not match:
                    continue
                name = objc_name.fullmatch(match[1]) or swift_name.fullmatch(match[1])
                if not name:
                    continue
                case = "/".join(name.groups())
                if match[2] == "started":
                    active.add(case)
                else:
                    active.discard(case)
                last_case = f"{case} ({match[2]})"
            elapsed = time.monotonic() - started
            age = max(0, time.time() - Path(log).stat().st_mtime) if received_output else elapsed
            output_age = f"last output {age:.1f}s ago" if received_output else f"no output for {age:.1f}s"
            print(f"run-ios-ui-tests: progress — {len(completed)}/{expected} completed; "
                  f"active {', '.join(sorted(active)) or 'none reported'}; "
                  f"last {last_case}; {output_age}; {elapsed:.1f}s elapsed", flush=True)

        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(process.args, seconds)
            try:
                code = process.wait(timeout=min(remaining, heartbeat_seconds))
            except subprocess.TimeoutExpired:
                report()
                continue
            report(final=True)
            return code


def main():
    """Keep the original xcodebuild status, and fail if owned cleanup fails."""
    seconds, log, device, expected, *command = sys.argv[1:]
    if int(expected) <= 0:
        raise ValueError("the selected XCTest case count must be positive")
    before = inventory()
    new_clones(before, before, device)  # Require the parent before spawning Xcode.
    code = 2
    process = None
    previous_handler = signal.signal(signal.SIGTERM, interrupted)
    try:
        with Path(log).open("w") as output:
            process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = wait_with_progress(process, log, int(seconds), int(expected))
            except subprocess.TimeoutExpired:
                stop(process)
                code = 124
    finally:
        if process is not None:
            stop(process)
        signal.signal(signal.SIGTERM, previous_handler)
        for clone in new_clones(before, inventory(), device):
            # Shutdown is allowed to report that a clone already stopped.
            subprocess.run(["xcrun", "simctl", "shutdown", clone], capture_output=True,
                           timeout=30, check=False)
            result = subprocess.run(["xcrun", "simctl", "delete", clone],
                                    capture_output=True, text=True, timeout=30)
            if result.returncode:
                print(f"run-ios-ui-tests: could not delete owned clone {clone}", file=sys.stderr)
                code = code or 2
            else:
                print(f"run-ios-ui-tests: deleted owned clone {clone}")
    return code


if __name__ == "__main__":
    sys.exit(main())
