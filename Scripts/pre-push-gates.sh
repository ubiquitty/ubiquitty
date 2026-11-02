#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# Scripts/pre-push-gates.sh — run ci.yml's gates on this machine, before the
# push. A workflow that is disabled or queued is indistinguishable from one that
# passed: nothing goes red, so the tree looks green while nothing has executed.
# These gates are the ones that decide whether a push is sound.
#
#   TIER=lint    every gate that needs no build                       no toolchain
#   TIER=quick   style + SSOT + PGO drift + host build + the arms the
#                push's changes reach                                 DEFAULT
#   TIER=ctest   quick + the ctest suite                              ON REQUEST
#   TIER=linux   quick + Core and the GTK frontend on real Linux
#   TIER=full    linux + macOS app + snapshot regressions
#
# How long a tier takes depends on what the push changes, because each arm runs
# only when the push reaches its sources. A push that changes CMakeLists.txt
# reaches every iOS gate, and the iOS UI tests on a simulator dominate quick
# from a cold build root. The PGO total-drift gate compiles every portable-core
# unit on every run.
#
# UBIQUITTY_PREPUSH selects the tier for one push; `git config
# ubiquitty.prepushTier <tier>` sets this clone's standing choice, for a machine
# whose limits are a property of the machine rather than of the push. There is no
# tier that runs nothing — see the note on the TIER assignment below.
#
# Successful gates are cached in this worktree's Git metadata. The key covers
# the committed and uncommitted source snapshot, origin/main, command, tier,
# relevant build environment, and toolchain identity; failures and skips are
# never cached. Set UBIQUITTY_PREPUSH_CACHE=off to force every selected gate.
#
# The linux tier runs through Scripts/run-linux.sh, so the Linux-only breaks a
# macOS compiler never sees are caught here: libstdc++ against libc++, GNU ld's
# left-to-right archive scan against Apple's whole-set search, -Werror arms gcc
# raises and clang does not, all of which reach main when nothing compiles that
# path.
#
# UNCOVERED, and named rather than dropped: musl static, coverage floors,
# bounded fuzz, and the bench gate. Bench is excluded for correctness, not cost —
# a contended machine against a baseline measured on an idle runner is wrong in
# both directions.
#
# wasm32 is not on that list: gate_wasm runs from the quick tier. Its coverage
# is conditional twice over, so read it as "covered when it can matter" rather
# than "always" — the gate returns early when the branch touches none of
# Source/Core, Source/Base or Source/Platform/Web, and reports SKIPPED,
# counted as having checked nothing, on a machine without emsdk.
set -uo pipefail

# Preserve the caller's scheduling priority. Coordinate compile jobs through
# the build-job limits and reserve a quiet machine for timing-sensitive tests.
source "$(dirname "$0")/gate-report-lib.sh"
source "$(dirname "$0")/pre-push-cache.sh"
source "$(dirname "$0")/pre-push-runner.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
cd "$ROOT" || exit 1

# The renderer-arm selection and the backlog-growth gate both diff against
# origin/main. A missing ref makes that diff fail, and ubq_renderer_arms then
# reads the failure as an empty change set and skips both renderer gates in
# silence rather than refusing. Verify the ref up front, so a checkout that has
# not fetched fails loud instead of running a subset that reads as a clean pass.
if ! git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    echo "pre-push gates: origin/main is not resolvable — fetch it first (git fetch origin main)." >&2
    echo "  The renderer-arm diff and the backlog-growth gate both need it; without it they" >&2
    echo "  would skip in silence and the run would read as a pass." >&2
    exit 1
fi

# The quick tier runs focused checks; ctest requests the complete suite.
# Choose a tier using the per-invocation environment, then clone-local Git
# configuration, then the quick default. Unknown tiers fall back to quick;
# no tier disables every gate.
#
#   git config ubiquitty.prepushTier lint    this clone builds nothing on push
#   UBIQUITTY_PREPUSH=full git push          overrides it for one push
TIER="${UBIQUITTY_PREPUSH:-}"
if [ -z "$TIER" ]; then
    TIER="$(git config --get ubiquitty.prepushTier 2>/dev/null || true)"
    TIER_SOURCE="git config ubiquitty.prepushTier"
fi
TIER="${TIER:-quick}"
case "$TIER" in
    lint | quick | default | ctest | linux | full) ;;
    *)
        echo "pre-push gates: unknown tier '$TIER'${TIER_SOURCE:+ (from $TIER_SOURCE)} — running quick" >&2
        TIER=quick
        ;;
esac

# Limit CTest fan-out because each test job may itself start a build.
# UBIQUITTY_PREPUSH_JOBS overrides the default for the available machine budget.
JOBS="${UBIQUITTY_PREPUSH_JOBS:-$( n=$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) ); echo $(( n > 3 ? n / 2 : 2 )) )}"

ubq_gate_cache_init "$ROOT" "$TIER"

# Every gate pre-commit runs, run again here.
#
# A rule enforced at commit alone holds only as long as every commit runs its
# hook. `git commit --no-verify` is one flag, and pre-commit documents it as
# turning off all of them: such a rule is one that flag retires, with the tree
# then carrying the violation under a full row of passing push gates.
#
# Push is where work stops being local, so it is the boundary that has to hold
# independently of what any commit did. check-gate-coverage.py keeps the two
# lists nested from the other side: a gate added to pre-commit and not to here
# fails Scripts/check-gate-coverage.py.
#
# No argument is passed where pre-commit passes --staged or a root. Those gates
# read the whole tree when given none, which is what a push wants — the question
# here is whether the tree is clean, not which lines this branch touched.
gate_commit_rules() {
    run "build dirs" python3 ./Scripts/check-build-dirs.py
    run "web fixture" python3 ./Scripts/check-web-fixture.py
    run "conformance claims" python3 ./Scripts/check-conformance-claims.py
    run "core subset paths" bash ./Scripts/check-core-subset-paths.sh
    run "empty array expansion" python3 ./Scripts/check-empty-array-expansion.py
    run "enum switches" python3 ./Scripts/check-enum-switches.py
    run "frontend capability policy" python3 ./Scripts/check-frontend-capability-policy.py
    run "glyph backend claims" python3 ./Scripts/check-glyph-backend-claims.py
    run "healing frame pair" python3 ./Scripts/check-healing-frame-pair.py
    run "literal qualifiers" python3 ./Scripts/check-literal-qualifiers.py
    run "memcmp fold" python3 ./Scripts/check-memcmp-fold.py
    run "name collisions" python3 ./Scripts/check-name-collisions.py
    run "pgo commit shape" python3 ./Scripts/check-pgo-commit-shape.py
    run "profile orphans" python3 ./Scripts/check-profile-orphans.py
    run "quic mandatory" python3 ./Scripts/check-quic-mandatory.py
    run "showcase goldens" python3 ./Scripts/check-showcase-goldens.py
    run "snapshot harness" python3 ./Scripts/check-snapshot-harness.py
    run "stale cmake cache" python3 ./Scripts/check-stale-cmake-cache.py
    run "unwired flags" python3 ./Scripts/check-unwired-flags.py
    run "web host bytes" python3 ./Scripts/check-web-host-bytes.py
    run "web parser entries" python3 ./Scripts/check-web-parser-entries.py
}

