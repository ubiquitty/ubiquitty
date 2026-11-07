#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Hold the pre-push arm selection to the arms each change actually needs.

`ubq_renderer_arms` in Scripts/pre-push-gates.sh decides which snapshot arms a
branch renders, from the files it changed. Selecting too few is invisible: the
stanza reports the arms it ran and passes, and nothing anywhere says which arm
was never asked. That is the whole failure mode, and the table pins three
instances of it:

    UBShaders.metal        must select the swift arm: editing the fragment
                           shader is the one change whose entire effect is the
                           image.

    a Core header the      must select the swift arm as well as `portable`,
    shader includes        because Metal compiles it into the swift arm's Tek
                           stroke. The selector reads the shader's includes.

    Source/Core/ under     must select the linux arm too: a Core change selects
    the linux tier         `portable` alone otherwise, and a hoisted span read
                           can draw correctly on both macOS arms and on
                           portable while aborting under libstdc++.

All three are the same shape: a selection that says less than the reader
assumes, with no run saying so. This pins the table, so a selector that stops
matching fails here rather than in whatever the arm would have caught.

## Why it runs the real function rather than restating the rule

A second copy of the table would agree with itself forever. The check extracts
`ubq_renderer_arms` and `kit_swift_arm_reached` from their scripts and evaluates that text, with a stand-in `git`
answering a fixture's file list, so what is measured is the code that ships.

Three bounds:

    a case selecting the wrong arms      -> FAIL, the table moved
    the function not found in the script -> REFUSE, an empty extraction and a
                                            correct table print the same green
    a fixture whose expectation is met
    by every possible answer             -> the self-test's own arm, below
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import library_scripts  # noqa: E402 — the shaders and their headers are read from the libraries
GATES = REPO / "Scripts" / "pre-push-gates.sh"
FUNCTION = "ubq_renderer_arms"
# The swift arm's selection is the kit's family function the selector calls.
# The library-aware diff both call is the shared lib's.
KIT_GATES = Path(library_scripts.locate("Scripts/pre-push-gates-kit.sh"))
KIT_FUNCTION = "kit_swift_arm_reached"
LIB_GATES = Path(library_scripts.locate("Scripts/pre-push-gates-lib.sh"))
LIB_FUNCTION = "ubq_changed_with_libraries"

# Each case: the tier, the changed files, and the arms that must come back.
#
# The linux entries are the point of the table. `quick` is the tier every push
# pays, so a Core change there selects portable and nothing else; `linux` is
# opted into by a developer who wants the arm with the other standard library, and
# for a Core change that arm is the only reason to type the variable.
CASES = [
    ("quick", ["Source/Core/Rendering/CellInstanceBuilder.cpp"], ["portable"]),
    ("quick", ["Source/Platform/Linux/main.cpp"], ["linux"]),
    ("quick", ["Source/Platform/Web/WebPAL.cpp"], ["web"]),
    ("quick", ["Source/UbiquittyRenderKit/GlyphSource.swift"], ["swift"]),
    ("quick", ["Source/UbiquittyRenderKit/UBShaders.metal"], ["swift"]),
    # A Core header the shader includes is compiled by Metal as well as by
    # Core, so it renders on both arms; a header the shader does not include
    # stays on portable alone.
    ("quick", ["Source/Core/Tek/BeamRaster.h"], ["portable", "swift"]),
    ("quick", ["Source/Core/Tek/BeamRaster.h", "Source/UbiquittyRenderKit/UBShaders.metal"],
     ["portable", "swift"]),
    ("quick", ["Source/Core/Rendering/CellInstanceBuilder.h"], ["portable"]),
    ("quick", ["Source/UbiquittyKit/Swift/SnapshotRunner.swift"], ["swift"]),
    ("quick", ["Source/Core/App/SnapshotRequest.h"], ["portable", "swift"]),
    ("quick", ["Source/Platform/macOS/App/Application/AppDelegate.swift"], ["swift"]),
    # The Kit's build modules hold the render kit's Swift flags and source
    # lists, so an edit to either renders on the swift arm; Core's build
    # modules do not reach the renderer's flags.
    ("quick", ["Scripts/cmake/UbiquittyKit.cmake"], ["swift"]),
    ("quick", ["Scripts/cmake/AppleSharedSwift.cmake"], ["swift"]),
    ("quick", ["Scripts/cmake/UbiquittyCoreLibrary.cmake"], []),
    ("quick", ["Source/Platform/macOS/UITest/Swift/NativeTestContext.swift"], []),
    ("quick", ["Docs/note.md"], []),
    ("linux", ["Source/Core/Rendering/CellInstanceBuilder.cpp"], ["portable", "linux"]),
    ("linux", ["Source/Platform/Linux/main.cpp"], ["linux"]),
    ("linux", ["Source/Core/A.cpp", "Source/Platform/Linux/main.cpp"], ["portable", "linux"]),
    ("linux", ["Docs/note.md"], []),
    ("full", ["Source/Core/Rendering/CellInstanceBuilder.cpp"], ["portable", "linux"]),
]


def functionText():
    """Returns the shipping text of the selector and the function it calls, or None when either is absent."""
    if not GATES.is_file() or not KIT_GATES.is_file() or not LIB_GATES.is_file():
        return None
    found = []
    for path, name in ((LIB_GATES, LIB_FUNCTION), (KIT_GATES, KIT_FUNCTION), (GATES, FUNCTION)):
        match = re.search(rf"^{name}\(\) \{{.*?^\}}", path.read_text(errors="replace"), re.S | re.M)
        if not match:
            return None
        found.append(match.group(0))
    return "\n".join(found)


