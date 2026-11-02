#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Scripts/check-merged-main.sh — build what the merge actually produced.
#
# Usage:
#   ./Scripts/check-merged-main.sh            # after gh pr merge --rebase
#   ./Scripts/check-merged-main.sh <ref>      # any ref, for bisecting a break
#
# the gap this closes
#
# A rebase merge does not rebuild. A pull request is verified against its own
# merge-base; the rebase replays it onto whatever landed in the meantime, and no
# build ever runs on the result. Two changes that never touch each other's text
# replay with no conflict and can still combine into something that compiles
# nowhere — one adds a parameter to a function, the other splits that function
# in two, and the body ends up reading a parameter belonging to its sibling.
#
# Both contributing branches are green while main is broken. To check this
# script still detects a break, replay two branches built that way onto a
# scratch main.
#
# No local gate can see this class. A pre-push hook measures the tree the author
# had, which stops existing at the rebase. The post-merge commit is the only
# place the combination is observable, and building it is the only way to look.
#
# Why not CI
#
# It belongs there too. It is here because a rebase merge builds nothing, and the
# commits it lands have coexisted only in this checkout — so the machine holding
# them is the one that can say whether they build together. A check that runs
# only where the author is not gives a verdict that arrives after the push it
# should have stopped.
# When they are on, this becomes redundant and should be deleted rather than
# left to rot beside the thing that replaced it.
#
# What this does not build
#
# Tests/. UBIQUITTY_BUILD_TESTS defaults off and cannot be turned on in this
# configuration: CMakeLists.txt makes it a fatal error beside NDEBUG, because
# CellGrid.h declares members under #ifndef NDEBUG and the two halves would
# disagree about sizeof(CellGrid). RelWithDebInfo carries NDEBUG, so reaching
# the test tree takes a second configure at Debug — Scripts/build-tests.sh —
# which is a different build rather than a flag on this one.
#
# So the combination class this script exists for is closed for what ships and
# open for Tests/. Pre-push does compile the test tree, but against the tree the
# author had, which is the vantage point that stops existing at the rebase: two
# branches whose tests each compile alone can still combine into a Tests/ that
# does not, and the argument for that is the same one made above for Source/.
# Measured on a main where it compiles clean, so this names a hole in the
# coverage rather than a break waiting in it. Closing it costs a second full
# build per run, and this staying cheap is what decides whether it gets run.

set -uo pipefail

# git exports these into a hook's environment and they OVERRIDE the repository a
# git command discovers from its directory — `git -C <tree>` included, because -C
# sets the working directory and an explicit GIT_DIR skips discovery entirely. A
# push from a linked worktree would aim the destructive git below at the PUSHING
# worktree instead of the one named here.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# How many compilers this machine can run at once; see Scripts/build-jobs.sh.
# shellcheck source=Scripts/build-jobs.sh
. "$ROOT/Scripts/build-jobs.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
cd "$ROOT" || exit 1

REF="${1:-origin/main}"