# ci.yml: style — check-style.py and check-capability-ssot.py.
#
# test-ci-batteries.py is here because ci.yml's preflight runs it, and a verdict
# only CI produces reaches only whoever opens the run. It parses the workflow
# and the CMake test registrations, both of which drift under ordinary edits — a
# set_tests_properties wrapped across lines can read as the property having been
# deleted, and the preflight then stops there for every push.
# It reads ci.yml as the preflight does: without --workflow the workflow
# contract test skips, and an edit to ci.yml reaches the preflight untested.
gate_style() {
    # Whole tree, not the branch diff. This tier is the floor because it is the
    # one an author can rely on: it runs before the push, on the machine making
    # it, whatever the remote is doing. A rule narrowed here is narrowed for
    # every push regardless of whether anything downstream is watching.
    # --since stays available for a fast local pass; it is not what gates a push.
    run "style (check-style.py)" ./Scripts/check-style.py
    run "workflow lint (actionlint)" ./Scripts/check-workflows.sh
    run "capability SSOT" ./Scripts/check-capability-ssot.py
    run "gate coverage" python3 ./Scripts/check-gate-coverage.py
    run "CI orchestration tests" python3 ./Scripts/test-ci-batteries.py --workflow .github/workflows/ci.yml
    run "terminfo infocmp gate" ./Scripts/check-terminfo.sh
    # CI runs the UI suite; validate its exception tables locally on every push.
    run "UI scenario entries" python3 ./Scripts/check-ui-scenarios.py --entries
    # Here rather than in pre-commit: it scans the whole tree twice, once here
    # and once in a throwaway worktree at origin/main, which is a push's budget
    # and not a commit's. The reference is computed rather than recorded because
    # a number several checkouts share goes stale the moment any of them lands
    # anything, and then blocks all of them.
    run "backlog growth" python3 ./Scripts/check-backlog-growth.py
    # Tests/Performance is built by scripts that each name the benchmarks they
    # want, and several benchmarks are named by none of them. Nothing compiles
    # those, so a tree-wide edit rots them with every gate green. Parsing the
    # directory fits a push's budget and not a commit's.
    run "benchmarks compile" ./Scripts/check-bench-compiles.sh
    # Prints rather than blocks, and cannot do otherwise: it names a build this
    # machine may not be able to run. A Core type whose layout is pinned by a
    # static_assert in a frontend has that assertion compiled by one build only,
    # so every portable gate passing says nothing about it.
    python3 ./Scripts/check-build-arm.py --since origin/main || true
}

# ci.yml: host-linux (glibc). The host's platform branches are invisible to a
# frontend-only build, and its source subset is trimmed, so a kept translation
# unit calling into a trimmed one is caught at link or not at all.
gate_host() {
    # In the quick tier rather than beside the macOS app, which only `full`
    # reaches. The app build is incremental and links a .swiftmodule already on
    # disk, so it never asks whether the module still compiles: a change that
    # crashes swiftc from clean passes every push. Three seconds, and it stands
    # down off macOS.
    run_scoped "Swift renderer from clean" \
        "Source/Platform/macOS Source/UbiquittyRenderKit Source/UbiquittyKit Source/Platform/Apple CMakeLists.txt Source/Core Source/Base Source/PAL Scripts/cmake Scripts/portable-core-sources.txt Scripts/check-core-layer-partition.sh Scripts/check-swift-module-compiles.sh Scripts/build-root.sh Scripts/build_root.py" \
        ./Scripts/check-swift-module-compiles.sh
    run_scoped "ubiquitty-host build" \
        "Source/Platform/Host Source/Platform/POSIX Source/Agent Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake Scripts/portable-core-sources.txt Scripts/check-core-layer-partition.sh Scripts/build-host.sh Scripts/build-provenance.sh Scripts/build-root.sh Scripts/build_root.py" \
        ./Scripts/build-host.sh
    # ubq trims Core through its own ubiquitty_core_subset(), so a
    # kept translation unit calling into an excluded one fails here and nowhere
    # else — the host subset excludes a different set and links fine. A source
    # entering the SSOT flows into both subsets, and can call into a translation
    # unit only one of them trims.
    #
    # One second warm, which is what makes a second subset worth gating.
    run_scoped "ubq build" \
        "Source/Agent Source/Platform/Host Source/Platform/POSIX Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake Scripts/portable-core-sources.txt Scripts/check-core-layer-partition.sh Scripts/build-agent.sh Scripts/build-provenance.sh Scripts/build-root.sh Scripts/build_root.py" \
        ./Scripts/build-agent.sh
    # Tests/ COMPILES. Not the suite — the suite is retired from this tier for
    # the load reason below, and it stays retired.
    #
    # No frontend build compiles Tests/, so a namespace move can pass host,
    # agent, Linux and macOS and leave a test file unable to compile: a
    # using-directive and a namespace alias are the two spellings that carry a
    # name with no trailing `::`, and every frontend is green because no
    # frontend includes them.
    #
    # Building is the whole of what this adds. Running is what costs, and a file
    # that does not compile fails here for the same reason it would fail there,
    # sooner and for a tenth of the machine.
    run_scoped "Tests/ compiles" \
        "Source Tests CMakeLists.txt Scripts/cmake Scripts/build-tests.sh Scripts/check-build-reached.py Scripts/portable-core-sources.txt Scripts/build-root.sh Scripts/build_root.py Scripts/build-jobs.sh Scripts/build_jobs.py" \
        ./Scripts/build-tests.sh
    # And RUNS the ones this branch can break. Compiling is not running: the
    # rows `test_preferences_keys` hand-copies from the `Key.h` descriptor table
    # can go one short, red on every platform, while every build gate here is
    # green.
    #
    # Not the suite, which stays retired for the load reason above — the tests
    # whose objects actually READ a file the branch changed, which ninja's
    # dependency database already knows per object. A settings change selects
    # five; a rendering change selects about twenty and runs them in under
    # thirty seconds. The directory is warm from the step above, so what this
    # adds is the run.
    #
    # It needs that build: asked against an unbuilt directory it refuses rather
    # than select nothing, because nothing selected is what a green run looks
    # like.
    #
    # Scoped to the build's paths and to everything a gate script can read. A
    # stanza that is nothing but gate scripts is selected by the paths those
    # scripts spell, and the scripts are read to learn them, so all of Scripts
    # and each directory a script may name is an input: a verdict cached across
    # a change to a script would be one for a selection that script no longer
    # makes.
    run_scoped "tests reaching the diff" \
        "Source Tests CMakeLists.txt Scripts Tools Docs Support Samples Resources" \
        ./Scripts/check-tests-reaching-the-diff.py "$(python3 Scripts/build_root.py)/BuildHostTests/ctest" --jobs "$JOBS"
    # A run of the tests leaves no process running and adds nothing to the
    # state directory of whoever ran it. Every run-tests.sh invocation judges
    # itself on the way out, so the tiers that run stanzas are covered by the
    # stanzas; this proves the judge still fails, against a stanza that leaks
    # on purpose. Five seconds, and it builds nothing; unscoped, because what
    # it reads is the driver itself, whose inputs are the whole test tree.
    run "test runs leave nothing behind" ./Scripts/run-tests.sh run_hygiene
    # The framework product has no other oracle: the app links the static
    # module, so a packaging break — the metallib off the bundle, the
    # swiftmodule missing from Modules/, the factory unreachable — passes
    # every app build. Runs only when the module's sources moved, because
    # it is a second whole-module Swift compile.
    if ! git diff --quiet origin/main -- Source/Platform/macOS/App Source/UbiquittyKit Source/UbiquittyRenderKit Scripts/check-ubiquittykit.sh 2>/dev/null; then
        run "UbiquittyKit consumer" ./Scripts/check-ubiquittykit.sh
    fi
    # The headless smokes assert into their exit codes; the runner derives the
    # mode list from the entry point's dispatch, so a smoke added there is gated
    # by the commit that adds it. Runs only
    # when the macOS sources moved, against whatever app the arm gates
    # above already required to be fresh.
    if ! git diff --quiet origin/main -- Source/Platform/macOS Scripts/check-macos-smokes.py 2>/dev/null; then
        run "macOS headless smokes" ./Scripts/check-macos-smokes.py
    fi
}

