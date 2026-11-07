#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
# Open the Sync web client, or add a host to this checkout's running browser launcher.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
host=""
should_build=1
extra=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat <<'HELP'
Usage: Scripts/open-web.sh [local|SSH_HOST] [--no-build] [launcher options]

  Scripts/open-web.sh          Open a local workspace in your browser.
  Scripts/open-web.sh devbox      Open devbox through your existing SSH configuration.
  Scripts/open-web.sh local    Add local to the same browser launcher.

A second invocation adds the host to the existing browser's host picker.
The launcher remains in the first terminal; Ctrl+C stops the web bridge only.
Set UBQ_BUILD_ROOT to reuse a prepared build. --no-build uses its current stage.
Extra options pass to serve-web.py (for example --remote-binary or --no-open).
HELP
            exit 0 ;;
        --no-build) should_build=0; shift ;;
        --no-open|--start-host) extra+=("$1"); shift ;;
        --socket|--host-binary|--remote-binary|--remote-socket|--token-file|--name)
            if [ "$#" -lt 2 ]; then echo "open-web: $1 needs a value" >&2; exit 2; fi
            extra+=("$1" "$2"); shift 2 ;;
        -*) echo "open-web: unknown option $1 (see --help)" >&2; exit 2 ;;
        *) if [ -n "$host" ]; then echo "open-web: specify only one host" >&2; exit 2; fi; host="$1"; shift ;;
    esac
done
# Adding another host does not rebuild an already running page. The server's
# owner-only registration file is checked for liveness by serve-web.py.
if [ "$should_build" -eq 1 ] && { [ ! -f "$UBQ_BUILD_ROOT/web-dist/workspace.html" ] || [ ! -f "$UBQ_BUILD_ROOT/web-launcher.json" ]; }; then
    "$ROOT/Scripts/build-web.sh"
fi
args=(--stage "$UBQ_BUILD_ROOT/web-dist" --registry "$UBQ_BUILD_ROOT/web-launcher.json")
if [ -n "$host" ] && [ "$host" != local ]; then
    args+=(--ssh "$host")
else
    args+=(--start-host)
fi
exec python3 "$ROOT/Scripts/serve-web.py" "${args[@]}" ${extra[@]+"${extra[@]}"}
