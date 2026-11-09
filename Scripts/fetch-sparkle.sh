#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# fetch-sparkle.sh — download the pinned, prebuilt Sparkle framework + tools the
# macOS auto-update build links against, into a prefix the CMake build finds
# (default $UBQ_BUILD_ROOT/sparkle, CMake's default UBIQUITTY_SPARKLE_PREFIX).
# Pinned to an exact version + SHA-256 for reproducibility; idempotent (skips
# when the installed release has a matching verification marker).
#
#   ./Scripts/fetch-sparkle.sh            # → $UBQ_BUILD_ROOT/sparkle
#   ./Scripts/fetch-sparkle.sh <prefix>   # → custom prefix (pass the same one as UBIQUITTY_SPARKLE_PREFIX)
#
# Run before building Ubiquitty.app to enable in-app updates. We use the PREBUILT
# release artifact, never a source build: building Sparkle from source strips
# its code signing (Sparkle's own docs). The extracted bin/ tools (generate_keys,
# sign_update, generate_appcast, BinaryDelta) drive the release flow — see
# Docs/auto-update.md.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
PREFIX="${1:-$UBQ_BUILD_ROOT/sparkle}"

SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
RELEASE_MARKER="$PREFIX/.sparkle-release"
VERIFIED_RELEASE="$SPARKLE_VERSION $SPARKLE_SHA256"

hasRelease() {
    [ -d "$1/Sparkle.framework" ] || return 1
    local tool
    for tool in generate_keys sign_update generate_appcast BinaryDelta; do
        [ -x "$1/bin/$tool" ] || return 1
    done
}

if hasRelease "$PREFIX" && [ -f "$RELEASE_MARKER" ] \
        && [ "$(cat "$RELEASE_MARKER")" = "$VERIFIED_RELEASE" ]; then
    echo "sparkle: already present at $PREFIX (v$SPARKLE_VERSION)"
    exit 0
fi

mkdir -p "$PREFIX"
STAGING="$(mktemp -d "$PREFIX/.sparkle-stage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
TARBALL="$STAGING/Sparkle-${SPARKLE_VERSION}.tar.xz"

echo "sparkle: downloading $SPARKLE_VERSION"
curl -fsSL -o "$TARBALL" "$SPARKLE_URL"

echo "sparkle: verifying SHA-256"
# shasum is on macOS; sha256sum on Linux — accept whichever exists.
if command -v shasum >/dev/null 2>&1; then
    GOT="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
else
    GOT="$(sha256sum "$TARBALL" | awk '{print $1}')"
fi
if [ "$GOT" != "$SPARKLE_SHA256" ]; then
    echo "ERROR: checksum mismatch for $TARBALL" >&2
    echo "  expected $SPARKLE_SHA256" >&2
    echo "  got      $GOT" >&2
    exit 1
fi

echo "sparkle: staging Sparkle.framework + bin tools"
# The archive holds Sparkle.framework, bin/ (the tools), a sample app, symbols,
# etc. We only need the framework + the bin tools. Members are stored with a
# leading "./" (GNU tar needs the exact "./Name"; bsdtar accepts either), so try
# the dot-prefixed form first and fall back to the bare form.
tar -xJf "$TARBALL" -C "$STAGING" ./Sparkle.framework ./bin 2>/dev/null \
    || tar -xJf "$TARBALL" -C "$STAGING" Sparkle.framework bin

hasRelease "$STAGING" || { echo "ERROR: Sparkle.framework or bin tools missing after extract" >&2; exit 1; }

# A failed download or extract must leave the installed cache intact. The marker
# certifies a complete installation, so invalidate it before replacing files.
rm -f "$RELEASE_MARKER"
rm -rf "${PREFIX:?}/Sparkle.framework" "${PREFIX:?}/bin"
mv "$STAGING/Sparkle.framework" "$PREFIX/Sparkle.framework"
mv "$STAGING/bin" "$PREFIX/bin"
hasRelease "$PREFIX" || { echo "ERROR: incomplete Sparkle installation" >&2; exit 1; }
printf '%s\n' "$VERIFIED_RELEASE" > "$STAGING/release-marker"
mv "$STAGING/release-marker" "$RELEASE_MARKER"

echo "sparkle: ready at $PREFIX (v$SPARKLE_VERSION)"
echo "  framework : $PREFIX/Sparkle.framework"
echo "  tools     : $PREFIX/bin/{generate_keys,sign_update,generate_appcast,BinaryDelta}"
echo "  Next: configure/build Ubiquitty.app (auto-detected via -DUBIQUITTY_SPARKLE)."