# The complete suite is selected by the ctest and full tiers. Quick and default
# run the focused dependency-based selection in gate_host instead.
gate_ctest() {
    local build="BuildHostTests/ctest"
    run "ctest configure" cmake -S . -B "$build" -G Ninja \
        -DUBIQUITTY_BUILD_TESTS=ON -DUBIQUITTY_FRONTEND=Core -DCMAKE_BUILD_TYPE=Debug
    # A failed configure is already reported; ctest against it adds only noise.
    [ -f "$build/CMakeCache.txt" ] || { SKIPPED+=("ctest (no configure)"); return; }
    run "ctest suite" env -C "$build" ctest -j"$JOBS" --output-on-failure
}

# What this branch detaches from the PGO profile, diff-scoped, and what the
# whole tree has detached since the retrain. Drift found weeks later is hard to
# place; per branch the number is small and names its function. The absolute
# budget at retrain lives in pgo-train.sh (--max-discarded 0), which also
# records the total-drift budget beside the profile; the first bound here is on
# the new mass only, and the value is the performance owner's knob.
# The budget is far below buildCellInstances-class detachment — a change to
# that function's shape discards its whole profile — so an edit there always
# refuses the push and lands as a pair: the change plus a retrain on the same branch, retrain
# second, driven by whoever owns the performance work. A branch that changes no portable-core TU
# prints zero and passes.
#
# It is its own gate because the per-branch bound and the test suite answer
# different questions, and a bound that only runs when someone asks for the
# suite bounds nothing: a profile bounded only beside the suite can drift far
# enough to lose whole lanes against a retrained one. It compiles only the
# portable-core units the branch changed, which is seconds.
gate_pgo_drift() {
    # 30000, set from the tree rather than picked: a budget far above anything
    # this tree produces runs on every push and cannot fail. An ordinary branch
    # reads zero; the budget sits above the drift a long run of commits
    # accumulates, so it tolerates a branch that rewrites that much and fails
    # one that goes further.
    #
    # Raise it with the number the failure prints, and say what the branch did
    # to earn it. A profile retrain is the other answer, and the better one when
    # the drift is real rather than a one-off.
    run "pgo diff-applies" python3 Scripts/check-pgo-applies.py \
        --changed-from origin/main --max-new-discarded 30000
    # The total, against the budget pgo-train.sh recorded beside the profile.
    # The bound above reads only the units a push changed: a header edit that
    # reshapes every function inlining it compiles nothing there and reads
    # zero, and pushes each under 30000 can leave the profile far off the tree
    # within days of a retrain. This compiles every portable-core unit across
    # the cores, and refuses once the total exceeds the
    # recorded budget; from 60% of it the gate prints a warning line that the
    # runner repeats beside the pass. A profile with no budget beside it stands
    # down here, by name, until a retrain records one.
    run "pgo total drift" python3 Scripts/check-pgo-applies.py --recorded-budget
}

# ci.yml: host-linux + linux-frontend. Needs Docker (OrbStack or Docker Desktop); absent is SKIPPED.
# The container runtime takes a whole core for the length of both builds, so a
# loaded machine may switch it off.
#
# A switched-off run names it in the skip list rather than passing over it,
# because what it covers is not covered elsewhere: no other gate compiles
# Source/Platform/Linux at all, and the container is the only arm that reads
# the toolchain floor. Without it, a branch that touches the GTK frontend or a
# Core header it includes reaches main with nobody having compiled it.
#
#   UBIQUITTY_LINUX_GATE=off ./Scripts/pre-push-gates.sh   (to skip it)
#
gate_linux() {
    if [ "${UBIQUITTY_LINUX_GATE:-on}" = "off" ]; then
        SKIPPED+=("linux build (paused; UBIQUITTY_LINUX_GATE=off pauses it)")
        printf '  %-34s %s\n' "linux build" "PAUSED (UBIQUITTY_LINUX_GATE=off)"
        return
    fi
    if ! command -v docker >/dev/null 2>&1; then
        SKIPPED+=("linux build (no docker; install OrbStack or Docker Desktop)")
        printf '  %-34s %s\n' "linux build" "SKIPPED (no docker)"
        return
    fi
    run "Core + host on Linux" ./Scripts/run-linux.sh test
    run "GTK frontend on Linux" ./Scripts/run-linux.sh
}

# ci.yml: linux-frontend (compile only). The one gate that compiles
# Source/Platform/Linux at all, and the reason it is affordable on every push
# where the full Linux tier is not: a warm incremental build answers in under a
# second, because ninja rebuilds the translation units a branch actually touched
# and nothing else.
#
# It is the COLD build that costs ten minutes and a whole core, which is what
# UBIQUITTY_LINUX_GATE=off pauses. So a tree with no configured build
# directory is reported rather than silently built: a checkout that has never run the
# container is told how to warm it once, and every push after that is free.
#
# What it covers is covered nowhere else. No other gate compiles the GTK
# frontend, and the two compilers this repo ships on disagree about code that is
# legal to one of them — clang takes a brace elision GCC refuses, so Linux can
# be uncompilable behind a green macOS build.
#
#   UBIQUITTY_LINUX_GATE=off ./Scripts/pre-push-gates.sh   (to skip it)
#
gate_linux_compile() {
    if [ "${UBIQUITTY_LINUX_GATE:-on}" = "off" ]; then
        SKIPPED+=("linux compile (paused; UBIQUITTY_LINUX_GATE=off pauses it)")
        printf '  %-34s %s\n' "linux compile" "PAUSED (UBIQUITTY_LINUX_GATE=off)"
        return
    fi
    if ! command -v docker >/dev/null 2>&1; then
        SKIPPED+=("linux compile (no docker; install OrbStack or Docker Desktop)")
        printf '  %-34s %s\n' "linux compile" "SKIPPED (no docker)"
        return
    fi
    if [ ! -f "$UBQ_BUILD_ROOT/linux-container/linux/build.ninja" ]; then
        # Reported with its remedy rather than run: the cold build is the
        # expensive one, and taking ten minutes out of a push nobody asked to
        # wait for is how a gate teaches the bypass.
        SKIPPED+=("linux compile (cold; warm it once with ./Scripts/run-linux.sh ./Scripts/build-linux-gtk.sh)")
        printf '  %-34s %s\n' "linux compile" "SKIPPED (cold; ./Scripts/run-linux.sh ./Scripts/build-linux-gtk.sh)"
        return
    fi
    run_scoped "GTK frontend compiles on Linux" \
        "Source/Platform/Linux Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake Scripts/portable-core-sources.txt Scripts/check-core-layer-partition.sh Scripts/run-linux.sh Scripts/build-version.sh Scripts/build-linux-gtk.sh Scripts/linux-images.txt Scripts/run-tests.sh Scripts/build-jobs.sh Scripts/build_jobs.py Scripts/build-root.sh Scripts/build_root.py" \
        ./Scripts/run-linux.sh bash -c 'cd build/linux && ninja'
}

