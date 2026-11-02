#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""check-wire-tables.py — the editors' wire numbers are the headers'.

The Emacs and Neovim clients read their wire numbers from two checked-in files
that `Scripts/gen-wire-tables.py` writes from the C++ headers
(`Scripts/wire_tables.py` says which numbers and where each is declared). A
checked-in file is only worth reading while it is what the headers produce, so
this gate writes both afresh in memory and fails when either differs from the
file in the tree: a renumbered kind, a moved capability bit or a new `Bye`
reason reaches both clients in the commit that makes it, or the commit is red.

It also holds the two clients to reading those files. A client that defines a
number of its own under one of the generated names has a second copy the
generator does not write, which is the drift the files exist to end; each
client's source is searched for the generated names being defined.

Stdlib only.

    python3 Scripts/check-wire-tables.py
    python3 Scripts/check-wire-tables.py --self-test
"""

import difflib
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_report  # noqa: E402 — the path above is what makes it importable
import wire_tables  # noqa: E402

EMACS_CLIENT = os.path.join("Source", "Platform", "Emacs", "ubiquitty-sync.el")
NEOVIM_CLIENT = os.path.join("Source", "Platform", "Neovim", "lua", "ubiquitty_sync", "init.lua")

# What each client says to read its generated file.
EMACS_READS = re.compile(r"\(require\s+'ubiquitty-sync-wire\b")
NEOVIM_READS = re.compile(r"require\(\s*\"ubiquitty_sync\.wire\"\s*\)")


def staleFailures(texts, checkedIn):
    """Where a checked-in output is not what the headers produce.

    - Parameters:
      - texts: {path: text} for the headers, as `wire_tables.sources` reads them.
      - checkedIn: {output path: text} for the files in the tree.
    - Returns: offender strings, empty when both files are current.
    """
    out = []
    for path, writer in wire_tables.OUTPUTS:
        try:
            wanted = writer(texts)
        except wire_tables.Unreadable as unread:
            out.append("%s cannot be written: %s did not read" % (path, unread))
            continue
        held = checkedIn.get(path, "")
        if held == wanted:
            continue
        if not held:
            out.append("%s is missing — run %s" % (path, wire_tables.GENERATOR))
            continue
        changed = [line for line in difflib.unified_diff(held.splitlines(), wanted.splitlines(), "checked in", "generated",
                                                         lineterm="", n=0)
                   if line[:1] in "+-" and line[:3] not in ("+++", "---")]
        out.append("%s is not what the headers produce — run %s (%d line(s) differ, the first: %s)"
                   % (path, wire_tables.GENERATOR, len(changed), changed[0] if changed else "whitespace"))
    return out


def emacsNames(texts):
    """Every name the Emacs output defines."""
    return set(re.findall(r"\(defconst\s+(ubiquitty-sync--[\w-]+)", wire_tables.emacsText(texts)))


def luaNames(texts):
    """Every table and number the Lua output defines, by its key under `M`."""
    return set(re.findall(r"^M\.(\w+)\s*=", wire_tables.luaText(texts), re.M))


def handWrittenFailures(texts, emacsClient, neovimClient):
    """Where a client keeps a number of its own under a generated name.

    - Parameters:
      - texts: {path: text} for the headers.
      - emacsClient: the Emacs client's source.
      - neovimClient: the Neovim client's source.
    - Returns: offender strings, empty when both clients read the outputs.
    """
    out = []
    try:
        lisp = emacsNames(texts)
        lua = luaNames(texts)
    except wire_tables.Unreadable as unread:
        return ["the generated names cannot be listed: %s did not read" % unread]
    if not EMACS_READS.search(emacsClient):
        out.append("%s does not require ubiquitty-sync-wire, the file its wire numbers are written to" % EMACS_CLIENT)
    for name in sorted(set(re.findall(r"\(def(?:const|var|custom)\s+(ubiquitty-sync--[\w-]+)", emacsClient)) & lisp):
        out.append("%s defines %s, which %s writes — delete the copy" % (EMACS_CLIENT, name, wire_tables.EMACS_OUTPUT))
    if not NEOVIM_READS.search(neovimClient):
        out.append("%s does not require ubiquitty_sync.wire, the file its wire numbers are written to" % NEOVIM_CLIENT)
    # A table or number written out in the client, not read from the module:
    # `local kind = {` or `local wire_version = 20`. `local kind = wire.kind`
    # is the reading this gate wants and is not matched.
    for name, value in re.findall(r"^local\s+(\w+)\s*=\s*([^\n]*)", neovimClient, re.M):
        if name in lua and not re.match(r"wire\.\w+\s*(?:--.*)?$", value.strip()):
            out.append("%s writes out `%s` itself, which %s holds — read it from the module"
                       % (NEOVIM_CLIENT, name, wire_tables.NEOVIM_OUTPUT))
    return out


def failures():
    """Every offender in the tree as it stands."""
    texts = wire_tables.sources()
    checkedIn = {path: wire_tables.read(path) for path, _writer in wire_tables.OUTPUTS}
    return staleFailures(texts, checkedIn) + handWrittenFailures(texts, wire_tables.read(EMACS_CLIENT), wire_tables.read(NEOVIM_CLIENT))


def selfTest():
    problems = []
    texts = wire_tables.sources()
    checkedIn = {path: wire_tables.read(path) for path, _writer in wire_tables.OUTPUTS}
    standing = failures()
    if standing:
        problems.append("the tree's own outputs fail: %s" % "; ".join(standing))

    # A change to any header a table is read from has to make the file of the
    # client that reads the table stale. Each case edits one header's text and
    # names the outputs that have to be reported.
    both = (wire_tables.EMACS_OUTPUT, wire_tables.NEOVIM_OUTPUT)
    cases = [
        ("the wire version bumped", wire_tables.ENVELOPE_HEADER, "wireVersion = %d;" % wire_tables.tables(texts)["scalars"]["wire_version"],
         "wireVersion = 999;", both),
        ("a frame kind renumbered", wire_tables.ENVELOPE_HEADER, "Raw = 69", "Raw = 99", both),
        ("a frame kind added", wire_tables.ENVELOPE_HEADER, "Viewport = 73,", "Viewport = 73, Later = 74,", both),
        ("a kind's direction changed", wire_tables.ENVELOPE_SOURCE,
         "    case FrameKind::Call:\n        return Direction::ClientToHost;", "        return Direction::ClientToHost;", both),
        ("a capability bit moved", wire_tables.MESSAGES_HEADER, "EchoContext = 1u << 3", "EchoContext = 1u << 4", both),
        ("a Bye reason inserted", wire_tables.MESSAGES_HEADER, "    Malformed,", "    Refused,\n    Malformed,", both),
        ("a virtual key renumbered", wire_tables.KEYS_HEADER, "UpArrow = 10", "UpArrow = 30", both),
        ("a modifier bit moved", wire_tables.KEYMAP_HEADER, "keymapModifierCtrl = 4", "keymapModifierCtrl = 8", both),
        ("a terminal's interrupt character changed", wire_tables.SCREEN_HEADER, ".interrupt = 0x03", ".interrupt = 0x04", both),
        ("an admission target renumbered", wire_tables.ADMISSION_HEADER, "Management = 3", "Management = 4", both),
        ("an app version bound changed", wire_tables.ADMISSION_HEADER, "maxAppVersionBytes = 32", "maxAppVersionBytes = 33", both),
        ("a kind's scope changed", wire_tables.ENVELOPE_SOURCE,
         "bool isConnectionKind(FrameKind kind)\n{\n    switch (kind) {\n    case FrameKind::Greet:",
         "bool isConnectionKind(FrameKind kind)\n{\n    switch (kind) {", both),
        ("an attribute bit moved", wire_tables.ATTRIBUTE_HEADER, "Italic = 0x0004", "Italic = 0x0010", both),
        ("a pen grown", wire_tables.ROW_HEADER, "penWireBytes = 20;", "penWireBytes = 22;", both),
    ]
    for title, path, before, after, outputs in cases:
        if texts[path].count(before) != 1:
            problems.append("case %r: %s does not carry %r exactly once" % (title, path, before))
            continue
        edited = dict(texts)
        edited[path] = texts[path].replace(before, after)
        reported = staleFailures(edited, checkedIn)
        for output in outputs:
            if not any(line.startswith(output) for line in reported):
                problems.append("case %r left %s current" % (title, output))

    # A declaration the reader cannot read stops the write; it never writes a
    # table with the unread part missing.
    unread = dict(texts)
    unread[wire_tables.MESSAGES_HEADER] = texts[wire_tables.MESSAGES_HEADER].replace("enum class ByeReason", "enum class ByeCause")
    if not any("did not read" in line for line in staleFailures(unread, checkedIn)):
        problems.append("an enumeration gone from its header was not reported as unread")

    # A hand edit of a checked-in file, and a file that is not there.
    for path in both:
        edited = dict(checkedIn)
        edited[path] = checkedIn[path].replace("69", "70", 1)
        if edited[path] == checkedIn[path] or not any(line.startswith(path) for line in staleFailures(texts, edited)):
            problems.append("a hand edit of %s was not reported" % path)
        if not any("missing" in line for line in staleFailures(texts, dict(checkedIn, **{path: ""}))):
            problems.append("a missing %s was not reported" % path)

    # A client that keeps a copy of a generated number, and one that does not
    # read its file at all.
    emacs = wire_tables.read(EMACS_CLIENT)
    neovim = wire_tables.read(NEOVIM_CLIENT)
    copies = [
        ("an Emacs copy of a kind", emacs + '\n(defconst ubiquitty-sync--kind-raw 69 "A copy.")\n', neovim, EMACS_CLIENT),
        ("an Emacs client that does not require its file", EMACS_READS.sub("(ignore", emacs), neovim, EMACS_CLIENT),
        ("a Lua copy of the kinds", emacs, neovim + "\nlocal kind = { raw = 69 }\n", NEOVIM_CLIENT),
        ("a Lua copy of the version", emacs, neovim + "\nlocal wire_version = 20\n", NEOVIM_CLIENT),
        ("a Lua client that does not require its file", emacs, NEOVIM_READS.sub("{}", neovim), NEOVIM_CLIENT),
    ]
    for title, lisp, lua, client in copies:
        if not any(line.startswith(client) for line in handWrittenFailures(texts, lisp, lua)):
            problems.append("%s was not reported" % title)
    if handWrittenFailures(texts, emacs + "\n(defconst ubiquitty-sync--raw-piece-bytes 4096 \"The client's own.\")\n",
                           neovim + "\nlocal kind = wire.kind\nlocal raw_piece_bytes = 4096\n"):
        problems.append("a client's own constant, or a table read from the module, was reported as a copy")

    # The reader's forms: a digit separator, a typed literal shifted, a
    # product, an alias, an unscoped enumeration, and what it will not guess.
    constants = wire_tables.headerConstants([
        "inline constexpr std::size_t separated = 65'535;\n"
        "inline constexpr std::size_t shifted = std::size_t { 8 } << 10;\n"
        "constexpr std::size_t multiplied = 72u * 1024u * 1024u;\n"
        "constexpr std::size_t aliased = Other::multiplied;\n"
        "constexpr std::size_t called = someCall(3);\n"
        "constexpr std::size_t summed = separated + 1;\n"
        "// constexpr int commented = 4;\n"
    ])
    wanted = {"separated": 65535, "shifted": 8192, "multiplied": 72 * 1024 * 1024, "aliased": 72 * 1024 * 1024, "summed": 65536}
    if constants != wanted:
        problems.append("the constant reader read %s, wanted %s" % (constants, wanted))
    if wire_tables.evaluate("1 + identity + 2 * 2", {"identity": 40}) != 45:
        problems.append("sum/product constants lose sample header fields")
    for invalid in ("1 +", "identity()", "1 / 2", "unknown + 1"):
        if wire_tables.evaluate(invalid, {"identity": 40}) is not None:
            problems.append("unsupported constant expression was accepted: " + invalid)
    if wire_tables.cppEnum("enum Plain : int { first = 0, second, count = 5, };", "Plain") != [("first", 0), ("second", 1), ("count", 5)]:
        problems.append("an unscoped enumeration did not read")
    if wire_tables.cppEnum("enum class Bits : std::uint32_t { A = 1u << 0, B = 1u << 3, C = 0x10 };", "Bits") != [("A", 1), ("B", 8), ("C", 16)]:
        problems.append("an enumeration of shifts and hex did not read")
    if wire_tables.cppEnum("enum class Odd { A = sizeof(int) };", "Odd"):
        problems.append("an enumeration with an initialiser the reader cannot evaluate was given values")
    names = [("PaneBind", "pane_bind"), ("colorRGB", "color_rgb"), ("QUICTokenGrant", "quic_token_grant"), ("F10", "f10"), ("Keypad0", "keypad0")]
    for member, wantedName in names:
        if wire_tables.snake(member) != wantedName:
            problems.append("%s is written %s, wanted %s" % (member, wire_tables.snake(member), wantedName))
    if 'M.virtual_key = {\n    none = 0,\n    ["return"] = 1,' not in wire_tables.luaText(texts):
        problems.append("a Lua key that is one of Lua's own words is not quoted")

    for problem in problems:
        print("self-test: %s" % problem, file=sys.stderr)
    print("check-wire-tables: self-test %s" % ("FAILED" if problems else "ok"))
    return 1 if problems else 0


def main():
    if "--self-test" in sys.argv[1:]:
        return selfTest()
    offenders = failures()
    if offenders:
        status = gate_report.failed("check-wire-tables", "generated wire table(s) out of step with the headers or the clients", offenders)
        print("\n  The editors' wire numbers are written from the C++ headers. After changing a\n"
              "  header, run python3 %s and commit what it writes;\n"
              "  a client never types one of these numbers itself." % wire_tables.GENERATOR, file=sys.stderr)
        return status
    texts = wire_tables.sources()
    print("check-wire-tables: ok (%d names for Emacs and %d tables and numbers for Neovim are what the headers produce, "
          "and neither client keeps a copy)" % (len(emacsNames(texts)), len(luaNames(texts))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
