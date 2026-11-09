#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# check-esctest.sh — esctest2's verdict, compared as a SET rather than a count.
#
#   ./Scripts/check-esctest.sh                     the default profile
#   ./Scripts/check-esctest.sh --profile macos-local
#   ./Scripts/check-esctest.sh --profile linux-container [--native]
#   ./Scripts/check-esctest.sh --update            rewrite the baseline from this run
#
# The linux-container profile runs Scripts/run-esctest-linux.sh, the GTK
# frontend under Xvfb with no window manager, in run-linux.sh's container or,
# with --native, on this machine; every other profile runs the macOS app through
# Scripts/run-esctest.sh.
#
# esctest2 is the only instrument here that reads the screen from outside the
# whole stack: it runs as a child process over a real PTY and reads cells back
# with DECRQCRA, so it sees the composition of parser, capability gate, daemon
# and frontend that every in-process tier is blind to by construction. A tier
# reporting all passed on a tree where a browser client fails 255 cases is not a
# hypothetical — it is what Docs/ecma48_conformance.md records.
#
# Why a set and not a count. The suite has failures that are not defects:
# divergences where it encodes one xterm's behaviour and Ubiquitty follows the
# specification. A count hides a swap — one new regression arriving as one old
# divergence is fixed reads as no change at all. The set does not:
#
#   a case fails that the baseline does not list  -> FAIL, a new regression
#   a listed case passes                          -> FAIL, delete its line
#   the sets match                                -> pass, and say which cases
#
# The second rule is what stops the baseline rotting into an allowlist. A fix
# cannot quietly leave a stale entry behind, because the stale entry is itself
# the failure.
#
# Why the profile is part of the FILENAME. A score measures a target at a
# capability posture, not Core: the same suite commit against the same Core
# answers 517/3/35 for the macOS app at origin Local and 272/255 for a browser
# through the daemon, because respond() drops any reply whose capability is
# non-Allow at the current origin. Two profiles compared against one baseline
# would report the posture difference as a regression.
#

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
PROFILE="macos-local"
UPDATE=0
NATIVE=0
# How many times --update runs the suite before writing a baseline.
#
# One run cannot tell a deterministic failure from a flaky one, and the two need
# opposite treatment: a stable failure is the baseline, a flaky case compared
# against any baseline reports a regression on the runs where it passes and a
# fix on the runs where it fails. Measured here, three runs of one binary
# produced three different failing sets — the window-op cases depend on timing
# the suite itself hedges (DelayAfterResize, GetPixelErrorLimit).
#
# A gate that fires for a reason it does not have is the one people learn to
# skip, so the flaky set is named and excluded rather than averaged in.
RUNS=3
PASSTHROUGH=()

while [ $# -gt 0 ]; do
    case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    --native) NATIVE=1; shift ;;
    --self-test) SELFTEST=1; shift ;;
    --runs) RUNS="$2"; shift 2 ;;
    --) shift; PASSTHROUGH=("$@"); break ;;
    -h|--help) sed -n '6,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "check-esctest: unknown argument: $1" >&2; exit 2 ;;
    esac
done

BASELINE="$ROOT/Tests/Esctest/known-failing-$PROFILE.txt"
RUNNER=("$ROOT/Scripts/run-esctest.sh")
LOG="$ROOT/BuildEsctest/esctest.log"
if [ "$PROFILE" = "linux-container" ]; then
    # shellcheck source=Scripts/build-root.sh
    . "$CORE_ROOT/Scripts/build-root.sh"
    RUNNER=("$ROOT/Scripts/run-esctest-linux.sh")
    [ "$NATIVE" = "1" ] && RUNNER+=(--native)
    LOG="$UBQ_BUILD_ROOT/linux-container/esctest-linux.log"
elif [ "$NATIVE" = "1" ]; then
    echo "check-esctest: --native runs the linux-container profile only" >&2
    exit 2
fi

# The suite commit is part of the comparison, not a note about it: esctest2 adds
# and retires cases, so a baseline taken at one commit describes a different
# population from the one a later checkout runs. Recorded in the baseline file
# and asserted here, because a set comparison across two populations reports
# arrivals and departures as regressions and fixes.
# The checkout run-esctest.sh resolves, in the same order.
esctestCheckout() {
    if [ -n "${ESCTEST2_DIR:-}" ]; then
        [ -f "$ESCTEST2_DIR/esctest/esctest.py" ] && printf '%s\n' "$ESCTEST2_DIR"
        return
    fi
    local candidate
    for candidate in "${UBIQUITTY_ESCTEST:-}" "$HOME/Projects/esctest2" "$ROOT/vendor/esctest2" "$ROOT/Tools/esctest2"; do
        [ -n "$candidate" ] && [ -f "$candidate/esctest/esctest.py" ] && { printf '%s\n' "$candidate"; return; }
    done
}

