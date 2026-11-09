#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# check-core-builder-frames.sh — drive the built macOS app through the portable
# builder and fail when a frame's own report contradicts what the build claims.
# macOS only (needs Metal).
#
#   ./Scripts/check-core-builder-frames.sh
#   ./Scripts/check-core-builder-frames.sh --self-test
#
# Each snapshot must report a completed Core/Metal/Swift frame and what Core's
# builder emitted for it: the `surface-frame-build:` line the snapshot command
# prints after the PNG. A frame whose builder emitted no cell, or no ink for a
# scene that was fed some, was produced by something other than the code under
# test, and the PNG it wrote says nothing about the builder. The multi-frame
# cases retain the same surface, atlas, and damage baseline across updates;
# the palette case verifies invalidation and a stable subsequent frame.
set -euo pipefail

MARKER='ubiquitty-render-path: builder=core compositor=metal encoder=swift'

# One frame's report, read off a snapshot run's output. Prints the verdict's
# reason and returns 1 when the output does not show a frame Core built. The
# second argument is what the scene must have built beyond its cells:
#
#   ink    glyphs, decorations and box fills together are nonzero, because a
#          scene of box-drawing characters builds fills rather than glyphs
#   baked  no glyph instance: with subpixel text off the glyph pass is skipped
#          and every glyph rides in its cell instance, so a glyph here means
#          the preference never reached the builder
#   any    the cells alone
#
# The cells count is the builder's own: zero means no row was built, whatever
# the PNG holds.
judgeFrame() { # <output> <ink|baked|any>
    local output="$1" expectation="$2" report cells glyphs decorations fills
    if ! grep -qxF "$MARKER" <<<"$output"; then
        echo "the snapshot reported no completed Core/Metal/Swift frame"
        return 1
    fi
    report=$(printf '%s\n' "$output" | sed -n 's/^surface-frame-build: //p' | tail -1)
    cells=$(printf '%s\n' "$report" | sed -n 's/^cells=\([0-9][0-9]*\) .*/\1/p')
    glyphs=$(printf '%s\n' "$report" | sed -n 's/.* glyphs=\([0-9][0-9]*\) .*/\1/p')
    decorations=$(printf '%s\n' "$report" | sed -n 's/.* decorations=\([0-9][0-9]*\) .*/\1/p')
    fills=$(printf '%s\n' "$report" | sed -n 's/.* boxFills=\([0-9][0-9]*\)$/\1/p')
    if [ -z "$cells" ] || [ -z "$glyphs" ] || [ -z "$decorations" ] || [ -z "$fills" ]; then
        echo "the frame printed no complete surface-frame-build line ('$report')"
        return 1
    fi
    if [ "$cells" -eq 0 ]; then
        echo "the builder built no cell ($report), so the PNG was produced by" \
            "something other than the code under test"
        return 1
    fi
    if [ "$expectation" = ink ] && [ $((glyphs + decorations + fills)) -eq 0 ]; then
        echo "the builder emitted no glyph, decoration or box fill for a scene" \
            "that was fed ink ($report)"
        return 1
    fi
    if [ "$expectation" = baked ] && [ "$glyphs" -ne 0 ]; then
        echo "the builder ran the glyph pass with subpixel text off ($report)"
        return 1
    fi
    return 0
}

