#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# run-ui-tests.sh — build + run the in-process UI integration suite.
#
#   ./Scripts/run-ui-tests.sh              build (if needed) + run default scenarios
#   ./Scripts/run-ui-tests.sh <name>...    run the named scenarios
#   ./Scripts/run-ui-tests.sh list         list registered scenarios
#   ./Scripts/run-ui-tests.sh --clean ...  wipe the UI-test build dir first
#   ./Scripts/run-ui-tests.sh --visible <name>...  run on-screen window tests
#   ./Scripts/run-ui-tests.sh --real-general-pasteboard <name>...
#                                            use the system-wide board in a
#                                            marked disposable GUI session
#
# Every name given must match a registered scenario. A name that matches none
# is named in the output and fails the run, rather than leaving the run to
# report a green earned by the names beside it.
# Scenarios requiring an external probe or updater are opt-in. Naming one
# explicitly still runs it and reports REFUSED when its environment is absent.
#
# Exit 0 every scenario passed, 1 a scenario failed, 2 a scenario was REFUSED
# and none failed: the machine could not give it what it needs (no
# pseudo-terminal left, say, or an operator's probe without its daemon), so
# the run says nothing about the cases it could not drive. A caller that treats 2
# as a product failure reports the machine as a regression.
#
# Drives the REAL window/pane/tmux UI from code (see Source/Platform/macOS/UITest).
# Builds into a SEPARATE build/macos-uitest with -DUBIQUITTY_UI_TESTS=ON so the normal
# build/macos stays free of test code. Needs a logged-in GUI session (the harness
# creates off-screen NSWindows; activation policy is Accessory so it won't steal
# focus). Exits 0 only when every selected scenario passes.

set -euo pipefail

# The app starts an attach bridge to its own host, and a bridge that reads
# SSH_CONNECTION marks its client as one on another machine, whose sessions
# are gated as a remote client's. A runner launched over ssh would hand the
# variable to the app and so to every bridge it starts; a scenario that models
# an SSH attach sets the variable itself.
unset SSH_CONNECTION SSH_CLIENT SSH_TTY

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
# shellcheck source=Scripts/test-run-hygiene.sh
. "$ROOT/Scripts/test-run-hygiene.sh"
# The app and its helper host must link the same persistent QUIC build. CMake's
# source-tree default otherwise makes every managed worktree compile AWS-LC and
# ngtcp2 again instead of using the checkout-specific DerivedData cache.
export UBIQUITTY_QUIC_PREFIX="${UBIQUITTY_QUIC_PREFIX:-$UBQ_BUILD_ROOT/quic-deps}"
# A caller may aim the UI-test build at its own dir and add configure flags, and
# both COMPOSE with the harness flag rather than being overridden by it. This is
# not cosmetic: when the script silently discarded a caller's -D, a build variant
# selected by define came out as the DEFAULT one, and the run's own output could
# not tell the two apart — four scenario runs were compared against themselves
# before that was noticed.
UIBUILD="${UBIQUITTY_BUILD_DIR:-$UBQ_BUILD_ROOT/macos-uitest}"
UITEST_CMAKE_EXTRA="${UBIQUITTY_CMAKE_EXTRA:+$UBIQUITTY_CMAKE_EXTRA }-DUBIQUITTY_UI_TESTS=ON"
APP="$UIBUILD/Source/Platform/macOS/Ubiquitty.app"
BUILD_LOCK="$UBQ_BUILD_ROOT/.run-ui-tests-build.lock"
BUILD_LOCK_OWNED=""
SANDBOX_CONFIG_HOME=""
TMUX_TMPDIR=""

release_build_lock() {
    if [[ -n "$BUILD_LOCK_OWNED" ]]; then
        rm -f "$BUILD_LOCK/pid"
        rmdir "$BUILD_LOCK" 2>/dev/null || true
        BUILD_LOCK_OWNED=""
    fi
}

