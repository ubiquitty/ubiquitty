#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# run-render-profile.sh — build the macOS app and run its headless `--profile-render`
# GPU render profiler, emitting one JSON object of per-frame latency
# distributions (µs/op) plus a human table on stderr. macOS only (Metal).
#
#   ./Scripts/run-render-profile.sh [out.json] [-- extra --profile-render args]
#
# Renders each representative scene offscreen many times and reports total +
# encode + GPU phase distributions per scene. Diff two runs with
# Scripts/compare-profile.py — the same shape the portable profiler emits.
#
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "run-render-profile.sh: macOS only (needs Metal)" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
OUT="${1:-$ROOT/render-profile-results.json}"
shift || true
[ "${1:-}" = "--" ] && shift

COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
PLATFORM="$(uname -s)-$(uname -m)"

# App-only build (no bundled helpers) is enough to drive the renderer headlessly.
"$ROOT/Scripts/build-macos.sh" --no-helpers >&2

APP="$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app/Contents/MacOS/Ubiquitty"
if [ ! -x "$APP" ]; then
    echo "run-render-profile.sh: app binary not found at $APP" >&2
    exit 2
fi

echo "Profiling render (platform=$PLATFORM commit=$COMMIT) ..." >&2
"$APP" --profile-render --platform "$PLATFORM" --commit "$COMMIT" "$@" > "$OUT"
echo "wrote $OUT" >&2
