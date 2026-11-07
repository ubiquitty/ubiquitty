#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Build the native runtime and updater with their notices and matching sources.
# Run on each release architecture with Docker; output is outside the checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
. "$CORE_ROOT/Scripts/build-root.sh"
ARCH="$(docker run --rm alpine:3.21@sha256:ee16d92f96db08d9d2d07da48555a27f3a69d8f0759021dbc601195ed0d2b5bd uname -m)"
case "$ARCH" in x86_64 | aarch64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
WORK="$UBQ_BUILD_ROOT/appimage-support-build/$ARCH"
mkdir -p "$WORK/updater" "$WORK/runtime"
cp "$ROOT/Scripts/appimage/updater.Dockerfile" "$WORK/updater/Dockerfile"
cp "$ROOT/Scripts/appimage/build-updater.sh" "$WORK/updater/build-helper.sh"
cp "$ROOT/Scripts/appimage/collect-updater.py" "$WORK/updater/collect-helper.py"
# Under a hook, GIT_DIR names the pushing worktree and overrides `git -C`, so the
# updater's clone would land on this checkout instead.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE GIT_COMMON_DIR \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
if [ ! -d "$WORK/updater/source/.git" ]; then
    git init "$WORK/updater/source"
    git -C "$WORK/updater/source" remote add origin https://github.com/AppImageCommunity/AppImageUpdate.git
    git -C "$WORK/updater/source" fetch --depth=1 origin a211784dfc746fdb6d8d32d6bb39add451c1ddeb
    git -C "$WORK/updater/source" checkout --detach FETCH_HEAD
fi
test "$(git -C "$WORK/updater/source" rev-parse HEAD)" = a211784dfc746fdb6d8d32d6bb39add451c1ddeb
test -z "$(git -C "$WORK/updater/source" status --porcelain)"
docker build -t ubq-appimage-updater-build "$WORK/updater"
docker run --rm --init -v "$WORK/updater:/work:Z" -w /work ubq-appimage-updater-build bash build-helper.sh
python3 "$ROOT/Scripts/appimage/prepare-runtime.py" prepare "$WORK/runtime"
docker build -t ubq-appimage-runtime-build -f "$WORK/runtime/source/scripts/docker/Dockerfile" "$WORK/runtime/source"
docker run --rm --init -v "$WORK/runtime/source:/work:Z" -w /work ubq-appimage-runtime-build bash scripts/build-runtime.sh
docker run --rm ubq-appimage-runtime-build apk list --installed > "$WORK/runtime/installed-packages.txt"
python3 "$ROOT/Scripts/appimage/prepare-runtime.py" archive "$WORK/runtime"
python3 "$ROOT/Scripts/appimage-support.py" assemble "$UBQ_BUILD_ROOT/appimage-support/$ARCH" "$ARCH" \
    "$WORK/updater/updater-$ARCH" "$WORK/runtime/source/out/runtime-$ARCH" \
    "$WORK/runtime/runtime-sources.tar.xz" "$WORK/runtime/notices"
