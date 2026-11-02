#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# Tests/Control/control_gate_lane.sh — launches the built macOS app against a
# private home and drives its control socket through control_smoke.sh twice:
# once with no rule file, where new-window, send-text and get-text must all be
# refused, and once with a rule file that allows them, where the typed marker
# must come back on screen. A socket that stops consulting the gate fails the
# first run; a gate that refuses what the rule file allows fails the second.
#
# The app is the worktree's own build (Scripts/build-macos.sh), found through
# the build root; the user's instance is never touched. UBIQUITTY_APP_BIN
# overrides the binary. SKIPs with no app unless CONTROL_REQUIRE=1.
#

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"

fail() { echo "control-gate-lane: FAIL: $*" >&2; exit 1; }
skip() { echo "control-gate-lane: SKIP: $*" >&2; [ "${CONTROL_REQUIRE:-0}" = "1" ] && exit 1; exit 0; }

APP="${UBIQUITTY_APP_BIN:-$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app/Contents/MacOS/Ubiquitty}"
[ -x "$APP" ] || skip "no built app at $APP (run Scripts/build-macos.sh)"
[ "$(uname)" = "Darwin" ] || skip "the app runs on macOS"

# sun_path holds 104 bytes, so the private home lives under /tmp rather than
# a deeper scratch directory.
WORK="$(mktemp -d /tmp/ubq-gate.XXXXXX)"
HOME_DIR="$WORK/.ubiquitty"
CONFIG_DIR="$WORK/config/ubiquitty"
mkdir -p "$HOME_DIR" "$CONFIG_DIR"
printf '[control]\nenable = true\n' > "$CONFIG_DIR/config.toml"
ALLOW_POLICY="$WORK/allow.conf"
printf 'allow <new window>\nallow echo\nallow <read screen>\n' > "$ALLOW_POLICY"
SOCK="$HOME_DIR/control.sock"

APP_PID=""
stop_app() {
    [ -n "$APP_PID" ] || return 0
    kill "$APP_PID" 2>/dev/null
    sleep 1
    kill -9 "$APP_PID" 2>/dev/null
    APP_PID=""
}
trap 'stop_app; rm -rf "$WORK"' EXIT

# run_lane <label> [ENV=VALUE ...] — launch the app with the given environment,
# wait for its socket, run the smoke, stop the app.
run_lane() {
    local label="$1"; shift
    rm -f "$SOCK"
    env UBIQUITTY_HOME="$HOME_DIR" XDG_CONFIG_HOME="$WORK/config" "$@" "$APP" > "$WORK/app-$label.log" 2>&1 &
    APP_PID=$!
    disown "$APP_PID"
    local _tick
    for _tick in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 0.5; done
    [ -S "$SOCK" ] || fail "$label: the app bound no socket at $SOCK ($(tail -3 "$WORK/app-$label.log" | tr '\n' ' '))"
    echo "control-gate-lane: $label"
    env UBIQUITTY_HOME="$HOME_DIR" CONTROL_SOCKET="$SOCK" CONTROL_REQUIRE=1 "$@" bash "$ROOT/Tests/Control/control_smoke.sh" \
        || fail "$label: control_smoke.sh failed"
    stop_app
}

run_lane "no rule file: every gated verb is refused"
run_lane "allowing rule file: the marker comes back" UBIQUITTY_AGENT_POLICY="$ALLOW_POLICY"

AUDIT="$HOME_DIR/agent-audit.log"
[ -s "$AUDIT" ] || fail "no audit log at $AUDIT"
grep -qE 'control-send\(window=[0-9]+ pane=[0-9]+\) confirm: echo CTLMARK_' "$AUDIT" || fail "the refused send is not in the audit trail"
grep -qE 'control-screen\(window=[0-9]+ pane=[0-9]+\) confirm: <read screen> source=screen' "$AUDIT" || fail "the refused read is not in the audit trail"
grep -qE 'control-new confirm: <new window>' "$AUDIT" || fail "the refused new-window is not in the audit trail"
grep -qE 'control-send\(window=[0-9]+ pane=[0-9]+\) allow: echo CTLMARK_' "$AUDIT" || fail "the allowed send is not in the audit trail"
grep -qE 'control-screen\(window=[0-9]+ pane=[0-9]+\) allow: <read screen> source=screen' "$AUDIT" || fail "the allowed read is not in the audit trail"
grep -qE 'control-new allow: <new window>' "$AUDIT" || fail "the allowed new-window is not in the audit trail"

echo "control-gate-lane: PASS"
exit 0
