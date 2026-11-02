#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Nothing in terminal.js may reach the wasm terminal before it is created.

THREE DEFECTS, one shape. Every web export that needs the terminal starts with
`if (!terminal) return 0;` — it answers rather than throwing, because throwing
across the C ABI is not an option. So a call made before ubiquittyWebCreate is
SILENT: the value is discarded, the page carries on, and the feature is
absent with nothing anywhere saying why.

    setFontOptions   called early     "Choose Font" never appears in Beam
    setBeamSurface   called early     ?beam= is discarded, and the page prints
                                      "unrecognized ?beam=native" for a value
                                      that is perfectly good
    recallTheme      a TDZ variant    the theme is stored and never read

No C++ test catches these, because every one of those tests calls the API on a
terminal it constructed itself. They assert the API and never the page's
ordering, which is the gap this closes.

The check: find the line that calls create(), then find every cwrapped binding
CALLED above it. Definitions do not count on their own — a function body runs
when the function is invoked, not where it is written.

Two idioms reach the module, and scanning one of them is scanning half the page.
`const name = module.cwrap(...)` binds first and calls later; `module.ccall('an
export', ...)` names the export at the call site and binds nothing. A check that
knows only the first reports success over any number of the second. The second
needs no binding line, so it costs nothing to write inline in start-up code —
where a call above create() is precisely the defect this file exists to refuse.

But a helper INVOKED above create() runs above create(), and its body is as
early as the call site. Reading only the call site misses that entirely: the
binding call sits at function-body depth and looks deferred, while the helper
that holds it has already run. So an invocation of a locally defined function
above create() pulls that function's body into the scan, transitively, and the
report names the path that reaches the binding rather than only the line.

Run standalone or from build-web.sh:

    python3 Scripts/check-web-init-order.py
