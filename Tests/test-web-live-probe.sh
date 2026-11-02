#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# test-web-live-probe.sh — a daemon, a bridge and a token, for a probe that
# needs a real host to talk to.
#
# The probes under Tests/Web each say what they measure; this is what they need
# around them. One script rather than one per probe, for the reason the shared
# fixture in Tests/Web/stub-dom.mjs exists: the copies drift, and the one nobody
# runs drifts furthest.
#
# All three are torn down on the way out, including when the probe fails. A
# daemon left holding a temporary home is a process nothing will reap and a
# directory nothing will clean.
#
# The home is temporary and per run. The daemon derives its socket name from the
# home, so two runs sharing one would share a daemon, and a probe that revokes
# tokens would revoke the other run's underneath it.
#
#   Tests/test-web-live-probe.sh <host-binary> <web-dist> <probe-script>
#
set -euo pipefail

HOST_BINARY="${1:?usage: test-web-live-probe.sh <host-binary> <web-dist> <probe-script>}"
WEB_DIST="${2:?usage: test-web-live-probe.sh <host-binary> <web-dist> <probe-script>}"
PROBE="${3:?usage: test-web-live-probe.sh <host-binary> <web-dist> <probe-script>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ubq-web-probe.XXXXXX")"
DAEMON_PID=""
PROXY_PID=""

cleanup() {
    for pid in "$PROXY_PID" "$DAEMON_PID"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    rm -rf "$HOME_DIR"
}
trap cleanup EXIT INT TERM

UBIQUITTY_HOME="$HOME_DIR" \
    "$HOST_BINARY" --daemon --columns 80 --rows 24 >"$HOME_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!

# Wait for the socket rather than sleeping a guess: the daemon writes it once it
# is listening, so its appearance is the readiness signal and a fixed sleep is
# either slower than that or a flake.
SOCKET=""
for _ in $(seq 1 100); do
    for candidate in "$HOME_DIR"/host-*.sock; do
        [ -S "$candidate" ] && SOCKET="$candidate" && break 2
    done
    sleep 0.1
done
if [ -z "$SOCKET" ]; then
    echo "web-live-probe: the daemon never listened" >&2
    cat "$HOME_DIR/daemon.log" >&2
    exit 1
fi

# A port the kernel says is free. A constant would collide with a previous run's
# bridge, and a bridge answering on the port this run wanted serves that run's
# daemon — which looks exactly like this one working.
WS_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

# The bridge admits only an upgrade naming this run's path; a probe sends no
# Origin, so it needs no allowed page.
BRIDGE_PATH="/$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
UBIQUITTY_HOME="$HOME_DIR" python3 "$ROOT/Scripts/web-proxy.py" \
    --socket "$SOCKET" --port "$WS_PORT" --path "$BRIDGE_PATH" >"$HOME_DIR/proxy.log" 2>&1 &
PROXY_PID=$!

for _ in $(seq 1 100); do
    python3 -c "import socket,sys; s = socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1', $WS_PORT)) == 0 else 1)" && break
    sleep 0.1
done

# The bridge's peer is python3, not one of the daemon's own binaries, so the
# daemon holds it to the token it would ask of any agent; a probe whose method
# is revoking the token needs there to be one to revoke.
TOKEN="$(UBIQUITTY_HOME="$HOME_DIR" "$HOST_BINARY" token issue --scope all --label web-live-probe 2>/dev/null | tail -1)"
if [ -z "$TOKEN" ]; then
    echo "web-live-probe: no token was issued" >&2
    exit 1
fi

UBQ_ATTACH_URL="ws://127.0.0.1:$WS_PORT$BRIDGE_PATH" \
UBQ_ATTACH_TOKEN="$TOKEN" \
UBQ_HOST_BINARY="$HOST_BINARY" \
UBIQUITTY_HOME="$HOME_DIR" \
    node "$PROBE" "$WEB_DIST"