# Planted reports, each of which judgeFrame must refuse, and the shapes the
# shipping snapshot prints, which it must accept. Without these a parser that
# read nothing would pass every case the same way a working frame does.
selfTest() {
    local failures=0 reason
    local good="$MARKER"$'\n''surface-frame-build: cells=384 glyphs=16 decorations=0 boxFills=0'
    local fills="$MARKER"$'\n''surface-frame-build: cells=384 glyphs=0 decorations=0 boxFills=4'
    local occluded="$MARKER"$'\n''surface-frame-build: cells=384 glyphs=0 decorations=0 boxFills=0'
    expectAccepted() { # <label> <output> <expectation>
        if ! reason=$(judgeFrame "$2" "$3"); then
            echo "check-core-builder-frames --self-test: $1 was refused: $reason" >&2
            failures=$((failures + 1))
        fi
    }
    expectRefused() { # <label> <output> <expectation>
        if reason=$(judgeFrame "$2" "$3"); then
            echo "check-core-builder-frames --self-test: $1 was accepted" >&2
            failures=$((failures + 1))
        fi
    }
    expectAccepted "a built text frame" "$good" ink
    expectAccepted "a frame drawn in box fills" "$fills" ink
    expectAccepted "an occluded frame not held to ink" "$occluded" any
    expectAccepted "a frame whose glyphs are baked into its cells" "$occluded" baked
    expectRefused "the marker with no build report" "$MARKER" any
    expectRefused "a build report with no marker" \
        'surface-frame-build: cells=384 glyphs=16 decorations=0 boxFills=0' any
    expectRefused "a frame that built no cell" \
        "$MARKER"$'\n''surface-frame-build: cells=0 glyphs=0 decorations=0 boxFills=0' any
    expectRefused "a fed scene that built no ink" "$occluded" ink
    expectRefused "a glyph pass with subpixel text off" "$good" baked
    expectRefused "a truncated build report" "$MARKER"$'\n''surface-frame-build: cells=384' any
    if [ "$failures" -gt 0 ]; then
        echo "check-core-builder-frames --self-test: $failures failure(s)" >&2
        return 1
    fi
    echo "check-core-builder-frames --self-test: ok (4 built frames accepted, 6 planted reports refused)"
}

if [ "${1:-}" = "--self-test" ]; then
    selfTest
    exit $?
fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "check-core-builder-frames.sh: macOS only (needs Metal)" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
"$ROOT/Scripts/build-macos.sh" --no-helpers >&2

APP="$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app/Contents/MacOS/Ubiquitty"
if [ ! -x "$APP" ]; then
    echo "check-core-builder-frames.sh: app binary not found at $APP" >&2
    exit 2
fi

WORK="$(mktemp -d -t check-core-builder-frames.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

COLUMNS_ARG=48
ROWS_ARG=8
# One tick outside the blink curve's solid hold: inside the hold every blinking
# cell resolves to full ink, and a scene keyed on blink phase proves nothing.
TICKS=45

failures=0
# Cases actually run. A verdict with no number cannot be sized by its reader:
# "every case agrees" reads the same whether twenty ran or none did.
cases=0

# One scene through the shipping surface: the frame must complete and report a
# build that drew ink. The other two hold a scene to what judgeFrame's `any`
# and `baked` say it must have built instead.
builds() {
    buildsExpecting ink "$@"
}

buildsOccluded() {
    buildsExpecting any "$@"
}

buildsBaked() {
    buildsExpecting baked "$@"
}

buildsExpecting() {
    local expectation="$1" name="$2" feed="$3"
    shift 3
    cases=$((cases + 1))
    # The whole stream, kept before it is filtered. The `sed` below keeps only
    # the gate's own lines, so a diagnostic the renderer prints for any other
    # reason is discarded rather than read — which is how a comparison comes to
    # report nothing because nobody is listening.
    local raw
    raw=$(UBIQUITTY_FAKE_TICKS="$TICKS" "$APP" \
        --snapshot "$WORK/$name.png" --columns "$COLUMNS_ARG" --rows "$ROWS_ARG" \
        --feed "$feed" "$@" 2>&1)
    local reason
    if ! reason=$(judgeFrame "$raw" "$expectation"); then
        echo "FAIL $name: $reason" >&2
        failures=$((failures + 1))
    elif [ ! -s "$WORK/$name.png" ]; then
        echo "FAIL $name: the frame produced no PNG" >&2
        failures=$((failures + 1))
    fi
}

