#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Hold every colour-atlas arm to Core's slot-side helper.

A colour glyph is drawn from a square slot, and the square has to be the one the
builder cuts the quad to. When a sheet's slot is larger, every colour glyph is
resampled on the way to the screen through a filter the backends do not share —
so the arms disagree by a blur nobody wrote.

That defect landed once, was fixed, and **recurred** in a second slot-cut
implementation. Recurrence is what this check is for.

## Why it keys on the helper and not on the arithmetic

Two arithmetic keys were tried and both are refuted:

    "the slot equals the cell height"     refuted by present data — the square
                                          is not the cell height under every
                                          metric, and the tree contains cases
                                          where it must not be
    "the two computations agree"          a type says `same kind`, never `same
                                          value`; two call sites can compute
                                          the same shape from different inputs
                                          and a lint cannot see it

What is decidable is whether an arm reaches
`Ubiquitty::Rendering::colourGlyphSquareInPixels` at all. One function, one
number, and an arm that does not call it is computing the square some other way
— which is the fork, whatever arithmetic it happens to contain today.

## The population

Files that hand out a `ColorAtlasBinding`. That is the whole set of arms with a
colour sheet, and it is measured from the tree rather than listed by hand: a new
renderer that binds one is a new arm, and it is caught by the first bound below.

The helper need not be called in the binder's own file. Linux binds in
`VulkanColorGlyphAtlas.cpp` and sizes in `VulkanRenderer.cpp`, so an arm is a
set of files and the check asks whether the helper is reached anywhere in it.

Three bounds, so the record cannot rot in either direction:

    a binder file in no recorded arm    -> FAIL, an arm may size its own slots
    a recorded arm that stops calling   -> FAIL, the fork is back
    a recorded arm with no binder left  -> FAIL, delete its entry
