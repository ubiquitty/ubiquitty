#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Iterate on one iOS XCUITest case without paying for the whole battery.

    ios-ui-test.py <TestCase>   one case: incremental build, restage the bundle, run just it
    ios-ui-test.py --full       the whole suite, through Scripts/run-ios-ui-tests.sh
    ios-ui-test.py --setup      generate the runner + .xctestrun (a --full run) and stop

Scripts/run-ios-ui-tests.sh is the canonical gate: it assembles the XCTRunner app and the
.xctestrun, holds the staleness guards, and checks the executed-count against the declared cases.
It runs every case, which is minutes. When the change under test is one case, that is the wrong
unit of work. This reuses the runner that a --full run already built and only rebuilds the test
bundle, restages it, and runs the single case with `-only-testing` — seconds, so a case can be
driven to green in a loop.

A single-case run needs the runner and .xctestrun a --full run produces; if they are absent this
generates them first (one --full), then runs the case. The build root, device and bundle names are
the same ones run-ios-ui-tests.sh uses, derived the same way, so the two never disagree.

The live-QUIC cases read UBQ_LIVE_SSH_HOST / UBQ_LIVE_SSH_USER / UBQ_LIVE_SSH_KEY_FILE from the
environment (see Scripts/run-ios-ui-tests.sh); without them those cases report themselves skipped.
This passes the environment straight through and hardcodes no credential or path.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

BUNDLE = "UbiquittyUITests"
TEST_CLASS = f"{BUNDLE}/TerminalGestureUITests"
# The model Scripts/ios-simulator.sh makes a device as when UBQ_IOS_DEVICE_TYPE is unset.
DEFAULT_DEVICE_TYPE = "iPhone 16"


def repoRoot() -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return Path(out)


def buildRoot(root: Path) -> Path:
    # Scripts/build_root.py derives the same DerivedData path build-root.sh gives shell callers,
    # so this tool and the build write to and read from one place.
    out = subprocess.run(
        [sys.executable, str(root / "Scripts" / "build_root.py"), str(root)],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return Path(out) / "ios-iphonesimulator"


def deviceName(root: Path) -> str:
    """The simulator this checkout owns.

    One simulator per checkout, named for the build root that already
    identifies it, the same way Scripts/run-ios-ui-tests.sh derives it. A
    shared device is one several worktrees install to and drive at once, and
    one run's uninstall landing mid-test in another reads as a broken test
    rather than as two runs on one machine.

    A device made as another model than the default, through
    UBQ_IOS_DEVICE_TYPE, carries the model as a suffix, exactly as
    Scripts/ios-simulator.sh names it.

    - Parameter root: the repository root.
    - Returns: the device name.
    """
    # buildRoot names the iOS build directory INSIDE the DerivedData root; the
    # hash that identifies the checkout is on the root itself, which is its
    # parent. Splitting the wrong one yields a name every checkout shares.
    name = "ubq-ios-test-" + buildRoot(root).parent.name.rsplit("-", 1)[-1]
    deviceType = os.environ.get("UBQ_IOS_DEVICE_TYPE") or DEFAULT_DEVICE_TYPE
    if deviceType == DEFAULT_DEVICE_TYPE:
        return name
    return name + "-" + re.sub(r"[^a-z0-9]+", "-", deviceType.lower()).strip("-")


def deviceUDID(root: Path) -> str:
    # The device this checkout owns, by name, so a run cannot depend on which
    # simulators happen to be open and cannot disturb another checkout's.
    name = deviceName(root)
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available"],
        capture_output=True, text=True, check=True,
    ).stdout
    for line in out.splitlines():
        # The name and the opening of the udid, so a device named with a
        # model suffix is not taken for the default one its name begins with.
        if f"{name} (" in line:
            match = re.search(r"\(([0-9A-Fa-f-]{36})\)", line)
            if match:
                return match.group(1)
    sys.exit(f"ios-ui-test: no available simulator named {name} — Scripts/ios-simulator.sh --boot makes it")


