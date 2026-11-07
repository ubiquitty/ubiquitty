#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""check-frontend-capability-policy — a frontend that wires a client, or builds a session that does, installs a policy.

With `Terminal::capabilityPolicy == nullptr`, Core's capability checks answer
from PAL's defaultDecision, as EffectGate.h says of effectAllowed. That is a
fallback for a terminal nobody configured, not a frontend's answer. A frontend
policy states the answer in the frontend's own module, where a change to it
reads as a decision about that frontend, and the file-read paths
(`effectGranted`) refuse every origin without one. The GUI frontends answer
`defaultDecisionWithoutConsent` (PAL/Capability.h); this gate holds a frontend
to having decided, not to what it decided.

A missing policy decides nothing for a frontend that wires no host-escaping
client, and it decides every effect the moment one is wired: a frontend whose
only client is the clipboard is fine without one, and adding a ShellClient
makes desktop notifications reachable from any origin with no gate going red.

So the pairing is the rule: a module whose code assigns any client member
declared on Terminal must also assign `capabilityPolicy` somewhere in that same
module. Module-scoped rather than per-file because a frontend legitimately seeds
the policy at startup and wires clients per pane, in different files.

A module that builds a session wires clients too, without assigning one. Core's
TerminalSession wires its own terminal's queues, measurer and clipboard writer
for whoever holds it, and a workspace model runs its frontend's installer on
every session it makes, so a frontend built on sessions alone assigns nothing
the scan above can see, while Source/Core, where the wiring is, is not a module
here. So constructing a
session counts as wiring a client, attributed to the module that constructs it
(SESSION_CONSTRUCTORS below), and the kits that construct sessions for the shell
hosting them are not asked: their host is.

"Module", not "frontend directory". Source/Agent/AgentSession.cpp owns a
Terminal and wires mirrorClient outside Source/Platform, and a walk of
Source/Platform alone would not see whether it installs a policy. A gate whose
scope excludes a real case reports ok about the tree it did not read.

The member names are read out of Terminal.h at run time rather than listed here.
A list in this file is exactly what fails: the next client is added under a name
the list does not have, and a gate reading a stale list reports ok about the one
case it was written for. Matching the `…Client` suffix instead is the other
failure — it catches `*outClient = std::move(client)` in the POSIX socket accept,
a file descriptor with no Terminal anywhere near it, and a gate that cries about
unrelated code gets an exemption bolted on and then believed. Reading the
declarations gives both: a new client is picked up the day it is declared, and
nothing that merely ends in Client is.

Every verdict here therefore rests on that parse, so finding no members exits 2
rather than passing — otherwise a header refactor leaves this checking nothing
while still printing ok.

What this does not check matters as much as what it does. It asks whether a
policy is installed, not whether the origins reaching it are stamped. Those are
different questions, and a pass on the first says nothing about the second:
`currentCapabilityOrigin` defaults to Local (its initializer in `Terminal`,
Core/Terminal.h), so a module
that installs a Local-allows policy and stamps nothing else allows everything.

Whether that is a defect depends on the module, and the difference is worth
keeping straight rather than reading a green here as either verdict:

  - Platform/Host computes an origin per driver and stamps it
    (`Daemon::stampInputOrigin`, and `Daemon::servicePTY` for output). Gate and
    stamp both present, which is the whole shape.
  - Platform/Linux stamps only inside its own smokes (`smokeFileRead` and
    `smokeCapabilityOrigin` in main.cpp), and Local is nonetheless the truth:
    the frontend's only launch path is a local PTY (`launchShell`), with no
    attach and no agent surface, so there is
    no other principal to stamp. Its policy is correct and decides nothing
    today; adding an attach path is what would give it something to refuse.
  - Platform/Web installs a policy and stamps only Local, and here Local is a
    claim rather than a fact. The page parses bytes that arrive from a host
    over the sync protocol, and NativeAttachment.h carries no origin field — so
    whatever the daemon decided about the principal driving those bytes
    (`Daemon::stampInputOrigin`) does not travel with them, and the page stamps
    Local either way. The header comment of WebCapabilityPolicy.h says as much
    itself.
  - Platform/iOS installs a policy on every pane and stamps nothing, so every
    pane is Local. What a host delivers to the device is judged by the Sync
    client against its own Remote verdicts, not by this policy.

