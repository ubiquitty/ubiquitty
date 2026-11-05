#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# check-linux-smokes.sh — run every GTK smoke and require it to pass.
#
# A passing smoke prints PASS (or its dump-png success marker) and exits zero.
# A printed FAIL or a nonzero exit fails the gate, as does a missing verdict or
# a verdict that disagrees with the exit code. The summary counts failures,
# disagreements and silent verdicts separately; classes can overlap.
#
# The mode list is derived from the source rather than written here. A hand list
# covers the modes someone remembered, which is the failure this file exists to
# stop repeating one level up.
#
# Usage: ./Scripts/check-linux-smokes.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"

# What a stand-down leaves uncovered, sized against the branch.
#
# "A green here does not cover the GTK smokes" is true on every machine, so it
# tells a reader nothing about the change in front of them. The cost of skipping
# is not constant: it is nothing for a change to the macOS renderer and it is the
# whole gate for a change to the GTK frontend, and both print the same word.
#
# A worktree is the common case rather than the exotic one — its build directory
# starts empty, so the reader most likely to see this line is one that has just
# started work rather than one with an unusual machine.
#
# Against the merge base, never origin/main's tip: a diff against the tip
# attributes to this branch every file someone else moved since it forked.
uncoveredByASkip()
{
    local base
    base="$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null)" || return 0
    [ -n "$base" ] || return 0
    git -C "$ROOT" diff --name-only "$base"...HEAD -- \
        Source/Platform/Linux Source/Core 2>/dev/null
}

reportSkip()
{
    echo "check-linux-smokes: SKIPPED — $1" >&2
    local touched
    touched="$(uncoveredByASkip)"
    if [ -n "$touched" ]; then
        echo "  This branch changes $(echo "$touched" | wc -l | tr -d ' ') file(s) the GTK smokes exercise," \
            "and none of them ran:" >&2
        echo "$touched" | sed 's/^/    /' >&2
    else
        echo "  This branch changes nothing under Source/Platform/Linux or Source/Core," >&2
        echo "  so the GTK smokes had nothing of its to say." >&2
    fi
    exit 0
}

# Standing down rather than failing when the container is unavailable: a gate
# that fails for the machine it sits on is one people switch off. The verdict
# says which of the two it is, because "clean" and "never ran" are otherwise the
# same output.
# The same switch the Linux push gate reads. This one runs inside check-style, so
# it starts a container on every push rather than on the Linux tier alone —
# pausing pre-push-gates and stopping there leaves the container running for
# everybody, which is what it did.
if [ "${UBIQUITTY_LINUX_GATE:-on}" = "off" ]; then
    reportSkip "the Linux container is paused (UBIQUITTY_LINUX_GATE=off pauses it)."
fi

# A Linux host that answers (Scripts/linux-host.sh) runs CI's own two stages, the
# frontend build and the smoke battery, on a machine with a GPU driver the
# dma-buf smokes need. The container logic below is for a machine with no host:
# it checks a binary built in this checkout's container, and here the binary is
# built from this tree on the host, so there is nothing stale to guard against.
linuxRoute="${UBQ_LINUX_HOST_ROUTE:-$("$ROOT/Scripts/linux-host.sh" route)}"
case "$linuxRoute" in
    "host "*)
        linuxHost="${linuxRoute#host }"
        hostLog="$(mktemp)"
        if "$ROOT/Scripts/linux-host.sh" stages linux-build linux-smokes >"$hostLog" 2>&1; then
            hostSummary="$(grep -E '^run-linux-smokes: [0-9]+ passed' "$hostLog" | tail -n 1 | sed 's/^run-linux-smokes: //')"
            rm -f "$hostLog"
            echo "check-linux-smokes: ok (on $linuxHost: $hostSummary; no verdict/exit disagreements or silent verdicts)"
            exit 0
        fi
        grep -vE '^  ok ' "$hostLog" | tail -n 60 >&2
        rm -f "$hostLog"
        echo "check-linux-smokes: FAILED — the GTK smokes did not all pass on $linuxHost." >&2
        exit 1
        ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    reportSkip "docker is not installed (install OrbStack or Docker Desktop), so the GTK build cannot run."
fi

# The client binary being on PATH is not the runtime being up. With the Docker
# provider (OrbStack or Docker Desktop) stopped, `command -v docker` succeeds, the build below fails silently, and the
# staleness check then reports a binary older than its source -- which reads as
# a tree that needs rebuilding rather than a runtime that is not running. There
# is no path forward from that message: the rebuild it asks for is the thing
# that cannot happen. An absent binary already skips; a stale one with no way to
# refresh it must skip for the same reason.
if ! docker info >/dev/null 2>&1; then
    reportSkip "the container runtime is not running, so the GTK build cannot run."
fi

binary="$UBQ_BUILD_ROOT/linux-container/linux/ubiquitty-linux"
if [ ! -x "$binary" ]; then
    reportSkip "no GTK build in this checkout (run ./Scripts/run-linux.sh)."
fi

