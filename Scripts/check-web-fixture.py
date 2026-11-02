#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""One browser fixture under Tests/Web, not one per probe.

The page is the only frontend no C++ test reaches, so every probe of it starts
by standing a browser up in node: a document, a canvas that measures text, a
localStorage, about twenty calls in all. That is cheap to write and expensive to
own once per probe.

Copies drift, which is what copies do. One probe grows a localStorage and a
CustomEvent when page paths reach for them; another keeps the version from
before both and throws a TypeError inside its own fixture on every run, which it
reports as "the page never opened a socket" — also what the defect it watches
for looks like, so the output cannot distinguish a broken fixture from a broken
page.

So the rule is that Tests/Web/stub-dom.mjs is the only file there that builds a
browser. A probe needing something the fixture lacks adds it to the fixture,
where every probe gets it, instead of to its own copy, where the next reader
finds two browsers that disagree.

What this cannot see. It looks for the assignments that stand a browser up, so a
probe that mutates what the fixture installed — reaching into `globalThis.window`
to add a property rather than assigning `globalThis.window` — passes. The line is
between a second fixture, which this catches, and any other way of disagreeing
with the first one, which it does not. It also says nothing about whether the
fixture resembles a browser: one thinner than the real thing satisfies this gate
and still throws the moment a page path reaches past it.
"""

import os
import re
import subprocess
import sys

REPO = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True).stdout.strip() or "."

WEB_TESTS = os.path.join("Tests", "Web")
FIXTURE = os.path.join(WEB_TESTS, "stub-dom.mjs")

# What standing a browser up looks like. Each of these replaces a global the
# page reads at module scope, which is the act this gate is about — a probe
# doing any of them is deciding for itself what a browser is.
FIXTURE_MARKERS = (
    "globalThis.document",
    "globalThis.window",
    "globalThis.localStorage",
    "globalThis.sessionStorage",
    "globalThis.CustomEvent",
    "globalThis.ImageData",
    "globalThis.requestAnimationFrame",
)

# A probe may replace these for itself: they are what it is measuring, not what
# a browser is. WebSocket is the wire the probe watches, location is the query
# string it attaches with, and fetch is how the page loads the wasm it is given.
PROBE_MAY_OWN = ("globalThis.WebSocket", "globalThis.location", "globalThis.fetch")


def probeFiles():
    """Returns the tracked probe files under Tests/Web, fixture excluded.

    - Returns: A list of repository-relative paths, empty if git answers nothing.
    """
    listing = subprocess.run(["git", "-C", REPO, "ls-files", WEB_TESTS],
                             capture_output=True, text=True).stdout
    return [p for p in listing.split()
            if p.endswith(".mjs") and os.path.normpath(p) != os.path.normpath(FIXTURE)]


def findingsFor(path, text):
    """Returns the fixture-building assignments this file makes, as sentences.

    - Parameters:
      - path: Repository-relative path, for the message.
      - text: The file's contents.
    - Returns: A list of failure sentences, empty when the file builds no browser.
    """
    findings = []
    for lineNumber, line in enumerate(text.split("\n"), start=1):
        if line.lstrip().startswith("//"):
            continue
        for marker in FIXTURE_MARKERS:
            if marker in PROBE_MAY_OWN:
                continue
            if re.search(r"%s\s*=" % re.escape(marker), line):
                findings.append(
                    "  %s:%d assigns %s, which is the fixture's to install — add what "
                    "this probe needs to %s, where every probe gets it"
                    % (path, lineNumber, marker, FIXTURE))
    return findings


def selfTest():
    """Checks the rule against a probe that builds a browser and ones that do not.

    - Returns: Zero when every arm answered as it must.
    """
    arms = [
        ("a probe installing its own document is faulted",
         "globalThis.document = { getElementById: () => null };", 1),
        ("a probe installing its own localStorage is faulted",
         "globalThis.localStorage = { store: new Map() };", 1),
        ("a probe importing the fixture is not",
         "import { installStubDom } from './stub-dom.mjs';\ninstallStubDom(dist);", 0),
        ("a probe owning the socket it measures is not",
         "globalThis.WebSocket = class extends RealWebSocket {};", 0),
        ("a probe owning its own query string is not",
         "globalThis.location = window.location;", 0),
        ("a commented-out assignment is not",
         "// globalThis.document = { getElementById: () => null };", 0),
        ("two fixtures in one file are two findings",
         "globalThis.document = {};\nglobalThis.window = {};", 2),
    ]
    failures = 0
    for description, source, expected in arms:
        actual = len(findingsFor("probe.mjs", source))
        if actual != expected:
            failures += 1
        print("  %s %s (reported %d, must be %d)"
              % ("ok " if actual == expected else "FAIL", description, actual, expected))

    # The fixture has to be a file, or the rule points every probe at nothing.
    if os.path.isfile(os.path.join(REPO, FIXTURE)):
        print("  ok  the fixture the rule points at is a file")
    else:
        print("  FAIL %s is not a file, so the rule names nowhere to put anything" % FIXTURE)
        failures += 1

    if failures:
        print("check-web-fixture: %d self-test arm(s) failed" % failures, file=sys.stderr)
        return 1
    print("check-web-fixture: self-test ok (%d arms)" % (len(arms) + 1))
    return 0


def main():
    if "--self-test" in sys.argv:
        return selfTest()

    probes = probeFiles()
    if not probes:
        print("check-web-fixture: no probe was read under %s — the walk found nothing, "
              "which is not the same as every probe sharing the fixture" % WEB_TESTS,
              file=sys.stderr)
        return 1

    failures = []
    for path in probes:
        try:
            with open(os.path.join(REPO, path), encoding="utf-8") as handle:
                failures.extend(findingsFor(path, handle.read()))
        except OSError:
            continue

    if failures:
        print("check-web-fixture: a probe builds a browser of its own", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1

    print("check-web-fixture: ok (%d probe(s), every one through %s)" % (len(probes), FIXTURE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