# The snapshot arms whose renderer this branch touched, and only those.
#
# gate_snapshots is TIER=full, which nobody runs before an ordinary push, so a
# renderer change would ship with its goldens unexamined: a fix verified on the
# oracle that was right for the change, while a golden on a different oracle
# goes stale. The arm named here catches that.
#
# Scoped by what changed, because the whole tier is minutes and one arm is
# seconds. A branch touching no renderer selects nothing and pays nothing,
# which is what makes failing a selected arm's refusal fair.
#
# Each arm refuses with status 2 when its binary predates the sources — a fresh
# worktree has no macOS app — and a refusal is reported as a skip rather than a
# failure, matching the snapshots stanza. Only a real disagreement fails.
ubq_renderer_arms() {
    local changed arms=""
    # Three dots, so the base is the MERGE BASE rather than origin/main's tip:
    # against the tip, every file another branch landed since this branch started
    # reads as changed here, and the arms selected would be theirs.
    changed="$(git diff --name-only origin/main...HEAD 2>/dev/null)" || return 0
    # Native snapshots use the same Swift surface and Metal encoder as the app.
    printf '%s\n' "$changed" | grep -v '^Source/Platform/macOS/UITest/' \
        | grep -qE '^Source/(Platform/macOS|UbiquittyRenderKit|UbiquittyKit)/' \
        && arms="$arms swift"
    # A header the Metal shader includes compiles into the swift arm's pipeline
    # as well as into Core, so a change to it is a swift-arm change too. The
    # set is read from the shaders' quoted includes, followed transitively and
    # folded to repository paths. With no shader to read, every Core header
    # selects the arm: an include list that could not be read is not an empty one.
    local shaderInputs="" pending="" source include resolved pattern selectsShader=0
    pattern='^(.*/)?([^/]+)/\.\./(.*)$'
    for source in Source/UbiquittyRenderKit/*.metal; do
        [ -f "$source" ] && pending="$pending$source"$'\n'
    done
    if [ -z "$pending" ]; then
        grep -qE '^Source/Core/.*\.(h|hpp|inc)$' <<<"$changed" && selectsShader=1
    fi
    while [ -n "$pending" ]; do
        source="${pending%%$'\n'*}"
        pending="${pending#*$'\n'}"
        while IFS= read -r include; do
            resolved="$(dirname "$source")/$include"
            resolved="${resolved//\/.\//\/}"
            while [[ "$resolved" =~ $pattern ]] && [ "${BASH_REMATCH[2]}" != ".." ]; do
                resolved="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
            done
            case $'\n'"$shaderInputs" in
                *$'\n'"$resolved"$'\n'*) continue ;;
            esac
            shaderInputs="$shaderInputs$resolved"$'\n'
            [ -f "$resolved" ] && pending="$pending$resolved"$'\n'
        done < <(sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*/\1/p' "$source")
    done
    if [ -n "$shaderInputs" ] && grep -qxF "${shaderInputs%$'\n'}" <<<"$changed"; then
        selectsShader=1
    fi
    # The native snapshot command reads its words, states its configuration and
    # draws its portable frame through these Core headers, so a change to them
    # changes what the swift arm renders.
    grep -qE '^Source/Core/(Diagnostics/SnapshotArguments|App/SnapshotRequest)\.h$' <<<"$changed" && selectsShader=1
    if [ "$selectsShader" = 1 ]; then
        case " $arms " in
            *" swift "*) ;;
            *) arms="$arms swift" ;;
        esac
    fi
    printf '%s\n' "$changed" | grep -q '^Source/Core/' && arms="$arms portable"
    printf '%s\n' "$changed" | grep -q '^Source/Platform/Web/' && arms="$arms web"
    printf '%s\n' "$changed" | grep -q '^Source/Platform/Linux/' && arms="$arms linux"
    # A Core change draws on every arm, and one of them links a different
    # standard library. The selection above gives it `portable` alone, so a Core
    # branch renders no Linux frame: a span read hoisted out from behind the
    # flag sizing it draws correctly past the end of an empty vector on both
    # macOS arms and on portable, and libstdc++ aborts on it.
    #
    # Only the tiers that already pay for a container get this. The default
    # tier does not, so a branch opting into nothing pays nothing — and a
    # developer who types the variable is asking for the arm that can disagree, which
    # for a Core change is the whole reason to type it.
    if [ "$TIER" = "linux" ] || [ "$TIER" = "full" ]; then
        case " $arms " in
            *" linux "*) ;;
            *) printf '%s\n' "$changed" | grep -q '^Source/Core/' && arms="$arms linux" ;;
        esac
    fi
    printf '%s' "$arms"
}

# The command that gives an arm a binary matching this tree. Commands rather
# than paths: the caller needs something a reader can run, and the paths are
# run.py's business — a second table of them here is one more thing to drift.
ubq_arm_rebuild() {
    case "$1" in
        portable) echo "./Scripts/build-core-snapshot.sh" ;;
        # Clean, not incremental: an incremental macOS rebuild after Swift
        # sources are re-dated can produce a binary that fails the surface
        # smoke's palette-epoch case while a CLEAN build of the same tree
        # passes — the Swift module's incremental state lies,
        # and every later gate step reads build/macos. The minutes a clean
        # build costs buy a verdict that describes the tree.
        macos|swift) echo "./Scripts/build-macos.sh --clean" ;;
        web) echo "./Scripts/build-web.sh" ;;
        linux) echo "./Scripts/run-linux.sh" ;;
        *) echo "a rebuild of the $1 arm" ;;
    esac
}

