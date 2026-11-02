#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Catch the assertion that measures the environment instead of the behaviour.

A zoom smoke asserting the re-fitted grid is under 80 columns, run in a window
54 columns wide, passes with `resizeGridToBounds()` deleted: `columns < 80` is a
true statement about the WINDOW, not about re-fitting. Only someone looking
finds it, and a green that cannot go red is worse than an absent test — it is a
claim of coverage that stops anyone writing the real one.

## What is decidable here, and what is not

Not decidable: whether an assertion can fail. That needs deleting the feature
and running it, which is the check written at the assertion seams themselves
(`UITestRunner.swift`, `SurfaceSmoke.swift`) for a person to apply.

Decidable: whether an assertion compares a GEOMETRIC measurement — the family
the reported defect came from, where the environment supplies the number — to a
hard-coded bound of two digits or more. That is a text fact, and it is the exact
shape of the one instance anybody has actually hit.

Two digits, because a one-digit bound is almost always a structural floor
(`>= 1`, `> 0`) rather than a threshold someone picked. Those are a weaker
adjacent shape — a `count >= 1` where the scenario knows the count is exactly
one cannot fail on a duplicate — but they are too common and too often correct
to refuse mechanically, so they are counted and reported, not failed.

## Scope

The UI-test scenarios and the smokes: the places whose assertions run against a
live window whose size nobody chose. Core tests construct their own terminals at
sizes they name, so a bound there is the test's own value and not the machine's.

EXEMPT records an assertion that looks like the shape and is not, with the
reason. It is a ratchet: an entry that stops matching fails too, so it cannot
outlive the line it was written for.

Stdlib only.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gate_report  # noqa: E402

GATE = "check-assertions-against-magic-bounds"

# Where an assertion meets a window whose size the machine chose.
ROOTS = [
    "Source/Platform/macOS/UITest/Scenarios",
    "Source/Platform/macOS/UITest/Swift",
    "Source/UbiquittyKit/Swift",
]

# The measurements the environment supplies.
GEOMETRY = r"columns|rows|width|height|Points|offset|Inset|cellWidth|cellHeight"

# An assertion comparing one of those to a bound of two digits or more.
# Both idioms: ObjC `[t expect:(…)` and Swift `t.expect(…`.
SUSPECT = re.compile(
    r"(?:\[\s*t\s+expect:|t\.expect\(|guard\s|CHECK\()"
    r"[^\n;]*?(?:" + GEOMETRY + r")[^\n;]*?(?:<|>|<=|>=)\s*([0-9]{2,})",
    re.I,
)

# The structural floors, counted rather than refused.
FLOOR = re.compile(
    r"(?:\[\s*t\s+expect:|t\.expect\(|CHECK\()"
    r"[^\n;]*?(?:count|Count)[^\n;]*?(?:>=|>)\s*[01]\b"
)

# Lines that match the shape and are not it, keyed by "path:line-fragment".
#
# A PRECONDITION is the legitimate case and the only one so far: an assertion
# that guards whether the case can be run at all, rather than asserting the
# behaviour the scenario exists to test. It is allowed to be true of the
# machine, because that is what it is asking. The tell is that it runs before
# the action and its description says what it is guarding.
EXEMPT = {
    "Source/Platform/macOS/UITest/Swift/TerminalBehaviourScenarios.swift:the grid is wide enough to wrap a line":
        "a precondition, not the assertion under test: it guards that the window "
        "can hold a wrapped line before the scenario feeds one, and the wrap "
        "assertion that follows is anchored to the grid's own text",
    "Source/UbiquittyKit/Swift/DrawEntrySmoke.swift:guard picture.columns == 132, picture.isColumnCountHeld":
        "a precondition, not the assertion under test: 132 is the width DECCOLM "
        "sets, not a measurement, and the guard only establishes that the "
        "picture is wider than the drawable before the hit test runs; the "
        "assertions that follow are anchored to column 99 of that picture",
    "Source/Platform/macOS/UITest/Swift/ScrollerChromeScenarios.swift:guard deepOffset > 20 else {":
        "a precondition, not the assertion under test: it guards that the 40-line "
        "scroll left the view deep enough in history for a short pull to stop "
        "before it, and the assertions that follow are anchored to the rows the "
        "pull moved (deepBefore against deepAfter)",
}


