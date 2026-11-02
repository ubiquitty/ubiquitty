#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Scripts/check-web-gpu-parity.sh — does the browser's GPU path draw what its
# CPU path draws?
#
# Usage:
#   ./Scripts/check-web-gpu-parity.sh          # after Scripts/build-web.sh
#   ./Scripts/check-web-gpu-parity.sh proportional-glyph-parity
#   ./Scripts/check-web-gpu-parity.sh doubled-run-parity
#   ./Scripts/check-web-gpu-parity.sh cursor-tier-parity
#   ./Scripts/check-web-gpu-parity.sh ligature-parity
#
# why this exists
#
# `page-smoke.mjs` runs the page against a stub DOM, so it proves the page
# reaches a frame and nothing about what is in it. Every C++ test reaches
# `WebTerminal`, which produces INSTANCES — the shaders that consume them are
# tested by nothing at all. Between the two sits every bug where the streams are
# right and the drawing is wrong.
#
# Two-cell glyphs are the case that shows this gap. A wide glyph draws from its
# own atlas page, and that page is the same SIZE as the mono one but its slots
# are two cells across — so the same normalized coordinate names a different
# glyph on each. A pass binding the wrong page draws a real, sharply rendered,
# WRONG glyph. Not a blank, not a fallback box: only a reader of the language
# can see it, so no check of the instance streams catches it.
#
# The CPU raster reads both pages and is correct independently, so it is the
# oracle. Comparing the GPU against itself — before and after, or one build
# against another — would pass against any bug that is stable frame to frame,
# which is every bug this pass can have.
#
# Opt-in, and not in pre-push. It needs Google Chrome, and this repository has
# no browser dependency anywhere else; a gate that fails for want of a browser
# on one developer's machine is worse than one that has to be asked for.
#
# The comparison admits DISPLACEMENT and nothing else: a pixel counts only when
# it matches no position in its 3x3 neighbourhood in the other arm. Two
# rasterizers resolve a quad whose edges miss the pixel grid a fraction apart,
# and the colour square reaches past its cells so its edges always miss —
# compared exactly it reports a hundred pixels for the same picture drawn a
# pixel over, which is the order of a wrong glyph and leaves no margin between
# them. Content has no neighbour to match at any offset, so a wrong page still
# fails everywhere.
#
# Controlled both ways, and the control is what licenses the relaxation: binding
# the mono page into the wide pass reports 349 differing pixels across columns
# 0-5, which read 0 without it.
#
# It reports DIFFER today on the colour square alone — 13 pixels, the emoji's
# top row and its right edge, where the CPU raster and the GL pass sample the
# sheet half a texel apart under NEAREST. The wide-glyph binding this exists for
# is green, which the per-population counts in the verdict say directly. Which
# sampling convention is canonical is the open question, and it is not decidable
# from these two images: both draw the emoji, in the same place, from the same
# instance.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
cd "$ROOT" || exit 1

DIST="$UBQ_BUILD_ROOT/web-dist"
CHROME="${UBQ_WEB_BROWSER:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROBE="${1:-wide-glyph-parity}"
case "$PROBE" in
wide-glyph-parity|proportional-glyph-parity|doubled-run-parity|scaled-run-at-size|cursor-tier-parity|font-fallback-parity|box-drawing-parity|ligature-parity) ;;
*) echo "check-web-gpu-parity: unknown probe $PROBE" >&2; exit 2 ;;
esac

if [[ ! -f "$DIST/ubiquitty.wasm" ]]; then
    echo "check-web-gpu-parity: no build at $DIST — run Scripts/build-web.sh first." >&2
    exit 2
fi
if [[ ! -x "$CHROME" ]]; then
    if [[ -n "${UBQ_WEB_BROWSER:-}" ]]; then
        echo "check-web-gpu-parity: configured browser is not executable: $CHROME" >&2
        exit 2
    fi
    echo "check-web-gpu-parity: Google Chrome not found; skipping." >&2
    echo "  This check is opt-in and needs a real WebGL2 context." >&2
    exit 0
fi

cp "$ROOT/Tests/Web/$PROBE.html" "$DIST/$PROBE.html"

# A port from the kernel rather than a guess, so two runs cannot collide.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIST" >/dev/null 2>&1 &
SERVER=$!
cleanup() {
    kill "$SERVER" >/dev/null 2>&1 || true
    rm -f "$DIST/$PROBE.html"
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 50); do
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.1
done

# SwiftShader so this does not depend on the machine's GPU: the question is what
# the shaders compute, not how fast. `--virtual-time-budget` lets the page's
# async module finish before the DOM is dumped.
DOM="$("$CHROME" --headless=new --no-sandbox --enable-unsafe-swiftshader \
    --virtual-time-budget=25000 --dump-dom \
    "http://127.0.0.1:$PORT/$PROBE.html?cb=$$" 2>/dev/null)"

VERDICT="$(printf '%s' "$DOM" | sed -n 's/.*<pre id="verdict">\(.*\)<\/pre>.*/\1/p' | head -1)"

if [[ -z "$VERDICT" || "$VERDICT" == "running" ]]; then
    echo "check-web-gpu-parity: the probe never reported — the page did not reach a frame." >&2
    exit 1
fi
if [[ "$VERDICT" == ERROR* ]]; then
    echo "check-web-gpu-parity: $VERDICT" >&2
    exit 1
fi

echo "check-web-gpu-parity: $VERDICT"
case "$VERDICT" in
*'"verdict":"MATCH"'*) exit 0 ;;
*) echo "  The GPU path disagrees with the CPU raster in $PROBE." >&2; exit 1 ;;
esac
