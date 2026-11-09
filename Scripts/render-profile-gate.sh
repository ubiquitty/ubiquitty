#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# render-profile-gate.sh — collect the headless GPU render-profile distributions
# (Scripts/run-render-profile.sh, macOS/Metal only) and compare them against the
# external per-platform baseline, gating on a TAIL regression. The render-profile
# counterpart of profile-gate.sh (which covers the portable parser/Sync/tmux
# profile_stack, no GPU) — same compare-profile.py, same JSON shape
# (Tests/Performance/Profiler.h's emitJSON), separate baseline file because the
# two measure disjoint operations on disjoint platforms-for-now (this one needs a
# real Metal device; there is no software/CPU fallback anywhere in the tree).
#
#   ./Scripts/render-profile-gate.sh            run + compare against the baseline, GATE
#   ./Scripts/render-profile-gate.sh --report   run + compare, print the table but never fail
#   ./Scripts/render-profile-gate.sh --update   run + overwrite the baseline with this run
#
# Hand-run by design, like profile-gate.sh: a render-latency baseline is
# per-machine and per-GPU-state, so nothing in the gate tiers invokes this —
# it is the instrument a render-path change is measured with, on a quiet
# machine, against a baseline generated the same session.
#
# Tunables (env): UBIQUITTY_PERF_BASELINE_DIR (external baseline directory),
# PROFILE_METRIC (default p95), PROFILE_THRESHOLD (default 15).
#
# Exit 0 = no gated regression (or --report/--update); 1 = a profile regressed;
# 2 = usage / missing baseline / not on macOS.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "render-profile-gate.sh: macOS only (needs Metal)" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
MODE="gate"
case "${1:-}" in
    --report) MODE="report" ;;
    --update) MODE="update" ;;
    --help|-h)
        sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//; p' "$0"; exit 0 ;;
    "") ;;
    *) echo "render-profile-gate.sh: unknown argument: $1" >&2; exit 2 ;;
esac

PLATFORM="$(uname -s)-$(uname -m)"
. "$CORE_ROOT/Scripts/perf-baseline-path.sh"
BASELINE_DIR="$(ubiquitty_perf_baseline_directory)"
BASELINE="$BASELINE_DIR/render-profile-$PLATFORM.json"
METRIC="${PROFILE_METRIC:-p95}"
THRESHOLD="${PROFILE_THRESHOLD:-15}"

if [ "$MODE" != "update" ] && [ ! -f "$BASELINE" ]; then
    echo "render-profile-gate: no baseline for $PLATFORM at $BASELINE" >&2
    echo "  capture one first: ./Scripts/render-profile-gate.sh --update" >&2
    exit 2
fi

CURRENT="$(mktemp -t render-profile-current.XXXXXX.json)"
trap 'rm -f "$CURRENT"' EXIT

"$ROOT/Scripts/run-render-profile.sh" "$CURRENT" >/dev/null

if [ "$MODE" = "update" ]; then
    mkdir -p "$BASELINE_DIR"
    cp "$CURRENT" "$BASELINE"
    echo "render-profile-gate: baseline updated → $BASELINE"
    echo "  (retain it outside the product checkout; it is this machine's reference)"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "render-profile-gate: no baseline for $PLATFORM at $BASELINE" >&2
    echo "  capture one first:  ./Scripts/render-profile-gate.sh --update" >&2
    exit 2
fi

GATE_FLAG=()
[ "$MODE" = "gate" ] && GATE_FLAG=(--gate)

# macOS ships bash 3.2, where expanding an EMPTY array under `set -u` is an
# unbound-variable error. GATE_FLAG is empty in --report mode, so a plain
# "${GATE_FLAG[@]}" kills exactly the mode that must never fail.
"$CORE_ROOT/Scripts/compare-profile.py" "$BASELINE" "$CURRENT" \
    --metric "$METRIC" --threshold "$THRESHOLD" ${GATE_FLAG[@]+"${GATE_FLAG[@]}"}
