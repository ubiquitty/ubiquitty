#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# bench-shader-ab.sh — time one of the terminal's shading passes on the GPU,
# two shader revisions against each other.
#
#   ./Scripts/bench-shader-ab.sh <refA> <refB> [grid|cell|glyph|blit|copy|clear] [fraction] [rounds]
#
# refA/refB name any git revision, or WORKTREE for the file as it sits now:
#
#   ./Scripts/bench-shader-ab.sh main WORKTREE grid      # what a branch costs
#   ./Scripts/bench-shader-ab.sh main main glyph          # the null control
#   ./Scripts/bench-shader-ab.sh main main blit           # one pass's absolute cost
#
# `grid` is the default because it encodes cells and glyphs into one pass, which
# is what a frame records. The single-pass modes each charge themselves a full
# load and store of the render target, so their figures do not add up to a frame
# and a pass timed alone can be bound by something it is not bound by in one.
#
# Run the null control first. Whichever arm is measured second can read faster
# on a busy machine; the harness alternates the order per round so that
# cancels, and refA-vs-refA is what proves it did on the day.
#
# The harness renders both arms once and compares every pixel before it times
# anything, because a shader that is faster because it draws less is not
# faster. It also counts the ink, so two arms cannot agree by both drawing
# nothing into a target no one looked at.
#
# The passes are driven with a synthetic screen at a fixed size, so the
# absolute milliseconds describe this corpus rather than a session. The ratio
# is the number to read.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shader="Source/UbiquittyRenderKit/UBShaders.metal"
out="${root}/BuildBench/shader-ab"

refA="${1:-main}"
refB="${2:-WORKTREE}"
pass="${3:-grid}"
fraction="${4:-}"
rounds="${5:-21}"

if [[ -z "${fraction}" ]]; then
    fraction=$([[ "${pass}" == "glyph" || "${pass}" == "grid" ]] && echo 0.4 || echo 0.0)
fi

mkdir -p "${out}"

# One repository path with its `.` and `..` segments folded, refusing a path
# that climbs out of the checkout.
normalise() { # <path>
    local path="$1" pattern='^(.*/)?([^/]+)/\.\./(.*)$'
    path="${path//\/.\//\/}"
    while [[ "${path}" =~ ${pattern} ]] && [[ "${BASH_REMATCH[2]}" != ".." ]]; do
        path="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    done
    case "/${path}/" in
        */../*) echo "bench-shader-ab.sh: $1 leaves the checkout" >&2; return 1 ;;
    esac
    printf '%s\n' "${path}"
}

# Materialises the shader at one ref under <destination>, in the checkout's own
# layout, with every file it includes by a quoted path, transitively, taken from
# the same ref. The shader includes Core headers by relative path, so a copy on
# its own does not compile, and a copy that found them in the working tree would
# time one ref's shader against the other's headers.
fetch() { # <ref> <destination>
    local ref="$1" destination="$2" pending="${shader}"$'\n' seen=$'\n' path include
    rm -rf "${destination}"
    while [[ -n "${pending}" ]]; do
        path="${pending%%$'\n'*}"
        pending="${pending#*$'\n'}"
        case "${seen}" in *$'\n'"${path}"$'\n'*) continue ;; esac
        seen="${seen}${path}"$'\n'
        mkdir -p "${destination}/$(dirname "${path}")"
        if [[ "${ref}" == "WORKTREE" ]]; then
            cp "${root}/${path}" "${destination}/${path}"
        else
            git -C "${root}" show "${ref}:${path}" > "${destination}/${path}"
        fi
        while IFS= read -r include; do
            pending="${pending}$(normalise "$(dirname "${path}")/${include}")"$'\n'
        done < <(sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*/\1/p' \
            "${destination}/${path}")
    done
}

fetch "${refA}" "${out}/A"
fetch "${refB}" "${out}/B"
xcrun metal -O2 -o "${out}/A.metallib" "${out}/A/${shader}"
xcrun metal -O2 -o "${out}/B.metallib" "${out}/B/${shader}"

if diff -r -q "${out}/A" "${out}/B" > /dev/null; then
    echo "note: ${refA} and ${refB} hold the same shader and includes — this is a null control run"
fi

xcrun swiftc -O -parse-as-library -swift-version 6 -warnings-as-errors \
    -o "${out}/bench_shaders" "${root}/Tests/Performance/bench_shaders.swift"

echo "A = ${refA}   B = ${refB}   pass = ${pass}"
"${out}/bench_shaders" "${out}/A.metallib" "${out}/B.metallib" \
    "${pass}" "${fraction}" "${rounds}" "${@:6}"
