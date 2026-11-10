#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-linux-smokes.sh — run the ubiquitty-linux headless --smoke-* self-test
# battery. UBQ_TEST_FAIL_FAST=1 stops after the first non-passing test;
# otherwise every smoke runs so local diagnostics can be collected together.
#
# The flag list is DERIVED from main.cpp's dispatch arms, never copied — so a new
# --smoke-* added to the frontend is covered by this gate automatically, with no
# second list to drift. Each smoke runs to completion and returns 0 on PASS,
# non-zero on FAIL (the `return pass ? 0 : 1` convention in main.cpp); a hung
# smoke is bounded by SMOKE_TIMEOUT and counts as a failure.
#
# Headless: the CALLER supplies the software-Vulkan + virtual-display environment.
# CI wraps this in `xvfb-run` with the Mesa lavapipe VK_ICD. Locally:
#   xvfb-run -a ./Scripts/run-linux-smokes.sh
#
# A smoke that cannot run its oracle on this machine exits 77, and 77 fails
# here like any other non-zero status, with one exception: under lavapipe, the
# modes named in LAVAPIPE_SKIPS that exit 77 are reported SKIPPED, each on its
# own line and counted in the summary. Lavapipe offers the dma-buf export
# extensions but cannot build an exportable image, so those modes run where
# UBQ_CI_LINUX_VULKAN=native. Any other status from a listed mode, and a 77
# from any unlisted mode, still fails, so a mode renamed away from the list
# fails rather than skips.
#
#   ./Scripts/run-linux-smokes.sh [BINARY]   default: build/linux/ubiquitty-linux
#   SMOKE_TIMEOUT=90 ./Scripts/run-linux-smokes.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
BIN="${1:-$UBQ_BUILD_ROOT/linux/ubiquitty-linux}"
SRC="$ROOT/Source/Platform/Linux/main.cpp"
TIMEOUT="${SMOKE_TIMEOUT:-60}"

[ -x "$BIN" ] || { echo "run-linux-smokes: binary not found/executable: $BIN" >&2; exit 2; }
[ -f "$SRC" ] || { echo "run-linux-smokes: source not found: $SRC" >&2; exit 2; }

# Every `mode == "--smoke…"` dispatch arm (the bare --smoke and --smoke-input,
# which falls back to a default path arg, both included). Portable array build
# (no mapfile) so it also runs under bash 3.2.
FLAGS=()
while IFS= read -r flag; do
    FLAGS+=("$flag")
done < <(grep -oE 'mode == "(--smoke[a-z0-9-]*)"' "$SRC" | grep -oE -- '--smoke[a-z0-9-]*' | sort -u)

[ "${#FLAGS[@]}" -gt 0 ] || { echo "run-linux-smokes: no --smoke flags found in $SRC" >&2; exit 2; }

# The modes that need a Vulkan dma-buf exporter, named one by one so that a
# mode added later is never excused by a pattern.
LAVAPIPE_SKIPS=(--smoke-dmabuf-import-failure)
isLavapipe=0
case "${VK_ICD_FILENAMES:-}" in */lvp_icd*.json) isLavapipe=1 ;; esac
isLavapipeSkip() { # <flag>
    [ "$isLavapipe" = 1 ] || return 1
    case " ${LAVAPIPE_SKIPS[*]} " in *" $1 "*) return 0 ;; esac
    return 1
}

echo "run-linux-smokes: $BIN — ${#FLAGS[@]} tests, ${TIMEOUT}s each"
pass=0
fail=0
skipped=0
failed_flags=()
for flag in "${FLAGS[@]}"; do
    out="$(timeout "$TIMEOUT" "$BIN" "$flag" 2>&1)"
    rc=$?
    # Authoritative signal is the exit code; an uppercase FAIL token guards a
    # smoke that prints failure but forgets to propagate it.
    if [ "$rc" -eq 0 ] && ! grep -qE '\bFAIL' <<<"$out"; then
        printf '  ok    %s\n' "$flag"
        pass=$((pass + 1))
    elif [ "$rc" -eq 77 ] && isLavapipeSkip "$flag"; then
        printf '  SKIPPED %s (lavapipe cannot export dma-buf; runs where UBQ_CI_LINUX_VULKAN=native)\n' "$flag"
        skipped=$((skipped + 1))
    else
        printf '  FAIL  %s (rc=%d)\n' "$flag" "$rc"
        sed 's/^/        /' <<<"$out"
        fail=$((fail + 1))
        failed_flags+=("$flag")
        if [ "${UBQ_TEST_FAIL_FAST:-0}" = "1" ]; then
            break
        fi
    fi
done

unexecuted=$((${#FLAGS[@]} - pass - fail - skipped))
echo "run-linux-smokes: $pass passed, $fail failed, $unexecuted unexecuted, $skipped skipped on lavapipe"
if [ "$fail" -ne 0 ]; then
    echo "run-linux-smokes: failed: ${failed_flags[*]}" >&2
    for failed_flag in ${failed_flags[@]+"${failed_flags[@]}"}; do
        printf 'run-linux-smokes: reproduce: timeout %q %q %q\n' "$TIMEOUT" "$BIN" "$failed_flag" >&2
    done
    exit 1
fi
