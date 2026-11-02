#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Assert every RenderKit Swift export naming a C++ interop type survives the seam.

The defect this catches: swiftc silently drops a public/package Swift declaration
whose signature the C++ reverse-interop header printer cannot represent. No
diagnostic is emitted and the build stays green -- the symptom appears only at an
ObjC++/C++ consumer, or nowhere at all until one is added. A plain build cannot
see it, because nothing fails to compile; the export is absent from the
generated `UbiquittyRenderKit-Swift.h`. This has already happened here:
`encodeTekFrame` and `imageQuads` ship as `UnsafeRawPointer?` because their typed
versions vanished (see the swift-cxx export audit).

Verified end to end: a `public func` returning `UnsafeMutablePointer<Ubiquitty.T>?`
or `(() -> Ubiquitty.T)?` compiles but is omitted from the generated header -- the
exact state this gate flags. A by-value `Ubiquitty.T?` or `[Ubiquitty.T]?`
survives, so the printer's refusal is shape-specific and not something a source
reader can eyeball.

The generated header is the authoritative artefact, and the only one checked. The
compiled archive is not: under whole-module optimisation a public func with no
external C++ caller can be inlined away with no standalone symbol emitted (that is
exactly why `encodeTekFrame` is present in the header yet absent from `nm`), so
archive-symbol presence is optimiser-dependent and cannot separate a drop from an
elision. A declared-but-undefined export that a caller actually needs is a link
error the build's own consumer catches; a latent one is benign.

Derived, not spelled. The member set is a source census -- the developer's own
`Ubiquitty.`-qualified signatures -- scoped to the RenderKit target's own source
list parsed from CMakeLists.txt. The interop marker (`Ubiquitty.`) is what the
developer wrote, not a table maintained here, so a rename or a newly added typed
export is covered without touching this file.

Freshness: this reads the header a build produced, so it is only as current as
that build. Verified here: check-ubiquittykit rebuilds the module and re-emits the
header whenever a Swift source changed, so the Swift-diff trigger it runs under
reads a current header (a canary added to a source dropped from the header exactly
as expected). Not established: whether a Core-header-only change re-emits it -- the
Swift/ninja header-dependency behaviour is subtle and has been misread repeatedly, so widening the trigger to Core-header changes must force the re-emit or
prove it happens, not assume it.

Boundary, stated not silent: funcs only, not stored properties; the RenderKit
target only, not the app Swift arm; base-name presence, so a partial drop of one
overload while a same-named overload survives reads as present.
"""
import os
import re
import subprocess
import sys

import os.path as _p, sys as _s
_s.path.insert(0, _p.dirname(_p.abspath(__file__)))
import build_root

DECL = re.compile(r"^\s*(?:public|package)\s+func\s+(\w+)\s*(?:<[^>]*>)?\s*\(")


def fail(msg):
    print(f"check-swift-cxx-exports: {msg}", file=sys.stderr)
    return 2


def cmake_list(text, name):
    """The .swift paths in one `set(<name> ...)` block.

    The close is matched wherever it falls, not only on its own line: a list
    whose last entry carries the paren — `...StreamDebugRecorder.swift)` — is
    the shape that made this return nothing at all, and an empty census reads
    like a clean tree.
    """
    m = re.search(r"set\(" + re.escape(name) + r"\b(.*?)\)\s*?\n", text, re.S)
    return re.findall(r"(\S+\.swift)", m.group(1)) if m else []


def renderkit_sources(cmake_path):
    """The RenderKit target's .swift list -- what the target compiles, so what
    its exports can come from.

    The list expands `${UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES}` and then adds
    this shell's own chrome, so reading the `set(` block alone censuses the
    chrome and none of the renderer. That is not an empty answer a reader would
    notice: it is a smaller one, and the exports it skipped are the renderer's
    own. So the variable is followed into the file that defines it.
    """
    text = open(cmake_path, encoding="utf-8").read()
    sources = cmake_list(text, "UBIQUITTY_RENDERKIT_SOURCES")
    if "${UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES}" not in text:
        return sources
    shared = os.path.join(os.path.dirname(cmake_path), "..", "..", "..",
                          "Scripts", "cmake", "AppleSharedSwift.cmake")
    shared = os.path.normpath(shared)
    if not os.path.exists(shared):
        return sources
    shared_text = open(shared, encoding="utf-8").read()
    return cmake_list(shared_text, "UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES") + sources


def exports_in_text(rel, text):
    """Public/package funcs whose (possibly multi-line) signature names Ubiquitty.*

    A declaration whose preceding line carries `swift-only:` states that its
    absence from the generated header is the design — an in-package Swift API
    whose shape (a pointer to an imported type, a closure over one) the printer
    cannot represent and no C++ consumer needs. Stated, not silent: the marked
    census is returned separately so the summary counts it.
    """
    lines = text.splitlines()
    found = []
    swift_only = []
    i = 0
    while i < len(lines):
        m = DECL.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        sig, j = [], i
        while j < len(lines) and j < i + 40:
            sig.append(lines[j])
            if "{" in lines[j]:
                break
            j += 1
        if "Ubiquitty." in "\n".join(sig):
            if i > 0 and "swift-only:" in lines[i - 1]:
                swift_only.append((rel, i + 1, name))
            else:
                found.append((rel, i + 1, name))
        i = j + 1
    return found, swift_only


def derive_exports(root, rel_files):
    exports = []
    swift_only = []
    for rel in rel_files:
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            continue
        found, marked = exports_in_text(rel, open(path, encoding="utf-8").read())
        exports.extend(found)
        swift_only.extend(marked)
    return exports, swift_only


def dropped_exports(exports, header_text):
    """Members whose C++ thunk is absent from the generated header.

    `\\b`-anchored so a dropped member's absence is real and a same-prefixed
    sibling cannot mask it. The header carries each surviving export three ways
    (the SWIFT_EXTERN declaration, the SWIFT_INLINE_THUNK definition, a trailing
    comment), so a present export always matches and an absent one never does.
    """
    dropped = []
    for rel, line, name in exports:
        if not re.search(r"\b" + re.escape(name) + r"\b", header_text):
            dropped.append((rel, line, name))
    return dropped


def self_test():
    fixture = """
