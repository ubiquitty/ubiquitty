#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Hold each frontend to the selection-bounds entry point it is recorded under.

`Selection::getBounds` and `Selection::getBoundsWide` differ by a whole cell on
a wide glyph: the wide entry point, given an `attributesAt`, snaps an anchor to
the glyph's leading half, and the plain one does not. The consequence is not a
misplaced edge — a bound anchored on a continuation half drops that glyph from
the copied text, because the continuation repeats the lead's code point and the
text walk skips it.

A call site reads the same under either explanation. A frontend on the plain
entry point may have judged that its arm never renders a wide cell, or may have
been written without the attributes callback in hand; both produce the identical
line, and no build, test or golden in the tree distinguishes them. So the entry point each file takes is
recorded in Tests/selection-bounds-callers.txt with the reason, and this
compares the record against the tree.

Keyed on (file, entry point, count) rather than on line numbers, so ordinary
edits above a call site do not churn the record while a switched entry point or
a new site still fails.

Four bounds, so the record cannot rot in either direction:

    a file whose entry point changed  -> FAIL, the record and the code disagree
    a file whose count changed        -> FAIL, a site appeared or left
    a call in an unlisted file        -> FAIL, a frontend defaulted silently
    a listed file with no calls left  -> FAIL, delete its line

The third is the one this exists for. A new frontend reaches for `getBounds`
because it is the shorter name, and nothing anywhere reports that it has taken
the unsnapped path.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

# Anchored to the script's own location, not the caller's cwd. `git grep`
# resolves its pathspec against the current directory, so from the ctest shell
# wrapper's build-dir cwd a relative search matches nothing and the gate refuses
# a tree it cannot reach — green from the repo root, red from ctest, the
# two-verdicts-by-cwd class measured in check-sync-struct-defaults. The record
# reads the same way. Both are absolute, and measure() runs the grep with cwd at
# REPO.
REPO = Path(__file__).resolve().parent.parent
RECORD = str(REPO / "Tests/selection-bounds-callers.txt")
SEARCH_ROOT = "Source/Platform"

# Ordered longest first: the names are prefixes of one another, and an
# alternation trying `getBounds` first would classify every site as the plain
# entry point and report the tree as uniformly unsnapped.
CALL_PATTERN = re.compile(r"\b(getBoundsWideWith|getBoundsWide|getBounds)\s*\(")


def measure(root):
    """Counts each file's selection-bounds calls by entry point.

    - Parameter root: the directory to search under.
    - Returns: {path: {entryPoint: count}}.
    """
    result = subprocess.run(
        ["git", "grep", "-n", "-E", r"getBounds(WideWith|Wide)?\s*\(", "--", root],
        capture_output=True, text=True, cwd=str(REPO))
    measured = {}
    for line in result.stdout.splitlines():
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        path, _, text = parts
        # A declaration or a comment is not a call site. Only lines naming the
        # Selection namespace or an unqualified call inside one count.
        if text.lstrip().startswith(("//", "*", "///")):
            continue
        match = CALL_PATTERN.search(text)
        if not match:
            continue
        measured.setdefault(path, {}).setdefault(match.group(1), 0)
        measured[path][match.group(1)] += 1
    return measured


def readRecord(path):
    """Parses the recorded call sites.

    - Parameter path: the record file.
    - Returns: {path: (entryPoint, count)}.
    """
    recorded = {}
    for line in Path(path).read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 3:
            continue
        recorded[fields[0]] = (fields[1], int(fields[2]))
    return recorded