gate_renderer_snapshots() {
    local arms
    arms="$(ubq_renderer_arms)"
    if [ -z "$arms" ]; then
        printf '  %-34s %s\n' "renderer snapshots" "none — this branch changes no renderer"
        return 0
    fi
    for arm in $arms; do
        local status=0
        # In this run's own artifact root, which a failed run keeps and names:
        # a fixed path under /tmp is shared by every checkout on the machine,
        # and two pushes gating at once would write over each other's logs.
        local arm_log="$UBQ_CI_ROOT/snapshot-arm-$arm.log"
        # The linux arm renders inside the container, so it obeys the same pause
        # the linux build does. Reported as PAUSED rather than skipped: a skip is
        # what this gate says when a binary predates its sources, and an arm that
        # answered that on every host forever would be rendering for no gate
        # while wearing the gate's uniform.
        if [ "$arm" = "linux" ] && [ "${UBIQUITTY_LINUX_GATE:-on}" = "off" ]; then
            printf '  %-34s %s\n' "snapshot arm: linux" "PAUSED (UBIQUITTY_LINUX_GATE=off)"
            SKIPPED+=("snapshot arm: linux (paused; UBIQUITTY_LINUX_GATE=off pauses it)")
            continue
        fi
        # One arm needs its invocation as well as its name. build/linux/ is the
        # path INSIDE the container; on the host the module is under
        # build/linux-container/linux/, and the shim is what bridges the two and
        # answers --print-render-binary for the freshness guards. Without it the
        # arm exits 2 on every host — a permanent skip, which reads as coverage.
        local extra=()
        [ "$arm" = "linux" ] && extra=(--linux-binary "$ROOT/Scripts/linux-snapshot-shim.sh")
        # A waived case is excused for the distance it was measured at, and an
        # entry naming no distance excuses any. The arms that run here carry
        # ceilings for every waiver they can measure, so a new waiver added
        # without one reds rather than joining a list nothing bounds. Not for
        # linux: its entries are minted on a Linux machine and this host cannot
        # measure them.
        [ "$arm" = "linux" ] || extra+=(--require-ceilings)
        # ${extra[@]+...}: bash 3.2 under `set -u` treats an EMPTY array's
        # "${extra[@]}" as unbound and kills the hook on a stock-bash host. The
        # +-expansion form expands to nothing when the array is empty and to
        # the elements when it is not, on every bash this repository meets.
        python3 "$ROOT/Tests/Snapshots/run.py" --backend "$arm" ${extra[@]+"${extra[@]}"} >"$arm_log" 2>&1 || status=$?
        if [ "$status" = "2" ]; then
            # One rebuild before refusing. The commonest status-2 cause is a
            # binary staled by a rebase, a checkout or a fresh worktree — the
            # reader's mechanical response is the printed rebuild command, so
            # the gate runs it once itself and re-verifies against the fresh
            # binary. The defect shapes behind status 2 (a foreign binary,
            # orphaned goldens, a manifest entry matching nothing) survive a
            # rebuild and still refuse below; nothing is waved through.
            printf '  %-34s rebuilding (stale or absent binary)…\n' "snapshot arm: $arm"
            local rebuild_command
            rebuild_command="$(ubq_arm_rebuild "$arm")"
            if (cd "$ROOT" && eval "$rebuild_command" >"$UBQ_CI_ROOT/snapshot-arm-$arm-rebuild.log" 2>&1); then
                status=0
                python3 "$ROOT/Tests/Snapshots/run.py" --backend "$arm" ${extra[@]+"${extra[@]}"} >"$arm_log" 2>&1 || status=$?
            fi
        fi
        if [ "$status" = "0" ]; then
            printf '  %-34s ok\n' "snapshot arm: $arm"
            PASSED+=("snapshot arm: $arm")
        elif [ "$status" = "2" ]; then
            # The arm declined, so no case was compared and this run is evidence
            # about nothing. Recorded as uncovered rather than printed and
            # dropped: an arm absent from the summary reads as one that ran, and
            # "8 passed" then means the renderer this branch touched was
            # compared when it was not.
            #
            # The reason is not named here. Status 2 carries several: a stale
            # binary, a foreign one, orphaned goldens, a manifest entry matching
            # nothing, a filter selecting nothing. Naming the most common one
            # teaches the reader to dismiss the rest, and two of them are defects
            # rather than a build that needs redoing.
            #
            # A failure rather than an uncovered note, because the arm is here at
            # all only because the branch changed code it renders: a refusal means
            # this renderer changed and nothing verified it, which is the
            # verification the push already implies rather than friction added to
            # it. The selection licenses that — a branch touching no renderer
            # names no arm and pays nothing, and one touching a renderer it has
            # never built is where a fresh worktree and a rebase land alike.
            printf '  %-34s REFUSED — nothing compared; run %s then retry\n' \
                "snapshot arm: $arm" "$(ubq_arm_rebuild "$arm")"
            FAILED+=("snapshot arm: $arm (refused, nothing compared — $(ubq_arm_rebuild "$arm"))")
        else
            # The arm's own verdict, carried up rather than pointed at: run.py
            # names its offenders on that line, so lifting it here means a
            # reader who kept only this output knows which case failed. A path
            # to a log is a pointer, and a pointer is what this gate refuses.
            # The verdict word goes too, not just the VERDICT label: run.py
            # prints "VERDICT  FAILED — <reason>" and the line below supplies
            # its own "FAILED — ", so lifting the whole tail prints the word
            # twice — "FAILED — FAILED — 3 cases differ". What is wanted from
            # that line is the reason.
            arm_verdict=$(grep -m1 '^VERDICT' "$arm_log" 2>/dev/null \
                | sed -E 's/^VERDICT +//; s/^(FAILED|REFUSED|PASSED) +(— *)?//')
            printf '  %-34s FAILED — %s\n' "snapshot arm: $arm" \
                "${arm_verdict:-no verdict in $arm_log}"
            FAILED+=("snapshot arm: $arm (${arm_verdict:-no verdict})")
        fi
    done
}


