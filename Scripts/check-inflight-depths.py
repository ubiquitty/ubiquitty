#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""check-inflight-depths.py — the pin window outlasts the frames in flight.

Two constants, in two languages, in two files, hold one invariant between them.

`GrowableBuffer.ringDepth` is how many allocations a stream cycles through, and
so how many frames the CPU may run ahead: a build waits only for the command
buffer that read the slot it is about to reuse, which leaves the frames in
between still executing.

`GlyphSlotCache::retainEpochDepth` is how many frames' worth of touched atlas
slots stay pinned. A pinned slot is not evicted, so it is not re-inked while
something still samples it.

An executing frame samples the atlas slots its instances point at. If the pin
window is shallower than the run-ahead, a frame still on the GPU can have its
slots evicted and re-inked by a later frame's misses, and it then draws whatever
landed there instead — the glyph that was there a moment ago, at the right
position with every count correct.

Nothing else catches that. It is a race, so it does not reproduce on demand; it
needs GPU load to open the window at all, and the symptom is a character that
was briefly wrong. A test would have to lose the race to see it.

So the relation is checked as text. Lowering the pin depth, or deepening the
ring, then fails here instead of shipping a rare wrong glyph.

Stdlib only.

    python3 Scripts/check-inflight-depths.py
    python3 Scripts/check-inflight-depths.py --self-test
"""

import os
import re
import sys
import tempfile

RING_DEPTH = (
    os.path.join("Source", "UbiquittyRenderKit", "GrowableBuffer.swift"),
    re.compile(r"\bstatic\s+let\s+ringDepth\s*=\s*(\d+)"),
    "GrowableBuffer.ringDepth",
)
PIN_DEPTH = (
    os.path.join("Source", "Core", "Rendering", "GlyphSlotCache.h"),
    re.compile(r"\bstatic\s+constexpr\s+int\s+retainEpochDepth\s*=\s*(\d+)"),
    "GlyphSlotCache::retainEpochDepth",
)


def readDepth(root, spec):
    """The constant's value, or a reason it could not be read."""
    relative, pattern, name = spec
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        return None, "%s is missing, so %s cannot be read" % (relative, name)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    found = pattern.search(text)
    if not found:
        return None, "%s no longer declares %s in the form this reads" % (relative, name)
    return int(found.group(1)), None


def check(root):
    """The failures, empty when the pin window outlasts the run-ahead."""
    failures = []
    ring, ringProblem = readDepth(root, RING_DEPTH)
    pins, pinProblem = readDepth(root, PIN_DEPTH)
    for problem in (ringProblem, pinProblem):
        if problem:
            failures.append(problem)
    if failures:
        return failures
    if pins < ring:
        failures.append(
            "%s is %d and %s is %d: a frame can still be executing after its atlas "
            "slots stop being pinned, so a later frame's misses can re-ink a slot it "
            "is sampling" % (PIN_DEPTH[2], pins, RING_DEPTH[2], ring))
    return failures


def selfTest():
    """The rule is shown to catch a shallow pin window and pass a deep one."""
    failures = []
    with tempfile.TemporaryDirectory() as root:
        def write(relative, text):
            path = os.path.join(root, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)

        def plant(ring, pins):
            write(RING_DEPTH[0], "struct GrowableBuffer {\n    static let ringDepth = %d\n}\n" % ring)
            write(PIN_DEPTH[0], "class GlyphSlotCache {\n    static constexpr int retainEpochDepth = %d;\n};\n" % pins)

        plant(ring=3, pins=4)
        if check(root):
            failures.append("a pin window deeper than the ring was rejected")

        plant(ring=3, pins=3)
        if check(root):
            failures.append("a pin window equal to the ring was rejected")

        plant(ring=3, pins=2)
        if not check(root):
            failures.append("a pin window shallower than the ring was accepted")

        plant(ring=6, pins=4)
        if not check(root):
            failures.append("deepening the ring past the pin window was accepted")

        # A constant that moved out of reach reads as a failure, not as a pass:
        # a regex that stops matching would otherwise turn this gate off.
        write(RING_DEPTH[0], "struct GrowableBuffer { }\n")
        if not check(root):
            failures.append("an unreadable constant was treated as satisfying the rule")

    for failure in failures:
        print("self-test: " + failure, file=sys.stderr)
    if failures:
        return 1
    print("check-inflight-depths: self-test ok (a shallow pin window is caught; an unreadable constant is not a pass)")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return selfTest()
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    failures = check(root)
    if failures:
        print("check-inflight-depths: FAIL - the atlas pin window does not outlast the frames in flight.")
        for failure in failures:
            print("  " + failure)
        return 1
    ring, _ = readDepth(root, RING_DEPTH)
    pins, _ = readDepth(root, PIN_DEPTH)
    print("check-inflight-depths: ok (%s=%d pins against %s=%d in flight)" % (PIN_DEPTH[2], pins, RING_DEPTH[2], ring))
    return 0


if __name__ == "__main__":
    sys.exit(main())
