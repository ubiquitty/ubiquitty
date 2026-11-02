#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# renderkit-sources.sh — the render kit's files and floor, read from what its
# targets compile against.
#
# A renderer driver that spells its own file list drifts the first time one
# kit file starts naming a type from another: the module still builds, and the
# driver stops compiling. check-frame-encoder broke that way when the atlas
# began reading FontGeometry. Reading Scripts/cmake/AppleSharedSwift.cmake makes
# the driver compile what the macOS and iOS targets compile, so there is no
# second list to fall behind.
#
# The floor is the app's, from Scripts/macos-deployment-target.txt, as the
# module's own -target is. Left to default, swiftc compiles for the build
# machine's OS and reports deprecations the shipped module never meets.

# Fills RENDERKIT_SOURCES with absolute paths, in list order, from
# UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES, and RENDERKIT_TARGET with the
# module's -target triple. $1 is the repository root and $2 the
# caller's name for the refusal line. An empty read exits 2: a driver compiling
# no kit files would fail on its own sources and blame them.
renderkit_sources_load() {
    local root="$1"
    local label="$2"
    local list="$root/Scripts/cmake/AppleSharedSwift.cmake"
    local source
    RENDERKIT_SOURCES=()
    while IFS= read -r source; do
        RENDERKIT_SOURCES+=("$root/$source")
    done < <(awk '
        /^set\(UBIQUITTY_APPLE_SHARED_RENDERKIT_SOURCES/ { inside = 1; next }
        inside {
            for (field = 1; field <= NF; ++field) {
                entry = $field
                closed = sub(/\)$/, "", entry)
                if (entry ~ /\.swift$/) print entry
                if (closed) exit
            }
        }' "$list")
    if (( ${#RENDERKIT_SOURCES[@]} == 0 )); then
        echo "$label: read no render kit sources from $list." >&2
        exit 2
    fi
    local floor
    floor="$(sed -n 's/^app=//p' "$root/Scripts/macos-deployment-target.txt")"
    if [[ -z "$floor" ]]; then
        echo "$label: read no app floor from Scripts/macos-deployment-target.txt." >&2
        exit 2
    fi
    # shellcheck disable=SC2034  # read by the driver that sources this file
    RENDERKIT_TARGET="$(uname -m)-apple-macos$floor"
}