# Every driver over the Swift renderer, each building a piece of it and reading
# a result back. Two passes with different reach: the type-check runs on every
# branch, the drawing pass on the diff paths that pick the swift snapshot arm.
#
# A harness nobody runs fails in the compiler, without reaching an assertion: a
# `package` declaration its compile line has no -package-name for, a source list
# behind the directory, a protocol member its stubs do not implement. Such
# breaks arrive from OUTSIDE the Swift renderer, which is why the halves are
# selected differently: a Core protocol growing a member breaks a stub's
# conformance on a branch that touches no Swift source at all.
# The iOS arm: it builds, and its surface still draws.
#
# The arm compiles the portable Core, the shared Swift layer and an app, and its
# breaks arrive from OUTSIDE it — a Core header that moves, a module map that
# gains an entry, an access level that changes with a module boundary. A gate
# selected on iOS paths alone would watch none of them, so this one is scoped to
# what it is built from.
#
# The smoke rather than the build alone, because building proves the arm
# compiles and says nothing about whether a surface is ever asked to draw: an
# iOS shell can be connected, parsing, holding a correct grid and showing black
# past a green build, because the toolkit calls nothing back. The build
# script runs that smoke on the simulator, which is what makes this a gate about
# the terminal rather than about the compiler.
gate_ios() {
    [ "$(uname -s)" = "Darwin" ] || {
        SKIPPED+=("iOS arm (needs the iPhone SDK; this host is $(uname -s))")
        return 0
    }
    if ! xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
        SKIPPED+=("iOS arm (no iphonesimulator SDK in this Xcode)")
        return 0
    fi
    run_scoped "iOS arm builds" \
        "Source/Platform/iOS Source/UbiquittyKit Source/UbiquittyRenderKit Source/Platform/Apple Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake Scripts/build-ios.sh Scripts/build-root.sh Scripts/build-provenance.sh Scripts/portable-core-sources.txt" \
        ./Scripts/build-ios.sh --sdk iphonesimulator
    # Building is not the subject. A view the toolkit never asks to draw and a
    # PAL seam with nothing installed in it both compile clean and need a
    # running application to see, so the smokes run on a simulator rather than
    # being built and left alone.
    if ! xcrun simctl list runtimes 2>/dev/null | grep -q "iOS"; then
        SKIPPED+=("iOS smokes (no iOS simulator runtime installed)")
        return 0
    fi
    run_scoped "iOS smokes" \
        "Source/Platform/iOS Source/UbiquittyKit Source/UbiquittyRenderKit Source/Platform/Apple Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake Scripts/build-ios.sh Scripts/build-root.sh Scripts/build-provenance.sh Scripts/portable-core-sources.txt Scripts/run-ios-smokes.sh Scripts/ios-simulator.sh" \
        ./Scripts/run-ios-smokes.sh
    # The phone's own build of the Sync wire tests, linked against the archive
    # the app carries: the same source compiled for another ABI is not the same
    # bytes until a run of that build says so.
    run_scoped "iOS Sync conformance" \
        "Source/Core/Protocol/Sync Source/Core Source/Base Source/PAL Tests/Core/Protocol/Sync Tests/Harness.h CMakeLists.txt Scripts/cmake Scripts/build-ios.sh Scripts/build-root.sh Scripts/run-ios-sync-conformance.sh Scripts/ios-simulator.sh" \
        ./Scripts/run-ios-sync-conformance.sh
    # The real Data Protection backend, which only a simulator process exercises.
    run_scoped "iOS protected file" \
        "Source/Platform/iOS/ProtectedFile.h Source/UbiquittyKit/Swift/ProtectedFile.swift Source/Platform/POSIX/SystemPAL.cpp Tests/Platform/test_ios_protected_file.cpp Tests/Platform/test_ios_protected_file_probe.swift Tests/Harness.h Scripts/run-ios-protected-file-tests.sh Scripts/ios-simulator.sh Scripts/build-root.sh" \
        ./Scripts/run-ios-protected-file-tests.sh
    # The smokes drive the app from INSIDE its own process: they build a
    # recogniser and call the action method themselves. That says nothing about
    # whether the recogniser is installed on the view a finger lands on, or
    # whether UIKit would route two touches to it — both have to hold before any
    # of the arithmetic a smoke checks ever runs. So the UI lane drives the
    # installed app from outside with synthesised touches, and needs its own
    # build because the XCUITest bundle is off by default.
    run_scoped "iOS UI tests build" \
        "Source/Platform/iOS CMakeLists.txt Scripts/build-ios.sh Scripts/run-ios-ui-tests.sh Scripts/build-provenance.sh Scripts/build-root.sh" \
        ./Scripts/build-ios.sh --sdk iphonesimulator --ui-tests
    # The Xcode generator, because ninja is not the only consumer of these
    # CMakeLists and is the more forgiving one. A custom command attached to two
    # targets builds fine under ninja and is REFUSED by Xcode's new build
    # system — so a directory every other gate accepts can still fail the
    # moment somebody opens the workspace.
    #
    # Configure only. It writes build/xcode/* and compiles nothing, so it costs
    # a CMake configure rather than a build.
    #
    # Generating is not the whole of it: a project CMake writes without
    # complaint can still be one no phone is a destination for, or one whose
    # Debug configuration loses members of a Swift module between two targets.
    # The script ends by running Scripts/check-xcode-workspace.py over what it
    # wrote, which is why that file is in this gate's scope.
    run_scoped "Xcode workspace generates" \
        "CMakeLists.txt Source/Platform/macOS/CMakeLists.txt cmake Scripts/cmake Scripts/generate-xcode-workspace.sh Scripts/check-xcode-workspace.py Scripts/apple-development-teams.py Scripts/macos-deployment-target.txt" \
        ./Scripts/generate-xcode-workspace.sh
    run_scoped "iOS UI tests" \
        "Source/Platform/iOS Source/UbiquittyKit Source/UbiquittyRenderKit CMakeLists.txt Scripts/build-ios.sh Scripts/run-ios-ui-tests.sh Scripts/build-root.sh Scripts/ios-simulator.sh" \
        ./Scripts/run-ios-ui-tests.sh
}

gate_swift_renderer_drivers() {
    # Both passes need swiftc against Metal-importing sources, so both stand
    # down off Darwin — through SKIPPED, because a gate that returns quietly
    # reads in the summary exactly like one that ran and found nothing.
    [ "$(uname -s)" = "Darwin" ] || {
        SKIPPED+=("swift-renderer drivers (needs macOS toolchain; this host is $(uname -s))")
        return 0
    }
    # The type-check pass on every branch, because these drivers break with
    # compile errors reached from OUTSIDE the Swift renderer: an access level
    # that moves with a module boundary, a Core protocol that grows members the
    # stubs do not follow. Selecting this half on Swift renderer paths would
    # leave exactly the branches that break it unwatched. It links nothing and
    # opens no device, so it costs seconds.
    run_scoped "swift-renderer drivers (type-check)" \
        "Source Scripts Resources/fonts CMakeLists.txt" \
        ./Scripts/check-swift-renderer.sh --typecheck-only
    local arms
    arms="$(ubq_renderer_arms)"
    case " $arms " in
    *" swift "*) ;;
    *)
        printf '  %-34s %s\n' "swift-renderer drivers (draw)" "none — this branch changes no Swift renderer source"
        return 0
        ;;
    esac
    run_scoped "swift-renderer drivers (draw)" \
        "Source Scripts Resources/fonts CMakeLists.txt" \
        ./Scripts/check-swift-renderer.sh
}