cleanup() {
    local exitStatus=$?
    local socket
    if command -v tmux >/dev/null 2>&1 && [[ -n "$TMUX_TMPDIR" && -d "$TMUX_TMPDIR" ]]; then
        while IFS= read -r -d '' socket; do
            tmux -S "$socket" kill-server >/dev/null 2>&1 || true
        done < <(find "$TMUX_TMPDIR" -type s -print0 2>/dev/null)
    fi
    if [[ -n "$TMUX_TMPDIR" ]]; then
        rm -rf "$TMUX_TMPDIR"
    fi
    if [[ -n "$SANDBOX_CONFIG_HOME" ]]; then
        rm -rf "$SANDBOX_CONFIG_HOME"
    fi
    # A scenario's daemon, or one a client's bridge started detached while
    # redialling, ends with the run; one found still alive after a run that
    # completed fails it, as does an entry the real state directory gained.
    # An interrupted run (129 and up) is only cleaned up.
    if ((exitStatus < 129)) && ! ubq_hygiene_judge run-ui-tests.sh; then
        [[ "$exitStatus" -ne 0 ]] || exitStatus=1
    fi
    ubq_hygiene_reap || true
    release_build_lock
    trap - EXIT
    exit "$exitStatus"
}

acquire_build_lock() {
    local lockError
    local nextReport=$((SECONDS + 30))
    local owner
    local startedAt=$SECONDS
    if ! mkdir -p "$UBQ_BUILD_ROOT"; then
        echo "ERROR: cannot create UI-test build root: $UBQ_BUILD_ROOT" >&2
        return 1
    fi
    while true; do
        if lockError="$(mkdir "$BUILD_LOCK" 2>&1)"; then
            break
        fi
        # A failed mkdir means contention only while the lock directory
        # exists. Retry once across the release race; a second failure with no
        # lock is a real filesystem error and must not become an infinite wait.
        if [[ ! -d "$BUILD_LOCK" ]]; then
            if lockError="$(mkdir "$BUILD_LOCK" 2>&1)"; then
                break
            fi
            if [[ ! -d "$BUILD_LOCK" ]]; then
                echo "ERROR: cannot create UI-test build lock $BUILD_LOCK: $lockError" >&2
                return 1
            fi
        fi
        owner=""
        if [[ -r "$BUILD_LOCK/pid" ]]; then
            IFS= read -r owner < "$BUILD_LOCK/pid" || true
        fi
        if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$BUILD_LOCK/pid"
            rmdir "$BUILD_LOCK" 2>/dev/null || true
            continue
        fi
        if ((SECONDS >= nextReport)); then
            echo "Waiting for UI-test build lock${owner:+ (owner PID $owner)} — $((SECONDS - startedAt))s elapsed"
            nextReport=$((SECONDS + 30))
        fi
        sleep 0.1
    done
    BUILD_LOCK_OWNED=1
    printf '%s\n' "$$" > "$BUILD_LOCK/pid"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

CLEAN=""
SCENARIO=""
REAL_GENERAL_PASTEBOARD=""
VISIBLE_WINDOWS=""
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN="--clean" ;;
        --visible) VISIBLE_WINDOWS=1 ;;
        --real-general-pasteboard) REAL_GENERAL_PASTEBOARD=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        # Every name is carried, comma-joined: keeping only the last of
        # several silently drops the rest and still reports the one that ran
        # as the whole run.
        *) SCENARIO="${SCENARIO:+$SCENARIO,}$arg" ;;
    esac
done
SCENARIO="${SCENARIO:-all}"
if [[ -n "$REAL_GENERAL_PASTEBOARD" \
    && "${UBIQUITTY_DISPOSABLE_GUI_SESSION:-}" != "ubiquitty-pasteboard-integration-v1" ]]; then
    echo "REFUSED: --real-general-pasteboard requires UBIQUITTY_DISPOSABLE_GUI_SESSION=ubiquitty-pasteboard-integration-v1" >&2
    exit 2
fi

# The adoption scenarios validate the running app's code signature. Helpers
# must be present before signing; adding one from inside a scenario breaks the seal.
acquire_build_lock
echo "Building UI-test bundle ($UITEST_CMAKE_EXTRA) → $UIBUILD"
UBIQUITTY_BUILD_DIR="$UIBUILD" UBIQUITTY_CMAKE_EXTRA="$UITEST_CMAKE_EXTRA" UBIQUITTY_HELPERS=1 \
    UBIQUITTY_LINUX_HOSTS="${UBIQUITTY_LINUX_HOSTS:-0}" \
    "$ROOT/Scripts/build-macos.sh" ${CLEAN:+$CLEAN}

