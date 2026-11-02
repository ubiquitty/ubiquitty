#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Report command-line flags whose only occurrence in the tree is their own read.

The entry points below exist to be driven by scripts and cases; nothing else
invokes them. So a flag one of them parses, which no script, case, config, doc
or workflow anywhere in the tree spells, has no caller — the capability behind
it is reachable only by a human who reads the source and types it.

A parity gate fed by such a flag compares against an empty capture in every
scene, prints `0/N glyphs` — no mismatches — and reports a whole seam, while
the lane compares nothing in any commit.

The distinguishing property is cheap and is not a judgement call: count the
FILES in the tree that spell the flag as an exact token. One means the reader is
alone. That separates "opt-in and driven from somewhere I did not look" from
"opt-in and never opted into", which a search of one directory cannot.

The verdict is a SET comparison against the tracked list, not a count:

    a flag is unwired that is not listed  -> FAIL, a capability just went dark
    a listed flag gains a caller          -> FAIL, delete its line
    the sets match                        -> pass, and say so

The second rule is what stops the list rotting into an allowlist. Wiring a flag
cannot quietly leave a stale entry behind, because the stale entry is itself a
failure.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Entry points whose command-line audience is scripts and cases: every flag they
# parse is meant to be driven from the tree, so one spelled nowhere else has no
# caller. A binary a person runs with flags does not belong here — its flags are
# typed, not scripted, and one without a script caller may still belong to a user.
#
# These four parse automation flags only. The census at the end of a passing run
# names the other files that parse flags and why each stays out: Host and Linux
# main.cpp are frontends a person runs; Linux and macOS main both build their
# test-mode names at runtime — check-linux-smokes.sh and check-macos-smokes.py
# grep the modes from the source and call them, so a flag one of those runners
# drives reads as dark to the spelling index here; and LaunchArguments.cpp is a
# shared parser, not a binary of its own.
ENTRY_POINTS = [
    "Source/Agent/main.cpp",
    "Source/UbiquittyKit/Swift/SurfaceRenderProfile.swift",
    "Source/Core/App/SnapshotRequest.h",
    "Source/Platform/macOS/UITest/Swift/UITestRunner.swift",
]

TRACKED = ROOT / "Tests" / "unwired-flags.txt"

FLAG = re.compile(r'"(--[a-z0-9][a-z0-9-]*)"')

# Vendored code: a flag spelled in a third-party README is not a caller here.
# Build products need no entry — the index reads tracked files only.
#
# The tracked list and this file are excluded, and without that the check reports
# every flag as wired the moment its own record is committed: the record spells
# each name, so each name reaches two files. A record of absence cannot be
# evidence of presence, and neither can the prose or the self-test of the check
# doing the looking — both name the flags they exist to discuss.
EXCLUDED = ["Source/ThirdParty", "Tests/unwired-flags.txt", "Scripts/check-unwired-flags.py",
            "Source/Core/Diagnostics/SnapshotArguments.h",  # parsed request fields are not callers
            "Source/Core/Preferences/SnapshotConfigurationFlags.h",  # a shared parser is a reader, not a caller
            "Audits"]  # audit reports discuss flags by name, as the record does


def flagsRead(path):
    """Returns the flag literals an entry point parses.

    - Parameters:
      - path: repository-relative path to the entry point.
    - Returns: a sorted list of flag strings, each including its leading dashes.
    """
    text = (ROOT / path).read_text(encoding="utf-8", errors="replace")
    return sorted(set(FLAG.findall(text)))


def spellingIndex():
    """Returns every flag token in the tracked tree, mapped to the files spelling it.

    One `git grep` pass rather than one per flag: the per-flag form costs a full
    walk each time and does not finish. `-o` also settles the boundary for free —
    it yields the token it matched, so `--bg-image` is recorded under its own
    name and never under `--bg`. Matching a flag as a substring would report
    every short name as wired by its longer siblings.

    Tracked files only, which is the right population: an untracked build
    product spelling a flag is not a caller, and `git grep` excludes it without
    a list of directory names to keep current.

    - Returns: a dict from flag string to a set of repository-relative paths.
    """
    excludes = [":!" + directory for directory in EXCLUDED]
    result = subprocess.run(
        ["git", "grep", "-oIE", "--", r"--[a-z0-9][a-z0-9-]*", "--", "."] + excludes,
        cwd=ROOT, capture_output=True, text=True)
    # git grep exits 1 for no match, which is an answer rather than an error.
    if result.returncode not in (0, 1):
        raise RuntimeError("git grep failed: " + result.stderr.strip())
    index = {}
    for line in result.stdout.splitlines():
        path, separator, token = line.rpartition(":")
        if not separator:
            continue
        index.setdefault(token, set()).add(path)
    return index