# A scene past the decoration prewarm. The drive sizes its own streams, so the
# assertion is the one `builds` makes: the flood frame built its ink at all.
buildsRetrying() {
    builds "$@"
}

builds text 'The quick brown fox jumps over the lazy dog 0123456789'
builds sgr $'\x1b[1;36mfile\x1b[0m.cpp:\x1b[33m42\x1b[0m \x1b[1;32mconst\x1b[0m auto v = \x1b[35mcompute\x1b[0m(x); \x1b[2m// note\x1b[0m'
builds decorated $'\x1b[4munder\x1b[0m \x1b[4:3mcurly\x1b[0m \x1b[4:4mdotted\x1b[0m \x1b[4:5mdashed\x1b[0m \x1b[21mdouble\x1b[0m \x1b[9mstrike\x1b[0m \x1b[53mover\x1b[0m \x1b[4;58;5;196mcolored\x1b[0m \x1b[51mframed\x1b[0m \x1b[52mcircled\x1b[0m \x1b[60m右\x1b[61m右\x1b[62m左\x1b[63m左\x1b[64m点\x1b[65m'
builds unicode $'日本語 αβγδ ñörmàl grüße \U0001f389\U0001f680 \U0001f468‍\U0001f469‍\U0001f467 \U0001f1ef\U0001f1f5 \U0001f44d\U0001f3fd العربية'
builds box $'┌─┬─┐ ├─┼─┤ └┴┘ ╔═╦╗ ╠╬╣ ╚╩╝ ┏━┳┓ ┣╋┫ █▓▒░ ▀▄▌▐ ▖▗▘▙▚▛▜▝▞▟ \U0001fb00\U0001fb01\U0001fb02 ╭╮╯╰ ╱╲╳'
builds doublerows $'\x1b#6double width\r\n\x1b#3double height\r\n\x1b#4double height\r\nsingle width'
builds statusrow $'\x1b[2$~\x1b[1$}status line here\x1b[0$}body text'
# DECSET 7402's opaque letterbox covers the grid, so the builder emits the
# cells and no ink: the frame is held to having been built, not to drawing text.
buildsOccluded letterbox $'\x1b[?7402hbody text behind the letterbox'
builds softfont $'\x1bP1;33;0;8;0;0;8;0{@~~~~~~~~/BBBBBBBB;~~~~????/BB??????;~?~?~?~?/B?B?B?B?\x1b\\\x1b(@ABC\x1b(B plain text'
# Subpixel text OFF: the atlas margins say the glyph pass is possible and the
# caller's preference says whether it is wanted; only the second changes when a
# user turns the setting off, and the frame must still build, with its text in
# the cells rather than in the glyph pass.
buildsBaked nosubpixel 'Subpixel off: the quick brown fox 0123' --no-subpixel

# A Cmd-hovered link run: the hovered presentation is a state in the flag array
# rather than a fallback. Two, because they are resolved by different rules —
# an OSC 8 run with an id, and a regex URL run with no id at all. The affordance
# is mouse state, so no feed reaches it and --hover-rect is the only way these
# cases exist.
builds osc8hover $'\x1b]8;;https://example.com\x07ho\x1b[4:3mvered\x1b[0m link\x1b]8;;\x07 plain' --hover-rect 0,0,0,11,1
builds regexhover 'plain https://example.com text' --hover-rect 0,6,0,24

# Two frames in one process: the second builds over the state the first left —
# the retained grid, the damage baseline, the atlas epochs. Every other case
# starts cold, and cold frames cannot reach what a frame LEAVES for the next.
cases=$((cases + 1))
multiReport=$(UBIQUITTY_FAKE_TICKS="$TICKS" "$APP" \
    --snapshot "$WORK/multi.1.png" --columns "$COLUMNS_ARG" --rows "$ROWS_ARG" \
    --feed 'first frame content' \
    --also-feed $'\r\nsecond frame line' --also-snapshot "$WORK/multi.2.png" 2>&1 \
    | grep -c '^surface-frame-build: cells=[1-9]' || true)
