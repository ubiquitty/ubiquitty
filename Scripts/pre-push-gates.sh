#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# Scripts/pre-push-gates.sh — run ci.yml's gates on this machine, before the
# push. A workflow that is disabled or queued is indistinguishable from one that
# passed: nothing goes red, so the tree looks green while nothing has executed.
# These gates are the ones that decide whether a push is sound.
#
# This list composes the app and its pinned Core and Kit: its frontends and the
# arms that build them, over the families ubiquitty-core's
# Scripts/pre-push-gates-core.sh defines. The tiers, runner and summary are
# Scripts/pre-push-gates-lib.sh's.

# The tiers, the runner and the families are ubiquitty-core's, found in the
# checkout that holds them.
# shellcheck source=Scripts/library-scripts.sh
. "$(cd "$(dirname "$0")" && pwd)/library-scripts.sh"
# Keep gate lookup and the cache on the same roots the app loader selected,
# including CMake-form aliases. Preserve any caller's export attributes.
UBQ_CORE_ROOT="$CORE_ROOT"
UBQ_KIT_ROOT="$KIT_ROOT"
# shellcheck source=Scripts/pre-push-gates-lib.sh
source "$CORE_ROOT/Scripts/pre-push-gates-lib.sh"
# shellcheck source=Scripts/pre-push-gates-core.sh
source "$UBQ_CORE_ROOT/Scripts/pre-push-gates-core.sh"
# shellcheck source=Scripts/pre-push-gates-kit.sh
source "$UBQ_KIT_ROOT/Scripts/pre-push-gates-kit.sh"

gate_commit_rules() { core_gate_commit_rules; gate_commit_rules_app; }
gate_style() { core_gate_style; gate_style_app; }
gate_style_without_builds() { core_gate_style_without_builds; gate_style_app_without_builds; }
gate_host() { core_gate_host; gate_host_apple; }
gate_ctest() { core_gate_ctest; }
gate_pgo_drift() { core_gate_pgo_drift; }
gate_forks() { core_gate_forks; }
# Linux arms of the application share one native-host checkout for the push.
# The libraries run their own Linux builds without the application's stage map.
UBQ_LINUX_HOST_RUN="push-$$-$(date +%s)"
export UBQ_LINUX_HOST_RUN

ubq_app_ci_root_finish() {
    local status=$?
    "$ROOT/Scripts/linux-host.sh" release >/dev/null 2>&1 || true
    ubq_ci_root_finish "$status"
}
trap ubq_app_ci_root_finish EXIT

# Decide once, so builds, snapshots and child gates run on the same machine.
ubq_linux_route() {
    if [ -z "${UBQ_LINUX_HOST_ROUTE:-}" ]; then
        UBQ_LINUX_HOST_ROUTE="$("$ROOT/Scripts/linux-host.sh" route)"
        export UBQ_LINUX_HOST_ROUTE
        printf '  %-34s %s\n' "linux arms run on" "$UBQ_LINUX_HOST_ROUTE"
    fi
    UBQ_LINUX_HOST=""
    case "$UBQ_LINUX_HOST_ROUTE" in
        "host "*) UBQ_LINUX_HOST="${UBQ_LINUX_HOST_ROUTE#host }" ;;
    esac
}

gate_linux() {
    if [ "${UBIQUITTY_LINUX_GATE:-on}" = "off" ]; then
        core_gate_linux
        return
    fi
    ubq_linux_route
    if [ -n "$UBQ_LINUX_HOST" ]; then
        run "Core + host on Linux ($UBQ_LINUX_HOST)" ./Scripts/linux-host.sh stages quic host-tests
        run "GTK frontend on Linux ($UBQ_LINUX_HOST)" ./Scripts/linux-host.sh stages linux-build
        return
    fi
    core_gate_linux
    gate_linux_gtk
}