suiteCommit() {
    local dir
    dir="$(esctestCheckout)"
    [ -n "$dir" ] && git -C "$dir" rev-parse --short HEAD 2>/dev/null
}

# The failing set from a log, cross-checked against the count esctest2 prints.
#
# The set is read by keying on the `Failing tests:` header and the
# `ClassName.test_` case spelling. A report that reformats either — an esctest2
# bump is the occasion the header comment names — collapses the set to empty
# while the run failed, and an empty set compared against an empty baseline reads
# as ok, which is the silence a conformance oracle cannot afford. The summary's
# `K TESTS FAILED` is written on a different line from the section, so it survives
# a reformat of the section and pins the count the parse must reproduce. When the
# two disagree the parse is not to be trusted, so this refuses rather than hand
# back a set the comparison would read as a verdict.
#
# Leaves the failing set on stdout, one case per line; returns non-zero on drift.
parseFailing() {
    local log="$1" parsed count reported
    parsed="$(sed -n '/^Failing tests:/,$p' "$log" | grep -E '^[A-Za-z_][A-Za-z0-9_]*\.test_' | sort -u)"
    count="$(printf '%s' "$parsed" | grep -c .)"
    # esctest2 spells it "K TESTS FAILED"; a clean run omits the clause, so an
    # absent count is zero failures rather than a drift.
    reported="$(grep -m1 'tests passed' "$log" | grep -oiE '[0-9]+ tests? failed' | grep -oE '^[0-9]+' | head -1)"
    if [ -n "$reported" ] && [ "$reported" != "$count" ]; then
        echo "check-esctest: parsed $count failing case(s) but esctest2 reports $reported failed —" >&2
        echo "  the report format drifted (the 'Failing tests:' section or the ClassName.test_" >&2
        echo "  spelling changed), so the failing set is empty or short for a reason that is not" >&2
        echo "  the tree. A comparison against the baseline here would be a false verdict; fix the" >&2
        echo "  parser against the current esctest2 output." >&2
        return 1
    fi
    printf '%s\n' "$parsed"
}

# One suite run. Leaves the failing set on stdout, one case per line.
runOnce() {
    if ! "${RUNNER[@]}" ${PASSTHROUGH+-- "${PASSTHROUGH[@]}"} > /dev/null 2>&1; then
        return 1
    fi
    grep -q 'tests passed' "$LOG" 2>/dev/null || return 1
    parseFailing "$LOG"
}

if [ "${SELFTEST:-0}" = "1" ]; then
    t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
    printf 'boot\n519 tests passed, 36 known bugs, 2 TESTS FAILED\nFailing tests:\nATests.test_a\nBTests.test_b\n' > "$t/normal"
    got="$(parseFailing "$t/normal")" || { echo "self-test: a well-formed report was refused" >&2; exit 1; }
    [ "$(printf '%s' "$got" | grep -c .)" = "2" ] || { echo "self-test: a well-formed report parsed $(printf '%s' "$got" | grep -c .) not 2" >&2; exit 1; }
    printf 'boot\n519 tests passed, 36 known bugs, 2 TESTS FAILED\n=== Failures ===\nATests.test_a\nBTests.test_b\n' > "$t/drift"
    if parseFailing "$t/drift" >/dev/null 2>&1; then echo "self-test: a reformatted failing section was not refused" >&2; exit 1; fi
    printf 'boot\n533 tests passed, 36 known bugs\n' > "$t/clean"
    got="$(parseFailing "$t/clean")" || { echo "self-test: a clean run was refused" >&2; exit 1; }
    [ -z "$(printf '%s' "$got" | grep -c . | grep -v '^0$')" ] || { echo "self-test: a clean run parsed a non-empty set" >&2; exit 1; }
    echo "check-esctest --self-test: ok (the count cross-check catches a reformatted failing section)"
    exit 0
fi

# runOnce discards run-esctest.sh's output, so a missing suite is named here
# rather than reported as a run with no verdict.
if [ -z "$(esctestCheckout)" ]; then
    echo "check-esctest: esctest2 checkout not found." >&2
    echo "  Clone it: git clone https://github.com/ThomasDickey/esctest2 vendor/esctest2" >&2
    echo "  or point UBIQUITTY_ESCTEST (or ESCTEST2_DIR) at an existing checkout." >&2
    exit 2
fi

echo "check-esctest: profile $PROFILE"

