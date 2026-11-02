#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# Tests/Control/control_smoke.sh — end-to-end check of the macOS app's
# remote-control socket (Source/Core/Protocol/Control/Server.h).
#
# Drives the live app over its unix-domain socket with real newline-delimited
# JSON-RPC 2.0 and asserts the responses: handshake (ping), ls, new-window,
# get-text, send-text, set-title, the unknown-method error, and — when a token
# is configured — that an unauthenticated request is rejected.
#
# This is an INTEGRATION smoke: the app must be running with the gate on. To
# enable, put this in ~/.config/ubiquitty/config.toml and (re)launch the app:
#
#     [control]
#     enable = true
#     # token = "s3cret"          # optional shared secret
#     # socket_path = "/tmp/ub.sock"  # optional override
#
# With no socket present the script prints how to enable it and SKIPS (exit 0),
# so it is safe to run unconditionally in a suite. Set CONTROL_REQUIRE=1 to turn
# a skip into a failure (for a CI lane that launches the app first).
#
# new-window, send-text and get-text are screened by the agent policy the app
# read at launch ($UBIQUITTY_AGENT_POLICY, else $UBIQUITTY_HOME/agent-policy.conf).
# The run reads the same file and picks its branch from it: a file with
# `default allow`, or with `allow <new window>` + `allow echo` +
# `allow <read screen>`, means the window opens and the typed marker comes
# back; anything else (no file, the built-in confirm default) means every one
# of the three is refused with -32002 forbidden. CONTROL_POLICY_ALLOWS=0|1
# overrides the detection.

set -uo pipefail


fail() { echo "control-smoke: FAIL: $*" >&2; exit 1; }
skip() { echo "control-smoke: SKIP: $*" >&2; [ "${CONTROL_REQUIRE:-0}" = "1" ] && exit 1; exit 0; }

# Resolve the socket path the app would bind: the [control] socket_path override
# if present in config, else ~/.ubiquitty/control.sock (honoring $UBIQUITTY_HOME).
SOCK="${CONTROL_SOCKET:-}"
if [ -z "$SOCK" ]; then
    CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ubiquitty/config.toml"
    if [ -f "$CONF" ]; then
        OVERRIDE="$(awk -F'=' '/^[[:space:]]*socket_path[[:space:]]*=/{gsub(/[" ]/,"",$2);print $2;exit}' "$CONF" 2>/dev/null || true)"
        [ -n "${OVERRIDE:-}" ] && SOCK="$OVERRIDE"
    fi
fi
[ -z "$SOCK" ] && SOCK="${UBIQUITTY_HOME:-$HOME/.ubiquitty}/control.sock"

[ -S "$SOCK" ] || skip "no control socket at $SOCK — launch the app with [control] enable = true"

command -v python3 >/dev/null 2>&1 || skip "python3 not available (needed to drive the socket)"

TOKEN="${CONTROL_TOKEN:-}"

# rpc <method> <json-params> — send one request, print the response line.
# A token, when set, is injected into params so authenticated calls succeed.
rpc() {
    SOCK="$SOCK" TOKEN="$TOKEN" METHOD="$1" PARAMS="${2:-"{}"}" python3 - <<'PY'
import json, os, socket, sys
sock_path = os.environ["SOCK"]
method = os.environ["METHOD"]
params = json.loads(os.environ["PARAMS"])
token = os.environ.get("TOKEN", "")
if token:
    params.setdefault("token", token)
req = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(sock_path)
s.sendall((json.dumps(req) + "\n").encode())
buf = b""
while b"\n" not in buf:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk
s.close()
sys.stdout.write(buf.decode(errors="replace").splitlines()[0] if buf else "")
PY
}

echo "control-smoke: socket = $SOCK"

# The policy the app is holding the socket to, read the way the app reads it.
POLICY_FILE="${UBIQUITTY_AGENT_POLICY:-${UBIQUITTY_HOME:-$HOME/.ubiquitty}/agent-policy.conf}"
policy_allows() {
    [ -f "$POLICY_FILE" ] || return 1
    grep -qE '^[[:space:]]*default[[:space:]]+allow' "$POLICY_FILE" && return 0
    grep -qE '^[[:space:]]*allow[[:space:]]+<new window>' "$POLICY_FILE" \
        && grep -qE '^[[:space:]]*allow[[:space:]]+echo' "$POLICY_FILE" \
        && grep -qE '^[[:space:]]*allow[[:space:]]+<read screen>' "$POLICY_FILE"
}
if [ -n "${CONTROL_POLICY_ALLOWS:-}" ]; then
    ALLOWS="$CONTROL_POLICY_ALLOWS"
