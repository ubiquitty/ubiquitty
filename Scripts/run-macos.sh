#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# run-macos.sh — launch the built macOS .app.
#   ./Scripts/run-macos.sh              just open Ubiquitty.app
#   ./Scripts/run-macos.sh --console    run in foreground, stream the app's
#                                       diagnostics to the terminal until Ctrl-C

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
APP="$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app"
BIN="$APP/Contents/MacOS/Ubiquitty"

if [ ! -x "$BIN" ]; then
    echo "Not built: $APP" >&2
    echo "Run: ./Scripts/build-macos.sh" >&2
    exit 1
fi

if [ "${1:-}" = "--console" ]; then
    exec "$BIN"
fi

open "$APP"
