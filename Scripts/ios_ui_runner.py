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


def main():
    """Keep the original xcodebuild status, and fail if owned cleanup fails."""
    seconds, log, device, *command = sys.argv[1:]
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
                code = process.wait(timeout=int(seconds))
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