# The commit rules whose subject is the app: the web page, the frontends' capability
# policy, the healing frame and the entry points' flags.
gate_commit_rules_app() {
    run "web fixture" python3 ./Scripts/check-web-fixture.py
    run "frontend capability policy" python3 ./Scripts/check-frontend-capability-policy.py
    run "healing frame pair" python3 ./Scripts/check-healing-frame-pair.py
    run "unwired flags" python3 ./Scripts/check-unwired-flags.py
    run "web host bytes" python3 ./Scripts/check-web-host-bytes.py
    run "web parser entries" python3 ./Scripts/check-web-parser-entries.py
}

# The pre-push gates of the style tier whose subject is the app.
gate_style_app() {
    # CI runs the UI suite; validate its exception tables locally on every push.
    run "UI scenario entries" python3 ./Scripts/check-ui-scenarios.py --entries
    # Prints rather than blocks, and cannot do otherwise: it names a build this
    # machine may not be able to run. A Core type whose layout is pinned by a
    # static_assert in a frontend has that assertion compiled by one build only,
    # so every portable gate passing says nothing about it.
    python3 ./Scripts/check-build-arm.py --since origin/main || true
}

# gate_style_app minus nothing: neither of its gates compiles.
gate_style_app_without_builds() {
    run "UI scenario entries" python3 ./Scripts/check-ui-scenarios.py --entries
    python3 ./Scripts/check-build-arm.py --since origin/main || true
}

# The Apple arms of the host tier: the Swift renderer compiled from clean, the
# framework product, and the macOS headless smokes.
gate_host_apple() {
    kit_gate_apple
    # The headless smokes assert into their exit codes; the runner derives the
    # mode list from the entry point's dispatch, so a smoke added there is gated
    # by the commit that adds it. Runs only
    # when the macOS sources moved, against whatever app the arm gates
    # above already required to be fresh.
    if ubq_select_all || ! git diff --quiet origin/main -- Source/Platform/macOS Scripts/check-macos-smokes.py 2>/dev/null; then
        run "macOS headless smokes" ./Scripts/check-macos-smokes.py
    fi
}

# The GTK frontend in the Linux container, after core_gate_linux has built Core and the host there.
gate_linux_gtk() {
    if [ "${UBIQUITTY_LINUX_GATE:-on}" = "off" ] || ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
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
    ubq_linux_route
    if [ -n "$UBQ_LINUX_HOST" ]; then
        # The host has no warm tree to be cold: its compiler cache is shared by
        # every run directory, so the build is the stage CI runs.
        # Paths shared with the libraries use their owner's relative spelling.
        # LicenseNotices is Core's; BundleLicenseNotices, BundleResources and
        # SwiftInteropStamp are Kit's. The cache also keys both libraries' full
        # commits and dirty diffs, including external source-root overrides.
        run_scoped "GTK frontend compiles on Linux ($UBQ_LINUX_HOST)" \
            "Source/Platform/Linux Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake Scripts/library-scripts.sh cmake/LicenseNotices.cmake cmake/BundleLicenseNotices.cmake cmake/BundleResources.cmake cmake/SwiftInteropStamp.cmake Libraries/ubiquitty-kit Tests/dependent-tests.cmake Scripts/portable-core-sources.txt Scripts/check-core-layer-partition.sh Scripts/linux-host.sh Scripts/ci_batteries.py Scripts/gate_framework.py Scripts/fetch-quic-deps.sh Scripts/build-version.sh Scripts/build-linux-gtk.sh Scripts/check-linux-build-prerequisites.sh Scripts/linux-images.txt Scripts/run-tests.sh Scripts/build-jobs.sh Scripts/build_jobs.py Scripts/build-root.sh Scripts/build_root.py" \
            ./Scripts/linux-host.sh stages linux-build
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
        "Source/Platform/Linux Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake Scripts/library-scripts.sh cmake Libraries/ubiquitty-kit Tests/dependent-tests.cmake Scripts/portable-core-sources.txt Scripts/check-core-layer-partition.sh Scripts/run-linux.sh Scripts/build-version.sh Scripts/build-linux-gtk.sh Scripts/linux-images.txt Scripts/run-tests.sh Scripts/build-jobs.sh Scripts/build_jobs.py Scripts/build-root.sh Scripts/build_root.py" \
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
    # A run that selects every gate (the full tier, CI) renders every arm.
    if ubq_select_all; then
        printf '%s' ' swift portable web linux'
        return 0
    fi
    # Three dots, so the base is the MERGE BASE rather than origin/main's tip:
    # against the tip, every file another branch landed since this branch started
    # reads as changed here, and the arms selected would be theirs.
    changed="$(ubq_changed_with_libraries)" || return 0
    # Consume every path: early grep exit can SIGPIPE printf under pipefail.
    # An unresolved library mount may contain changes to every renderer.
    if printf '%s\n' "$changed" | grep -E '^Libraries/ubiquitty-(core|kit)$' >/dev/null; then
        printf '%s' ' swift portable web linux'
        return 0
    fi
    kit_swift_arm_reached "$changed" && arms="$arms swift"
    printf '%s\n' "$changed" | grep '^Source/Core/' >/dev/null && arms="$arms portable"
    printf '%s\n' "$changed" | grep '^Source/Platform/Web/' >/dev/null && arms="$arms web"
    printf '%s\n' "$changed" | grep '^Source/Platform/Linux/' >/dev/null && arms="$arms linux"
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
            *) printf '%s\n' "$changed" | grep '^Source/Core/' >/dev/null && arms="$arms linux" ;;
        esac
    fi
    printf '%s' "$arms"
}