def buildBundle(root: Path) -> None:
    result = subprocess.run(
        [str(root / "Scripts" / "build-ios.sh"), "--sdk", "iphonesimulator", "--ui-tests"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        for line in result.stdout.splitlines() + result.stderr.splitlines():
            if "error:" in line:
                print(line)
        sys.exit("ios-ui-test: build failed")


def runFull(root: Path) -> int:
    # The canonical runner owns setup and the count guard; a full run also (re)generates the
    # runner and .xctestrun a single-case run reuses.
    proc = subprocess.run(
        [str(root / "Scripts" / "run-ios-ui-tests.sh")],
        capture_output=True, text=True,
    )
    for line in proc.stdout.splitlines():
        if re.search(r"^  test|passed,|FAILED —|RAN ", line):
            print(line)
    return proc.returncode


def restage(root: Path, build: Path) -> None:
    runner = build / "uitest" / f"{BUNDLE}-Runner.app"
    plugin = runner / "PlugIns" / f"{BUNDLE}.xctest"
    subprocess.run(["rm", "-rf", str(plugin)], check=True)
    subprocess.run(["cp", "-R", str(build / f"{BUNDLE}.xctest"), str(runner / "PlugIns")], check=True)
    for target, entitlements in ((plugin, None), (runner, runner / "RunnerEntitlements.plist")):
        cmd = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
        if entitlements:
            cmd += ["--entitlements", str(entitlements)]
        cmd.append(str(target))
        subprocess.run(cmd, capture_output=True)
    subprocess.run(["xcrun", "simctl", "install", deviceName(root), str(build / "Ubiquitty.app")], capture_output=True)


def bootDevice(root: Path) -> bool:
    """Boots the checkout's simulator through Scripts/ios-simulator.sh.

    Returns whether this call booted it. A device that was already up belongs to whoever booted
    it and is left running; one booted here is shut down when the case is done, so a run of
    single cases leaves no simulator behind. UBQ_IOS_KEEP_BOOTED=1 keeps it up between cases for
    a developer iterating on one.
    """
    out = subprocess.run(
        [str(root / "Scripts" / "ios-simulator.sh"), "--boot"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"ios-ui-test: no simulator for this checkout: {out.stderr.strip()}")
    return out.stdout.strip().endswith(" booted")


def shutdownDevice(root: Path) -> None:
    subprocess.run([str(root / "Scripts" / "ios-simulator.sh"), "--shutdown"], capture_output=True)


def runCase(root: Path, build: Path, case: str) -> int:
    xctestrun = build / "uitest" / f"{BUNDLE}.xctestrun"
    if not xctestrun.exists():
        print("ios-ui-test: no runner yet — generating it with one full run")
        if runFull(root) == 2:
            sys.exit("ios-ui-test: setup failed")
    buildBundle(root)
    bootedHere = bootDevice(root)
    try:
        restage(root, build)
        proc = subprocess.run(
            [
                "xcodebuild", "test-without-building",
                "-xctestrun", str(xctestrun),
                "-destination", f"id={deviceUDID(root)}",
                f"-only-testing:{TEST_CLASS}/{case}",
            ],
            capture_output=True, text=True,
        )
    finally:
        if bootedHere and os.environ.get("UBQ_IOS_KEEP_BOOTED") != "1":
            shutdownDevice(root)
    for line in proc.stdout.splitlines():
        if re.search(r"^Test Case '.*' (passed|failed|skipped)|error: -\[|TEST EXECUTE FAILED", line):
            print(re.sub(r" \(.*\)", "", line))
    return proc.returncode


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = repoRoot()
    build = buildRoot(root)
    arg = sys.argv[1]
    if arg in ("--full", "--setup"):
        buildBundle(root)
        return runFull(root)
    return runCase(root, build, arg)


if __name__ == "__main__":
    sys.exit(main())