def judge(measured, recorded):
    """Compares the tree against the record.

    - Parameters:
      - measured: what the tree has.
      - recorded: what the record claims.
    - Returns: a list of finding strings, empty when they agree.
    """
    findings = []
    for path, entries in sorted(measured.items()):
        # One file, one entry point: a file calling both would be resolving the
        # same question two ways, which the record has no way to spell and which
        # is worth failing on rather than recording.
        if len(entries) > 1:
            findings.append(f"{path} calls {len(entries)} different entry points "
                            f"({', '.join(sorted(entries))}) — one file resolving the "
                            "same question two ways is the fork this record exists to "
                            "surface, not a shape to write down")
            continue
        entry, count = next(iter(entries.items()))
        if path not in recorded:
            findings.append(f"{path} calls {entry} {count} time(s) and is not recorded — "
                            "a frontend took an entry point with nothing saying which")
            continue
        recordedEntry, recordedCount = recorded[path]
        if recordedEntry != entry:
            findings.append(f"{path} is recorded under {recordedEntry} and calls {entry}")
        elif recordedCount != count:
            findings.append(f"{path} is recorded with {recordedCount} {entry} call(s) "
                            f"and has {count}")

    for path in sorted(set(recorded) - set(measured)):
        findings.append(f"{path} is recorded and calls none — delete its line")
    return findings


def selfTest():
    """Proves each bound fires, and that the measurement is not empty.

    The last arm matters most: `judge` returns no findings when the tree
    measures nothing at all, which is the same answer it gives when everything
    agrees. Only a non-empty measurement tells those apart.

    - Returns: 0 when every arm behaves as stated, 1 otherwise.
    """
    failures = []
    whole = {"a.mm": {"getBounds": 2}}
    record = {"a.mm": ("getBounds", 2)}

    if judge(whole, record):
        failures.append("a file matching its record was flagged")
    if not judge({"a.mm": {"getBoundsWide": 2}}, record):
        failures.append("a switched entry point was not flagged")
    if not judge({"a.mm": {"getBounds": 3}}, record):
        failures.append("a changed call count was not flagged")
    if not judge({"b.mm": {"getBounds": 1}}, record):
        failures.append("an unrecorded file was not flagged")
    if not judge({}, record):
        failures.append("a recorded file with no calls was not flagged")
    if not judge({"a.mm": {"getBounds": 1, "getBoundsWide": 1}}, record):
        failures.append("a file calling both entry points was not flagged")

    # The measurement arm. A grep that matched nothing would produce an empty
    # dict, and `judge({}, {})` is clean — so the count is what separates a tree
    # that agrees from a search that ran over nothing.
    measured = measure(SEARCH_ROOT)
    if not measured:
        failures.append(f"the search found no call site under {SEARCH_ROOT} — a clean "
                        "verdict from this check would be the search's and not the tree's")

    for failure in failures:
        print("check-selection-bounds-callers --self-test: " + failure, file=sys.stderr)
    if failures:
        return 1
    print("check-selection-bounds-callers --self-test: ok (each bound fires, and the "
          f"search finds {sum(sum(e.values()) for e in measured.values())} call site(s) "
          "so a clean verdict is the tree's)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--record", default=RECORD)
    parser.add_argument("--root", default=SEARCH_ROOT)
    parser.add_argument("--self-test", action="store_true",
                        help="prove each bound fires, and that the search is not the zero")
    arguments = parser.parse_args()

    if arguments.self_test:
        return selfTest()

    measured = measure(arguments.root)
    if not measured:
        print(f"check-selection-bounds-callers: REFUSED — no call site found under "
              f"{arguments.root}. An agreeing tree and a search over nothing print "
              "alike, so this is not a pass.", file=sys.stderr)
        return 2

    findings = judge(measured, readRecord(arguments.record))
    if findings:
        print("check-selection-bounds-callers: the tree and " + arguments.record
              + " disagree:", file=sys.stderr)
        for finding in findings:
            print("    " + finding, file=sys.stderr)
        print("  getBounds and getBoundsWide differ by a whole cell on a wide glyph, "
              "and a call site reads the same whether that was chosen or omitted. "
              "Record which one, with the reason.", file=sys.stderr)
        return 1

    total = sum(sum(entries.values()) for entries in measured.values())
    wide = sum(count for entries in measured.values()
               for entry, count in entries.items() if entry != "getBounds")
    print(f"check-selection-bounds-callers: ok ({total} call site(s) across "
          f"{len(measured)} file(s), {wide} wide-aware, each under the entry point "
          "recorded for it)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
