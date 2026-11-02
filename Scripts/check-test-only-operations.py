#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Name the terminal operations whose only callers are their own tests.

Such an operation reads as covered by every signal at once: its tests pass, its
lines are green in the coverage report, its symbol links, and `check-unwired`
style greps find it spelled. What none of those say is that no shipping code
path reaches it — the capability behind it either arrives another way, or does
not arrive at all.

The population is the declarations in Source/Core/TerminalOperations.h, which
is the surface frontends call. For each name, the callers are counted in every
shipping world — the frontends, PAL, the agent, the tools, and Core itself,
since Core compiles into every frontend and its Runtime is a real consumer. A
declaration or definition is not a caller, and the discriminator is what
stands immediately before the name — a type token means decl or def, a
qualifier, an assignment or `return` means call. Two line-opening shapes were
tried first and each dropped a real caller; the doc on `isCallSite` names them.

The record's verdicts are not one thing, and collapsing them is the error this
check exists to prevent:

    wired-otherwise   the capability ships through a client callback or a
                      direct field, and the operation is the test seam. Fine,
                      and worth a line so the next census does not rediscover
                      it.
    orphaned          no caller anywhere, tests included. Not this gate's to
                      delete; recorded so the next reader starts from the
                      measurement.
    inert-install     the operation is the gated install point for a
                      capability that stays dead until a frontend wires it,
                      and staying dead is the design. The MC print sink's own doc says the inertness
                      is the security property. What the record adds is that
                      the decision is WRITTEN — an install point nobody wired
                      and an install point nobody finished read identically in
                      the tree.

Three bounds, so the record cannot rot in either direction:

    an unrecorded test-only operation   -> FAIL, say which kind it is
    a recorded one that gains a caller  -> FAIL, delete its line
    a recorded name no longer declared  -> FAIL, likewise
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

# Anchored to the script's own location, not the caller's cwd. The ctest shell
# wrapper runs stanzas from the build directory, not the repo root, and a
# root-relative HEADER read there is a FileNotFoundError — the stanza goes red
# from ctest while a by-hand run from the root stays green, the two-verdicts-by-cwd
# class check-sync-struct-defaults also guards against.
REPO = Path(__file__).resolve().parent.parent
HEADER = str(REPO / "Source/Core/TerminalOperations.h")
SHIPPING = ("Source/Platform", "Source/PAL", "Source/Agent", "Tools", "Source/Core")
SUFFIXES = (".cpp", ".mm", ".h", ".swift", ".cc", ".js")

# Each test-only operation, its verdict, and the reason a reader can check.
RECORDED = {
    "progressGeneration": (
        "wired-otherwise",
        "OSC 9;4 progress reaches frontends through the PAL client; the "
        "generation accessor's own doc describes a polling consumer that no "
        "frontend is."),
    "tabStatusGeneration": (
        "wired-otherwise",
        "OSC 21337 tab status ships through UBWindowController and "
        "TabAttentionDots.swift; the generation accessor is the test seam."),
    "userVariable": (
        "wired-otherwise",
        "OSC 1337 SetUserVar stores through the parser; the readback accessor "
        "has no shipping reader."),
    "setPrintSinkPath": (
        "inert-install",
        "DEC MC writes through the sink this installs, and the operation's own "
        "doc names the inertness as the security property: without a sink the "
        "MC operations cannot write files. No frontend installs one, so MC is "
        "inert in every shipping build. Confirmed as the decision by "
        "ubiquitty-frontends (2026-08-12): the capability ships when someone "
        "designs the consent surface around host-written files, not before."),
}


def declaredOperations(headerText):
    """Returns the function names declared in the operations header.

    - Parameter headerText: the header's contents.
    - Returns: a sorted list of lowerCamelCase names.
    """
    names = set(re.findall(
        r"^\s*(?:\[\[nodiscard\]\]\s*)?[A-Za-z_][\w:<>&*\s]*?\b([a-z][A-Za-z0-9_]*)\s*\(",
        headerText, re.M))
    return sorted(n for n in names
                  if n not in {"if", "for", "while", "switch", "return", "sizeof"})


def shippingText(root):
    """Returns the concatenated shipping-world sources, comments stripped.

    - Parameter root: the repository root.
    - Returns: one string over every frontend, PAL, agent, tool and Core source.
    """
    listed = subprocess.run(["git", "ls-files", *SHIPPING],
                            capture_output=True, text=True, cwd=root).stdout.split()
    lines = []
    for path in listed:
        if not path.endswith(SUFFIXES):
            continue
        for line in (Path(root) / path).read_text(errors="ignore").splitlines():
            lines.append(line.split("//")[0])
    return "\n".join(lines)


# The last word of a call's prefix, when the prefix ends in an identifier: these
# introduce an expression, so `return processBytes(` is a call and `void
# processBytes(` is not. Everything hangs on classifying by what stands
# IMMEDIATELY before the name — two earlier shapes classified by how the LINE
# opens, and each dropped a real caller: a filter keyed on `Ubiquitty::` ate
# `Ubiquitty::hardReset(&t)`, and one keyed on `const ` ate
# `const int consumed = Ubiquitty::processBytesUpToSyncClear(...)`.
CALL_KEYWORDS = {"return", "co_return", "co_await", "else", "case", "and", "or", "not"}


