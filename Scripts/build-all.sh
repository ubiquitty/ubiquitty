#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# build-all.sh — build every frontend over the shared Core/Sync layer in one
# shot: the ubiquitty-host daemon, the ubq client, and the macOS app.
#
# All three are Sync-protocol clients of the same wire, so they must stay
# LOCK-STEP. Rebuilding only one (e.g. the agent but not the host daemon) lets a
# stale binary silently mask a protocol/behavior change in another — a real
# footgun: an old daemon dropped an OSC-133 exit code a fresh agent expected, so
# the agent smoke failed against a stale host even though the code was correct.
# Building them together avoids that drift.
#
#   ./Scripts/build-all.sh             # release: host + agent + macOS app
#   ./Scripts/build-all.sh --headless  # host + agent only (skip the slow macOS build)
#   ./Scripts/build-all.sh --smoke     # also run the host + agent smokes on the fresh binaries
#   ./Scripts/build-all.sh --debug     # debug builds (passed through to each)
#   ./Scripts/build-all.sh --clean     # wipe each build dir first (passed through)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
HEADLESS=0
SMOKE=0
PASS=""   # flags forwarded to each sub-build (no spaces, so word-splitting is fine)
for arg in "$@"; do
    case "$arg" in
        --headless) HEADLESS=1 ;;
        --smoke)    SMOKE=1 ;;
        --debug|--clean) PASS="$PASS $arg" ;;
        *) echo "build-all: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

echo "== build-all: host daemon =="
"$ROOT/Scripts/build-host.sh" $PASS
echo "== build-all: agent client =="
"$ROOT/Scripts/build-agent.sh" $PASS
if [ "$HEADLESS" = "0" ]; then
    echo "== build-all: macOS app =="
    "$ROOT/Scripts/build-macos.sh" $PASS
fi

if [ "$SMOKE" = "1" ]; then
    echo "== build-all: smokes on the fresh host + agent =="
    export UBIQUITTY_HOST_BIN="$UBQ_BUILD_ROOT/host/ubiquitty-host"
    export UBQ_BIN="$UBQ_BUILD_ROOT/agent/ubq"
    "$ROOT/Tests/Host/smoke.sh"
    "$ROOT/Tests/Agent/smoke.sh"
    "$ROOT/Tests/Agent/mcp_smoke.sh"
    "$ROOT/Tests/Agent/auth_smoke.sh"
    # The app lane drives the fresh macOS build over its control socket; it
    # SKIPs where there is no app to launch.
    "$ROOT/Tests/Control/control_gate_lane.sh"
fi

echo "build-all: done"
