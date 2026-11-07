#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""check-editor-wire-tables.py — what an editor still writes by hand tracks the wire's headers.

The Emacs and Neovim clients read the files `Scripts/gen-wire-tables.py` writes
from the headers, which `Scripts/check-wire-tables.py` holds current, so neither
types a version, a kind or a capability bit of its own. Each editor still keeps a
few tables no header declares, written in the generated names: the kinds a host
sends that the client reads past, and the Emacs client's choice of which key each
Emacs event is sent as. Those are held here to the enumerations they name: an
unsolicited kind is one a host sends, and a forwarded key is a
`Keys::VirtualKey`. The Emacs terminal specification names the generated table
and its generator as the authority for the wire's numbers, and keeps naming them.

Stdlib only.

    python3 Scripts/check-editor-wire-tables.py
    python3 Scripts/check-editor-wire-tables.py --self-test
"""

import importlib
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import library_scripts  # noqa: F401, E402 — makes the libraries' modules importable
import gate_report  # noqa: E402
import ubq_roots  # noqa: E402
import wire_tables  # noqa: E402
from wire_tables import camel, clientToHostKinds, cppEnum  # noqa: E402

versionPins = importlib.import_module("check-wire-version-pins")

REPO = ubq_roots.subject_root()

DOC_REFERENCES = {
    os.path.join("Docs", "emacs-terminal-spec.md"): (
        "`Source/Platform/Emacs/ubiquitty-sync-wire.el`",
        "`Scripts/gen-wire-tables.py`",
    ),
}


def read(path):
    try:
        # The headers are Core's and the clients this checkout's.
        with open(library_scripts.locate(path), encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


EMACS_CLIENT = os.path.join("Source", "Platform", "Emacs", "ubiquitty-sync.el")
NEOVIM_CLIENT = os.path.join("Source", "Platform", "Neovim", "lua", "ubiquitty_sync", "init.lua")


def elispForm(text, name):
    """The text of `(defconst NAME ...` up to its docstring, or None."""
    found = re.search(r"\(defconst\s+%s\s+(.*?)\n\s+\"" % re.escape(name), text, re.S)
    return found.group(1) if found else None


def handKeptFailures(sources):
    """The tables an editor keeps in generated names, against what they name.

    - Parameter sources: {path: text} for the headers and the two clients.
    - Returns: offender strings, empty when every name is one the headers hold.
    """
    out = []
    kinds = dict(cppEnum(sources[wire_tables.ENVELOPE_HEADER], "FrameKind"))
    clientOnly = clientToHostKinds(sources[wire_tables.ENVELOPE_SOURCE])
    virtualKeys = dict(cppEnum(sources[wire_tables.KEYS_HEADER], "VirtualKey"))
    for label, table in (("FrameKind", kinds), ("directionOf's client-to-host kinds", clientOnly), ("VirtualKey", virtualKeys)):
        if not table:
            out.append("%s could not be read from its header, so every table naming it was "
                       "compared against nothing" % label)
    if out:
        return out

    def unsolicited(where, what, names):
        if names is None:
            out.append("%s no longer has %s" % (where, what))
            return
        if not names:
            out.append("%s %s names no kind this gate can read" % (where, what))
        for name in sorted(names):
            if camel(name) not in kinds:
                out.append("%s %s holds %s, which names no FrameKind" % (where, what, name))
            elif camel(name) in clientOnly:
                out.append("%s %s holds %s, which is not a kind a host sends" % (where, what, name))

    lua = sources[NEOVIM_CLIENT]
    found = re.search(r"\blocal\s+unsolicited_kind\s*=\s*\{([^{}]*)\}", lua)
    unsolicited(NEOVIM_CLIENT, "the `unsolicited_kind` set", set(re.findall(r"\[kind\.(\w+)\]\s*=\s*true", found.group(1))) if found else None)

    elisp = sources[EMACS_CLIENT]
    form = elispForm(elisp, "ubiquitty-sync--unsolicited-kinds")
    unsolicited(EMACS_CLIENT, "`ubiquitty-sync--unsolicited-kinds`",
                set(re.findall(r"ubiquitty-sync--kind-([\w-]+)", form)) if form is not None else None)
    form = elispForm(elisp, "ubiquitty-sync--virtual-keys")
    sent = re.findall(r"\(([\w-]+)\s+\.\s+([\w-]+)\)", form or "")
    if not sent:
        out.append("%s no longer has the `ubiquitty-sync--virtual-keys` table" % EMACS_CLIENT)
    for event, key in sent:
        if camel(key) not in virtualKeys:
            out.append("%s sends %s as %s, which names no VirtualKey" % (EMACS_CLIENT, event, key))
    return out


def handKeptSources():
    """The headers and clients `handKeptFailures` reads, as {path: text}."""
    return {path: read(path) for path in (wire_tables.ENVELOPE_HEADER, wire_tables.ENVELOPE_SOURCE, wire_tables.KEYS_HEADER,
                                           EMACS_CLIENT, NEOVIM_CLIENT)}


def handKeptSelfTest():
    """Whether a name an editor writes that the headers do not hold is reported.

    Each case edits one file's text and names who has to be reported. The
    tree as it stands has to pass first: a gate that is red before the edit
    says nothing about the edit.

    - Returns: the failures, as strings.
    """
    problems = []
    sources = handKeptSources()
    standing = handKeptFailures(sources)
    if standing:
        return ["the tree's own tables fail: %s" % "; ".join(standing)]
    cases = [
        ("a kind an editor reads past becomes one a client sends", wire_tables.ENVELOPE_SOURCE,
         "    case FrameKind::Call:\n        return Direction::ClientToHost;",
         "    case FrameKind::Call:\n    case FrameKind::PaneDirty:\n        return Direction::ClientToHost;", ("Emacs", "Neovim")),
        ("a kind an editor reads past is renamed", wire_tables.ENVELOPE_HEADER, "PaneListed = 17", "PaneNamed = 17", ("Emacs", "Neovim")),
        ("a key Emacs forwards is renamed", wire_tables.KEYS_HEADER, "ForwardDelete = 5", "DeleteForward = 5", ("Emacs",)),
        ("an Emacs key sent as no key", EMACS_CLIENT, "(deletechar . forward-delete)", "(deletechar . delete-forward)", ("Emacs",)),
        ("a Lua unsolicited kind that is a client's", NEOVIM_CLIENT, "[kind.pane_listed] = true,", "[kind.viewport] = true,", ("Neovim",)),
    ]
    for title, path, before, after, clients in cases:
        if sources[path].count(before) != 1:
            problems.append("hand-kept case %r: %s does not carry %r exactly once" % (title, path, before))
            continue
        edited = dict(sources)
        edited[path] = sources[path].replace(before, after)
        reported = handKeptFailures(edited)
        for client in clients:
            if not any("/" + client + "/" in line.replace(os.sep, "/") for line in reported):
                problems.append("hand-kept case %r was not reported for the %s client" % (title, client))
    return problems


def selfTest():
    problems = handKeptSelfTest()
    documents = {path: read(path) for path in DOC_REFERENCES}
    if versionPins.docReferences(documents, DOC_REFERENCES):
        problems.append("the tree's own authoritative references fail")
    for path, references in DOC_REFERENCES.items():
        for reference in references:
            edited = dict(documents, **{path: documents[path].replace(reference, "missing-reference")})
            if not versionPins.docReferences(edited, DOC_REFERENCES):
                problems.append("removing %s from %s passed" % (reference, path))
    for problem in problems:
        print("self-test: %s" % problem, file=sys.stderr)
    print("check-editor-wire-tables: self-test %s" % ("FAILED" if problems else "ok"))
    return 1 if problems else 0


def main():
    if "--self-test" in sys.argv[1:]:
        return selfTest()
    offenders = handKeptFailures(handKeptSources())
    offenders += versionPins.docReferences({path: read(path) for path in DOC_REFERENCES}, DOC_REFERENCES)
    if offenders:
        status = gate_report.failed("check-editor-wire-tables",
                                    "editor table(s) naming what the wire's headers do not hold", offenders)
        print("\n  The editors' hand-kept tables are written in the generated names; each must\n"
              "  name a kind a host sends or a key the headers hold.", file=sys.stderr)
        return status
    print("check-editor-wire-tables: ok (the editors' own tables name what the headers hold, and the "
          "Emacs specification names its authorities)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
