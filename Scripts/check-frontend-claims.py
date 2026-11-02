#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""check-frontend-claims.py — a header that says a frontend uses it is checked.

A portable component is extracted for a second consumer, the extraction lands,
and the second consumer does not arrive. What is left behind is a header whose
comment says `shared by the macOS MTKView drive and the Linux GTK frame clock`
while nothing under `Source/Platform/Linux` can reach it. The code is fine; the
sentence is not, and it is the sentence the next frontend author reads when
deciding whether a seam is proven. `FrameDriver`, `IngestLoop` and `AppRuntime`
all carried one, which is what makes this a class rather than a typo.

Nothing else catches it. A build cannot: the claim is a comment. A reviewer
cannot, reliably: the claim is true on the day it is written, and becomes false
by a consumer never being added, which is not an event anyone reviews.

So the claim is read as an assertion and checked. A sentence in a header's
leading comment that names an arm alongside a sharing phrase asserts that the
arm reaches the header, and reach is decided over the include graph rather than
by a direct include -- a Core header consumed through another Core header is
reached, and the claim is about adoption, not about who types the include.

Sentence-scoped, because the arm has to be named by the claim rather than
anywhere in the block: `Core/Title/Directory.h` mentions a web browser several
paragraphs from its sharing sentence, and reading the block as one string makes
that a claim about the Web frontend.

`--self-test` plants a header claiming an arm that cannot reach it, and one
claiming an arm that reaches it only transitively. The first must be caught and
the second must not, which is what separates this from a direct-include grep.

Stdlib only.

    python3 Scripts/check-frontend-claims.py
    python3 Scripts/check-frontend-claims.py --self-test
"""

import os
import re
import sys
import tempfile

# The platform arms, by directory name under Source/Platform. The spelling here
# is the spelling a claim has to use to name one.
ARMS = ("macOS", "Linux", "Web", "Host")

# A sentence that shares. Kept to phrases that assert a consumer rather than a
# design intent: "portable so a frontend could" is a plan, and a plan is allowed
# to have no consumer yet.
SHARING = re.compile(
    r"\bshared (?:by|across|between)\b"
    r"|\bboth frontends\b"
    r"|\bevery frontend\b"
    r"|\bso (?:the|a) \w+ (?:backend|frontend|arm)\b"
    r"|\bconsumed by\b",
    re.IGNORECASE,
)

# "every frontend" is not read as an enumeration. Expanding it to the four
# directories that happen to exist would file two claims its author did not
# make: that a headless daemon is a frontend, and that the policy is in
# violation until an arm nobody has written yet adopts it. Only an arm the
# sentence names is checked, since only that names a consumer.

SOURCE_EXTENSIONS = (".h", ".hpp", ".cpp", ".mm", ".m", ".c")
INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)


def leadingComment(text):
    """The file's own header block: the comment lines before the first code.

    Copyright and license lines are part of it and harmless -- they name no arm.
    """
    lines = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            lines.append(stripped[2:].strip())
            continue
        if not stripped or stripped.startswith("#pragma"):
            continue
        break
    return lines


def sentences(commentLines):
    """The block re-joined and split into sentences.

    Joined first because a sentence wraps across lines, and it is the sentence
    that scopes a claim -- the whole block would let any arm named anywhere
    answer for a sharing phrase written paragraphs away.
    """
    joined = " ".join(commentLines)
    return [part for part in re.split(r"(?<=[.;])\s+", joined) if part]


def claimedArms(text):
    """The arms a file's leading comment asserts as consumers."""
    claimed = set()
    for sentence in sentences(leadingComment(text)):
        if not SHARING.search(sentence):
            continue
        for arm in ARMS:
            # Word-bounded so "Host" does not match "hosting" and "Web" does not
            # match "webhook".
            if re.search(r"\b" + re.escape(arm) + r"\b", sentence):
                claimed.add(arm)
    return claimed


def sourceFiles(sourceRoot):
    for directory, _, names in os.walk(sourceRoot):
        for name in names:
            if name.endswith(SOURCE_EXTENSIONS):
                yield os.path.join(directory, name)


