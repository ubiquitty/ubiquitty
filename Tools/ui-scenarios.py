#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""ui-scenarios.py — run a chosen set of UI scenarios from one build.

`Scripts/run-ui-tests.sh` takes one scenario name or the word `all`, and each
invocation runs the whole build script before it launches: a configure check,
a ninja pass, and a code-signing step. Running a family of scenarios one name
at a time therefore pays that cost once per scenario, and running `all` pays
for every scenario in the tree to answer a question about nine of them.

This runs the build once and launches the built binary per scenario, which is
what the shell script does on its last two lines. Patterns select the set:

    Tools/ui-scenarios.py tag_editor_          every scenario whose name
                                               carries that substring
    Tools/ui-scenarios.py --regex 'titlebar_.*popover'
    Tools/ui-scenarios.py --list               the registry, nothing run
    Tools/ui-scenarios.py --no-build a_name    skip the build entirely
    Tools/ui-scenarios.py --verbose a_name      the scenario's full stdout, not
                                               just its failing assertions --
                                               for a print() left in a scenario
                                               under diagnosis

Each scenario is launched on its own, which is the isolation the suite is
written for: the runner closes every window between scenarios within a launch,
but a scenario that wedges the app takes only its own launch down. Launches
are serial because the scenarios drive real windows and a real pointer.

Each launch gets a throwaway `XDG_CONFIG_HOME`, so scenarios that drive the
settings writers cannot reach the operator's `config.toml`.

Exit status is the number of scenarios that did not pass, capped at 125.

Stdlib only.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "Scripts" / "run-ui-tests.sh"

# The scenario runner prints one of these three verdicts per scenario, then
# indents the failing assertions under a FAIL and the reason under a REFUSED.
VERDICT = re.compile(r"^(PASS|FAIL|REFUSED)\s+(\S+)")


def buildRoot() -> str:
    """The build root, as `Scripts/build_root.py` derives it.

    - Returns: the root's path.
    """
    resolve = subprocess.run(
        [sys.executable, str(ROOT / "Scripts" / "build_root.py"), str(ROOT)],
        cwd=ROOT, capture_output=True, text=True)
    if resolve.returncode != 0 or not resolve.stdout.strip():
        raise SystemExit("ui-scenarios: the build root did not resolve")
    return resolve.stdout.strip()


def bundleBinary() -> Path:
    """The UI-test executable, without building it.

    The build root is asked of `Scripts/build_root.py`, which derives the same
    path `Scripts/build-root.sh` gives shell callers and is held to agreeing
    with it by `Scripts/check-build-root.py`. A path spelled a second time here
    is one that can disagree with the tree it is meant to describe.

    - Returns: the executable's path, built or not.
    """
    resolve = subprocess.run(
        [sys.executable, str(ROOT / "Scripts" / "build_root.py"), str(ROOT)],
        cwd=ROOT, capture_output=True, text=True)
    if resolve.returncode != 0 or not resolve.stdout.strip():
        raise SystemExit("ui-scenarios: the build root did not resolve")
    build = os.environ.get("UBIQUITTY_BUILD_DIR") or f"{resolve.stdout.strip()}/macos-uitest"
    return Path(build) / "Source/Platform/macOS/Ubiquitty.app/Contents/MacOS/Ubiquitty"


def listScenarios(binary: Path) -> list[str]:
    """The scenario registry, read from the built binary.

    - Parameter binary: the UI-test executable.
    - Returns: every registered scenario name.
    """
    completed = subprocess.run(
        [str(binary), "--ui-test", "list"], cwd=ROOT, capture_output=True, text=True)
    names = [l.strip() for l in completed.stdout.splitlines() if l.strip() and " " not in l.strip()]
    if not names:
        raise SystemExit("ui-scenarios: the binary listed no scenarios")
    return names