def uncensusedReaders():
    """Returns the files that PARSE flags and are not among the entry points.

    Keyed on a parse site — a flag literal compared against an argument — and
    not on the presence of a flag-shaped string. Counting the second reports a
    README, an Emacs lisp file, a CMakeLists and Core sources that merely
    contain `--` in prose. Same error the rest of this file exists to catch: a
    predicate keyed on the shape of the evidence rather than on its subject.

    The entry-point list is a claim about which binaries scripts drive, and it
    is narrower than the set of files that parse. A file outside it may be the
    shipping app's own command line — where a flag with no in-tree caller is
    typed by a person and belongs to nobody — or a driver whose flags this
    check ought to cover. Counting cannot separate them, and
    `Source/Platform/Linux/main.cpp` is both at once: `--config` and
    `--print-config` for a user, `--dump-png-vk` and `--feed-file` for a script.

    So the count is stated rather than acted on. A census that names its scope
    can be read; one that prints `ok` over an unexamined binary cannot be told
    from one that examined it.

    - Returns: a sorted list of (path, parse-site count) outside ENTRY_POINTS.
    """
    pattern = r'(hasFlag|std::strcmp\(arg[A-Za-z]*|argument ==|arg ==)[^;]*"--'
    result = subprocess.run(["git", "grep", "-cE", "--", pattern, "--",
                             "Source/*.cpp", "Source/*.mm", "Source/*.h",
                             "Source/**/*.cpp", "Source/**/*.mm", "Source/**/*.h"],
                            cwd=ROOT, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError("git grep failed: " + result.stderr.strip())
    found = []
    for line in result.stdout.splitlines():
        path, _, count = line.rpartition(":")
        if not path or path in ENTRY_POINTS:
            continue
        if any(path.startswith(d) for d in EXCLUDED):
            continue
        found.append((path, int(count)))
    return sorted(found)


def readTracked():
    """Returns the flags recorded as unwired, and the file's comment lines.

    - Returns: a tuple of (set of flag strings, list of comment lines).
    """
    if not TRACKED.exists():
        return set(), []
    flags, comments = set(), []
    for line in TRACKED.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            comments.append(line)
            continue
        flags.add(stripped.split()[0])
    return flags, comments


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true",
                        help="print the measured set and exit 0, for updating the tracked file")
    parser.add_argument("--self-test", action="store_true",
                        help="prove the boundary match and the set comparison both directions")
    arguments = parser.parse_args()

    if arguments.self_test:
        return selfTest()

    index = spellingIndex()
    unwired, readCount = {}, 0
    for entry in ENTRY_POINTS:
        if not (ROOT / entry).exists():
            print("check-unwired-flags: entry point missing: " + entry, file=sys.stderr)
            print("  The list of entry points is a claim about which binaries scripts drive.",
                  file=sys.stderr)
            print("  A renamed or deleted one silently empties this check.", file=sys.stderr)
            return 2
        for flag in flagsRead(entry):
            readCount += 1
            if len(index.get(flag, set())) <= 1:
                unwired[flag] = entry

    if arguments.list:
        for flag in sorted(unwired):
            print(flag + "  " + unwired[flag])
        return 0

    if readCount == 0:
        print("check-unwired-flags: no flag literals found in any entry point", file=sys.stderr)
        print("  The reader pattern no longer matches, so this check inspects nothing.",
              file=sys.stderr)
        return 2

    tracked, _ = readTracked()
    measured = set(unwired)

    newlyDark = sorted(measured - tracked)
    nowWired = sorted(tracked - measured)

    if newlyDark:
        print("check-unwired-flags: a flag went dark — read by an entry point, spelled nowhere else",
              file=sys.stderr)
        for flag in newlyDark:
            print("    " + flag + "  read in " + unwired[flag], file=sys.stderr)
        print("  Nothing in the tree passes it, so the capability behind it runs in no run.",
              file=sys.stderr)
        print("  Wire it from a script or a case, or record it in " +
              str(TRACKED.relative_to(ROOT)) + " with the reason.", file=sys.stderr)
    if nowWired:
        print("check-unwired-flags: a recorded flag now has a caller", file=sys.stderr)
        for flag in nowWired:
            print("    " + flag, file=sys.stderr)
        print("  Delete its line. A stale entry suppresses nothing and hides the next one.",
              file=sys.stderr)
    if newlyDark or nowWired:
        return 1

    print("check-unwired-flags: ok (" + str(readCount) + " flag reads across " +
          str(len(ENTRY_POINTS)) + " entry point(s); " + str(len(measured)) +
          " unwired, each recorded)")
    uncensused = uncensusedReaders()
    if uncensused:
        total = sum(n for _, n in uncensused)
        print("  Not examined: " + str(total) + " flag parse site(s) in " +
              str(len(uncensused)) + " other file(s) that parse flags —")
        for path, n in uncensused:
            print("    " + str(n).rjust(3) + "  " + path)
        print("    why each stays out, and what wired means here: this file's own header")
    return 0


def selfTest():
    """Proves the boundary match and both directions of the set comparison.

    - Returns: 0 when every arm behaves as stated, 1 otherwise.
    """
    failures = []
    index = spellingIndex()

    def spelling(flag):
        return index.get(flag, set())

    # The boundary is the whole reason a short flag is not reported as wired by
    # its longer siblings. `--bg` occurs inside `--bg-image` textually.
    short = spelling("--bg")
    longer = spelling("--bg-image")
    if len(short) > 1 and len(longer) <= 1:
        failures.append("--bg matched more files than --bg-image, so the boundary is not holding")

    # A flag every script spells must never be reported.
    if len(spelling("--snapshot")) <= 1:
        failures.append("--snapshot reported as unwired; it is spelled across Tests/ and Scripts/")

    # A flag nothing spells must be reported. Taken from the tracked list rather
    # than named here: a flag hardcoded as the unwired example goes stale the day
    # it is wired, and then the self-test fails for a reason that is not a defect.
    tracked, _ = readTracked()
    if not tracked:
        failures.append("the tracked list is empty, so the unwired arm of this test has no subject")
    else:
        example = sorted(tracked)[0]
        if len(spelling(example)) > 1:
            failures.append(example + " is recorded as unwired and has a caller; "
                            "the set comparison should have said so first")

    # A name that occurs nowhere at all is still 'one file or fewer'.
    if len(spelling("--this-flag-does-not-exist-anywhere")) != 0:
        failures.append("a nonexistent flag matched a file")

    for failure in failures:
        print("check-unwired-flags --self-test: " + failure, file=sys.stderr)
    if failures:
        return 1
    print("check-unwired-flags --self-test: ok (boundary holds; a wired flag, an unwired "
          "flag and a nonexistent one each classify as stated)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
