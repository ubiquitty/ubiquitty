#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Exercise one stanza through each build route: inline compilation, the
# standalone archive fixture, a shared CMake target, and an external script.
# CTest may supply a built fixture; the stanza still executes its assertions.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAILURES=0

shape() { # <description> <stanza>
    local what="$1" stanza="$2"
    printf '  %-14s %-26s ' "$what" "$stanza"
    if ./Scripts/run-tests.sh "$stanza" >/dev/null 2>&1; then
        echo ok
    else
        echo FAILED
        FAILURES=$((FAILURES + 1))
    fi
}

# The stanza for each shape is derived from the driver rather than named here.
#
# A name is a thing that leaves. The inline representative was migrated to a
# CMake target, and this check then failed reporting a broken inline path — true
# of nothing except its own example, and phrased as though the driver were
# broken. Every stanza this file names is a stanza somebody may move.
#
# The cost of deriving: whichever stanza comes first may have dependencies of
# its own, so a red row can mean that stanza rather than the driver. Each row
# prints the stanza it used, which is what lets a reader tell the two apart —
# and a representative that rots produces a red row about nothing at all.
#
# `first_stanza_of` reports the first stanza matching a shape, tracking the
# enclosing stanza name so a match inside a body is attributed to the stanza it
# is in rather than to the last one declared.
first_stanza_of() { # <awk pattern matching a line inside the body>
    awk -v want="$1" -v platform="$(uname -s)" \
        -f Scripts/stanza-declarations.awk -f /dev/stdin Scripts/run-tests.sh <<'AWK'
    {
        declaration = stanzaName($0)
        if (declaration != "") {
            name = declaration
            if (!stanzaIsAvailable($0, platform) || name ~ /_fixture$/) { name = ""; next }
            if (want == "@inline" && $0 ~ /^[ \t]*build_and_run /) { print name; exit }
            next
        }
        if (name != "" && want != "@inline" && $0 ~ want) { print name; exit }
    }
AWK
}

echo "test-driver-shapes: one stanza per build route"
SHAPES=0

# A shape with no stanza left is an error, not a skip. Deriving from an empty
# set removes the row from the output entirely, and a path that stopped being
# checked looks exactly like a path with nothing to say.
# CTest supplies the standalone build fixture to both this probe and the
# consumer stanza. The probe still executes the consumer's assertions.
for pair in \
        "inline:@inline" \
        "shared-lib:ubq_libcore_consumer" \
        "shared-target:ubq_build_test " \
        "standalone:ROOT/Tests/test-[a-z-]+[.]sh"; do
    SHAPES=$((SHAPES + 1))
    what="${pair%%:*}"
    pattern="${pair#*:}"
    stanza="$(first_stanza_of "$pattern")"
    if [ -z "$stanza" ]; then
        echo "  FAILED   no stanza left with the $what shape" >&2
        echo "           Either the driver stopped building that way, in which" >&2
        echo "           case delete the row, or every example migrated and this" >&2
        echo "           path is now unchecked." >&2
        FAILURES=$((FAILURES + 1))
        continue
    fi
    shape "$what" "$stanza"
done

echo
if [ "$FAILURES" -ne 0 ]; then
    echo "test-driver-shapes: FAILED — $FAILURES of $SHAPES build routes are broken" >&2
    echo "  A stanza passing proves its own route." >&2
    exit 1
fi
echo "test-driver-shapes: all $SHAPES build routes passed"
