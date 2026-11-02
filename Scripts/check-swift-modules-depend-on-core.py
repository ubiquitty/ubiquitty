#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Hold every Swift module that inlines C++ to a declared dependency on it.

A Swift target's sources are its `.swift` files. The Swift sources reach Core
through C++ interop and INLINE header-only code, and CMake does not scan an
interop include — so without a declared dependency there is no edge from
`Source/Core/**.h` to the module, and editing a Core header leaves the built
library holding the code from before the edit. The app then runs the old Core
on the Swift arm, and nothing says so.

Measured without the stamp: editing `TerminalSession.h` rebuilds the C-family
targets that include it and relinks; the Swift libraries keep their previous
objects. Touch any `.swift` in a module and it rebuilds. Which you get is decided
by whether an unrelated Swift file happens to be newer.

The module that hosts every Swift UI scenario is one of them, which is why this
is a correctness gate and not a build-time one: an ablation meant to prove a
scenario can fail reaches nothing, and reports a healthy test as vacuous.

## Why a stamp source and not OBJECT_DEPENDS

`OBJECT_DEPENDS` is a C/C++/ObjC source property and CMake's Swift support
ignores it. MEASURED: with it set, the same edit still rebuilds neither library.
It reads like a fix and is not one, which is why
this check looks for the stamp and not for a dependency in the abstract.

What a Swift target does honour is its own sources, so the header set rides as
one: a generated `.swift` holding a hash of every header, regenerated when any
of them changes.

## What this decides

That every Swift target in the file carries the stamp — DISCOVERED from the
CMake rather than listed here, so a Swift module added tomorrow fails this until
it carries one too. A target may take it as a source-list append (which must
survive to its declaration) or through `target_sources`.

It cannot decide that the stamp's header set is COMPLETE — a header outside the
globbed trees would still be missed — so the globs are named in the output for a
reader to judge.

Stdlib only.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gate_report  # noqa: E402

GATE = "check-swift-modules-depend-on-core"

# The files that own the Swift modules, and the stamp they must carry.
#
# Both arms are covered, not the macOS one alone. The iOS Swift modules live in
# the root CMakeLists.txt — there is no Source/Platform/iOS/CMakeLists.txt — and
# have the same hazard in a sharper form: Source/Core/Runtime/TerminalSession.h
# reaches that arm through interop and nothing else, so without the stamp editing
# it produces no ninja action, and RuntimeDrive.swift holds a stored property of
# that header-only C++ type. A layout change there desyncs the two halves about
# the size of an object they pass between them with nothing in the build to
# notice.
#
# A gate whose prose knows about a case its code never opens cannot fail on it,
# so both lists are read.
MODULE_LISTS = ("Source/Platform/macOS/CMakeLists.txt", "CMakeLists.txt")
STAMP = "UBIQUITTY_SWIFT_INTEROP_STAMP"

# What makes a Swift module need the stamp: it compiles with C++ interop on, so
# it inlines header-only Core. A Swift module with interop off inlines nothing and
# has no such dependency — the iOS XCUITest bundle is one, and demanding a stamp
# of it would be noise. The signal is the flag rather than a name list, so a
# module that turns interop on tomorrow is covered without anyone editing this.
INTEROP_FLAG = "-cxx-interoperability-mode"
FLAGS_VARIABLE = re.compile(r'set\((\w*SWIFT_FLAGS)\b((?:(?!\)).)*)\)', re.S)

# A Swift module is a target carrying Swift_MODULE_NAME. Finding them this way
# rather than from a list here is the point: a new Swift module is covered on
# the day it is written, not on the day someone remembers this file.
MODULE_NAME = re.compile(r'set_target_properties\((\w+)\s+PROPERTIES(?:(?!\)).)*?Swift_MODULE_NAME', re.S)
DECLARES = re.compile(r'add_(?:library|executable)\((\w+)\b((?:(?!\)).)*)\)', re.S)
VARIABLE = re.compile(r'\$\{(\w+)\}')


def withoutComments(text):
    """CMake with every comment blanked, keeping byte offsets.

    Offsets are preserved because the ordering rules below compare positions:
    an append counts only if it precedes its target's declaration. Blanking
    rather than deleting keeps every position meaningful.

    Comments have to go before anything is parsed. This file's own commentary
    names the very constructs being looked for — a line reading
    `add_executable(Ubiquitty) is above` registered as a second target until
    this existed — and a commented-out append must never read as a live one.
    """
    out = []
    for line in text.split("\n"):
        quoted = False
        cut = len(line)
        for index, character in enumerate(line):
            if character == '"' and (index == 0 or line[index - 1] != "\\"):
                quoted = not quoted
            elif character == "#" and not quoted:
                cut = index
                break
        out.append(line[:cut] + " " * (len(line) - cut))
    return "\n".join(out)