BIN="$APP/Contents/MacOS/Ubiquitty"
[ -x "$BIN" ] || { echo "ERROR: $BIN not found" >&2; exit 1; }
# An ordinary app ignores the test flag and opens a normal window. Verify the
# linked entry point without launching it, including when the build is reused.
if ! xcrun nm -gU "$BIN" | grep -E ' [Ss] _OBJC_CLASS_\$_UBUITestRunner$' >/dev/null; then
    echo "ERROR: $BIN has no verifiable UI-test entry point; refusing to launch" >&2
    exit 2
fi
# The scenarios run as their own application. User defaults, AppKit's frame
# autosaves and saved window state are keyed by bundle identifier, and under
# the installed app's identifier a run would read the window frames the reader
# last left — so a verdict depended on history, and on a long-lived runner on
# every run before it — and would write its own frames back into the reader's
# preferences. The UI-test build carries an identifier of its own (see
# Source/Platform/macOS/CMakeLists.txt); a bundle that does not is refused
# rather than run, since running it is the leak. plistlib reads the XML and the
# binary form alike, and on any host python3 runs on.
UITEST_BUNDLE_ID="$(python3 -c 'import plistlib, sys
with open(sys.argv[1], "rb") as plist:
    print(plistlib.load(plist).get("CFBundleIdentifier", ""))' "$APP/Contents/Info.plist" 2>/dev/null || true)"
case "$UITEST_BUNDLE_ID" in
    *.uitest) ;;
    *)
        echo "ERROR: $APP carries the bundle identifier '${UITEST_BUNDLE_ID:-none}', not a UI-test one;" >&2
        echo "  running it would read and write the installed app's preferences; refusing to launch. Rebuild with --clean." >&2
        exit 2
        ;;
esac
# Scenarios use the helper already sealed into this exact app.
export UBIQUITTY_UI_TEST_HOST="$APP/Contents/Helpers/ubiquitty-host"
[ -x "$UBIQUITTY_UI_TEST_HOST" ] || { echo "ERROR: the signed test bundle has no host helper." >&2; exit 1; }
if ! codesign --verify --deep --strict "$APP"; then
    echo "ERROR: the UI-test bundle's signature is invalid; refusing to launch." >&2
    exit 2
fi
release_build_lock

# Every run starts from the defaults a fresh install has. The domain and the
# saved state are the test bundle's alone (checked above), so clearing them
# touches nothing the reader owns.
defaults delete "$UITEST_BUNDLE_ID" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Saved Application State/$UITEST_BUNDLE_ID.savedState"
echo "Defaults domain:     $UITEST_BUNDLE_ID (cleared)"

echo
echo "Running scenario(s): $SCENARIO"
echo "────────────────────────────────────────────"
# SANDBOX the config: scenarios drive the REAL settings setters, which persist
# through configWriteSetting* to config.toml — pointed at the user's file, a
# suite run would corrupt their live config (and their running app live-reloads
# it). Preferences resolution honors $XDG_CONFIG_HOME before $HOME, so a throwaway
# config home isolates every scenario write; cleaned up on exit.
SANDBOX_CONFIG_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ubiquitty-uitest-config.XXXXXX")"
# The same for the host's state directory. A scenario that forks a daemon names
# a directory of its own and puts back what it found; with nothing to put back,
# a bridge that redialled after the scenario started its daemon in the reader's
# own ~/.ubiquitty, beside the installed app's, and nothing ended it.
ubq_hygiene_begin
# tmux appends tmux-<uid>/<socket> to this path. Keep it short enough for
# Darwin's AF_UNIX sun_path even for the longest scenario socket name.
TMUX_TMPDIR="$(mktemp -d /tmp/ubq-tmux.XXXXXX)"
echo "Preferences sandbox: $SANDBOX_CONFIG_HOME"
echo "tmux sandbox:        $TMUX_TMPDIR"
# Run the binary directly (not `open`) so stdout and the exit code come back here.
UITEST_ARGUMENTS=(--ui-test "$SCENARIO")
if [[ -n "$VISIBLE_WINDOWS" ]]; then
    UITEST_ARGUMENTS+=(--ui-test-visible)
fi
if [[ -n "$REAL_GENERAL_PASTEBOARD" ]]; then
    UITEST_ARGUMENTS+=(--ui-test-real-general-pasteboard)
fi
XDG_CONFIG_HOME="$SANDBOX_CONFIG_HOME" TMUX_TMPDIR="$TMUX_TMPDIR" "$BIN" "${UITEST_ARGUMENTS[@]}"