def selectedArms(body, tier, changed, checkout=REPO):
    """Runs the extracted selector against a stand-in git.

    - Parameters:
      - body: the function's source text.
      - tier: the value of TIER the function reads.
      - changed: the file list the stand-in `git diff` answers.
      - checkout: the directory it runs in, whose shaders it reads.
    - Returns: the arms it printed, as a list.
    """
    with tempfile.TemporaryDirectory() as directory:
        standIn = Path(directory) / "git"
        standIn.write_text('#!/bin/bash\n[ "$1" = "diff" ] && printf "%s\\n" $UBQ_FAKE_CHANGED\nexit 0\n')
        standIn.chmod(0o755)
        script = Path(directory) / "run.sh"
        script.write_text(f'export PATH="{directory}:$PATH"\n{body}\n{FUNCTION}\n')
        # The shaders are the Kit's and the headers they include Core's; an
        # empty checkout stands for a tree holding neither, and the real
        # checkout is its own library.
        environment = dict(os.environ, TIER=tier, UBQ_FAKE_CHANGED=" ".join(changed),
                           UBQ_CORE_ROOT=library_scripts.CORE_ROOT if checkout == REPO else str(checkout),
                           UBQ_KIT_ROOT=library_scripts.KIT_ROOT if checkout == REPO else str(checkout))
        # From the checkout, as the gate runs it: the selector reads the shader's
        # includes off the tree.
        result = subprocess.run(["bash", str(script)], capture_output=True, text=True,
                                env=environment, cwd=checkout)
        return result.stdout.split()


def judge(body):
    """Returns the cases whose selection differs from the table."""
    findings = []
    for tier, changed, expected in CASES:
        got = selectedArms(body, tier, changed)
        if sorted(got) != sorted(expected):
            findings.append(f"TIER={tier} {' '.join(changed) or '(nothing)'}: "
                            f"expected [{' '.join(expected) or '-'}], got [{' '.join(got) or '-'}]")
    return findings


def selfTest():
    """Proves the harness can fail, and that a green is not an empty extraction.

    - Returns: 0 when every arm behaves as stated, 1 otherwise.
    """
    failures = []
    body = functionText()
    if body is None:
        failures.append(f"{FUNCTION} was not found in {GATES.name} — an extraction that finds "
                        "nothing and a table that holds print the same green")
    else:
        if judge(body):
            failures.append("the shipping selector disagrees with the table, so this arm cannot "
                            "tell a working harness from a broken one")
        # The harness has to be able to see a wrong answer. A case demanding an
        # arm the selector cannot return has to fail here, or the greens above
        # belong to the comparison rather than to the selector.
        wrong = [("quick", ["Docs/note.md"], ["portable"])]
        saved = CASES[:]
        try:
            CASES[:] = wrong
            if not judge(body):
                failures.append("a case demanding an arm the selector cannot return was reported "
                                "as passing, so the comparison is not comparing")
        finally:
            CASES[:] = saved
        # And the stand-in has to be reached. A selector run with no file list
        # selects nothing, which is also what a git that never answered gives —
        # so this arm checks the other direction, that a file list does select.
        if not selectedArms(body, "quick", ["Source/Core/x.cpp"]):
            failures.append("a Core change selected no arm, so the stand-in git is not being read "
                            "and every green above is its silence")
        # A checkout whose shader cannot be read must not read as a shader that
        # includes nothing: every Core header then selects the swift arm.
        with tempfile.TemporaryDirectory() as empty:
            got = selectedArms(body, "quick", ["Source/Core/Rendering/CellInstanceBuilder.h"], empty)
            if "swift" not in got:
                failures.append("with no shader to read, a Core header selected "
                                f"[{' '.join(got) or '-'}], so an unreadable include list "
                                "passed as an empty one")

    for failure in failures:
        print("check-renderer-arm-selection --self-test: " + failure, file=sys.stderr)
    if failures:
        return 1
    print(f"check-renderer-arm-selection --self-test: ok ({len(CASES)} case(s) hold against the "
          "shipping selector, a case demanding an impossible arm fails, and a Core change "
          "selects through the stand-in rather than through its silence)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="prove the harness can fail, and that a green is not an empty extraction")
    arguments = parser.parse_args()

    if arguments.self_test:
        return selfTest()

    body = functionText()
    if body is None:
        print(f"check-renderer-arm-selection: REFUSED — {FUNCTION} not found in "
              f"Scripts/{GATES.name}. A renamed selector and a correct table print the same "
              "verdict, so this is not a pass.", file=sys.stderr)
        return 2

    findings = judge(body)
    if findings:
        print("check-renderer-arm-selection: the arm selection differs from the table:",
              file=sys.stderr)
        for finding in findings:
            print("    " + finding, file=sys.stderr)
        print("  Selecting too few arms is invisible at push time: the stanza reports what it "
              "ran and passes, and nothing names the arm nobody asked.", file=sys.stderr)
        print("  Update the table if the change is deliberate, so the next reader sees which "
              "arms a change of each kind renders.", file=sys.stderr)
        return 1

    tiers = sorted({tier for tier, _, _ in CASES})
    print(f"check-renderer-arm-selection: ok ({len(CASES)} case(s) across tier(s) "
          f"{', '.join(tiers)}, each selecting the arms the table names)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