multiBuilt="$multiReport"
if [ "${multiBuilt:-0}" -lt 2 ]; then
    echo "FAIL multiframe: expected two built frames in one process, got '$multiReport'" >&2
    failures=$((failures + 1))
fi

# An OSC 4 recolour writes no cell, so only the model's palette epoch keeps a
# retained frame from Loading rows that still wear the replaced colour. Four
# frames because a full plan re-arms the baseline on its successor: frame one
# is fresh, frame two settles, frame three follows the recolour and must
# differ from frame two pixel-for-pixel — the grid content is identical and
# only index 33 moved — and frame four, with no input at all, must not.
# The coloured text sits rows above the cursor on purpose: the plan marks the
# cursor's row dirty every frame, so text beside the cursor repaints whatever
# the verdict and proves nothing.
cases=$((cases + 1))
osc4Report=$(UBIQUITTY_FAKE_TICKS="$TICKS" "$APP" \
    --snapshot "$WORK/osc4.1.png" --columns "$COLUMNS_ARG" --rows "$ROWS_ARG" \
    --feed $'\x1b[38;5;33mosc4-retained-colour\x1b[0m\r\n\r\n\r\nbelow' \
    --also-feed '' --also-snapshot "$WORK/osc4.2.png" \
    --also-feed $'\x1b]4;33;rgb:ff/00/ff\x07' --also-snapshot "$WORK/osc4.3.png" \
    --also-feed '' --also-snapshot "$WORK/osc4.4.png" 2>&1 \
    | grep -c '^surface-frame-build: cells=[1-9]' || true)
if [ "${osc4Report:-0}" -ne 4 ]; then
    echo "FAIL osc4retained: expected four built frames, got '$osc4Report'" >&2
    failures=$((failures + 1))
fi
if cmp -s "$WORK/osc4.2.png" "$WORK/osc4.3.png"; then
    echo "FAIL osc4retained: the frame after an OSC 4 recolour is pixel-identical to its" >&2
    echo "     predecessor, so the retained grid kept the replaced colour ($osc4Report)" >&2
    failures=$((failures + 1))
elif ! cmp -s "$WORK/osc4.3.png" "$WORK/osc4.4.png"; then
    echo "FAIL osc4retained: two frames with no input between them differ ($osc4Report)" >&2
    failures=$((failures + 1))
fi

# Per-kind link styling: the kind is resolved once into the per-cell state the
# capture fills, and the kind-to-style mapping is Core's. All three schemes in
# one feed, because a plain https run must stay on the base style — a case with
# only the two special schemes agrees with a builder that styles every link the
# same.
builds linkperkind $'\x1b]8;;file:///tmp/x\x07file\x1b]8;;\x07 \x1b]8;;mailto:a@b.c\x07mail\x1b]8;;\x07 \x1b]8;;https://e.org\x07web\x1b]8;;\x07' --link-style-per-kind

# Decorations past the prewarm: every cell carries underline, strike and
# overline — three each — so the first pass overruns by 3x and the retry is the
# only reason this frame draws with its rules. The row is repeated to fill the
# grid, because a single overrunning row still fits the whole-grid prewarm.
buildsRetrying decorationflood "$(printf '\033[4;9;53m'; for _ in $(seq 1 30); do printf 'decorated text across the whole row 0123456789 '; done)"

if [ "$failures" -gt 0 ]; then
    echo "check-core-builder-frames: $failures failure(s)" >&2
    exit 1
fi
if [ "$cases" -eq 0 ]; then
    echo "check-core-builder-frames: FAILED — 0 case(s) ran; the case list is empty or unreachable" >&2
    exit 1
fi
echo "check-core-builder-frames: ok ($cases case(s), each built by Core and completed by Metal/Swift)" >&2