public func keep() -> Ubiquitty.Terminal? { session.terminal() }
public func multiline(
    to style: inout Ubiquitty.Rendering.TerminalSnapshotStyle,
    _ inputs: borrowing FrameStyleInputs
) { }
public func plain() -> Int { 0 }
private func hidden() -> Ubiquitty.Terminal { fatalError() }
package func pkg(_ t: Ubiquitty.Terminal) -> Bool { true }
func internalHelper() -> Ubiquitty.Terminal? { nil }
// swift-only: the printer cannot represent the closure, and no C++ caller exists
package func marked(_ body: (Ubiquitty.Terminal) -> Void) { }
"""
    failures = 0

    census, marked = exports_in_text("Fixture.swift", fixture)
    got = sorted(name for _, _, name in census)
    want = ["keep", "multiline", "pkg"]
    ok = got == want and [name for _, _, name in marked] == ["marked"]
    failures += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} census picks public/package interop funcs, swift-only marks aside "
          f"(got {got} + {[name for _, _, name in marked]}, want {want} + ['marked'])")

    exports = [("F.swift", 1, "alive"), ("F.swift", 2, "dropped")]
    # A surviving export's thunk is present; the dropped one's is not. `aliveish`
    # proves the boundary: a longer sibling must not vouch for a shorter name.
    header = "SWIFT_INLINE_THUNK void alive(Ubiquitty::Terminal&) noexcept;\n" \
             "SWIFT_INLINE_THUNK void aliveish() noexcept;\n"
    got_drop = sorted(name for _, _, name in dropped_exports(exports, header))
    ok = got_drop == ["dropped"]
    failures += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} the dropped export is flagged, the survivor is not "
          f"(flagged {got_drop}, want ['dropped'])")

    # The prefix boundary, isolated: 'alive' must be reported dropped when only
    # 'aliveish' is present -- a longer sibling does not vouch for a shorter name.
    ok = dropped_exports([("F.swift", 1, "alive")], "void aliveish();\n") != []
    failures += 0 if ok else 1
    print(f"  {'ok ' if ok else 'FAIL'} a name is not vouched for by a longer sibling")

    print(f"check-swift-cxx-exports: self-test {'ok' if failures == 0 else 'FAILED'}")
    return 1 if failures else 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    positionals = [a for a in sys.argv[1:] if not a.startswith("-")]
    root = positionals[0] if positionals else subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True
    ).stdout.strip()
    if not root:
        return fail("not a git repository and no root given")
    build = (positionals[1] if len(positionals) > 1
             else os.path.join(build_root.build_root(root), "ubiquittykit"))

    cmake = os.path.join(root, "Source/Platform/macOS/CMakeLists.txt")
    header = os.path.join(build, "Source/Platform/macOS/UbiquittyRenderKit-Swift.h")
    if not os.path.exists(cmake):
        return fail(f"CMakeLists not found: {cmake}")
    if not os.path.exists(header):
        return fail(f"generated header missing (build the macOS arm first): {header}")

    exports, swift_only = derive_exports(root, renderkit_sources(cmake))
    if not exports:
        return fail("derived zero interop-typed exports -- the census is broken, not the tree")

    header_text = open(header, encoding="utf-8", errors="replace").read()
    dropped = dropped_exports(exports, header_text)

    if dropped:
        print("\nFAIL: these Swift exports name a C++ interop type but are absent from the "
              "generated header:", file=sys.stderr)
        for rel, line, name in dropped:
            print(f"  {rel}:{line}  {name}", file=sys.stderr)
        return 1
    # The counts say what was covered; the FAIL above names what to fix. Naming
    # every export whether it survives or not would print a roll-call of what is
    # fine for a reader who acts on what is not.
    print("check-swift-cxx-exports: ok "
          f"({len(exports)} interop-typed export(s) survive the generated header, "
          f"{len(swift_only)} marked swift-only by declaration)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