# The command that gives an arm a binary matching this tree. Commands rather
# than paths: the caller needs something a reader can run, and the paths are
# run.py's business — a second table of them here is one more thing to drift.
ubq_arm_rebuild() {
    case "$1" in
        portable) echo "$UBQ_CORE_ROOT/Scripts/build-core-snapshot.sh" ;;
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

ubq_app_snapshot_sources() {
    local failuresBefore="${#FAILED[@]}"
    # The App composes the three owners; it need not contain their files in
    # one Git tree. Validate the selected roots before any rebuild or render.
    run "snapshot source roots" python3 "$UBQ_CORE_ROOT/Scripts/ubq_roots.py" shell-context \
        --source-root "$ROOT" --core-source-root "$UBQ_CORE_ROOT" --kit-source-root "$UBQ_KIT_ROOT"
    [ "${#FAILED[@]}" -eq "$failuresBefore" ]
}

gate_renderer_snapshots() {
    ubq_app_snapshot_sources || return 0
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
        # The linux arm renders where the hook's Linux arms run (ubq_linux_route).
        # On a Linux host it is CI's own pair of stages, the build and the
        # native render, and nothing there can be a stale binary: it is built
        # from this tree first.
        local arm_host=""
        if [ "$arm" = "linux" ]; then
            ubq_linux_route
            arm_host="$UBQ_LINUX_HOST"
            [ -z "$arm_host" ] || printf '  %-34s %s\n' "snapshot arm: linux" "rendering on $arm_host"
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
        if [ -n "$arm_host" ]; then
            "$ROOT/Scripts/linux-host.sh" stages linux-build linux-snapshots >"$arm_log" 2>&1 || status=$?
        else
            python3 "$UBQ_CORE_ROOT/Tests/Snapshots/run.py" \
                --source-root "$ROOT" --core-source-root "$UBQ_CORE_ROOT" --kit-source-root "$UBQ_KIT_ROOT" \
                --backend "$arm" ${extra[@]+"${extra[@]}"} >"$arm_log" 2>&1 || status=$?
        fi
        if [ "$status" = "2" ] && [ -z "$arm_host" ]; then
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
                python3 "$UBQ_CORE_ROOT/Tests/Snapshots/run.py" \
                    --source-root "$ROOT" --core-source-root "$UBQ_CORE_ROOT" --kit-source-root "$UBQ_KIT_ROOT" \
                    --backend "$arm" ${extra[@]+"${extra[@]}"} >"$arm_log" 2>&1 || status=$?
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
        "Source/Platform/iOS Source/UbiquittyKit Source/UbiquittyRenderKit Source/Platform/Apple Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake cmake Scripts/build-ios.sh Scripts/library-scripts.sh Scripts/build-root.sh Scripts/build-provenance.sh Scripts/portable-core-sources.txt" \
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
        "Source/Platform/iOS Source/UbiquittyKit Source/UbiquittyRenderKit Source/Platform/Apple Source/Core Source/Base Source/PAL CMakeLists.txt Scripts/cmake cmake Scripts/build-ios.sh Scripts/library-scripts.sh Scripts/build-root.sh Scripts/build-provenance.sh Scripts/portable-core-sources.txt Scripts/run-ios-smokes.sh Scripts/ios-simulator.sh" \
        ./Scripts/run-ios-smokes.sh
    # The phone's own build of the Sync wire tests, linked against the archive
    # the app carries: the same source compiled for another ABI is not the same
    # bytes until a run of that build says so.
    run_scoped "iOS Sync conformance" \
        "Source/Core/Protocol/Sync Source/Core Source/Base Source/PAL Tests/Core/Protocol/Sync Tests/Harness.h CMakeLists.txt Scripts/cmake cmake Scripts/build-ios.sh Scripts/library-scripts.sh Scripts/build-root.sh Scripts/run-ios-sync-conformance.sh Scripts/ios-simulator.sh" \
        ./Scripts/run-ios-sync-conformance.sh
    # The real Data Protection backend, which only a simulator process exercises.
    # The Kit's own suite: a repository that carries the Kit does not run it.
    if ubq_runs_here "kit" "iOS protected file"; then
        run_scoped "iOS protected file" \
            "Source/Platform/iOS/ProtectedFile.h Source/UbiquittyKit/Swift/ProtectedFile.swift Source/Platform/POSIX/SystemPAL.cpp Tests/Platform/test_ios_protected_file.cpp Tests/Platform/test_ios_protected_file_probe.swift Tests/Harness.h Scripts/run-ios-protected-file-tests.sh Scripts/ios-simulator.sh Scripts/build-root.sh Scripts/ubq-library.sh" \
            ./Scripts/run-ios-protected-file-tests.sh
    fi
    # The smokes drive the app from INSIDE its own process: they build a
    # recogniser and call the action method themselves. That says nothing about
    # whether the recogniser is installed on the view a finger lands on, or
    # whether UIKit would route two touches to it — both have to hold before any
    # of the arithmetic a smoke checks ever runs. So the UI lane drives the
    # installed app from outside with synthesised touches, and needs its own
    # build because the XCUITest bundle is off by default.
    run_scoped "iOS UI tests build" \
        "Source/Platform/iOS CMakeLists.txt Scripts/cmake cmake Scripts/build-ios.sh Scripts/library-scripts.sh Scripts/run-ios-ui-tests.sh Scripts/build-provenance.sh Scripts/build-root.sh" \
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
        "CMakeLists.txt Source/Platform/macOS/CMakeLists.txt cmake Scripts/cmake Scripts/generate-xcode-workspace.sh Scripts/library-scripts.sh Scripts/check-xcode-workspace.py Scripts/apple-development-teams.py Scripts/macos-deployment-target.txt" \
        ./Scripts/generate-xcode-workspace.sh
    run_scoped "iOS UI tests" \
        "Source/Platform/iOS Source/UbiquittyKit Source/UbiquittyRenderKit CMakeLists.txt Scripts/cmake cmake Scripts/build-ios.sh Scripts/library-scripts.sh Scripts/run-ios-ui-tests.sh Scripts/build-root.sh Scripts/ios-simulator.sh" \
        ./Scripts/run-ios-ui-tests.sh
}