def buildAndList() -> tuple[Path, list[str]]:
    """Builds the UI-test bundle and reads the scenario registry from it.

    `list` is the cheapest scenario argument the binary takes: it prints the
    registry and exits, so one call both settles the build and answers what
    can be run.

    - Returns: the built binary and every registered scenario name.
    """
    completed = subprocess.run(
        [str(RUNNER), "list"], cwd=ROOT, capture_output=True, text=True)
    if completed.returncode != 0:
        sys.stderr.write(completed.stdout)
        sys.stderr.write(completed.stderr)
        raise SystemExit("ui-scenarios: the UI-test bundle did not build")
    app = ""
    names = []
    for line in completed.stdout.splitlines():
        if line.startswith("Built: "):
            app = line[len("Built: "):].strip()
        elif line and not line[0].isspace() and ":" not in line and " " not in line:
            names.append(line)
    if not app:
        raise SystemExit("ui-scenarios: the build printed no bundle path")
    binary = Path(app) / "Contents" / "MacOS" / "Ubiquitty"
    if not binary.is_file():
        raise SystemExit(f"ui-scenarios: {binary} is not there")
    if not names:
        raise SystemExit("ui-scenarios: the binary listed no scenarios")
    return binary, names


def runOne(binary: Path, name: str) -> tuple[str, list[str], str]:
    """Runs one scenario in its own launch and reads back its verdict.

    - Parameters:
      - binary: the built UI-test executable.
      - name: the scenario to run.
    - Returns: the verdict, the lines reported under it, and the full stdout
      the launch produced. A launch that printed no verdict reads as CRASH,
      which is a result and not an absence.
    """
    sandbox = tempfile.mkdtemp(prefix="ubiquitty-uiscenarios-")
    environment = dict(os.environ, XDG_CONFIG_HOME=sandbox)
    # The attached-daemon scenarios fork this binary; run-ui-tests.sh exports
    # the same path.
    environment.setdefault("UBIQUITTY_UI_TEST_HOST", f"{buildRoot()}/host/ubiquitty-host")
    try:
        completed = subprocess.run(
            [str(binary), "--ui-test", name],
            cwd=ROOT, capture_output=True, text=True, env=environment)
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)
    verdict = ""
    detail = []
    for line in completed.stdout.splitlines():
        matched = VERDICT.match(line)
        if matched and matched.group(2) == name:
            verdict = matched.group(1)
        elif verdict and line.startswith("        - "):
            detail.append(line.strip()[2:])
    if not verdict:
        tail = [l for l in completed.stdout.splitlines()[-3:] if l.strip()]
        return "CRASH", tail or [f"exit {completed.returncode}, no verdict printed"], completed.stdout
    return verdict, detail, completed.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("patterns", nargs="*", help="substrings a name must carry")
    parser.add_argument("--regex", help="select by regular expression instead")
    parser.add_argument("--list", action="store_true", help="print the registry and stop")
    parser.add_argument("--no-build", action="store_true", help="use the bundle as it stands")
    parser.add_argument("--verbose", action="store_true",
                         help="print each scenario's full stdout, not just its failing assertions")
    arguments = parser.parse_args()

    if arguments.no_build:
        binary = bundleBinary()
        if not binary.is_file():
            raise SystemExit(f"ui-scenarios: {binary} is not there; drop --no-build")
        registry = listScenarios(binary)
    else:
        binary, registry = buildAndList()

    if arguments.list:
        for name in registry:
            print(name)
        return 0

    if arguments.regex:
        wanted = re.compile(arguments.regex)
        selected = [n for n in registry if wanted.search(n)]
    elif arguments.patterns:
        selected = [n for n in registry if any(p in n for p in arguments.patterns)]
    else:
        selected = list(registry)

    if not selected:
        # A selection matching nothing is a typo, not a clean run: reporting
        # "0 failed" for a pattern that named no scenario reads as a pass.
        raise SystemExit("ui-scenarios: no scenario matches; --list shows the registry")

    failures = []
    for index, name in enumerate(selected, 1):
        verdict, detail, stdout = runOne(binary, name)
        print(f"[{index}/{len(selected)}] {verdict:8}{name}", flush=True)
        if arguments.verbose:
            for line in stdout.splitlines():
                print(f"    | {line}", flush=True)
        elif verdict != "PASS":
            for line in detail:
                print(f"           {line}", flush=True)
        if verdict != "PASS":
            failures.append((name, verdict, detail))

    print()
    print(f"ui-scenarios: {len(selected) - len(failures)}/{len(selected)} passed")
    for name, verdict, _ in failures:
        print(f"  {verdict} {name}")
    return min(len(failures), 125)


if __name__ == "__main__":
    sys.exit(main())