def isCallSite(prefix):
    """Whether an occurrence with this preceding text is a call.

    - Parameter prefix: the line's text before the name, qualifiers stripped.
    - Returns: True for a call, False for a declaration or definition.
    """
    trimmed = prefix.rstrip()
    if not trimmed:
        return True
    match = re.search(r"([A-Za-z_][\w<>:,\s]*?)[\s*&]+$", prefix)
    if match is None:
        return True
    lastWord = re.findall(r"[A-Za-z_]\w*", match.group(1))
    return bool(lastWord) and lastWord[-1] in CALL_KEYWORDS


# Every `identifier(` in the shipping text, mapped to the lines it appears on.
# One pass builds it; each operation then reads its own candidate lines instead
# of scanning the whole corpus. The scan it replaces was a lazy `[^\n]*?` prefix
# applied to the concatenated worlds once per operation, which backtracks across
# megabytes per name.
CALLED_NAME = re.compile(r"([A-Za-z_]\w*)\s*\(")


def callSiteIndex(shipping):
    """Maps each called name to the shipping lines that mention it.

    - Parameter shipping: the shipping worlds' concatenated text.
    - Returns: a dict from name to the list of lines holding `name(`.
    """
    index = {}
    for line in shipping.split("\n"):
        for name in set(CALLED_NAME.findall(line)):
            index.setdefault(name, []).append(line)
    return index


def hasShippingCaller(name, index):
    """Whether any shipping line calls the operation.

    A qualified call is reached through the same name: `A::foo(` indexes under
    `foo`, so the qualifier chain is matched here and excluded from the prefix
    the call test judges.

    - Parameters:
      - name: the operation.
      - index: the call-site index over the shipping worlds.
    - Returns: True when at least one occurrence is call-shaped.
    """
    pattern = re.compile(r"((?:[A-Za-z_]\w*::)*)\b" + name + r"\s*\(")
    for line in index.get(name, ()):
        match = pattern.search(line)
        if match is not None and isCallSite(line[:match.start()]):
            return True
    return False


def judge(operations, shipping):
    """Compares the measured test-only set against the record.

    - Parameters:
      - operations: the declared operation names.
      - shipping: the shipping worlds' concatenated source.
    - Returns: a list of finding strings, empty when the record holds.
    """
    findings = []
    index = callSiteIndex(shipping)
    testOnly = set()
    for name in operations:
        if not hasShippingCaller(name, index):
            testOnly.add(name)

    for name in sorted(testOnly - set(RECORDED)):
        findings.append(f"{name} is called by nothing in {', '.join(SHIPPING)} and is "
                        "not recorded — every signal reads it as covered, and whether "
                        "the capability ships another way or not at all is exactly "
                        "what the record exists to say")
    for name in sorted(set(RECORDED) - set(operations)):
        findings.append(f"{name} is recorded and no longer declared in {HEADER} — "
                        "delete its entry")
    for name in sorted(set(RECORDED) & (set(operations) - testOnly)):
        findings.append(f"{name} is recorded as test-only and now has a shipping "
                        "caller — delete its entry, the capability is wired")
    return findings


def selfTest():
    """Proves each bound fires, and that the parse is not the zero.

    - Returns: 0 when every arm behaves as stated, 1 otherwise.
    """
    failures = []
    operations = list(RECORDED) + ["wiredOperation"]
    shipping = "void caller() { wiredOperation(1); }"

    if judge(operations, shipping):
        failures.append("the recorded state was flagged against itself")
    if not judge(operations + ["strayOperation"], shipping):
        failures.append("an unrecorded test-only operation was not flagged")
    if not judge([o for o in operations if o != "setPrintSinkPath"], shipping):
        failures.append("a recorded name no longer declared was not flagged")
    if not judge(operations, shipping + " setPrintSinkPath(t, s);"):
        failures.append("a recorded operation that gained a caller was not flagged")
    if judge(operations, shipping + "\nvoid setPrintSinkPath(Terminal* t, const char* s);"):
        failures.append("a declaration line was counted as a caller")

    headerText = Path(HEADER).read_text()
    parsed = declaredOperations(headerText)
    if len(parsed) < 10:
        failures.append(f"only {len(parsed)} operation(s) parsed from {HEADER} — the "
                        "parser has stopped seeing the header, and a clean verdict "
                        "would be its own")

    for failure in failures:
        print("check-test-only-operations --self-test: " + failure, file=sys.stderr)
    if failures:
        return 1
    print(f"check-test-only-operations --self-test: ok (each bound fires, and the "
          f"parser sees {len(parsed)} declared operation(s))")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="prove each bound fires, and that the parse is not the zero")
    arguments = parser.parse_args()

    if arguments.self_test:
        return selfTest()

    operations = declaredOperations(Path(HEADER).read_text())
    if not operations:
        print(f"check-test-only-operations: REFUSED — no operation parsed from "
              f"{HEADER}. A surface that moved and a surface fully wired print the "
              "same verdict, so this is not a pass.", file=sys.stderr)
        return 2

    findings = judge(operations, shippingText(str(REPO)))
    if findings:
        print("check-test-only-operations: the operations surface and the record "
              "disagree:", file=sys.stderr)
        for finding in findings:
            print("    " + finding, file=sys.stderr)
        print("  A test-only operation passes its tests, counts as covered, and "
              "links — and no shipping path reaches it. Record which kind it is, "
              "or wire it.", file=sys.stderr)
        return 1

    byVerdict = {}
    for verdict, _ in RECORDED.values():
        byVerdict[verdict] = byVerdict.get(verdict, 0) + 1
    breakdown = ", ".join(f"{count} {verdict}" for verdict, count in sorted(byVerdict.items()))
    print(f"check-test-only-operations: ok ({len(operations)} operation(s) declared, "
          f"{len(RECORDED)} with no shipping caller, each recorded — {breakdown})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