# Fetch only when checking a remote ref: bisecting a local commit should not
# move the world under the person bisecting.
if [[ "$REF" == origin/* ]]; then
    git fetch -q origin || {
        echo "check-merged-main: cannot reach origin — checking the local ref instead." >&2
    }
fi

if ! COMMIT="$(git rev-parse --verify --quiet "$REF^{commit}")"; then
    echo "check-merged-main: no such ref: $REF" >&2
    exit 2
fi

SUBJECT="$(git log -1 --format='%s' "$COMMIT")"
echo "check-merged-main: $REF at ${COMMIT:0:9} — $SUBJECT"

# A dedicated build directory. Sharing one with build-host.sh is how a Release
# tree came to be silently reconfigured to Debug and stayed that way for three
# hours, and a verification build has no business changing what anyone else's
# next build produces.
BUILD_DIR="$UBQ_BUILD_ROOT/merged-main"

# The logs go in the same per-checkout root. A fixed path under /tmp would be
# shared by every checkout on the machine, and two runs at once would write
# over each other's evidence.
CONFIGURE_LOG="$UBQ_BUILD_ROOT/merged-main-configure.log"
LOG="$UBQ_BUILD_ROOT/merged-main-build.log"

# A worktree rather than a checkout, because this runs in a tree that usually
# has work in it. Checking out over that work is a data-loss bug wearing a
# verification script's clothes.
#
# A STABLE path, not a fresh mktemp per run. CMake records the source directory
# in its cache and refuses a build directory generated from a different one, so
# a new temp path each time makes every run after the first fail to configure —
# which this script would then report as a broken main. A verifier with a false
# positive is worse than no verifier, because the first thing anyone does with
# it is stop believing it. The stable path also makes runs incremental, which is
# what decides whether this gets run at all.
WORKTREE="$UBQ_BUILD_ROOT/merged-main-src"

# What the previous run built, so a run at a NEW commit starts from nothing.
#
# Incremental across a commit is what this script must not be. Ninja tracks
# file inputs, and a Swift target's inputs do not include the module interface
# another target emitted — so a commit that moves that interface leaves the
# previous one on disk, the consumer compiles against it, and the build fails
# naming a member that is present and public in both commits. What was built
# is then a mixture of two trees, which is the one thing a script called
# "build what the merge actually produced" may not report on.
#
# It reports the failure as the commit's, and the commit is innocent: the same
# commit builds green in an isolated worktree, and the report sends its reader
# hunting a Swift import bug that does not exist. The inverse of the same cause
# is the false green — an incremental run does not recompile the consumer at
# all, so no smoke covers that module.
#
# A repeat run at the same commit stays incremental, which is what keeps this
# cheap enough to be run at all.

# The configuration this verifies: the one a merge ships.
#
# Every release, measurement and snapshot arm is RelWithDebInfo. Verifying
# Debug here would let a rebase-combination break in what we ship pass, and
# stop every checkout with "MAIN IS BROKEN. Every checkout pulls this." over a
# fault in a configuration we do not ship. That is the wrong way round for a
# gate whose subject is the merge.
#
# Debug is not unused: build-macos.sh's --asan option selects it, so the
# sanitizer arm is a Debug build and a Debug break makes ASan on macOS
# unusable. A Debug break can also sit in the Swift compilation mode rather
# than in the merged code, which is not a break in anything that landed.
#
# So the split: this gate answers "does the merge build what we ship", and the
# sanitizer configuration is its own arm's to verify.
BUILD_TYPE="RelWithDebInfo"

# Keyed on the configuration as well as the commit: changing either makes the
# objects on disk answer a different question from the one being asked.
STAMP="$BUILD_DIR/.verified-commit"
if [[ ! -f "$STAMP" ]] || [[ "$(cat "$STAMP" 2>/dev/null)" != "$COMMIT $BUILD_TYPE" ]]; then
    rm -rf "$BUILD_DIR"
fi

if [[ -d "$WORKTREE" ]] && git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$WORKTREE" checkout -q --detach "$COMMIT" 2>/dev/null; then
        echo "check-merged-main: could not move the verification worktree to $COMMIT" >&2
        exit 2
    fi
else
    rm -rf "$WORKTREE"
    git worktree prune
    if ! git worktree add --detach -q "$WORKTREE" "$COMMIT" 2>/dev/null; then
        echo "check-merged-main: could not create a worktree at $COMMIT" >&2
        exit 2
    fi
fi

echo "check-merged-main: configuring…"
if ! cmake -S "$WORKTREE" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -G Ninja >"$CONFIGURE_LOG" 2>&1; then
    echo "check-merged-main: CONFIGURE FAILED" >&2
    tail -25 "$CONFIGURE_LOG" >&2
    echo "  full log: $CONFIGURE_LOG" >&2
    exit 1
fi

# Which commit's objects this directory now holds. Written before the build
# and whatever the build reports, because it records what is ON DISK rather
# than what verified: a run that fails leaves this commit's artifacts, and
# re-running at the same commit may reuse them. The success stamp below
# answers a different question and is written only when the build passes.
echo "$COMMIT $BUILD_TYPE" > "$STAMP" 2>/dev/null || true

echo "check-merged-main: building…"
cmake --build "$BUILD_DIR" -j"$(ubq_build_jobs)" >"$LOG" 2>&1
STATUS=$?

# The exit code and the error count, because a build that fails partway can
# still leave a previous binary in place, and reading a stale binary's output as
# this run's result is the trap this repository has hit more than once.
# `grep -c` prints 0 and exits 1 when it matches nothing, so `|| echo 0` appends
# a SECOND line and the arithmetic below dies with a syntax error on every clean
# run. The verdict survived only because `||` short-circuits on a nonzero exit
# status and never reached the broken operand — reorder those two and it starts
# reporting a failed build as ok. Assign on failure instead, so this stays one
# number and the check does not depend on which side of an `||` it sits.
ERRORS="$(grep -cE '(^|[[:space:]])error:' "$LOG" 2>/dev/null)" || ERRORS=0

# A compiler that crashes is not a tree that is wrong. swiftc prints
# "error: compile command failed due to signal 11" and asks for a bug report,
# which counts as an error line and reads as a broken main — and the same tree
# builds clean when the machine is quieter, so the verdict would be a property
# of the load rather than of the commit.
#
# Reported as its own outcome rather than folded into either. Calling it broken
# names the wrong cause for whoever reads it next; calling it clean claims a
# build that did not finish.
CRASHED=0
if grep -qE 'due to signal [0-9]+|Please submit a bug report' "$LOG" 2>/dev/null; then
    CRASHED=1
fi

if [[ $STATUS -ne 0 || $ERRORS -gt 0 ]]; then
    echo
    echo "check-merged-main: MAIN IS BROKEN at ${COMMIT:0:9} ($ERRORS error line(s), exit $STATUS)"
    echo "  Every checkout pulls this. Fixing it outranks whatever you were doing."
    if [[ $CRASHED -eq 1 ]]; then
        # A crash is still a break: a tree nothing can compile is broken
        # whatever killed the compiler. Said separately because the error line
        # names no source file — swiftc builds the module with -wmo, so the
        # whole module is one job and the diagnostic points at the job.
        echo
        echo "  The compiler crashed rather than diagnosing. There is no file in"
        echo "  the error because -wmo makes the module a single compile; narrow"
        echo "  it by splitting the module or dropping -wmo to get a name."
    fi
    echo
    grep -E '(^|[[:space:]])error:' "$LOG" | head -15
    echo
    echo "  full log: $LOG"
    exit 1
fi

# The commit this verified, so something else can tell whether main has moved
# past it. Written only on success: a stamp recording a build that failed would
# read as a verification, which is the distinction the whole script is about.
mkdir -p "$UBQ_BUILD_ROOT" 2>/dev/null || true
echo "$COMMIT" > "$UBQ_BUILD_ROOT/.merged-main-verified" 2>/dev/null || true

echo "check-merged-main: ok — ${COMMIT:0:9} builds clean"