So a module can pass here and be ungated, and the way to tell which is to ask
where its sequences come from — not to read the pass.

Stdlib only.

    python3 Scripts/check-frontend-capability-policy.py
    python3 Scripts/check-frontend-capability-policy.py --self-test
"""

import collections
import os
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import library_scripts  # noqa: F401 — makes the libraries' modules importable
import gate_report  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
SOURCE = "Source"

# Each Source/Platform/<name> is its own module; every other Source/<name> is one
# module whole. A module is the unit that owns a Terminal and is therefore the
# unit that must pair a wiring with a policy.
PLATFORM = "Platform"

# Source/Core is not a module for this purpose. Core/VT/Init.cpp assigns every
# one of these members, but it is the RIS save/restore round trip: it puts back
# what the frontend had, including a null policy. Counting it would credit the
# tree with an install that installs nothing, and Core is not where the decision
# lives in any case. A module that holds no Terminal — the PAL backends under
# POSIX and Wasm — needs no entry here: it wires nothing, so it never fails.
NOT_A_MODULE = {"Core"}

# The modules open today, recorded rather than silently skipped.
#
# Each entry is checked in two directions, not one: an unlisted module that goes
# open fails, and a listed module that has been closed fails too, naming this line.
# That second half is the point. An exemption that only suppresses is one nobody
# revisits — it outlives the condition it was written for and then reads as a
# decision. These cannot: closing one turns the gate red until its entry is
# deleted, so the cleanup is not optional and not remembered, it is reported.
KNOWN_OPEN: dict[str, str] = {
    # Empty on purpose. Source/Agent was the one entry; it installs a policy now
    # (AgentCapabilityPolicy), and this gate reported the entry stale the moment
    # it did — which is the property that keeps the list from becoming an
    # allowlist. A module recorded here must name the condition that retires it.
}

SOURCE_SUFFIXES = (".cpp", ".mm", ".m", ".h", ".swift")

TERMINAL_HEADER = os.path.join("Source", "Core", "Terminal.h")

# `Ubiquitty::CheckedPtr<Ubiquitty::ShellClient> shellClient {};` and
# `Ubiquitty::GatedClient<Ubiquitty::WindowClient> windowClient {};` — the
# declaration of a client member, from which only the member name is taken.
DECLARED_CLIENT = re.compile(
    r"^\s*Ubiquitty::(?:CheckedPtr|GatedClient)<[^>]+>\s+([A-Za-z_]\w*Client)\s*\{",
    re.MULTILINE)

ASSIGNS_POLICY = re.compile(r"\bcapabilityPolicy\s*=(?!=)")

# A declaration is not a wiring: the line in Terminal.h that declares the member
# would otherwise read as every frontend wiring every client.
DECLARES = re.compile(r"^\s*(?:[A-Za-z_][\w:<>,\s*&]*\s+)?[A-Za-z_]\w*Client\s*(?:\{\}|=\s*(?:nullptr|NULL|\{\}))\s*;")

# One way a module gets a session whose terminal Core wires for it: the
# spelling of a construction (`use`), the file that declares the constructor
# (`declaredIn`), and how the declaration reads there (`declaration`).
SessionConstructor = collections.namedtuple("SessionConstructor", ["use", "declaredIn", "declaration"])

# Every constructor a module reaches a TerminalSession through: Core's two
# factories, and the Swift kit's drive and surface over them. Each declaration
# is confirmed in its file before a verdict, and a missing one exits 2, for the
# reason the client members are read out of Terminal.h: a renamed constructor
# would otherwise match nothing, and every caller of the new name would pass
# unread. A new way to construct a session joins this list in the change that
# adds it.
#
# A module that declares one of these is a kit: it builds sessions for the
# shell hosting it, and that shell is the one asked. A kit's own assignments of
# a client still count.
SESSION_CONSTRUCTORS = (
    SessionConstructor(r"\bTerminalSession(?:::|\.)make\s*\(",
                       "Source/Core/Runtime/TerminalSession.h", r"\bstatic TerminalSession\* make\("),
    SessionConstructor(r"\bWorkspaceSession(?:::|\.)make\s*\(",
                       "Source/Core/Runtime/WorkspaceSession.h", r"\bstatic WorkspaceSession\* make\("),
    SessionConstructor(r"\bRuntimeDrive\s*\(\s*(?:rows|adopting)\s*:",
                       "Source/UbiquittyRenderKit/RuntimeDrive.swift", r"\binit\?\((?:rows: Int|adopting terminal:)"),
    SessionConstructor(r"\bTerminalSurface\s*\(\s*rows\s*:",
                       "Source/UbiquittyKit/Swift/TerminalSurface.swift", r"\binit\?\(rows: Int, columns: Int\)"),
)


def clientMembers(text):
    """The client member names declared on Terminal, in declaration order."""
    return [match.group(1) for match in DECLARED_CLIENT.finditer(text)]


def assignsClient(members):
    """A regex matching an assignment into any one of `members`."""
    return re.compile(r"\b(?:%s)\s*=(?!=)" % "|".join(re.escape(m) for m in members))


def code(line):
    """The code portion of a line, dropping a `//` line comment.

    The member names are discussed in prose in these files — this very rule is
    described in a comment in the GTK frontend — and matching a comment would
    credit a frontend with a wiring it does not do, or flag one for a sentence.
    """
    return line.split("//", 1)[0]


def scan(lines, wires):
    """Returns (client assignment line numbers, policy assignment line numbers)."""
    clients = []
    policies = []
    for index, line in enumerate(lines):
        body = code(line)
        if ASSIGNS_POLICY.search(body):
            policies.append(index + 1)
        if wires.search(body) and not DECLARES.match(body):
            clients.append(index + 1)
    return clients, policies


def constructsSession(constructors):
    """A regex matching a construction through any one of `constructors`."""
    return re.compile("|".join("(?:%s)" % constructor.use for constructor in constructors))


def scanConstructions(lines, constructs):
    """The line numbers that construct a session, line comments excluded."""
    return [index + 1 for index, line in enumerate(lines) if constructs.search(code(line))]


def moduleOf(relativePath):
    """The module a repository-relative source path belongs to, None outside one."""
    parts = pathlib.PurePosixPath(relativePath).parts
    if len(parts) < 2 or parts[0] != SOURCE:
        return None
    if parts[1] == PLATFORM:
        return PLATFORM + "/" + parts[2] if len(parts) > 2 else None
    return parts[1]


def missingDeclarations(constructors, read):
    """One sentence for each constructor whose file no longer declares it.

    `read` takes a repository-relative path and answers its text, or None when
    the file is absent.
    """
    missing = []
    for constructor in constructors:
        text = read(constructor.declaredIn)
        if text is None:
            missing.append("%s is missing" % constructor.declaredIn)
        elif not re.search(constructor.declaration, text):
            missing.append("%s does not declare /%s/" % (constructor.declaredIn, constructor.declaration))
    return missing


def isOpen(name, wirings, constructions, installs, kits):
    """Whether a module wires a client, by assignment or through a session,
    and installs no policy. A kit's constructions are its host's and do not
    count against it."""
    wired = wirings + ([] if name in kits else constructions)
    return bool(wired) and not installs


def modules():
    """Every module that could own a Terminal, as (label, absolute path).

    Source/Platform fans out one level, because the frontends under it are
    independent of each other and a policy in one says nothing about another.
    Every other Source/<name> is one module.
    """
    found = []
    # Every checkout holding a Source/ tree: the libraries' modules own Terminals
    # too, and a policy missing there is as open as one missing in the app's.
    for root in library_scripts.directories(SOURCE):
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            if not os.path.isdir(path) or name in NOT_A_MODULE:
                continue
            if name == PLATFORM:
                for inner in sorted(os.listdir(path)):
                    innerPath = os.path.join(path, inner)
                    if os.path.isdir(innerPath):
                        found.append(("Platform/" + inner, innerPath))
                continue
            found.append((name, path))
    return found


def surveyModule(root, wires, constructs):
    """Every client wiring, session construction and policy install under one module."""
    wirings = []
    constructions = []
    installs = []
    for directory, _, files in os.walk(root):
        for entry in sorted(files):
            if not entry.endswith(SOURCE_SUFFIXES):
                continue
            path = os.path.join(directory, entry)
            with open(path, encoding="utf-8", errors="replace") as handle:
                lines = handle.read().splitlines()
            clients, policies = scan(lines, wires)
            relative = library_scripts.relative(path)
            wirings += ["%s:%d" % (relative, n) for n in clients]
            constructions += ["%s:%d" % (relative, n) for n in scanConstructions(lines, constructs)]
            installs += ["%s:%d" % (relative, n) for n in policies]
    return wirings, constructions, installs


def readRepositoryFile(relativePath):
    """A repository file's text, or None when it is absent."""
    try:
        with open(library_scripts.locate(relativePath), encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def selfTest():
    """Both arms, plus the two failure modes this design trades between."""
    # A stand-in Terminal.h, so the parse is exercised rather than assumed. It
    # holds a client nothing in this file names, which is the point: the members
    # come from the header, so tomorrow's client needs no edit here.
    header = "\n".join([
        "struct Terminal {",
        "    Ubiquitty::GatedClient<Ubiquitty::WindowClient> windowClient {};",
        "    Ubiquitty::CheckedPtr<Ubiquitty::ShellClient> shellClient {};",
        "    Ubiquitty::CheckedPtr<Ubiquitty::HolographicProjectorClient> holographicProjectorClient {};",
        "    Ubiquitty::GatedPolicy capabilityPolicy {};",
        "};",
    ])
    members = clientMembers(header)
    # Matches nothing when the parse came back empty, so a broken pattern reports
    # every later check as a failure instead of raising over a None.
    wires = assignsClient(members) if members else re.compile(r"(?!)")

    wired = [
        "void setup(Terminal* term) {",
        "    term->shellClient = &shell;",
        "}",
    ]
    seeded = [
        "void setup(Terminal* term) {",
        "    term->capabilityPolicy = &policy;",
        "    term->shellClient = &shell;",
        "}",
    ]
    # Declared in the header above and named nowhere in this script.
    unknown = [
        "void setup(Terminal* term) {",
        "    term->holographicProjectorClient = &beam;",
        "}",
    ]
    # The false positive that a `…Client` suffix rule produced: a socket
    # descriptor in Platform/POSIX, no Terminal within reach.
    unrelated = [
        "SocketAcceptOutcome acceptConnection(const Descriptor& l, Descriptor* outClient) {",
        "    if (outClient)",
        "        *outClient = std::move(client);",
        "}",
    ]
    reading = [
        "void use(Terminal* term) {",
        "    if (term->shellClient == nullptr)",
        "        return;",
        "}",
    ]
    declaring = [
        "struct Terminal {",
        "    Ubiquitty::CheckedPtr<Ubiquitty::ShellClient> shellClient {};",
        "};",
    ]
    commented = [
        "void setup(Terminal* term) {",
        "    // an example only: shellClient = x belongs in the caller",
        "}",
    ]

    # The constructions a frontend built on sessions alone makes: the Swift
    # surface the iOS shell builds, and Core's factory from C++.
    constructs = constructsSession(SESSION_CONSTRUCTORS)
    swiftSurface = [
        "func makePaneSurface() -> TerminalSurface? {",
        "    guard let created = TerminalSurface(rows: rows, columns: columns) else { return nil }",
        "    return created",
        "}",
    ]
    cppSession = [
        "auto* session = Ubiquitty::Runtime::TerminalSession::make();",
    ]
    namedInComment = [
        "/// A shell builds one with TerminalSurface(rows: 24, columns: 80).",
        "// TerminalSession::make() is Core's factory.",
    ]
    # The registry's declarations, as their files hold them, and one file that
    # lost its constructor: a rename there must fail the gate, not empty it.
    declarations = {
        "Source/Core/Runtime/TerminalSession.h": "    [[nodiscard]] static TerminalSession* make() UBIQUITTY_RETURNS_RETAINED",
        "Source/Core/Runtime/WorkspaceSession.h": "    [[nodiscard]] static WorkspaceSession* make(IngestPolicy ingestPolicy, DrawnText drawnText)",
        "Source/UbiquittyRenderKit/RuntimeDrive.swift": "    public init?(rows: Int, columns: Int) {",
        "Source/UbiquittyKit/Swift/TerminalSurface.swift": "    public convenience init?(rows: Int, columns: Int) {",
    }
    renamed = dict(declarations)
    renamed["Source/UbiquittyKit/Swift/TerminalSurface.swift"] = "    public convenience init?(grid: GridSize) {"
    kits = {"UbiquittyKit", "UbiquittyRenderKit"}
    construction = ["Source/Platform/iOS/App/TerminalSessionModel.swift:870"]
    install = ["Source/Platform/iOS/SessionClients.cpp:51"]

    checks = [
        ("the client members are read out of the header",
            members == ["windowClient", "shellClient", "holographicProjectorClient"]),
        ("a header declaring no client is a failure, not an empty pass",
            clientMembers("struct Terminal { int rows = 0; };") == []),
        ("a wired client with no policy is caught", scan(wired, wires) == ([2], [])),
        ("a wired client beside a policy passes", scan(seeded, wires) == ([3], [2])),
        ("a client named only in the header is still caught", scan(unknown, wires) == ([2], [])),
        ("an unrelated outClient is not a wiring", scan(unrelated, wires) == ([], [])),
        ("comparing a client is not wiring one", scan(reading, wires) == ([], [])),
        ("declaring the member is not wiring it", scan(declaring, wires) == ([], [])),
        ("a client named in a comment is not a wiring", scan(commented, wires) == ([], [])),
        ("building a Swift surface is a construction", scanConstructions(swiftSurface, constructs) == [2]),
        ("calling Core's session factory is a construction", scanConstructions(cppSession, constructs) == [1]),
        ("a constructor named in a comment is not a construction", scanConstructions(namedInComment, constructs) == []),
        ("a module that builds sessions and installs no policy is caught",
            isOpen("Platform/iOS", [], construction, [], kits)),
        ("a module that builds sessions beside a policy passes",
            not isOpen("Platform/iOS", [], construction, install, kits)),
        ("a kit's own constructions are its host's",
            not isOpen("UbiquittyKit", [], construction, [], kits)),
        ("a kit's own client assignments still count",
            isOpen("UbiquittyKit", ["Source/UbiquittyKit/Session.cpp:1"], [], [], kits)),
        ("every registered constructor is found where it is declared",
            missingDeclarations(SESSION_CONSTRUCTORS, declarations.get) == []),
        ("a constructor its file no longer declares is reported",
            len(missingDeclarations(SESSION_CONSTRUCTORS, renamed.get)) == 1),
        ("a declaring file that is gone is reported",
            len(missingDeclarations(SESSION_CONSTRUCTORS, {}.get)) == len(SESSION_CONSTRUCTORS)),
        ("a declaring file names its kit", moduleOf("Source/UbiquittyKit/Swift/TerminalSurface.swift") == "UbiquittyKit"
            and moduleOf("Source/Platform/iOS/SessionClients.cpp") == "Platform/iOS"),
    ]
    ok = True
    for label, passed in checks:
        print("  %s %s" % ("ok " if passed else "FAIL", label))
        ok = ok and passed
    print("check-frontend-capability-policy: self-test %s" % ("ok" if ok else "FAILED"))
    return 0 if ok else 1


def main():
    if "--self-test" in sys.argv:
        return selfTest()

    headerPath = library_scripts.locate(TERMINAL_HEADER)
    try:
        with open(headerPath, encoding="utf-8") as handle:
            members = clientMembers(handle.read())
    except FileNotFoundError:
        print("check-frontend-capability-policy: FAILED — %s is missing, so no client"
              " member names were read and nothing was checked" % TERMINAL_HEADER,
              file=sys.stderr)
        return 2
    if not members:
        print("check-frontend-capability-policy: FAILED — 0 client members parsed from"
              " %s, so every module would pass without being checked" % TERMINAL_HEADER,
              file=sys.stderr)
        print("  The declarations moved or changed shape. This check reads them at run"
              " time on purpose — fix the pattern rather than pasting a list here,"
              " because a list goes stale the next time a client is added.",
              file=sys.stderr)
        return 2
    wires = assignsClient(members)

    missing = missingDeclarations(SESSION_CONSTRUCTORS, readRepositoryFile)
    if missing:
        print("check-frontend-capability-policy: FAILED — %d session constructor(s) in"
              " SESSION_CONSTRUCTORS are not declared where it says, so their callers"
              " would pass unread" % len(missing), file=sys.stderr)
        for sentence in missing:
            print("    %s" % sentence, file=sys.stderr)
        print("  Point the entry at the constructor's new name and file rather than"
              " deleting it.", file=sys.stderr)
        return 2
    constructs = constructsSession(SESSION_CONSTRUCTORS)
    kits = {moduleOf(constructor.declaredIn) for constructor in SESSION_CONSTRUCTORS}

    found = modules()
    if not found:
        print("check-frontend-capability-policy: FAILED — 0 modules under %s, so"
              " nothing was checked" % SOURCE, file=sys.stderr)
        return 2

    failures = []
    stale = []
    wiredCount = 0
    seededCount = 0
    for name, path in found:
        wirings, constructions, installs = surveyModule(path, wires, constructs)
        wired = wirings + ([] if name in kits else constructions)
        if wired:
            wiredCount += 1
        if installs:
            seededCount += 1
        moduleIsOpen = isOpen(name, wirings, constructions, installs, kits)
        if moduleIsOpen and name not in KNOWN_OPEN:
            failures.append("%s (%s)" % (name, wired[0]))
        if not moduleIsOpen and name in KNOWN_OPEN:
            stale.append(name)

    if failures:
        status = gate_report.failed("check-frontend-capability-policy",
            "module(s) wire a client and install no capability policy", failures)
        for site in failures:
            print("    %s: wires a Terminal client, or builds a session that wires"
                  " them, and assigns capabilityPolicy nowhere in its module" % site,
                  file=sys.stderr)
        print("  A null policy is not the module's answer — Core falls back to"
              " PAL's defaultDecision for a terminal nobody configured, and its"
              " file reads refuse every origin. Install one the way"
              " Source/Platform/Linux/CapabilityPolicy.h does, or, for panes a kit"
              " builds, the way Source/Platform/iOS/SessionClients.cpp does.",
              file=sys.stderr)
        return status

    if stale:
        status = gate_report.failed("check-frontend-capability-policy",
            "KNOWN_OPEN entr(ies) name a module that is now closed", stale)
        for name in stale:
            print("    %s: installs a policy now, so its KNOWN_OPEN entry in %s"
                  " is describing a state that no longer exists — delete it."
                  % (name, os.path.relpath(os.path.abspath(__file__), REPO)),
                  file=sys.stderr)
        print("  This is the exemption expiring on purpose: it is reported rather"
              " than remembered, so it cannot outlive the condition it records.",
              file=sys.stderr)
        return status

    known = ", ".join(sorted(KNOWN_OPEN)) if KNOWN_OPEN else "none"
    print("check-frontend-capability-policy: ok (%d module(s); %d wire a client or"
          " build a session, %d install a policy; %d client member(s) from Terminal.h;"
          " %d session constructor(s); known-open: %s)"
          % (len(found), wiredCount, seededCount, len(members), len(SESSION_CONSTRUCTORS), known))
    return 0


if __name__ == "__main__":
    sys.exit(main())