"""

import pathlib
import re
import sys

PAGE = pathlib.Path(__file__).resolve().parent.parent / "Source" / "Platform" / "Web" / "terminal.js"

# Bindings that do not need a terminal. ubiquittyWebCreate is the one that makes
# it, and the module-level helpers answer from the module rather than the
# instance. Kept explicit: a name added here is a claim that the export works
# with `terminal` null, and that claim is checkable in WebExports.cpp.
NEEDS_NO_TERMINAL = {"create"}

# The same claim for the ccall idiom, where the call site names the EXPORT rather
# than a local binding. Verified below against WebExports.cpp rather than
# trusted: an entry here says the export answers without a terminal, and that is
# true only while its body never mentions one.
NEEDS_NO_TERMINAL_EXPORTS = {"ubiquittyWebCreate", "ubiquittyWebSetPreferenceBlob"}

EXPORTS = pathlib.Path(__file__).resolve().parent.parent / "Source" / "Platform" / "Web" / "WebExports.cpp"


def exemptionsThatAreNotTrue():
    """Returns the exempted exports whose body does reach `terminal` after all.

    - Returns: a list of (name, reason) for every claim WebExports.cpp refutes.
    """
    if not EXPORTS.exists():
        return [("WebExports.cpp", "is missing, so no exemption can be checked")]
    text = EXPORTS.read_text()
    broken = []
    for name in sorted(NEEDS_NO_TERMINAL_EXPORTS):
        start = text.find(f"UBIQUITTY_WEB_EXPORT")
        while start >= 0 and f" {name}(" not in text[start:text.find("{", start) + 1]:
            start = text.find("UBIQUITTY_WEB_EXPORT", start + 1)
        if start < 0:
            broken.append((name, "is not an export in WebExports.cpp"))
            continue
        opening = text.find("{", start)
        depth, end = 0, len(text)
        for index in range(opening, len(text)):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    end = index
                    break
        # DEPENDENCE, not mention. `terminal = make_unique<…>` is how create
        # makes one and is not a use of an existing terminal; `!terminal`,
        # `terminal->` and `terminal ?` are the three shapes that answer 0 when
        # there is none, which is the whole reason the ordering matters.
        body = text[opening:end]
        if re.search(r"!terminal\b|terminal\s*->|terminal\s*\?", body):
            broken.append((name, "depends on an existing `terminal`, so it does need one"))
    return broken


def main() -> int:
    if not PAGE.exists():
        print(f"check-web-init-order: no page at {PAGE}", file=sys.stderr)
        return 2

    lines = PAGE.read_text().split("\n")
    source = "\n".join(lines)

    bindings = set(re.findall(r"const (\w+) = module\.cwrap", source))
    if not bindings:
        # A rename of the cwrap idiom would leave this scanning for nothing and
        # reporting success. The count is asserted rather than assumed.
        print("check-web-init-order: found no cwrap bindings at all — the idiom "
              "changed and this check is no longer looking at anything", file=sys.stderr)
        return 2

    create_line = None
    for index, line in enumerate(lines, start=1):
        if re.search(r"(?<![.\w])create\s*\(\s*grid\.rows", line):
            create_line = index
            break
    if create_line is None:
        print("check-web-init-order: could not find the create(grid.rows, …) call; "
              "the check cannot place anything relative to it", file=sys.stderr)
        return 2

    # The nesting that matters is FUNCTION-BODY depth, not raw brace depth. A
    # call runs before create() when it is reachable at module load and sits
    # above the create() line: at module scope, or inside the async main() that
    # also holds create(), or inside an if/for/try block in either. Control flow
    # does not defer a call — it runs inline — so counting an `if` block as a
    # level of depth, which `depth <= 1` did, went blind to a terminal call one
    # guard-clause deep. Only a function body defers its calls to its own
    # invocation, and only those braces raise the depth here.
    def opensFunction(before):
        """Whether the `{` at the end of `before` opens a function body.

        - Parameter before: the line text preceding the brace.
        - Returns: True for `=> {`, a `function` body, or a method's `) {`;
          False for `if/for/while/switch/catch (...) {`, `try`/`else`/`do`, an
          object literal or a bare block.
        """
        trimmed = before.rstrip()
        if trimmed.endswith("=>"):
            return True
        if re.search(r"\b(if|for|while|switch|catch)\b\s*\(", before):
            return False
        if re.search(r"\bfunction\b", before):
            return True
        return trimmed.endswith(")")

    stack = []            # one bool per open brace: True when it opens a function
    createFuncDepth = None
    candidates = []       # (line number, name, function-body depth entering the line)
    for index, line in enumerate(lines, start=1):
        funcDepth = sum(1 for isFunction in stack if isFunction)
        if index == create_line:
            createFuncDepth = funcDepth
            break
        stripped = line.strip()
        if not stripped.startswith("//") and "module.cwrap" not in line:
            for name in bindings:
                if name in NEEDS_NO_TERMINAL:
                    continue
                if re.search(r"(?<![.\w])" + re.escape(name) + r"\s*\(", line):
                    candidates.append((index, name, funcDepth))
            for export in re.findall(r"\.ccall\(\s*['\"](\w+)['\"]", line):
                if export not in NEEDS_NO_TERMINAL_EXPORTS:
                    candidates.append((index, export + " [ccall]", funcDepth))
        for brace in re.finditer(r"[{}]", line):
            if brace.group() == "{":
                stack.append(opensFunction(line[: brace.start()]))
            elif stack:
                stack.pop()

    offenders = [(index, name, "") for index, name, depth in candidates
                 if createFuncDepth is not None and depth <= createFuncDepth]

    # Functions defined in this file, with the line span of each body. A helper
    # called before create() runs before create(), however deep its own calls sit.
    definitions = {}
    for index, line in enumerate(lines, start=1):
        match = re.search(r"(?:async\s+)?function\s+(\w+)\s*\(", line) or re.search(
            r"const\s+(\w+)\s*=\s*(?:async\s*)?\([^)]*\)\s*=>", line)
        if not match or "module.cwrap" in line:
            continue
        depth, started, end = 0, False, None
        for scan in range(index, len(lines) + 1):
            for brace in lines[scan - 1]:
                if brace == "{":
                    depth += 1
                    started = True
                elif brace == "}":
                    depth -= 1
            if started and depth <= 0:
                end = scan
                break
        if end:
            definitions[match.group(1)] = (index, end)

    # Which of them are invoked above create(), at a depth that actually runs.
    #
    # Two readings turn the check into noise, so neither is made: a COMMENT
    # naming a function is not a call to it (this page explains
    # itself in prose that mentions paint() and pointerCell() by name), and a call
    # sitting inside another function's body is deferred exactly as a binding
    # call there would be. The depth rule is the same one the direct scan uses.
    reached, pending = set(), []
    stack = []
    for index, line in enumerate(lines, start=1):
        if index >= create_line:
            break
        funcDepth = sum(1 for isFunction in stack if isFunction)
        stripped = line.strip()
        if not stripped.startswith("//") and funcDepth <= createFuncDepth:
            for name, (first, last) in definitions.items():
                if first <= index <= last:
                    continue  # its own definition, not a call to it
                if re.search(r"(?<![.\w])" + re.escape(name) + r"\s*\(", line):
                    pending.append((name, index))
        for brace in re.finditer(r"[{}]", line):
            if brace.group() == "{":
                stack.append(opensFunction(line[: brace.start()]))
            elif stack:
                stack.pop()

    # Transitively: a helper called by a helper that ran is a helper that ran.
    while pending:
        name, calledAt = pending.pop()
        if name in reached or name not in definitions:
            continue
        reached.add(name)
        first, last = definitions[name]
        for bodyIndex in range(first, last + 1):
            body = lines[bodyIndex - 1]
            if body.strip().startswith("//"):
                continue
            for binding in bindings:
                if binding in NEEDS_NO_TERMINAL:
                    continue
                if re.search(r"(?<![.\w])" + re.escape(binding) + r"\s*\(", body):
                    offenders.append((bodyIndex, binding, f" (via {name}(), called at line {calledAt})"))
            for export in re.findall(r"\.ccall\(\s*['\"](\w+)['\"]", body):
                if export not in NEEDS_NO_TERMINAL_EXPORTS:
                    offenders.append((bodyIndex, export + " [ccall]",
                                      f" (via {name}(), called at line {calledAt})"))
            for other in definitions:
                if other != name and re.search(r"(?<![.\w])" + re.escape(other) + r"\s*\(", body):
                    pending.append((other, calledAt))

    if offenders:
        print("check-web-init-order: FAIL — these reach the terminal before "
              f"create() at line {create_line}:", file=sys.stderr)
        for index, name, via in offenders:
            print(f"  terminal.js:{index}: {name}(){via}", file=sys.stderr)
        print("\n  A call runs before create() when it is reachable at module load — at "
              "module\n  scope, or inside main(), or inside an if/for/try block in "
              "either. Control flow\n  does not defer it; only a function body does. The "
              "export answers 0 with no\n  terminal, so the call is discarded and its "
              "feature goes missing. Move it below\n  create(), or into a function that "
              "runs after create().", file=sys.stderr)
        return 1

    broken = exemptionsThatAreNotTrue()
    if broken:
        print("check-web-init-order: REFUSED — an exemption claims an export needs no "
              "terminal, and WebExports.cpp disagrees:", file=sys.stderr)
        for name, reason in broken:
            print(f"  {name} {reason}", file=sys.stderr)
        print("\n  The exemption is what lets a call sit above create(). If the export "
              "reads\n  `terminal` it answers 0 there, so the exemption has to go rather "
              "than the check.", file=sys.stderr)
        return 2

    print(f"check-web-init-order: ok ({len(bindings)} cwrap binding(s) and the ccall "
          f"idiom, none called before create() at line {create_line}; "
          f"{len(NEEDS_NO_TERMINAL_EXPORTS)} exempt export(s) verified against "
          "WebExports.cpp)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