def liveAppendsStamp(text, variable, before):
    """Whether an append of the stamp into `variable` survives to `before`.

    An append placed above a later `set(<var> "")` is discarded, and the module
    then builds without the stamp while the CMake reads correctly. That was got
    wrong here once, so it is checked rather than assumed.
    """
    appendPattern = re.compile(rf'list\(APPEND\s+{re.escape(variable)}\s+"\$\{{{STAMP}\}}"\)')
    resets = [m.start() for m in re.finditer(rf'set\({re.escape(variable)}\s+""\)', text)]
    for append in appendPattern.finditer(text):
        at = append.start()
        if at < before and not any(at < reset < before for reset in resets):
            return True
    return False


def interopFlagVariables(text):
    """The names of the swift-flag variables that switch C++ interop on."""
    return {match.group(1) for match in FLAGS_VARIABLE.finditer(text)
            if INTEROP_FLAG in match.group(2)}


def inlinesCore(text, target, interopVariables):
    """Whether this target compiles with interop, so it inlines Core headers.

    Read from the target's own compile options: a Swift module that never turns
    interop on inlines no C++ and cannot go stale against a header.
    """
    opening = f"target_compile_options({target}"
    at = text.find(opening)
    while at != -1:
        depth, index = 0, at + len(opening) - len(target) - 1
        while index < len(text):
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        block = text[at:index]
        if any(variable in block for variable in interopVariables):
            return True
        at = text.find(opening, index)
    return False


def checkOneList(root, listing, findings, covered, exempt):
    """Reads one CMake list, recording modules that inline Core without the stamp.

    - Returns: A gate_report exit status when the file itself is unusable, else
      None. A missing file is not an error — the iOS list exists only in some
      trees — but a file carrying Swift modules with no stamp is.
    """
    path = root / listing
    if not path.is_file():
        return None
    text = withoutComments(path.read_text())

    swiftTargets = {match.group(1) for match in MODULE_NAME.finditer(text)}
    if not swiftTargets:
        return None

    interopVariables = interopFlagVariables(text)
    needing = {target for target in swiftTargets
               if inlinesCore(text, target, interopVariables)}
    exempt.update((listing, target) for target in swiftTargets - needing)
    if not needing:
        return None

    if STAMP not in text:
        return gate_report.failed(
            GATE, "Swift module(s) with no interop stamp at all",
            [f"{listing} compiles {len(needing)} Swift module(s) with "
             f"{INTEROP_FLAG} and never defines {STAMP}"])

    return checkTargets(text, listing, needing, findings, covered)


def checkTargets(text, listing, needing, findings, covered):
    """The per-target check, once the file is known to be worth reading."""

    # target_sources takes a target by name, so it needs no ordering argument.
    givenDirectly = set(re.findall(
        rf'target_sources\((\w+)\s+PRIVATE\s+"\$\{{{STAMP}\}}"\)', text))

    for declaration in DECLARES.finditer(text):
        target, sources = declaration.group(1), declaration.group(2)
        if target not in needing:
            continue
        if target in givenDirectly:
            covered.add(f"{target} ({listing})")
            continue
        variables = VARIABLE.findall(sources)
        if any(liveAppendsStamp(text, variable, declaration.start()) for variable in variables):
            covered.add(f"{target} ({listing})")
            continue
        findings.append(
            f"{listing}: {target} does not carry {STAMP} — neither through "
            f"target_sources nor through a surviving append into "
            f"{' or '.join(variables) or 'its sources'}")
    return None


def main():
    root = Path(__file__).resolve().parent.parent
    findings, covered, exempt = [], set(), set()
    for listing in MODULE_LISTS:
        status = checkOneList(root, listing, findings, covered, exempt)
        if status is not None:
            return status

    if not covered and not findings:
        print(f"{GATE}: SKIPPED — none of {', '.join(MODULE_LISTS)} declares a "
              "Swift module that compiles with interop", file=sys.stderr)
        return 0

    if findings:
        gate_report.failed(GATE, "Swift module(s) that inline Core without depending on it", findings)
        print(f"  A Swift module compiles C++ headers into itself and CMake does not scan them. "
              f"Give the module the {STAMP} source: target_sources(<target> PRIVATE ...), or a "
              f"list(APPEND ...) placed after its source list is populated and before its "
              f"add_library/add_executable.", file=sys.stderr)
        return 1

    # The exemptions are PRINTED, not silent. A module drops off this gate's
    # duty by not compiling with interop, and that is a real answer — but an
    # exemption nobody can see is how a module stops being checked without
    # anyone deciding it should.
    note = ""
    if exempt:
        note = ("; exempt, compiling without interop so inlining nothing: "
                + ", ".join(f"{target} ({listing})" for listing, target in sorted(exempt)))
    print(f"{GATE}: ok ({len(covered)} Swift module(s) carry the interop stamp — "
          f"{', '.join(sorted(covered))}{note}; its header set is Source/Core, Source/PAL "
          "and Source/Base plus the interop module map, and a header outside those is "
          "still missed and this cannot see it)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