# The drivers are the Kit's own checks of its renderer; a repository that carries
# the Kit does not run them.
gate_swift_renderer_drivers() {
    ubq_runs_here "kit" "swift-renderer drivers" || return 0
    kit_gate_renderer_drivers
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
    # What the push changes, a library read as the files between its pins.
    local changed
    changed="$(ubq_changed_with_libraries 2>/dev/null)" || true
    ubq_select_all || grep -qE '^(Source/(Core|Base|Platform/Web)/|Tests/Snapshots/(cases\.json|golden)|Libraries/ubiquitty-(core|kit)$)' <<<"$changed" || return 0
    if ! command -v emcmake >/dev/null 2>&1; then
        SKIPPED+=("wasm build (no emscripten; emsdk provides emcmake)")
        printf '  %-34s %s\n' "wasm build" "SKIPPED (no emscripten)"
        return
    fi
    # Prove the arm still disagrees with the host before trusting its Core build:
    # a build that compiles everything and says ok is indistinguishable from one
    # whose toolchain quietly stopped rejecting what the host accepts.
    core_gate_wasm_oracle
    run "portable Core on wasm" ./Scripts/build-web.sh
}

ubq_optional_web_snapshots() {
    local status=2
    if [ -f "$UBQ_BUILD_ROOT/web-dist/ubiquitty.wasm" ]; then
        status=0
        python3 "$UBQ_CORE_ROOT/Tests/Snapshots/run.py" \
            --source-root "$ROOT" --core-source-root "$UBQ_CORE_ROOT" --kit-source-root "$UBQ_KIT_ROOT" \
            --backend web --quiet || status=$?
    fi
    if [ "$status" = 2 ] && [ "${SNAPSHOT:-}" != demand ]; then
        echo "app-snapshots: SKIPPED — Web tier unavailable; rebuild with Scripts/build-web.sh (SNAPSHOT=demand requires it)"
        return 0
    fi
    return "$status"
}

