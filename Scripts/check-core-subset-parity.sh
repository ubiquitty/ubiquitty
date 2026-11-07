#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# check-core-subset-parity.sh — the Wscons Core trim is the Linux one, and this
# is what keeps it that way.
#
#   ./Scripts/check-core-subset-parity.sh
#
# `ubiquitty_core_subset(... EXCLUDE ...)` carves Core four ways. Three of the
# four are compiled by somebody here; UBIQUITTY_WSCONS_CORE is fenced behind
# `message(FATAL_ERROR "UBIQUITTY_FRONTEND=Wscons only builds on OpenBSD/NetBSD")`
# and no Linux or macOS machine can configure it.
#
# It does not need one. Its exclude list is IDENTICAL to Linux's, so the Core
# half of that subset is link-checked by every Linux build — the container one
# included.
#
# The equivalence carries the check and shows nothing: edit one list, leave the other,
# and the Wscons Core half silently returns to being verified by nobody — with
# no diagnostic, because the fence means nothing ever tries to build it. That is
# the failure this refuses. If the two should diverge, this fails and the person
# diverging them says so out loud, which is the point.
#
# The PAL half is a separate question and Scripts/check-wscons-compiles.sh
# answers it: -fsyntax-only over the four Source/Platform/Wscons translation
# units against a stub of the one header no host has. It type-checks every call
# those files make into Core — which is where they rot — and links
# nothing, so no claim here covers whether the frontend runs on a BSD.
#
# Two arms reach that target without a BSD, and neither is this script. The
# other is manual and worth knowing: neutralise the OpenBSD/NetBSD FATAL_ERROR
# in CMakeLists.txt and `cmake -DUBIQUITTY_FRONTEND=Wscons` configures anywhere,
# after which all 162 Core and ThirdParty objects of ubiquitty-wscons compile.
# That is the only arm that reads the target'"'"'s own CMake — a source list or an
# include directory wrong for Wscons alone is invisible to everything else here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT/CMakeLists.txt" <<'PYEOF'
import re, sys

text = open(sys.argv[1]).read()

# The body ends at the paren that closes the call, which is found by counting
# depth with comments removed -- not at the first ')' in the text. A CMake
# comment inside one of these lists carries parens ("(ScrollSearch,
# OverlayGeometry)"), and a non-greedy body ended there: UBIQUITTY_HOST_CORE
# read 31 of its 67 paths, stopping at line 710.
#
# The pair this gate compares survived that only because neither list carries a
# comment. They are byte-identical twins maintained by copying, so one
# parenthetical copied into both truncates both to the same short set, they
# compare equal, and the gate reports parity it never checked. The sibling over
# this same construct, Scripts/check-core-subset-paths.sh, already counts depth
# and strips comments for exactly this reason.
def subsetBodies(source):
    """Each ubiquitty_core_subset EXCLUDE list, as the text between its parens.

    - Parameter source: the CMakeLists text.
    - Returns: a dict of list name to body text, comments removed.
    """
    found = {}
    for opening in re.finditer(r"ubiquitty_core_subset\((UBIQUITTY_\w+_CORE)\s+(?:ABSOLUTE\s+)?EXCLUDE", source):
        depth, index, collected = 1, opening.end(), []
        while index < len(source) and depth:
            lineEnd = source.find("\n", index)
            if lineEnd == -1:
                lineEnd = len(source)
            line = source[index:lineEnd]
            comment = line.find("#")
            for character in (line if comment == -1 else line[:comment]):
                if character == "(":
                    depth += 1
                elif character == ")":
                    depth -= 1
                    if depth == 0:
                        break
                if depth:
                    collected.append(character)
            if depth == 0:
                break
            collected.append("\n")
            index = lineEnd + 1
        found[opening.group(1)] = "".join(collected)
    return found


lists = {}
for name, body in subsetBodies(text).items():
    lists[name] = {
        f.strip() for f in body.split() if f.strip().endswith((".cpp", ".mm", ".c"))
    }

# A named list that parses to nothing is a parser that lost its subject, and two
# empty sets compare equal -- which is this gate reporting parity between lists
# it never read. Refuse rather than pass.
empty = sorted(name for name, files in lists.items() if not files)
if empty:
    print("check-core-subset-parity: parsed no path from " + ", ".join(empty) + " —")
    print("  a list that reads as empty compares equal to any other, so parity here")
    print("  would be a verdict about nothing.")
    sys.exit(2)

for name in ("UBIQUITTY_LINUX_CORE", "UBIQUITTY_WSCONS_CORE"):
    if name not in lists:
        print(f"check-core-subset-parity: {name} not found — the subset was renamed or")
        print("  its EXCLUDE form changed, and this check stopped covering it.")
        sys.exit(2)

linux, wscons = lists["UBIQUITTY_LINUX_CORE"], lists["UBIQUITTY_WSCONS_CORE"]
for name, files in sorted(lists.items()):
    print(f"  {name:<24}{len(files):>4} excluded")

if linux == wscons:
    print(f"\ncheck-core-subset-parity: Wscons trims exactly what Linux trims"
          f" ({len(wscons)} files), so every Linux build link-checks it")
    sys.exit(0)

print("\ncheck-core-subset-parity: the Wscons and Linux trims have diverged.")
print("  Wscons cannot be configured on Linux or macOS, so its Core half")
print("  was only ever verified by being identical to Linux's. It no longer is:")
for f in sorted(wscons - linux):
    print(f"    excluded by Wscons only: {f}")
for f in sorted(linux - wscons):
    print(f"    excluded by Linux only:  {f}")
print("\n  Either restore the equivalence, or arrange a build that compiles the")
print("  Wscons subset — on a BSD host, or under qemu.")
sys.exit(1)
PYEOF