# Build before running, then check the binary is actually newer than the source.
#
# Without this the gate reports on whatever binary happens to be present and
# calls it the tree's behaviour: a binary minutes older than the sources reports
# defects the tree it is run against has already fixed.
#
# The rebuild is not enough on its own. This container's ninja intermittently
# reports "no work to do" for a file that changed, so the timestamp is checked
# after the build rather than the build's exit code being trusted. A binary
# still older than the newest source after a build is that skip, and it is worth
# failing on rather than reporting whatever the old one says.
#
# An mtime is not identity — a binary from another branch can be newer than
# every source here. It is what is available without a build id, and it catches
# the case that actually happens: a build that did not run.
# The build, and the build's own account of what it compiles, in one container
# start — each one costs seconds, and this runs before every push.
buildInputs="$(mktemp)"
trap 'rm -f "$buildInputs"' EXIT
# `-t deps` as well as `-t inputs`: the first answers which translation units this
# binary compiles, the second which headers they reached. Without the second the
# header population is "everything under Source/", which is not derived from
# anything and refuses permanently on a header no Linux unit includes.
"$ROOT/Scripts/run-linux.sh" sh -c \
    'ninja -C build/linux >/dev/null 2>&1; ninja -C build/linux -t inputs ubiquitty-linux 2>/dev/null; ninja -C build/linux -t deps 2>/dev/null' \
    > "$buildInputs" 2>/dev/null || true

# The comparison is against the sources this build compiles, which is a smaller
# set than every source in the tree.
#
# `git ls-files Source/` includes Source/Platform/macOS, and ninja never names an
# .mm. A macOS-only commit therefore advances the newest source without giving
# ninja anything to do, the binary correctly does not move, and a guard reading
# the whole tree refuses from then on — permanently, because the remedy it prints
# is a rebuild and a rebuild is not what is missing. That lands on every checkout that
# rebases past a macOS commit, which is most rebases.
#
# The excluded set is derived rather than listed: a platform directory ninja's
# input list never names is one this build does not compile. Naming macOS here
# would be right today and wrong the first time a frontend is added or removed,
# which is the same defect one level up.
#
# The cut is by directory rather than by the input list itself, because that list
# is translation units and carries no headers — a header is discovered through a
# depfile and never appears. Directories are the coarser cut, and they keep every
# header of a compiled frontend in the population, which matters for the case
# this check exists for: a ninja that skips an edit, where the header is newer
# than the binary and nothing else says so.
#
# An empty input list means ninja did not answer. Excluding nothing is the safe
# reading of that — the guard falls back to the whole tree and can only be too
# strict, never too lax.
# By translation unit and by header, which is what ninja can answer exactly and a
# directory cannot.
#
# A directory cut works only where every unit under it falls the same way, and
# Core is not like that: Source/Core/Protocol has Tmux compiled and Sync not, so
# no depth of directory glob separates them. 29 of Core's 166 units are in no
# Linux binary, and a comment edit in one of them refused this guard permanently
# with a message saying rebuild.
#
# Headers were left in the population wholesale on the reasoning that a header
# arrives through a depfile and so cannot be dropped by a rule that only excludes
# units. That is true and it is the wrong conclusion: a header no Linux unit
# includes is newer than a binary that correctly does not contain it, and no
# rebuild can ever clear it. Core/Protocol/Tmux/StateRecovery.h is one — its only
# includers are a macOS .mm and two tests.
#
# The depfile is what distinguishes them, so the depfile is what the population
# comes from. A header a Linux unit really includes appears in `-t deps` and still
# refuses when it is newer than the binary, which is the case this guard exists
# for: a ninja that skipped an edit.
#
# An empty ninja answer means ninja did not run. Excluding nothing is the safe
# reading — the guard falls back to the whole tree and can only be too strict.
newestSource="$(git -C "$ROOT" ls-files -z Source/ \
    | python3 -c '
import os, sys

root, ninjaAnswer = sys.argv[1], sys.argv[2]
compiled = set()
try:
    with open(ninjaAnswer, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            # `-t inputs` prints one path per line; `-t deps` indents each
            # dependency under an output header line ending in `)`. Both reduce
            # to "a path mentioned by ninja", which is the whole question.
            for token in line.strip().rstrip(":").split():
                if "/" in token:
                    compiled.add(token)
except OSError:
    pass

def isCompiled(name):
    # Ninja names paths as the container sees them (/src/...) and relative to the
    # build directory. Suffix matching answers both without knowing which.
    return any(entry == name or entry.endswith("/" + name) for entry in compiled)

newest = 0
for path in sys.stdin.buffer.read().split(b"\0"):
    name = path.decode("utf-8", "replace")
    if not name:
        continue
    if compiled and not isCompiled(name):
        continue
    try:
        newest = max(newest, int(os.stat(os.path.join(root, name)).st_mtime))
    except OSError:
        pass
print(newest or "")
' "$ROOT" "$buildInputs")"
# python3, not stat. `stat -f` is a modification time to BSD stat and a
# FILESYSTEM report to GNU stat, which a developer Mac has as soon as anything
# pulls in coreutils: the flag succeeds, prints a block of filesystem
# statistics, and the comparison below then errors out and reads as false. The
# guard went quiet exactly where the sources it guards get edited.
binaryStamp="$(python3 -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$binary" 2>/dev/null || echo "")"
if [ -z "$binaryStamp" ]; then
    echo "check-linux-smokes: FAILED — cannot read the GTK binary's timestamp at $binary." >&2
    echo "  Without it nothing here can tell a fresh verdict from a stale one." >&2
    exit 1