gate_snapshots() {
    ubq_app_snapshot_sources || return 0
    if [ "$(uname -s)" = "Darwin" ]; then
        run "macOS app build" ./Scripts/build-macos.sh --no-helpers
        run "snapshot regressions" python3 "$UBQ_CORE_ROOT/Scripts/ci_batteries.py" run apple \
            --only portable-build --only snapshots \
            --source-root "$ROOT" --core-source-root "$UBQ_CORE_ROOT" --kit-source-root "$UBQ_KIT_ROOT"
    else
        run "portable snapshot build" "$UBQ_CORE_ROOT/Scripts/build-core-snapshot.sh"
        run "snapshot regressions" python3 "$UBQ_CORE_ROOT/Tests/Snapshots/run.py" \
            --source-root "$ROOT" --core-source-root "$UBQ_CORE_ROOT" --kit-source-root "$UBQ_KIT_ROOT" \
            --backend portable --quiet
        run "Web snapshot regressions" ubq_optional_web_snapshots
    fi
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
    # The Kit's build modules hold the renderer's flags and source lists; the
    # Kit pin, which carries Core's, may also change those sources outside the
    # App checkout.
    if ! ubq_select_all && ! printf '%s\n' "$changed" | grep -E '^Source/Core/Rendering/|^Source/Platform/macOS/|^Scripts/cmake/(UbiquittyKit|AppleSharedSwift)\.cmake$|^Libraries/ubiquitty-kit$' >/dev/null; then
        printf '  %-34s %s\n' "core builder frames" "none — this branch changes no frame path"
        return 0
    fi
    if [ "$(uname -s)" != "Darwin" ]; then
        SKIPPED+=("core builder frames (needs the macOS app and a Metal device; this host is $(uname -s))")
        return 0
    fi
    run "core builder frames" ./Scripts/check-core-builder-frames.sh
}


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
    # Every gate, each run whatever the push reaches (the lib sets select-all for
    # this tier): what CI runs, run here.
    full)    gate_pgo_drift; gate_style; gate_commit_rules; gate_host; gate_forks; gate_wasm; gate_core_builder_frames; gate_ctest; gate_linux; gate_snapshots; gate_ios; gate_esctest ;;
    # The families UBQ_PREPUSH_FAMILIES names, in order: CI's entry.
    families) ubq_run_families ;;
    *)
        echo "pre-push gates: unknown tier '$TIER' (want lint|quick|ctest|linux|full|families)" >&2
        exit 1
        ;;
esac

ubq_pre_push_finish