# ci.yml: snapshots (macOS) + portable-snapshots-linux.
# The arm that DISAGREES rather than the one that is merely missing.
#
# wasm builds portable Core against a different standard library, so a header
# every other libc++ hands over transitively can be absent there, and a file
# every other gate here compiles and calls ok can fail on this arm alone.
#
# It runs rather than advising. A sentence at the end of a green run telling
# the pusher to build this arm themselves is read once and skipped after that,
# and the condition it would be printed under is the same one selecting it here.
#
# Selected by what changed, on the same terms as the renderer arms: a branch
# touching neither Source/Core nor Source/Base cannot break this lane and pays
# nothing. One that does pays about a minute.
#
# The toolchain check is here rather than left to build-web.sh, which exits 0
# when emscripten is absent — correct for a script someone runs by hand, and a
# silent pass for a gate. A machine without emsdk reports SKIPPED and is counted
# as having checked nothing.
# Source/Platform/Web is in the selection because build-web.sh runs
# Tests/Web/page-smoke.mjs, which `await import`s the built terminal.js and
# executes it — the only thing in the tree that loads that file. Selecting on
# Core and Base alone leaves a change confined to terminal.js or webgl.js running
# nothing that reads it. The renderer arm a Web change does select launches
# Scripts/web-snapshot-shim.mjs against the wasm module, which never touches the
# page's own scripts.
#
# Tests/Snapshots/cases.json and the goldens are in the selection for a reason
# that is not about what a branch can break. The web arm renders only when a
# wasm module newer than Core exists, and this gate is the only thing that
# builds one — so a branch that mints a case, touching no source at all, leaves
# the web arm never having rendered it, and its first web verdict arrives on
# some unrelated branch as a NEW FAILURE. Minting a case is what creates the
# obligation, so minting a case is what pays for it.
gate_wasm() {
    [ -n "$(git -C "$ROOT" diff --name-only origin/main...HEAD -- Source/Core Source/Base Source/Platform/Web Tests/Snapshots/cases.json Tests/Snapshots/golden 2>/dev/null)" ] || return 0
    if ! command -v emcmake >/dev/null 2>&1; then
        SKIPPED+=("wasm build (no emscripten; emsdk provides emcmake)")
        printf '  %-34s %s\n' "wasm build" "SKIPPED (no emscripten)"
        return
    fi
    # Prove the arm still disagrees with the host before trusting its Core build:
    # a build that compiles everything and says ok is indistinguishable from one
    # whose toolchain quietly stopped rejecting what the host accepts.
    run "wasm arm disagrees with host" ./Scripts/check-wasm-oracle.sh
    run "portable Core on wasm" ./Scripts/build-web.sh
}

gate_snapshots() {
    if [ "$(uname -s)" = "Darwin" ]; then
        run "macOS app build" ./Scripts/build-macos.sh --no-helpers
    fi
    run "snapshot regressions" ./Scripts/run-tests.sh snapshots
}

# esctest2 read from OUTSIDE the whole stack: it runs as a child of the terminal
# over a real PTY and reads cells back with DECRQCRA, so it sees the composition
# of parser, capability gate, daemon and frontend that every in-process tier is
# blind to. Only in `full`, which already builds the macOS app it needs.
#
# The profile excludes the window-op family on purpose. Those cases drive a live
# window manager, and running them beside size-dependent conformance cases in one
# process makes the latter non-deterministic: cases change answer between runs
# of one binary with them in, far fewer with them out. A gate that fires
# without a cause is one people learn to skip, so the flaky family is measured
# separately rather than averaged into a verdict.
gate_esctest() {
    [ "$(uname -s)" = "Darwin" ] || {
        SKIPPED+=("esctest2 conformance (needs the macOS app; this host is $(uname -s))")
        return 0
    }
    run "esctest2 conformance" ./Scripts/check-esctest.sh --profile macos-nowinops \
        -- --include '^(?!XtermWinops).*'
}

# gate_style minus the one step in it that compiles.
#
# check-bench-compiles.sh builds the benchmarks Tests/Performance holds, which is
# the whole of what gate_style spends a toolchain on. Everything else there reads
# the tree: check-style.py, the capability SSOT, and the backlog ratchet against a
# throwaway worktree at origin/main.
#
# The skipped gate is announced through the same SKIPPED channel a missing tool
# uses, so the summary says a build gate stood down instead of reporting that
# everything ran. A tier that quietly narrowed what it checked would be the
# bypass this ladder refuses to have.
gate_style_without_builds() {
    run "style (check-style.py)" ./Scripts/check-style.py
    run "workflow lint (actionlint)" ./Scripts/check-workflows.sh
    run "capability SSOT" ./Scripts/check-capability-ssot.py
    run "gate coverage" python3 ./Scripts/check-gate-coverage.py
    run "CI orchestration tests" python3 ./Scripts/test-ci-batteries.py --workflow .github/workflows/ci.yml
    run "UI scenario entries" python3 ./Scripts/check-ui-scenarios.py --entries
    run "backlog growth" python3 ./Scripts/check-backlog-growth.py
    SKIPPED+=("benchmarks compile (tier lint builds nothing; ask for quick to compile them)")
    python3 ./Scripts/check-build-arm.py --since origin/main || true
}

# The frame report the built app makes about itself: that a frame was built by
# the builder with a count that moved, and that the Swift and C++ assembly agree.
#
# Selected on the code it asserts about rather than run always — the app must be
# built and drawn, which is 22 s and a Metal device. Darwin only for the same
# reason the esctest gate is; elsewhere it stands down and says so, rather than
# passing over a check that never looked.
#
# Invoked wherever a runner can draw rather than excused on the grounds that no
# runner is known to: an excuse keyed on a capability nobody has is right until
# somebody has it, and stops being checked at the moment it stops being true.
gate_core_builder_frames() {
    local changed
    changed="$(git diff --name-only origin/main...HEAD 2>/dev/null)" || return 0
    if ! printf '%s\n' "$changed" | grep -qE '^Source/Core/Rendering/|^Source/Platform/macOS/'; then
        printf '  %-34s %s\n' "core builder frames" "none — this branch changes no frame path"
        return 0
    fi
    if [ "$(uname -s)" != "Darwin" ]; then
        SKIPPED+=("core builder frames (needs the macOS app and a Metal device; this host is $(uname -s))")
        return 0
    fi
    run "core builder frames" ./Scripts/check-core-builder-frames.sh
}

# One implementation, checked against the symbol tables the build just produced.
#
# Docs/coding-conventions.md §10 says portable policy lives in Core and every
# frontend routes through it. A forked copy of that policy is fixed in one place
# and tested in another: with two byte-identical copies of an ownership gate,
# the test suite can link the copy that lacks a fix the other one carries.
#
# After gate_host, because it reads objects rather than sources and a build
# directory this push did not refresh answers about an older tree. Only the
# directories this tier actually built are passed.
gate_forks() {
    local dirs=""
    [ -d "$UBQ_BUILD_ROOT/host" ] && dirs="$dirs $UBQ_BUILD_ROOT/host"
    [ "$(uname -s)" = "Darwin" ] && [ -d "$UBQ_BUILD_ROOT/macos" ] \
        && dirs="$dirs $UBQ_BUILD_ROOT/macos"
    if [ -z "$dirs" ]; then
        SKIPPED+=("one implementation (no built directory to read symbol tables from)")
        return 0
    fi
    # shellcheck disable=SC2086
    run "one implementation" ./Scripts/check-forks.sh $dirs
}

