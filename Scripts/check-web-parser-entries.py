#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""check-web-parser-entries.py — the web page's parser is fed locally, never by the host.

The web frontend is the one that both parses bytes itself and attaches to a host
over the sync protocol. Those two facts are safe together only while they stay
apart: `feedFromHost` decodes frames into `SyncClientCore`, which applies
snapshots and row deltas and never calls `processBytes`, so host-driven content
reaches no capability gate site. Everything the parser does see is the page's own
— a keystroke it encoded, or a string it supplied.

That is what makes `CapabilityOrigin::Local` true there rather than merely
default. Route host bytes through the parser — a passthrough mode, a replay, a
debug hook — and Local becomes a claim: the daemon knows the driving principal,
the wire does not carry it, and every gate site would then answer for a
principal nobody established. The fix at that point is a protocol field, which
is a much larger change than the line that caused it.

So the invariant is a count, which is the cheapest form it can take: `processBytes`
has exactly the callers recorded below, each one local by construction. A new
caller fails, naming itself, and whoever added it decides whether it is local
before the gate goes green again.

Half the rule, and the docstring says so because a count reads like the whole of
it. `Scripts/check-web-host-bytes.py` owns the other half: JavaScript can route
socket bytes into an export already recorded here — `socket.onmessage` calling
`feed` adds no C++ caller at all — and this file stays green while the invariant
it describes is gone. Two questions in two languages, checked in two places.

Not a tree-wide rule either. Frontends that drive Core through `Runtime::TerminalRuntime`
feed the parser from inside Core rather than from their own code, and macOS names
`processBytes` at dozens of sites; a count means nothing there. Web is scoped
here because Web is where parsing locally and attaching remotely meet.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WEB = REPO / "Source" / "Platform" / "Web"

# Each recorded entry is a parser feed and why its bytes are local. A site absent
# from this list fails; an entry no call reaches fails too, so the record cannot
# outlive the code.
RECORDED = {
    "feed":
        "the page's own bytes — the splash strings it supplies, and a paste or "
        "sendText the page echoes when no socket is attached",
    "feedKey":
        "a keystroke this terminal encoded three lines earlier, so the bytes are "
        "the user's by construction",
}

CALL = re.compile(r"\bUbiquitty::processBytes\s*\(")
# The enclosing definition, as the file writes them: `bool WebTerminal::feed(...)`.
DEFINITION = re.compile(r"^\w[\w:<>,\s\*&]*\bWebTerminal::(\w+)\s*\(")


def main():
    source = WEB / "WebTerminal.cpp"
    if not source.is_file():
        print("check-web-parser-entries: FAILED — %s is absent, so nothing was checked"
              % source.relative_to(REPO), file=sys.stderr)
        return 1

    lines = source.read_text(errors="replace").split("\n")
    observed = {}
    enclosing = "<file scope>"
    for number, line in enumerate(lines, 1):
        match = DEFINITION.match(line)
        if match:
            enclosing = match.group(1)
        if CALL.search(line.split("//")[0]):
            observed.setdefault(enclosing, []).append(number)

    unrecorded = sorted(set(observed) - set(RECORDED))
    vanished = sorted(set(RECORDED) - set(observed))

    if unrecorded:
        first = unrecorded[0]
        print("check-web-parser-entries: FAILED — %d parser entr(ies) not recorded, first %s (WebTerminal.cpp:%d)"
              % (len(unrecorded), first, observed[first][0]), file=sys.stderr)
        for name in unrecorded:
            print("    %s feeds processBytes at line(s) %s"
                  % (name, ", ".join(str(n) for n in observed[name])), file=sys.stderr)
        print("\n  Every byte the page's parser sees must be the page's own. If these are,\n"
              "  record them here with why. If they are the host's, Local stops being true\n"
              "  and the origin has to come from the daemon over the wire.", file=sys.stderr)
        return 1

    if vanished:
        print("check-web-parser-entries: FAILED — %d recorded entr(ies) no call reaches, first %s"
              % (len(vanished), vanished[0]), file=sys.stderr)
        for name in vanished:
            print("    %s — delete the entry, or restore the call" % name, file=sys.stderr)
        return 1

    print("check-web-parser-entries: ok (%d parser entr(ies), each recorded local: %s)"
          % (len(observed), ", ".join(sorted(observed))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
