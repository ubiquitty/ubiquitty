#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-web-demo.sh — one command from a clean tree to a browser attached to a
# local host, and nothing left running when it exits.
#
# Builds the wasm frontend and the daemon, starts the daemon, mints a token,
# bridges it to WebSocket, serves the staged page, and opens it. Ctrl-C tears
# all three down.
#
# Three things this script exists to get right, each of which cost real time
# when done by hand:
#
#   The build type is named and then VERIFIED. An unset CMAKE_BUILD_TYPE means
#   no optimisation flags, not a default, and a -O0 daemon is indistinguishable
#   from a slow one across the wire — it has cost an hour twice. The daemon is
#   also built in a directory of its own, because Core's Scripts/run-tests.sh
#   configures build/host as Debug for its own (correct) reasons and whichever
#   ran last decides what build/host/ubiquitty-host is.
#
#   Every process is torn down on exit. Six daemons once accumulated over a
#   night, each holding the binary it was exec'd with; a browser tab pointed at
#   one of them was running code from before a rebuild, with nothing in the tree
#   to show for it.
#
#   Ports are taken, not assumed. A stale server on the port you wanted serves a
#   stale build and looks exactly like the fresh one.
#
# The bridge hands whoever it admits this user's own socket, so it admits only
# this page: its origin, a per-run secret path in the attach URL, and the token
# the daemon checks. The daemon keeps its token requirement, and both servers
# listen on loopback alone.
#
#   ./Scripts/run-web-demo.sh [--columns N] [--rows N] [--no-open] [--keep] [--stable]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
BUILD="$UBQ_BUILD_ROOT/host-demo"
STAGE="$UBQ_BUILD_ROOT/web-dist"
# Under the build root, which this user owns, not a fixed name in /tmp that
# another user can create first and fill with links.
HOME_DIR="${UBIQUITTY_DEMO_HOME:-$UBQ_BUILD_ROOT/web-demo-home}"

COLUMNS_ARG=120
ROWS_ARG=34
OPEN_BROWSER=1
KEEP=0
STABLE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//; p' "$0"; exit 0 ;;
        --columns) COLUMNS_ARG="${2:?--columns needs a number}"; shift 2 ;;
        --rows)    ROWS_ARG="${2:?--rows needs a number}"; shift 2 ;;
        --no-open) OPEN_BROWSER=0; shift ;;
        --keep)    KEEP=1; shift ;;
        --stable)  STABLE=1; shift ;;
        *) echo "run-web-demo: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# A port nothing is listening on. Asking the kernel for one beats a constant:
# a previous run's server answers on the constant and serves its own stale
# build, which is indistinguishable from a working fresh one.
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# --stable: the same URL every run.
#
# The browser keys localStorage by ORIGIN, and an origin includes the port. With
# a kernel-chosen port every restart is a fresh origin with an empty store, so a
# theme the user picked is gone the next time the demo comes up — which reads as
# the setting not persisting rather than as the URL having moved.
#
# The token has to be stable for the same reason: it is in the URL.
#
# The stale-server hazard the comment above names is real and is handled rather
# than accepted. A listener on the fixed port that is not this script's previous
# run is refused loudly, because serving someone else's build from the URL we
# just printed is worse than not starting.
STABLE_WS_PORT=7681
STABLE_HTTP_PORT=7680
PORT_OWNER_FILE="$HOME_DIR/.stable-ports.pid"

stop_previous_stable_run() {
    [ -f "$PORT_OWNER_FILE" ] || return 0
    while read -r pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done < "$PORT_OWNER_FILE"
    rm -f "$PORT_OWNER_FILE"
    sleep 1
}

port_is_free() {
    python3 -c "import socket,sys; s=socket.socket(); sys.exit(1 if s.connect_ex(('127.0.0.1', $1)) == 0 else 0)"
}

DAEMON_PID=""
PROXY_PID=""
HTTP_PID=""

cleanup() {
    [ "$KEEP" = "1" ] && { echo "run-web-demo: --keep, leaving the daemon, proxy and server running" >&2; return; }
    for pid in "$HTTP_PID" "$PROXY_PID" "$DAEMON_PID"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    rm -f "$HOME_DIR"/host-*.sock 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- the page -------------------------------------------------------------

echo "run-web-demo: building the browser frontend" >&2
"$ROOT/Scripts/build-web.sh" >/dev/null
if [ ! -f "$STAGE/ubiquitty.wasm" ]; then
    echo "run-web-demo: no staged page at $STAGE — build-web.sh skips without emscripten" >&2
    exit 1
fi

# --- the daemon -----------------------------------------------------------

echo "run-web-demo: building the daemon (Release)" >&2
cmake -S "$ROOT" -B "$BUILD" -G Ninja \
    -DUBIQUITTY_FRONTEND=Host -DCMAKE_BUILD_TYPE=Release >/dev/null
# Read it back rather than trust the flag. A cache configured earlier with a
# different type keeps that type unless it is overridden, and the build then
# succeeds while producing something nobody asked for.
RESOLVED_TYPE="$(sed -n 's/^CMAKE_BUILD_TYPE:STRING=//p' "$BUILD/CMakeCache.txt")"
if [ "$RESOLVED_TYPE" != "Release" ]; then
    echo "run-web-demo: $BUILD resolved to '$RESOLVED_TYPE', not Release — refusing to serve an unoptimised host" >&2
    exit 1
fi
cmake --build "$BUILD" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)" >/dev/null
echo "run-web-demo: daemon is $RESOLVED_TYPE" >&2

(umask 077 && mkdir -p "$HOME_DIR")
if [ ! -O "$HOME_DIR" ] || [ -L "$HOME_DIR" ]; then
    echo "run-web-demo: $HOME_DIR is not a directory this user owns" >&2
    exit 1