fi
if [ -n "$newestSource" ] && [ "$binaryStamp" -lt "$newestSource" ]; then
    echo "check-linux-smokes: FAILED — the GTK binary is older than the newest source after a build." >&2
    echo "  binary $(date -r "$binaryStamp" '+%Y-%m-%d %H:%M:%S'), source $(date -r "$newestSource" '+%Y-%m-%d %H:%M:%S')." >&2
    echo "  Every verdict below would describe a tree that is not this one." >&2
    exit 1
fi

# Every mode the frontend dispatches, taken from the dispatch itself.
modes=$(grep -oE '"--smoke-[a-z-]+"' "$ROOT/Source/Platform/Linux/main.cpp" \
    | tr -d '"' | sed 's/^--smoke-//' | sort -u)
if [ -z "$modes" ]; then
    echo "check-linux-smokes: FAILED — no --smoke- modes found in the frontend; the derivation broke." >&2
    exit 1
fi

# Every mode runs in ONE container: each invocation is several seconds of
# startup, and thirty-three of those is the difference between a gate someone
# runs and one they do not.
report="$("$ROOT/Scripts/run-linux.sh" xvfb-run -a sh -c '
    for mode in '"$(echo "$modes" | tr "\n" " ")"'; do
        output=$(./build/linux/ubiquitty-linux --smoke-"$mode" 2>&1)
        code=$?
        output=$(printf "%s\n" "$output" | grep -vE "glyph font")
        verdict=none
        # Mesa diagnostics can contain VK_ERROR_INITIALIZATION_FAILED even
        # when another renderer succeeds. Read the verdict word itself.
        if printf "%s\n" "$output" | grep -qw FAIL; then
            verdict=fail
        elif printf "%s\n" "$output" | grep -qw PASS; then
            verdict=pass
        elif printf "%s\n" "$output" | grep -q dump-png; then
            verdict=pass
        fi
        lastFailLine=
        if [ "$verdict" = fail ]; then
            lastFailLine=$(printf "%s\n" "$output" | grep -w FAIL | tail -n 1 | tr "\t\r" "  ")
        fi
        printf "%s %s %s %s\n" "$mode" "$verdict" "$code" "$lastFailLine"
    done
' 2>/dev/null | grep -E '^[a-z-]+ (none|pass|fail) [0-9]+( |$)')"

total=0
failed=0
disagreed=0
silent=0
while read -r mode verdict code lastFailLine; do
    [ -z "$mode" ] && continue
    total=$((total + 1))
    if [ "$verdict" = fail ] || [ "$code" -ne 0 ]; then
        failed=$((failed + 1))
        if [ -n "$lastFailLine" ]; then
            echo "check-linux-smokes: --smoke-$mode failed (exit $code): $lastFailLine" >&2
        else
            echo "check-linux-smokes: --smoke-$mode failed (exit $code; no FAIL line)." >&2
        fi
    fi
    case "$verdict:$code" in
        fail:0)
            echo "check-linux-smokes: --smoke-$mode printed FAIL and returned 0 — every caller reads success." >&2
            disagreed=$((disagreed + 1))
            ;;
        # A FAIL with nonzero exit agrees, but still fails the gate above.
        fail:*) ;;
        pass:0) ;;
        pass:*)
            echo "check-linux-smokes: --smoke-$mode printed PASS and returned $code." >&2
            disagreed=$((disagreed + 1))
            ;;
        none:*)
            echo "check-linux-smokes: --smoke-$mode printed no verdict — a reader cannot tell what it decided." >&2
            silent=$((silent + 1))
            ;;
        *)
            echo "check-linux-smokes: --smoke-$mode returned $code with no passing verdict." >&2
            disagreed=$((disagreed + 1))
            ;;
    esac
done <<< "$report"

if [ "$total" -eq 0 ]; then
    echo "check-linux-smokes: FAILED — the container produced no results for $(echo "$modes" | wc -w | tr -d ' ') mode(s)." >&2
    exit 1
fi

# A pass requires every smoke to pass, to print a verdict, and to agree with
# its exit code. Failure classes overlap when a smoke prints FAIL but exits zero
# or prints PASS but exits nonzero.
if [ "$failed" -gt 0 ] || [ "$disagreed" -gt 0 ] || [ "$silent" -gt 0 ]; then
    echo "check-linux-smokes: FAILED — $failed failing smoke(s), $disagreed verdict/exit disagreement(s)," \
        "$silent silent verdict(s), across $total smoke(s)." >&2
    exit 1
fi

echo "check-linux-smokes: ok ($total smoke(s) passed; no verdict/exit disagreements or silent verdicts)"