def includeGraph(sourceRoot):
    """file -> the set of Source-relative headers it includes.

    Include text is resolved against Source/ because that is the include root
    the tree compiles with: `#include "Core/Runtime/FrameDriver.h"`.
    """
    graph = {}
    for path in sourceFiles(sourceRoot):
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        relative = os.path.relpath(path, sourceRoot)
        edges = set()
        for included in INCLUDE.findall(text):
            candidate = os.path.normpath(included)
            if os.path.exists(os.path.join(sourceRoot, candidate)):
                edges.add(candidate)
        graph[relative] = edges
    return graph


def reachableFrom(graph, roots):
    """Every header the roots reach, directly or through another header."""
    seen = set()
    pending = list(roots)
    while pending:
        current = pending.pop()
        for edge in graph.get(current, ()):
            if edge not in seen:
                seen.add(edge)
                pending.append(edge)
    return seen


def scan(sourceRoot):
    """The violations: a claimed arm that cannot reach the header claiming it."""
    graph = includeGraph(sourceRoot)
    reach = {}
    for arm in ARMS:
        armPrefix = os.path.join("Platform", arm) + os.sep
        roots = [name for name in graph if name.startswith(armPrefix)]
        reach[arm] = reachableFrom(graph, roots) if roots else None

    violations = []
    for relative in sorted(graph):
        # Only the portable layers make this claim; a platform file saying it is
        # shared is describing something it owns.
        if not relative.startswith(("Core" + os.sep, "App" + os.sep)):
            continue
        if not relative.endswith((".h", ".hpp")):
            continue
        try:
            with open(os.path.join(sourceRoot, relative), encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        for arm in sorted(claimedArms(text)):
            if reach[arm] is None:
                continue  # the arm is not in this tree, so it claims nothing here
            if relative not in reach[arm]:
                violations.append((relative, arm))
    return violations


def selfTest():
    """The rule is shown to catch its case and to leave the near-miss alone."""
    failures = []
    with tempfile.TemporaryDirectory() as root:
        def write(relative, text):
            path = os.path.join(root, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)

        # Claimed and unreachable: the case.
        write("Core/Orphan.h", "// Pacing policy, shared by the macOS drive and the Linux clock.\n")
        # Claimed and reached only through another Core header: not a violation,
        # and the reason a direct-include grep cannot do this job.
        write("Core/Indirect.h", "// Scroll state, shared by the macOS and Linux frontends.\n")
        write("Core/Middle.h", '#include "Core/Indirect.h"\n')
        # An arm named far from the sharing sentence is not a claim about it.
        write(
            "Core/Unrelated.h",
            "// Directory titles, shared by the macOS and Linux frontends.\n"
            "//\n"
            "// A Web browser shows the same segment, which is where the rule came from.\n",
        )
        write("Platform/macOS/App.mm", '#include "Core/Middle.h"\n#include "Core/Unrelated.h"\n')
        write("Platform/Linux/main.cpp", '#include "Core/Middle.h"\n#include "Core/Unrelated.h"\n')

        found = set(scan(root))
        for expected in (("Core/Orphan.h", "macOS"), ("Core/Orphan.h", "Linux")):
            if expected not in found:
                failures.append("a header claiming an arm that cannot reach it went uncaught: %s" % (expected,))
        for relative, arm in sorted(found):
            if relative != "Core/Orphan.h":
                failures.append("fired on a reachable claim: %s claims %s" % (relative, arm))

    for failure in failures:
        print("self-test: " + failure, file=sys.stderr)
    if failures:
        return 1
    print("check-frontend-claims: self-test ok (an unreachable claim is caught; a transitive one is not)")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return selfTest()

    sourceRoot = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Source")
    sourceRoot = os.path.normpath(sourceRoot)
    if not os.path.isdir(sourceRoot):
        print("check-frontend-claims: FAIL - %s is missing, so nothing was checked" % sourceRoot, file=sys.stderr)
        return 1

    violations = scan(sourceRoot)
    if violations:
        print("check-frontend-claims: FAIL - a header says a frontend uses it, and that frontend cannot reach it.")
        print("  Adopt the component there, or name the consumer the header actually has.")
        for relative, arm in violations:
            print("  Source/%s claims %s, which reaches no include path to it" % (relative, arm))
        return 1

    print("check-frontend-claims: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
