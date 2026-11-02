#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-web-host-bytes — the PAGE never hands socket bytes to the parser.

The Web frontend stamps `CapabilityOrigin::Local` on everything its parser sees,
and that is correct only while the parser sees nothing but the page's own bytes.
Break it and host content reaches the gate wearing the user's principal: every
host-escaping capability granted to whoever is on the other end of that socket,
with the policy installed and the gate answering Allow because the origin it was
handed says the user asked.

Two things have to hold, and they are checked in two places because they are two
questions in two languages.

`Scripts/check-web-parser-entries.py` owns the C++ half: it counts every
`processBytes` caller under Source/Platform/Web and requires each to be recorded
with why its bytes are local, failing both when a new caller appears and when a
recorded one no longer exists. That subsumes a "feedFromHost must not parse"
rule, so this file does not carry one — one question, one gate.

What a caller count cannot see is the page. JavaScript could route socket bytes
into an export that is already recorded — `feed` is recorded and local by
construction, and `socket.onmessage` calling it would add no new C++ caller.
The count stays green and the invariant is gone. So this checks the page: the socket
handler feeds `feedFromHost` and never the parser export.

Stdlib only.

    python3 Scripts/check-web-host-bytes.py
    python3 Scripts/check-web-host-bytes.py --self-test
"""

import os
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import gate_report

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
PAGE_SOURCE = os.path.join("Source", "Platform", "Web", "terminal.js")

# The page's socket handler, and the parser export it must not reach.
SOCKET_HANDLER = re.compile(r"\bsocket\.onmessage\s*=")
PARSER_EXPORT_CALL = re.compile(r"\bfeedBytes\s*\(")


def strippedLine(line):
    """The code portion, dropping a `//` line comment.

    The page names the forbidden call in prose — this rule is described in a
    comment beside the handler — and matching that would report the invariant
    broken by its own explanation.
    """
    return line.split("//", 1)[0]


def bodyAfter(lines, startIndex):
    """The lines of the brace-delimited body opening at or after `startIndex`.

    Counts braces from the first `{` on or after the start, so it follows the
    body wherever it ends rather than guessing a length. Returns an empty list
    when no body opens, which the caller reports rather than passing.
    """
    depth = 0
    started = False
    body = []
    for line in lines[startIndex:]:
        code = strippedLine(line)
        if started:
            body.append(code)
        for character in code:
            if character == "{":
                depth += 1
                if not started:
                    started = True
                    body.append(code)
            elif character == "}":
                depth -= 1
                if started and depth == 0:
                    return body
    return body if started else []


def parserCallsIn(body, pattern):
    """Line offsets within `body` that call `pattern`."""
    return [index for index, line in enumerate(body) if pattern.search(line)]


def findBody(lines, opener):
    """The body of the first construct matching `opener`, and its line number."""
    for index, line in enumerate(lines):
        if opener.search(strippedLine(line)):
            return bodyAfter(lines, index), index + 1
    return [], 0


def selfTest():
    """Both arms of each rule, on sources this file carries rather than reads."""
    handlerClean = [
        "    socket.onmessage = (event) => {",
        "      const ok = feedFromHost(buffer, bytes.length);",
        "    };",
    ]
    handlerParsing = [
        "    socket.onmessage = (event) => {",
        "      feedBytes(buffer, bytes.length);",
        "    };",
    ]
    # A comment naming the call is documentation, not a route into the parser.
    handlerCommented = [
        "    socket.onmessage = (event) => {",
        "      // never feedBytes( here — host bytes go to the mirror",
        "      const ok = feedFromHost(buffer, bytes.length);",
        "    };",
    ]

    checks = [
        ("a socket handler that only mirrors passes",
            not parserCallsIn(findBody(handlerClean, SOCKET_HANDLER)[0], PARSER_EXPORT_CALL)),
        ("a socket handler that feeds the parser is caught",
            parserCallsIn(findBody(handlerParsing, SOCKET_HANDLER)[0], PARSER_EXPORT_CALL) != []),
        ("the call named in a comment is not a route",
            not parserCallsIn(findBody(handlerCommented, SOCKET_HANDLER)[0], PARSER_EXPORT_CALL)),
        ("a body that never opens is reported empty, not passed",
            findBody(["const unrelated = 1;"], SOCKET_HANDLER)[0] == []),
    ]
    ok = True
    for label, passed in checks:
        print("  %s %s" % ("ok " if passed else "FAIL", label))
        ok = ok and passed
    print("check-web-host-bytes: self-test %s" % ("ok" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    if "--self-test" in sys.argv:
        return selfTest()

    failures = []
    for relative, opener, forbidden, what in (
        (PAGE_SOURCE, SOCKET_HANDLER, PARSER_EXPORT_CALL, "the socket handler reaches the parser"),
    ):
        path = os.path.join(REPO, relative)
        try:
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
        except FileNotFoundError:
            print("check-web-host-bytes: FAILED — %s is missing, so nothing was checked" % relative,
                  file=sys.stderr)
            return 2
        body, declaredAt = findBody(lines, opener)
        if not body:
            # An empty body is the shape where this checks nothing and says ok:
            # the construct was renamed or reshaped and the scan found no
            # subject, which is a failure rather than a pass.
            print("check-web-host-bytes: FAILED — no body found for the guarded construct in %s;"
                  " it was renamed or reshaped and this checked nothing" % relative, file=sys.stderr)
            return 2
        for offset in parserCallsIn(body, forbidden):
            failures.append("%s:%d (%s)" % (relative, declaredAt + offset, what))

    if failures:
        status = gate_report.failed("check-web-host-bytes",
            "site(s) route host bytes into the page's parser", failures)
        for site in failures:
            print("    %s" % site, file=sys.stderr)
        print("  The Web frontend stamps CapabilityOrigin::Local on everything its"
              " parser sees. That is true only while the parser sees the page's own"
              " bytes; route host bytes there and every host-escaping capability is"
              " granted to whoever is on the other end of the socket.", file=sys.stderr)
        return status

    print("check-web-host-bytes: ok (the page's socket handler feeds the mirror, not the"
          " parser; check-web-parser-entries owns the C++ side)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
