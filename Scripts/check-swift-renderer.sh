#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# check-swift-renderer.sh — every driver over the Swift renderer, in one run.
#
# Six checks, each driving one piece of the renderer and reading a result back
# rather than inspecting the source. They are gathered here because a gate
# nobody invokes leaves no line in any log and reads the same as one that
# passed — six separate entry points is six chances for that, and this is one.
#
# The order is the dependency order, so the first failure is the innermost:
# faces before the catalogue that resolves them, the rasteriser before the atlas
# that uploads its planes, the streams before the encoder that draws them, and
# the whole renderer last.
#
# Prerequisites are refused, not skipped. Two of these link Core and two need
# the app's compiled shaders; a run that quietly omitted them would report a
# subset as though it were the set, which is the failure every one of these
# checks exists to catch.
#
# It needs a Metal device, and a driver nothing runs rots to compile errors no
# other gate can see. pre-push-gates.sh runs it when a branch changes a Swift
# renderer source, so a driver that stops compiling stops a push.
#
# The builder-frames gate beside it is still a named tool rather than a runner
# entry: a mention in a caller-shaped file is counted as a call, so naming that
# script here would read as calling it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHECKS=(
    check-font-catalogue.sh
    check-glyph-rasterizer.sh
    check-glyph-atlas.sh
    check-frame-instances.sh
    check-frame-encoder.sh
    check-terminal-renderer.sh
)

MODE=drive
if [ "${1:-}" = "--typecheck-only" ]; then
    MODE=typecheck
    export UBIQUITTY_DRIVER_TYPECHECK_ONLY=1
elif [ "$#" -ne 0 ]; then
    echo "check-swift-renderer: unknown argument '$1' (only --typecheck-only)" >&2
    exit 2
fi

FAILED=()
for check in "${CHECKS[@]}"; do
    printf '=== %s ===\n' "$check"
    if "$ROOT/Scripts/$check"; then
        continue
    fi
    FAILED+=("$check")
done

if [ "${#FAILED[@]}" -ne 0 ]; then
    echo "check-swift-renderer: FAILED — ${#FAILED[@]} of ${#CHECKS[@]} driver(s): ${FAILED[*]}" >&2
    exit 1
fi
# The verdict names which pass ran. Both report every driver, and only one of
# them drew anything — a line that read the same either way would let the cheap
# pass stand in for the whole gate, which is the confusion this file is about.
if [ "$MODE" = typecheck ]; then
    echo "check-swift-renderer: ok (${#CHECKS[@]} driver(s) type-checked; none linked Core, none drew, no device was opened)"
else
    echo "check-swift-renderer: ok (${#CHECKS[@]} driver(s), each read a result back)"
fi