if [ "$UPDATE" = "1" ]; then
    # Classify across runs. A case failing in every run is a stable failure and
    # belongs in the baseline; a case failing in some is flaky, and comparing it
    # against any baseline reports a regression on the runs where it passes.
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    for i in $(seq 1 "$RUNS"); do
        echo "  run $i of $RUNS"
        if ! runOnce > "$tmp/run$i"; then
            echo "check-esctest: run $i produced no verdict — baseline not written" >&2
            exit 1
        fi
        [ "$i" = "1" ] && summary="$(grep -m1 'tests passed' "$LOG" | tr -d '*' | sed 's/^ *//;s/ *$//')"
    done
    commit="$(suiteCommit)"

    cat "$tmp"/run* | sort -u > "$tmp/union"
    cp "$tmp/run1" "$tmp/stable"
    for i in $(seq 2 "$RUNS"); do
        comm -12 "$tmp/stable" "$tmp/run$i" > "$tmp/next" && mv "$tmp/next" "$tmp/stable"
    done
    comm -23 "$tmp/union" "$tmp/stable" > "$tmp/flaky"

    mkdir -p "$(dirname "$BASELINE")"
    {
        echo "# esctest2 cases that fail for profile: $PROFILE"
        echo "#"
        echo "# NOT a list of things to ignore. It exists so the suite can still detect"
        echo "# change: a permanently-red case that nobody compares against makes a NEW"
        echo "# regression invisible, and a red line nobody can act on trains people to"
        echo "# stop reading the whole report."
        echo "#"
        echo "# Both directions fail. A case failing that is absent here is a regression;"
        echo "# a case listed here that passes is a stale entry, and deleting it is the"
        echo "# fix. The second rule is what keeps this from becoming an allowlist."
        echo "#"
        echo "# suite-commit $commit"
        echo "# taken-from   $summary"
        echo "# runs         $RUNS"
        echo "#"
        cat "$tmp/stable"
        if [ -s "$tmp/flaky" ]; then
            echo ""
            echo "# FLAKY — failed in some runs and not others, on ONE binary. Excluded"
            echo "# from the comparison in both directions, because a case that changes"
            echo "# answer by itself reports a regression half the time and a fix the"
            echo "# other half, and a gate that fires without a cause is one people learn"
            echo "# to skip. Listed rather than dropped so the flakiness stays visible:"
            echo "# these are the cases to make deterministic, not to forget."
            while read -r c; do echo "?$c"; done < "$tmp/flaky"
        fi
    } > "$BASELINE"
    echo "check-esctest: baseline written — $(grep -c . "$tmp/stable") stable, $(grep -c . "$tmp/flaky") flaky"
    echo "  $BASELINE"
    exit 0
fi

observed="$(runOnce)" || { echo "check-esctest: the suite produced no verdict" >&2; exit 1; }
summary="$(grep -m1 'tests passed' "$LOG" | tr -d '*' | sed 's/^ *//;s/ *$//')"
commit="$(suiteCommit)"

if [ ! -f "$BASELINE" ]; then
    echo "check-esctest: no baseline for profile '$PROFILE'." >&2
    echo "  Take one with: ./Scripts/check-esctest.sh --profile $PROFILE --update" >&2
    exit 1
fi

expectedCommit="$(grep -m1 '^# suite-commit' "$BASELINE" | awk '{print $3}')"
if [ -n "$expectedCommit" ] && [ -n "$commit" ] && [ "$expectedCommit" != "$commit" ]; then
    echo "check-esctest: the suite moved — baseline was taken at $expectedCommit, this checkout is $commit." >&2
    echo "  esctest2 adds and retires cases, so the two runs describe different" >&2
    echo "  populations and a set comparison would report arrivals as regressions." >&2
    echo "  Re-take the baseline at this commit, or check out $expectedCommit." >&2
    exit 1
fi

baseline="$(grep -vE '^\s*#|^\s*$|^\?' "$BASELINE" | sort -u)"
flaky="$(grep -E '^\?' "$BASELINE" | sed 's/^?//' | sort -u)"
# Remove the flaky cases from what was observed too, or a flaky case failing
# today reads as a regression and passing tomorrow reads as a stale entry.
[ -n "$flaky" ] && observed="$(comm -23 <(printf '%s\n' "$observed") <(printf '%s\n' "$flaky"))"
newlyFailing="$(comm -23 <(printf '%s\n' "$observed") <(printf '%s\n' "$baseline") | grep -c .)"
newlyPassing="$(comm -13 <(printf '%s\n' "$observed") <(printf '%s\n' "$baseline") | grep -c .)"

if [ "$newlyFailing" != "0" ]; then
    echo "check-esctest: $newlyFailing case(s) fail that the baseline does not list:" >&2
    comm -23 <(printf '%s\n' "$observed") <(printf '%s\n' "$baseline") | sed 's/^/    /' >&2
fi
if [ "$newlyPassing" != "0" ]; then
    echo "check-esctest: $newlyPassing baseline case(s) now pass — delete their lines:" >&2
    comm -13 <(printf '%s\n' "$observed") <(printf '%s\n' "$baseline") | sed 's/^/    /' >&2
fi
if [ "$newlyFailing" != "0" ] || [ "$newlyPassing" != "0" ]; then
    echo "  baseline: $BASELINE" >&2
    exit 1
fi

echo "check-esctest: ok — $summary"
echo "  failing set unchanged ($(printf '%s\n' "$baseline" | grep -c .) known), suite $commit"
