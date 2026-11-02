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
#   ./Scripts/run-linux-smokes.sh [BINARY]   default: build/linux/ubiquitty-linux
#   SMOKE_TIMEOUT=90 ./Scripts/run-linux-smokes.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
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

echo "run-linux-smokes: $BIN — ${#FLAGS[@]} tests, ${TIMEOUT}s each"
pass=0
fail=0
failed_flags=()
for flag in "${FLAGS[@]}"; do
    out="$(timeout "$TIMEOUT" "$BIN" "$flag" 2>&1)"
    rc=$?
    # Authoritative signal is the exit code; an uppercase FAIL token guards a
    # smoke that prints failure but forgets to propagate it.
    if [ "$rc" -eq 0 ] && ! grep -qE '\bFAIL' <<<"$out"; then
        printf '  ok    %s\n' "$flag"
        pass=$((pass + 1))
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

unexecuted=$((${#FLAGS[@]} - pass - fail))
echo "run-linux-smokes: $pass passed, $fail failed, $unexecuted unexecuted"
if [ "$fail" -ne 0 ]; then
    echo "run-linux-smokes: failed: ${failed_flags[*]}" >&2
    for failed_flag in ${failed_flags[@]+"${failed_flags[@]}"}; do
        printf 'run-linux-smokes: reproduce: timeout %q %q %q\n' "$TIMEOUT" "$BIN" "$failed_flag" >&2
    done
    exit 1
fi