"""

import argparse
import subprocess
import sys
from pathlib import Path

# Anchor every tree read to the repository, not the caller's cwd. Under ctest the
# stanza runs from the build directory, where `git grep` and a bare relative
# `Path(path)` both come back empty -- and the self-test's search arms then read
# that as "the tree has no arms", a clean verdict that belongs to the cwd and not
# to the tree. The script sits in Scripts/, so its parent's parent is the root.
REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import library_scripts  # noqa: E402 — the arms live in the app and in the libraries it builds on

HELPER = "colourGlyphSquareInPixels"
BINDING = "ColorAtlasBinding"

# Each arm: the files that may carry its call to the helper. The binder is
# listed first and is what the tree is measured against.
ARMS = {
    "core-software": [
        "Source/Core/Rendering/SoftwareRenderer.cpp",
    ],
    "linux-vulkan": [
        "Source/Platform/Linux/VulkanColorGlyphAtlas.cpp",
        "Source/Platform/Linux/VulkanRenderer.cpp",
    ],
    "macos-swift": [
        "Source/UbiquittyRenderKit/GlyphAtlas.swift",
    ],
}

# A declaration is not a binding: a header naming the return type, and the
# builder consuming one, are neither of them arms.
NOT_ARMS = (
    "Source/Core/Rendering/GlyphBackend.h",
    "Source/Core/Rendering/GlyphBackendTypes.h",
    "Source/Core/Rendering/CellInstanceBuilder.cpp",
    "Source/Core/Rendering/SoftwareRenderer.h",
    "Source/Platform/Linux/VulkanColorGlyphAtlas.h",
    "Source/Platform/Linux/VulkanGlyphAtlas.cpp",
    "Source/UbiquittyRenderKit/GlyphSource.swift",
)


# What each arm does with the helper's documented zero. `colourGlyphSquareInPixels`
# returns 0 when either cell extent is zero or negative — stated in its own
# header — and two arms floor that to a 1x1 slot while two pass it through to a
# zero-sized texture. Both answers ship.
#
# This records the split rather than judging it: which is right is a rendering
# question for the arm that owns the sheet, and a check that picked one would
# assert a policy nobody decided. What it holds is that an arm cannot change its
# answer silently, and that a new arm has to state one.
#
# Keyed on a substring of the arm's own guard, because the shapes have nothing
# in common across three languages and a pattern general enough to match all of
# them would match a great deal that is not a guard.
ZERO_TREATMENT = {
    "core-software": ("floors-to-one", "Source/Core/Rendering/SoftwareRenderer.cpp",
                      "whole > 0 ? whole : 1"),
    "linux-vulkan": ("passes-zero-through", "Source/Platform/Linux/VulkanRenderer.cpp", None),
    "macos-swift": ("passes-zero-through",
                    "Source/UbiquittyRenderKit/GlyphAtlas.swift", None),
}


def zeroTreatmentFindings():
    """Checks each arm still treats the helper's zero as recorded.

    - Returns: a list of finding strings, empty when every arm matches.
    """
    findings = []
    for arm, (treatment, path, evidence) in sorted(ZERO_TREATMENT.items()):
        if evidence is None:
            continue
        try:
            text = Path(library_scripts.locate(path)).read_text()
        except OSError:
            text = ""
        if evidence not in text:
            findings.append(f"{arm} is recorded as {treatment} on the helper's zero and "
                            f"{path} no longer contains `{evidence}` — say what it does "
                            "now, because two answers already ship and no pixel oracle "
                            "distinguishes them")
    for arm in sorted(set(ARMS) - set(ZERO_TREATMENT)):
        findings.append(f"{arm} has a colour sheet and no recorded answer for the "
                        "helper's zero")
    return findings


def grepFiles(pattern):
    """Returns the tracked files containing a pattern.

    - Parameter pattern: a fixed string to search for.
    - Returns: a sorted list of repository-relative paths.
    """
    return library_scripts.grepFiles(pattern)


def namesInCode(path):
    """Whether a file names the binding outside a comment.

    `git grep -l` matches prose, and the first run of this check flagged
    `GlyphRasterizer.h` for a doc comment that mentions the type. A mention is
    not a producer, so comments are stripped before the token is looked for.

    - Parameter path: a repository-relative path.
    - Returns: True when a code line names the binding.
    """
    # The working tree, not HEAD: a gate that reads the committed file passes an
    # uncommitted fork, which is the state a gate exists to catch.
    try:
        contents = Path(library_scripts.locate(path)).read_text()
    except OSError:
        return False
    inBlockComment = False
    for line in contents.splitlines():
        stripped = line.strip()
        if inBlockComment:
            if "*/" in stripped:
                inBlockComment = False
                stripped = stripped.split("*/", 1)[1]
            else:
                continue
        if stripped.startswith(("//", "///", "*")):
            continue
        if "/*" in stripped and "*/" not in stripped:
            inBlockComment = True
        code = stripped.split("//", 1)[0]
        if BINDING in code:
            return True
    return False


def binderFiles():
    """Returns the source files that hand out a colour-atlas binding.

    A file counts when it names the binding in code; the header declaring the
    struct and the builder reading it are excluded by name because they are
    consumers rather than arms.

    - Returns: a sorted list of paths.
    """
    candidates = [path for path in grepFiles(BINDING)
                  if path.startswith("Source/") and path not in NOT_ARMS]
    candidates = [path for path in candidates
                  if not path.endswith((".vert", ".frag", ".metal"))]
    return [path for path in candidates if namesInCode(path)]


def armsCallingHelper():
    """Returns the arms whose files reach the helper.

    - Returns: a set of arm names.
    """
    carriers = set(grepFiles(HELPER))
    return {arm for arm, files in ARMS.items() if carriers.intersection(files)}


def judge(binders, calling):
    """Compares the tree against the recorded arms.

    - Parameters:
      - binders: the binder files measured from the tree.
      - calling: the arms measured to reach the helper.
    - Returns: a list of finding strings, empty when the arms hold.
    """
    findings = []
    recordedBinders = {files[0] for files in ARMS.values()}
    for path in sorted(set(binders) - recordedBinders):
        findings.append(f"{path} hands out a {BINDING} and belongs to no recorded arm — "
                        f"an arm that never calls {HELPER} sizes its colour slots some "
                        "other way, and a resample nobody wrote is what that costs")
    for arm, files in sorted(ARMS.items()):
        if files[0] not in binders:
            findings.append(f"{arm} is recorded and {files[0]} no longer hands out a "
                            f"{BINDING} — delete its entry")
        elif arm not in calling:
            findings.append(f"{arm} reaches {HELPER} in none of {', '.join(files)} — "
                            "the slot side is being computed somewhere else")
    return findings


def selfTest():
    """Proves each bound fires, and that the search is not the zero.

    The measurement arm matters most: `judge` finds nothing when the tree
    measures nothing, which is the same answer it gives when every arm holds.

    - Returns: 0 when every arm behaves as stated, 1 otherwise.
    """
    failures = []
    recorded = [files[0] for files in ARMS.values()]
    everyArm = set(ARMS)

    if judge(recorded, everyArm):
        failures.append("the recorded arms were flagged against themselves")
    if not judge(recorded + ["Source/Platform/Newcomer/Renderer.cpp"], everyArm):
        failures.append("an unrecorded binder was not flagged")
    if not judge(recorded, everyArm - {"macos-swift"}):
        failures.append("an arm that stopped calling the helper was not flagged")
    if not judge([p for p in recorded if "Vulkan" not in p], everyArm):
        failures.append("a recorded arm with no binder left was not flagged")

    binders = binderFiles()
    if not binders:
        failures.append(f"no file in the tree hands out a {BINDING} — a clean verdict "
                        "here would be the search's and not the tree's")
    carriers = grepFiles(HELPER)
    if not carriers:
        failures.append(f"no file in the tree names {HELPER} — likewise")

    for failure in failures:
        print("check-colour-slot-helper --self-test: " + failure, file=sys.stderr)
    if failures:
        return 1
    print(f"check-colour-slot-helper --self-test: ok (each bound fires, and the tree "
          f"has {len(binders)} binder(s) and {len(carriers)} file(s) naming the helper, "
          "so a clean verdict is the tree's)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="prove each bound fires, and that the search is not the zero")
    arguments = parser.parse_args()

    if arguments.self_test:
        return selfTest()

    binders = binderFiles()
    if not binders:
        print(f"check-colour-slot-helper: REFUSED — no file hands out a {BINDING}. A "
              "tree that lost the type and a tree where every arm holds print the same "
              "verdict, so this is not a pass.", file=sys.stderr)
        return 2

    findings = judge(binders, armsCallingHelper()) + zeroTreatmentFindings()
    if findings:
        print("check-colour-slot-helper: an arm sizes colour slots outside Core's "
              "helper:", file=sys.stderr)
        for finding in findings:
            print("    " + finding, file=sys.stderr)
        print(f"  The slot must be the square the builder cuts the quad to. Call "
              f"{HELPER}, or record why this arm cannot.", file=sys.stderr)
        return 1

    floors = sum(1 for treatment, _, _ in ZERO_TREATMENT.values()
                 if treatment == "floors-to-one")
    print(f"check-colour-slot-helper: ok ({len(ARMS)} arm(s) with a colour sheet, each "
          f"reaching {HELPER}; {len(binders)} binder(s) in the tree, all recorded. "
          f"{floors} floor the helper's zero to one and {len(ZERO_TREATMENT) - floors} "
          "pass it through — recorded, not adjudicated)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
