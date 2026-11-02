#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-shared-kit-imports.py — fail when a shared Apple source imports a
module only one of the two arms has.

  ./Scripts/check-shared-kit-imports.py

UBIQUITTY_APPLE_SHARED_KIT_SOURCES and UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES
compile into both Apple arms, macOS and iOS. A file added there that imports
AppKit or Carbon compiles for whoever added it and fails for the other arm —
not as a warning, as "no such module".

A shared source importing Carbon.HIToolbox blocks every iOS build, and the macOS
author cannot see it, because their arm is the one that works. That is the
defect this closes: the feedback is on the other side of the wall from the
person who can act on it, so it arrives as someone else's broken build.

An import is fine inside `#if canImport(...)` or `#if os(...)`, because that is
the construct that makes it conditional. A bare import at file scope is not.

Textual, for the reason check-swift-sources.py gives: the question is about a
LIST, and asking the build to answer it means configuring both arms to learn
what a grep already knows. It also fails in seconds with no iOS toolchain, which
is the point — it puts the feedback on the macOS author's own side.

Stdlib only.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
SHARED_LIST = os.path.join(HERE, "cmake", "AppleSharedSwift.cmake")

sys.path.insert(0, HERE)
import gate_report  # noqa: E402

GATE = "check-shared-kit-imports.py"

# The two lists that compile into both arms. Named, not guessed: a third shared
# list added later should fail this gate's own extraction check rather than be
# silently skipped.
SHARED_VARIABLES = (
    "UBIQUITTY_APPLE_SHARED_KIT_SOURCES",
    "UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES",
)

# Modules exactly one Apple arm has. Submodules count — the breakage that
# prompted this was `import Carbon.HIToolbox`, not `import Carbon`.
PLATFORM_ONLY = ("AppKit", "Cocoa", "Carbon", "UIKit")

IMPORT = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|internal|package|private|fileprivate)\s+)?import\s+([A-Za-z_][A-Za-z0-9_.]*)")
CONDITION_OPEN = re.compile(r"^\s*#\s*(if|elseif)\b")
CONDITION_CLOSE = re.compile(r"^\s*#\s*endif\b")


def shared_sources():
    """Repo-relative paths named by the two shared lists."""
    try:
        with open(SHARED_LIST, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return None
    found = []
    for variable in SHARED_VARIABLES:
        start = text.find("set(%s" % variable)
        if start < 0:
            return None
        # Balance the parens rather than looking for a newline before the
        # close: these lists end with `....swift)` on the last entry's own
        # line, and a gate that assumed otherwise read every list as empty.
        depth = 0
        end = -1
        for index in range(text.index("(", start), len(text)):
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
                if depth == 0:
                    end = index
                    break
        if end < 0:
            return None
        found.extend(re.findall(r"(Source/[A-Za-z0-9_/.+-]+\.swift)", text[start:end]))
    return found


def scan(lines):
    """(line number, module) for each BARE platform-only import.

    Split from `offenders_in` so the self-test drives the rule itself rather
    than a file on disk.
    """
    found = []
    depth = 0
    for number, text in enumerate(lines, start=1):
        if CONDITION_OPEN.match(text):
            depth += 1
            continue
        if CONDITION_CLOSE.match(text):
            depth = max(0, depth - 1)
            continue
        # Inside any #if, the import is conditional — which is the whole ask.
        if depth:
            continue
        match = IMPORT.match(text)
        if not match:
            continue
        module = match.group(1)
        head = module.split(".", 1)[0]
        if head in PLATFORM_ONLY:
            found.append((number, module))
    return found


def offenders_in(path):
    """(line number, module) for each BARE platform-only import in one file."""
    full = os.path.join(REPO, path)
    try:
        with open(full, encoding="utf-8") as handle:
            return scan(handle.read().splitlines())
    except (OSError, UnicodeDecodeError):
        return []


def selfTest():
    bare = ["import AppKit", "import Foundation", "import UIKit"]
    # The breakage that prompted the gate was a SUBMODULE import, and a rule
    # keyed on the bare module name would have vouched for it.
    submodule = ["import Carbon.HIToolbox"]
    guarded = [
        "#if canImport(AppKit)",
        "import AppKit",
        "#endif",
        "#if os(iOS)",
        "import UIKit",
        "#endif",
    ]
    # An access-level import is still an import; Swift 6 spells several.
    levelled = ["internal import AppKit"]
    ok = ([m for _, m in scan(bare)] == ["AppKit", "UIKit"]
          and [m for _, m in scan(submodule)] == ["Carbon.HIToolbox"]
          and not scan(guarded)
          and [m for _, m in scan(levelled)] == ["AppKit"])
    print("  %s bare and submodule and access-levelled imports are caught, guarded ones are not"
          % ("ok " if ok else "FAIL"))
    print("check-shared-kit-imports: self-test %s" % ("ok" if ok else "FAILED"))
    return 0 if ok else 1


def main(argv):
    if "--self-test" in argv[1:]:
        return selfTest()

    paths = shared_sources()

    # The vacuous direction is the reassuring one. If the extraction stops
    # matching, every file reads as unlisted and a naive gate passes over an
    # empty set — which is exactly when the boundary is unguarded.
    if not paths:
        gate_report.failed(
            GATE,
            "found no shared Apple sources at all, so the gate checked nothing. "
            "Scripts/cmake/AppleSharedSwift.cmake must define %s as set(...) "
            "blocks naming Source/... .swift paths; fix the extraction rather "
            "than the list." % " and ".join(SHARED_VARIABLES),
            [SHARED_LIST],
        )
        return 1

    missing = [p for p in paths if not os.path.exists(os.path.join(REPO, p))]
    if missing:
        gate_report.failed(
            GATE, "a shared list names a file that is not in the tree", missing
        )
        return 1

    offenders = []
    for path in sorted(set(paths)):
        for number, module in offenders_in(path):
            offenders.append(
                "%s:%d: imports %s at file scope — it compiles into both Apple "
                "arms, so guard it with #if canImport(%s) or move the file to "
                "the arm's own list"
                % (path, number, module, module.split(".", 1)[0])
            )

    if offenders:
        gate_report.failed(
            GATE,
            "a source shared by both Apple arms imports a module only one of "
            "them has; the other arm fails with \"no such module\"",
            offenders,
        )
        return 1

    gate_report.ok(GATE, "no bare platform-only import in %d shared Apple sources" % len(set(paths)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