# One artifact root for this run. ci_batteries.py puts a battery's stage logs
# and its events.jsonl under UBQ_CI_ROOT/<battery>, and its report reads the
# same root, so everything this run starts agrees on one directory that no
# other run on this machine has. Without it the root is /tmp/ubiquitty-ci for
# every run on the machine, which two pushes gating at once would share.
# Removed when every gate passed; kept and named when one failed, since that
# is where a failed battery's logs are. UBQ_ rather than UBIQUITTY_ because
# the verdict cache's key covers every UBIQUITTY_ variable, and a path that is
# new on every run would make every verdict new on every run.
UBQ_CI_ROOT="${TMPDIR:-/tmp}"
UBQ_CI_ROOT="$(mktemp -d "${UBQ_CI_ROOT%/}/ubiquitty-ci-XXXXXX")" || exit 1
export UBQ_CI_ROOT

# On exit rather than at the two verdicts, so an interrupted push or a run
# that set -u ends does not leave a root behind either. An interrupt exits
# with its own status, so it reads as the failure it is rather than as a pass.
ubq_ci_root_finish() {
    local status=$?
    # Kept only when a failed run left something in it; an empty root names
    # nothing a reader could open.
    if [ "$status" -ne 0 ] && [ -n "$(ls -A "$UBQ_CI_ROOT" 2>/dev/null)" ]; then
        echo "  battery artifacts: $UBQ_CI_ROOT" >&2
        return
    fi
    rm -rf "$UBQ_CI_ROOT"
}
trap ubq_ci_root_finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "pre-push gates (tier: $TIER) — the local stand-in for ci.yml" >&2
case "$TIER" in
    # Every gate that needs no build, and nothing else. For a machine that
    # cannot afford one — no disk, no toolchain, a container mid-rebuild — where
    # the alternative people actually reach for is removing pre-push from their
    # hooks directory, which takes check-style down with it and is invisible to
    # everyone else. This is depth, not existence: it still runs the lint gates,
    # and it names the build gates it skips rather than passing quietly over
    # them.
    lint)    gate_style_without_builds; gate_commit_rules ;;
    quick)   gate_pgo_drift; gate_style; gate_commit_rules; gate_host; gate_linux_compile; gate_forks; gate_wasm; gate_core_builder_frames; gate_renderer_snapshots; gate_swift_renderer_drivers; gate_ios ;;
    # `default` is quick under another name, and neither runs the suite — see
    # gate_ctest. `ctest` is how you ask for it.
    default) gate_pgo_drift; gate_style; gate_commit_rules; gate_host; gate_linux_compile; gate_forks; gate_wasm; gate_core_builder_frames; gate_renderer_snapshots; gate_swift_renderer_drivers; gate_ios ;;
    ctest)   gate_pgo_drift; gate_style; gate_commit_rules; gate_host; gate_linux_compile; gate_forks; gate_wasm; gate_core_builder_frames; gate_ctest; gate_renderer_snapshots; gate_swift_renderer_drivers; gate_ios ;;
    linux)   gate_pgo_drift; gate_style; gate_commit_rules; gate_host; gate_forks; gate_wasm; gate_core_builder_frames; gate_linux; gate_renderer_snapshots; gate_swift_renderer_drivers; gate_ios ;;
    full)    gate_pgo_drift; gate_style; gate_commit_rules; gate_host; gate_forks; gate_wasm; gate_core_builder_frames; gate_ctest; gate_linux; gate_snapshots; gate_esctest ;;
    *)
        echo "pre-push gates: unknown tier '$TIER' (want lint|quick|ctest|linux|full)" >&2
        exit 1
        ;;
esac

# Whether anyone has built what the last merges produced. A rebase merge replays
# a branch onto a base it was never built against and pushes without building
# the result, so the first tree in which two changes coexist is main itself and
# no gate here has seen it — these gates measure the tree this author has.
#
# Said at the end of a push because that is the moment someone is looking at
# this output and has the repository in hand. It is not a failure: another
# checkout's merge being unverified is not a reason to refuse this push.
UBQ_VERIFIED_FILE="$UBQ_BUILD_ROOT/.merged-main-verified"
UBQ_MAIN_TIP="$(git -C "$ROOT" rev-parse --verify --quiet origin/main 2>/dev/null || true)"
UBQ_VERIFIED="$(cat "$UBQ_VERIFIED_FILE" 2>/dev/null || true)"
if [ -n "$UBQ_MAIN_TIP" ] && [ "$UBQ_MAIN_TIP" != "$UBQ_VERIFIED" ]; then
    echo >&2
    if [ -z "$UBQ_VERIFIED" ]; then
        echo "pre-push gates: no build has verified origin/main in this checkout." >&2
    else
        UBQ_BEHIND="$(git -C "$ROOT" rev-list --count "$UBQ_VERIFIED..$UBQ_MAIN_TIP" 2>/dev/null || echo "?")"
        echo "pre-push gates: origin/main is $UBQ_BEHIND commit(s) past the last build that" >&2
        echo "  verified it (${UBQ_VERIFIED:0:9})." >&2
    fi
    echo "  A rebase merge builds nothing, so those commits have coexisted only here:" >&2
    echo "      ./Scripts/check-merged-main.sh" >&2
fi

echo >&2
ubq_gate_report_skipped
ubq_gate_report_warned
if [ "${#FAILED[@]}" -gt 0 ]; then
    gate_failed "pre-push gates" "gate(s) failed" "${FAILED[@]}"
    # The name of a gate is not a diagnosis. By the time this prints, the
    # detail is forty lines up and past whatever else ran; a reader who scrolls
    # to the bottom gets "ctest suite" and nothing to act on. So each failure
    # repeats the lines that name what broke, and where the whole log is.
    ubq_i=0
    for ubq_name in "${FAILED[@]}"; do
        ubq_log="${FAILED_LOG[$ubq_i]:-}"
        echo "  - $ubq_name" >&2
        if [ -n "$ubq_log" ] && [ -f "$ubq_log" ]; then
            # ctest names its casualties under a header; anything else falls
            # back to its own last lines rather than to silence.
            if grep -q 'The following tests FAILED:' "$ubq_log"; then
                sed -n '/The following tests FAILED:/,$p' "$ubq_log" | sed -n '2,9p' \
                    | sed 's/^/      /' >&2
            else
                tail -4 "$ubq_log" | sed 's/^/      /' >&2
            fi
            echo "      full log: $ubq_log" >&2
        fi
        ubq_i=$((ubq_i + 1))
    done
    echo >&2
    exit 1
fi
echo "pre-push gates: ${#PASSED[@]} passed (${#CACHED[@]} cached). Uncovered here: musl, coverage," >&2
echo "  fuzz, the bench gate, and every test this diff does not reach — the" >&2
echo "  \"tests reaching the diff\" line above says which ran, and says so when none" >&2
echo "  did. UBIQUITTY_PREPUSH=default adds the whole suite, =linux the Linux build." >&2
# A list of names reads as boilerplate. wasm is the one worth a sentence, because
# it is the lane that DISAGREES rather than the lane that is merely missing: it
# builds portable Core against a different standard library, so a header every
# other libc++ hands over transitively can be absent there, and a file every
# other lane accepts can fail on that arm alone.
#
# Printed only when the branch touched what it decides, so a push that cannot be
# affected does not learn to skip a paragraph.
exit 0