def scan(root):
    """Every suspect and floor line under one root.

    - Parameter root: The directory to walk.
    - Returns: (suspects, floorCount) where suspects are "path:line: text".
    """
    suspects = []
    floors = 0
    base = Path(root)
    if not base.is_dir():
        return suspects, floors
    for path in sorted(base.rglob("*")):
        if path.suffix not in (".mm", ".swift", ".m"):
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if FLOOR.search(line):
                floors += 1
            if not SUSPECT.search(line):
                continue
            stripped = line.strip()
            if isExempt(path, stripped):
                continue
            suspects.append(f"{path}:{number}: {stripped[:110]}")
    return suspects, floors


def isExempt(path, text):
    """Whether this line is recorded in EXEMPT.

    - Parameters:
      - path: The file the line is in.
      - text: The line, stripped.
    - Returns: Whether a recorded entry names both.
    """
    for key in EXEMPT:
        keyPath, _, fragment = key.partition(":")
        if keyPath in str(path) and fragment in text:
            return True
    return False


def exemptIsLive(roots):
    """Every EXEMPT entry that still names a line in the tree.

    An entry that stops matching has outlived the line it was written for and
    must go, or the record becomes a place where exemptions accumulate.

    - Parameter roots: The directories scanned.
    - Returns: The set of keys that matched something.
    """
    live = set()
    for root in roots:
        base = Path(root)
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if path.suffix not in (".mm", ".swift", ".m"):
                continue
            for line in path.read_text().splitlines():
                for key in EXEMPT:
                    keyPath, _, fragment = key.partition(":")
                    if keyPath in str(path) and fragment in line:
                        live.add(key)
    return live


# The defect this gate exists for, in both idioms, so a pattern that stops
# matching it is caught by the self-test rather than by the next person to hit
# the bug: an assertion that the re-fitted grid is under 80 columns passes in a
# 54-column simulator window with resizeGridToBounds() deleted.
SELF_TEST_LINES = [
    '    [t expect:(columns < 80) desc:@"zooming in re-fits to fewer columns"];',
    '        t.expect(surface.publishedGrid.columns < 80, desc: "re-fits to fewer columns")',
]

# And the shapes that must not match, or the gate is noise.
SELF_TEST_CLEAN = [
    '    [t expect:(columns > 0 && rows > 0) desc:@"window starts with a positive grid"];',
    '    [t expect:(panes.count >= 1) desc:@"the new window has a pane"];',
    '        t.expect(after.height > before.height, desc: "a font-size change reaches the window")',
]


def selfTest():
    """Checks the pattern against the reported defect and against clean lines.

    - Returns: 0 when it catches every defect and no clean line, 1 otherwise.
    """
    problems = []
    for line in SELF_TEST_LINES:
        if not SUSPECT.search(line):
            problems.append(f"missed the reported shape: {line.strip()}")
    for line in SELF_TEST_CLEAN:
        if SUSPECT.search(line):
            problems.append(f"flagged a clean line: {line.strip()}")
    if problems:
        return gate_report.failed(GATE + " --self-test", "pattern answer(s) wrong", problems)
    print(f"{GATE}: self-test ok (catches the reported shape in both idioms, "
          f"flags none of {len(SELF_TEST_CLEAN)} clean lines)")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return selfTest()
    suspects = []
    floors = 0
    scanned = 0
    for root in ROOTS:
        found, floorCount = scan(root)
        suspects += found
        floors += floorCount
        scanned += 1 if Path(root).is_dir() else 0
    if scanned == 0:
        print(f"{GATE}: SKIPPED — none of the scanned roots are in this tree", file=sys.stderr)
        return 0

    live = exemptIsLive(ROOTS)
    stale = [f"EXEMPT names {key}, which no longer matches any line" for key in EXEMPT if key not in live]
    if suspects or stale:
        gate_report.failed(GATE, "assertion(s) comparing a measured geometry to a fixed bound",
                           suspects + stale)
        print("  The machine supplies that number, so the assertion may be true whatever the "
              "code does. Anchor it to what the feature produces, or record it in EXEMPT with "
              "the reason. Delete the feature and watch it go red before trusting it.", file=sys.stderr)
        return 1

    print(f"{GATE}: ok ({scanned} root(s), no unrecorded assertion compares a measured "
          f"geometry to a fixed bound; {len(EXEMPT)} recorded precondition(s), "
          f"{floors} structural floor(s) counted and allowed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