fi
chmod 700 "$HOME_DIR"
rm -f "$HOME_DIR"/host-*.sock

UBIQUITTY_HOME="$HOME_DIR" \
    "$BUILD/ubiquitty-host" --daemon --columns "$COLUMNS_ARG" --rows "$ROWS_ARG" \
    > "$HOME_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!

SOCKET=""
for _ in $(seq 1 60); do
    SOCKET="$(ls "$HOME_DIR"/host-*.sock 2>/dev/null | head -1 || true)"
    [ -n "$SOCKET" ] && break
    sleep 0.1
done
if [ -z "$SOCKET" ]; then
    echo "run-web-demo: the daemon never opened a socket" >&2
    sed -n '1,20p' "$HOME_DIR/daemon.log" >&2
    exit 1
fi

# The page reaches the daemon through Scripts/web-proxy.py, whose peer binary is
# python3 — not one of the daemon's own, so it lands in the gated Agent tier and
# must present a token, as it would to any host.
TOKEN=""
TOKEN_FILE="$HOME_DIR/.stable-token"
if [ "$STABLE" = "1" ] && [ -f "$TOKEN_FILE" ]; then
    # Reused only when the store it was minted against still exists. A token
    # from a wiped home is refused with AUTH_DENIED and the page just sits at
    # "handshaking", which is the least diagnosable failure this script has.
    TOKEN="$(cat "$TOKEN_FILE")"
    if ! UBIQUITTY_HOME="$HOME_DIR" "$BUILD/ubiquitty-host" token list 2>/dev/null | grep -q "web-demo"; then
        echo "run-web-demo: the stored token no longer matches this home; minting a new one" >&2
        TOKEN=""
    fi
fi
if [ -z "$TOKEN" ]; then
    TOKEN="$(UBIQUITTY_HOME="$HOME_DIR" "$BUILD/ubiquitty-host" token issue --scope all --label web-demo 2>/dev/null | tail -1)"
    [ "$STABLE" = "1" ] && [ -n "$TOKEN" ] && (umask 077 && printf '%s\n' "$TOKEN" > "$TOKEN_FILE")
fi
if [ -z "$TOKEN" ]; then
    echo "run-web-demo: could not mint a token" >&2
    exit 1
fi

# --- the bridges ----------------------------------------------------------

if [ "$STABLE" = "1" ]; then
    stop_previous_stable_run
    for p in "$STABLE_WS_PORT" "$STABLE_HTTP_PORT"; do
        if ! port_is_free "$p"; then
            echo "run-web-demo: port $p is in use by something that is not this script's previous run." >&2
            echo "run-web-demo: refusing --stable rather than serving whatever is already there." >&2
            exit 1
        fi
    done
    WS_PORT="$STABLE_WS_PORT"
else
    WS_PORT="$(free_port)"
fi
if [ "$STABLE" = "1" ]; then HTTP_PORT="$STABLE_HTTP_PORT"; else HTTP_PORT="$(free_port)"; fi

# The bridge's secret path is in the URL, so --stable keeps it as it keeps the token.
BRIDGE_PATH=""
BRIDGE_PATH_FILE="$HOME_DIR/.stable-bridge-path"
[ "$STABLE" = "1" ] && [ -f "$BRIDGE_PATH_FILE" ] && BRIDGE_PATH="$(cat "$BRIDGE_PATH_FILE")"
if [ -z "$BRIDGE_PATH" ]; then
    BRIDGE_PATH="/$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    [ "$STABLE" = "1" ] && (umask 077 && printf '%s\n' "$BRIDGE_PATH" > "$BRIDGE_PATH_FILE")
fi

UBIQUITTY_HOME="$HOME_DIR" python3 "$ROOT/Scripts/web-proxy.py" --socket "$SOCKET" --port "$WS_PORT" \
    --path "$BRIDGE_PATH" --origin "http://127.0.0.1:$HTTP_PORT" --origin "http://localhost:$HTTP_PORT" \
    > "$HOME_DIR/proxy.log" 2>&1 &
PROXY_PID=$!

( cd "$STAGE" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 ) > "$HOME_DIR/http.log" 2>&1 &
HTTP_PID=$!

# Both bridges are separate processes that can fail after fork — a bound port is
# the only proof either is actually serving.
sleep 1
for probe in "$WS_PORT:proxy" "$HTTP_PORT:page server"; do
    port="${probe%%:*}"; what="${probe#*:}"
    if ! python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1', $port)) == 0 else 1)"; then
        echo "run-web-demo: the $what is not listening on $port" >&2
        cat "$HOME_DIR/proxy.log" "$HOME_DIR/http.log" 2>/dev/null >&2
        exit 1
    fi
done

if [ "$STABLE" = "1" ]; then
    printf '%s\n%s\n%s\n' "$HTTP_PID" "$PROXY_PID" "$DAEMON_PID" > "$PORT_OWNER_FILE"
fi

URL="http://127.0.0.1:$HTTP_PORT/?attach=ws://127.0.0.1:$WS_PORT$BRIDGE_PATH&token=$TOKEN"

echo >&2
echo "  $URL" >&2
echo >&2
echo "run-web-demo: ${COLUMNS_ARG}x${ROWS_ARG}, home $HOME_DIR, Ctrl-C to stop" >&2

if [ "$OPEN_BROWSER" = "1" ]; then
    if command -v open >/dev/null 2>&1; then
        open "$URL"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL"
    else
        echo "run-web-demo: no opener found — the URL above is the whole of it" >&2
    fi
fi

# Hold the processes. Waiting on the daemon specifically: it owns the shell, so
# its exit is the one that means the session is over.
wait "$DAEMON_PID"