elif policy_allows; then
    ALLOWS=1
else
    ALLOWS=0
fi
echo "control-smoke: policy = $POLICY_FILE (allows=$ALLOWS)"

# 1. ping → method catalog.
echo "control-smoke: ping"
R="$(rpc ping)"
echo "$R" | grep -q '"ubiquitty-control"' || fail "ping: no server name ($R)"
echo "$R" | grep -q '"send-text"'         || fail "ping: catalog missing send-text ($R)"

# 2. ls → at least one window with tabs + panes.
echo "control-smoke: ls"
R="$(rpc ls)"
echo "$R" | grep -q '"windows"' || fail "ls: no windows array ($R)"
echo "$R" | grep -q '"panes"'   || fail "ls: no panes in window ($R)"

# 3 + 4. new-window, then send-text into it and get-text back. Under a policy
#        that allows them the window opens and the marker lands on screen; under
#        any other policy all three are refused with the policy's own code.
MARK="CTLMARK_$$"
if [ "$ALLOWS" = "1" ]; then
    echo "control-smoke: new-window (policy allows)"
    BEFORE="$(rpc ls | grep -o '"id"' | wc -l | tr -d ' ')"
    R="$(rpc new-window)"
    echo "$R" | grep -q '"window"' || fail "new-window: no window id ($R)"
    sleep 0.5
    AFTER="$(rpc ls | grep -o '"id"' | wc -l | tr -d ' ')"
    [ "$AFTER" -ge "$BEFORE" ] || fail "new-window: window count did not grow ($BEFORE -> $AFTER)"
    WID="$(echo "$R" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["result"]["window"])')"
    echo "control-smoke: new window id = $WID"

    echo "control-smoke: send-text + get-text (policy allows)"
    R="$(rpc send-text "{\"window\":$WID,\"text\":\"echo $MARK\\n\"}")"
    echo "$R" | grep -q '"sent"' || fail "send-text: not sent under an allowing policy ($R)"
    # A fresh window's shell may still be starting; the marker is polled for.
    R=""
    for _tick in $(seq 1 25); do
        R="$(rpc get-text "{\"window\":$WID,\"source\":\"screen\"}")"
        echo "$R" | grep -q "$MARK" && break
        sleep 0.4
    done
    echo "$R" | grep -q "$MARK" || fail "get-text: screen lacks the echoed marker ($R)"
else
    echo "control-smoke: new-window + send-text + get-text (policy refuses)"
    R="$(rpc new-window)"
    echo "$R" | grep -q -- '-32002' || fail "new-window: not refused by the policy ($R)"
    echo "$R" | grep -q '"window"' && fail "new-window: a refused request still opened a window ($R)"
    R="$(rpc send-text "{\"text\":\"echo $MARK\\n\"}")"
    echo "$R" | grep -q -- '-32002' || fail "send-text: not refused by the policy ($R)"
    R="$(rpc get-text '{"source":"screen"}')"
    echo "$R" | grep -q -- '-32002' || fail "get-text: not refused by the policy ($R)"
    echo "$R" | grep -q "$MARK" && fail "get-text: a refused read still returned the screen ($R)"
    WID="$(rpc ls | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["result"]["windows"][0]["id"])')"
fi

# 5. set-title pins a user title; ls reflects it.
echo "control-smoke: set-title"
rpc set-title "{\"window\":$WID,\"title\":\"SmokeTitle_$$\"}" >/dev/null
sleep 0.3
rpc ls | grep -q "SmokeTitle_$$" || fail "set-title: ls does not show the new title"

# 6. unknown method → JSON-RPC error.
echo "control-smoke: unknown method → error"
R="$(rpc no/such/method)"
echo "$R" | grep -q '"error"' || fail "unknown method did not return an error ($R)"

# 7. token enforcement (only when a token is configured for this run).
if [ -n "$TOKEN" ]; then
    echo "control-smoke: bad token rejected"
    R="$(CONTROL_TOKEN="" rpc ls)"  # drop the token: must be unauthorized
    echo "$R" | grep -q 'unauthorized' || fail "missing-token request was not rejected ($R)"
fi

echo "control-smoke: PASS"
exit 0
