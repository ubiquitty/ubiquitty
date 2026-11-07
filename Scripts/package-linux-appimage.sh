#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# package-linux-appimage.sh — build ubiquitty-linux and package it as an AppImage
# with zsync update information pointing at the website's release downloads.
# See Docs/auto-update.md.
#
#   ./Scripts/package-linux-appimage.sh [--no-build]
#
# Produces $UBQ_BUILD_ROOT/dist/Ubiquitty-<version>-<architecture>.AppImage (+ .zsync).
# UBIQUITTY_PACKAGE_SOURCE selects a clean tagged source tree when running newer
# packaging tools against an existing release; --no-build reuses its build.
#
# This builds a thin AppImage: it bundles the ubiquitty-linux binary with the
# shaders and fonts it opens from its own directory, and the AppImage updater,
# and relies on the host's GTK 4.16 or newer, Vulkan loader, glibc and
# libstdc++, whose floors are checked below. It does not bundle the GTK stack:
# linuxdeploy produced a broken (mixed-GLib) bundle on the newest toolchains,
# and the self-update mechanism does not need it.
#
# appimagetool is pinned to its 1.9.1 release. The runtime and updater come
# from build-appimage-support.sh, together with their matching source archives
# and library notices. UBIQUITTY_APPIMAGE_SUPPORT selects that verified bundle.
#
set -euo pipefail

TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The toolchain launcher belongs to the tools checkout, even when the package
# below is built from a different tagged source tree.
TOOLS_CORE_ROOT="$TOOLS_ROOT/Libraries/ubiquitty-core"
export UBIQUITTY_PGO=REQUIRE
if [ -z "${UBQ_CI_LINUX_IMAGE_ID:-}" ]; then
    exec python3 "$TOOLS_CORE_ROOT/Scripts/pgo_toolchain.py" run "$TOOLS_ROOT/Scripts/package-linux-appimage.sh" "$@"
fi
export PATH="$UBQ_PGO_LLVM:$PATH"
export CC=clang CXX=clang++
ROOT="${UBIQUITTY_PACKAGE_SOURCE:-$TOOLS_ROOT}"
# The checkouts holding the scripts this one runs; see CMakeLists.txt.
CORE_ROOT="${UBIQUITTY_CORE_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-core}"
KIT_ROOT="${UBIQUITTY_KIT_SOURCE_DIR:-$ROOT/Libraries/ubiquitty-kit}"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
case "$(uname -m)" in
    x86_64) ARCH=x86_64 ;;
    aarch64 | arm64) ARCH=aarch64 ;;
    *) echo "ERROR: no AppImage package for $(uname -m)." >&2; exit 1 ;;
esac
BUILD=1
REQUESTED=""
for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        -*)        echo "unknown flag: $arg" >&2; exit 2 ;;
        *)         REQUESTED="$arg" ;;
    esac
done

DIST="$UBQ_BUILD_ROOT/dist"
APPDIR="$UBQ_BUILD_ROOT/linux-appdir/AppDir"
TOOLS="$UBQ_BUILD_ROOT/linux-tools"
SUPPORT="${UBIQUITTY_APPIMAGE_SUPPORT:-$UBQ_BUILD_ROOT/appimage-support/$ARCH}"
python3 "$TOOLS_ROOT/Scripts/appimage-support.py" verify "$SUPPORT" "$ARCH"

APPIMAGETOOL_URL="${APPIMAGETOOL_URL:-https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$ARCH.AppImage}"
# Pin each fetched tool to its SHA-256 — these binaries run at build time, so an
# upstream change (the AppImage projects ship a rolling "continuous" channel) must
# FAIL the build so the new binary is re-pinned by someone who checked it, never
# flow through unverified.
# Override the URL + its matching SHA-256 together to move to a newer tool.
case "$ARCH" in
    x86_64)
        toolDigest=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
        ;;
    aarch64)
        toolDigest=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
        ;;
esac
APPIMAGETOOL_SHA256="${APPIMAGETOOL_SHA256:-$toolDigest}"

# AppImage helper tools need FUSE; extract-and-run avoids requiring /dev/fuse
# (CI containers, headless build machines).
export APPIMAGE_EXTRACT_AND_RUN=1

fetch() { # url dest sha256
    if [ ! -f "$2" ]; then
        echo "fetch: $(basename "$2")"
        curl -fsSL -o "$2" "$1"
    fi
    # Verify on every run, cache hits included — a poisoned cache must not pass.
    printf '%s  %s\n' "$3" "$2" | sha256sum -c - >/dev/null 2>&1 \
        || { echo "ERROR: $(basename "$2") failed its SHA-256 pin (expected $3). Upstream changed — verify the new build and re-pin in $0." >&2; rm -f "$2"; exit 1; }
    chmod +x "$2"
}

mkdir -p "$TOOLS" "$DIST"
fetch "$APPIMAGETOOL_URL"   "$TOOLS/appimagetool.AppImage"       "$APPIMAGETOOL_SHA256"

# 1. Build the release binary.
if [ "$BUILD" = 1 ]; then
    "$ROOT/Scripts/build-linux-gtk.sh" Release
fi
BIN="$UBQ_BUILD_ROOT/linux/ubiquitty-linux"
[ -x "$BIN" ] || { echo "ERROR: no binary at $BIN" >&2; exit 1; }
python3 "$CORE_ROOT/Scripts/check-pgo-applies.py" --recorded-budget --max-discarded 0

# The binary links the host's glibc and libstdc++, so the newest symbol version
# it asks of each is the oldest host it starts on. README.md,
# Docs/building-and-releasing.md and Docs/auto-update.md state these floors. A
# binary that needs more would fail to start on hosts they name, so it is
# refused here until the floors and the documents are raised together.
GLIBC_FLOOR="2.38"
GLIBCXX_FLOOR="3.4.31"
newestSymbolVersion() { # <GLIBC or GLIBCXX>; prints nothing when it finds none
    objdump -T "$BIN" | { grep -oE "$1_[0-9]+(\.[0-9]+)*" || true; } | sed "s/^$1_//" | sort -uV | tail -n1
}
for floor in "GLIBC $GLIBC_FLOOR" "GLIBCXX $GLIBCXX_FLOOR"; do
    library="${floor% *}" limit="${floor#* }"
    needed="$(newestSymbolVersion "$library")"
    [ -n "$needed" ] || { echo "ERROR: objdump found no ${library}_ symbol version in $BIN" >&2; exit 1; }
    echo "==> host floor: ${library}_$needed (documented: ${library}_$limit)"
    if [ "$(printf '%s\n' "$limit" "$needed" | sort -V | tail -n1)" != "$limit" ]; then
        echo "ERROR: $BIN needs ${library}_$needed, newer than the documented floor ${library}_$limit." >&2
        echo "       Build in Scripts/ci-linux-image.sh's image with its UBQ_PGO_LLVM clang," >&2
        echo "       or raise ${library}_FLOOR here with README.md, Docs/building-and-releasing.md and Docs/auto-update.md." >&2
        exit 1
    fi
done

# 2. Version: what the binary itself reports. --version prints the program
#    name, the version, then the build identity in parentheses.
VERSION="$("$BIN" --version | awk '{print $2}')"
[ -n "$VERSION" ] || { echo "ERROR: could not read --version" >&2; exit 1; }
# The version names the file and the release, so it is held to its shape here
# as well as in the build.
if ! printf '%s' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.[1-9][0-9]*)?$'; then
    echo "ERROR: --version reported '$VERSION', which is not a version." >&2
    exit 1
fi

# Version safety: an explicit positional arg must match, and (in CI) the pushed
# tag must equal v<version> so a
# tag/VERSION mismatch cannot produce a mislabeled AppImage.
if [ -n "$REQUESTED" ] && [ "$REQUESTED" != "$VERSION" ]; then
    echo "ERROR: requested version '$REQUESTED' != built version ('$VERSION')." >&2
    exit 1
fi
if [ -n "${GITHUB_REF_NAME:-}" ] && [ "$GITHUB_REF_NAME" != "v$VERSION" ]; then
    echo "ERROR: tag '$GITHUB_REF_NAME' != v$VERSION (the built version) — the build did not see the tag." >&2
    exit 1
fi
SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD)"
if [ "$(git -C "$ROOT" rev-parse "v$VERSION^{commit}")" != "$SOURCE_REVISION" ] \
    || [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "ERROR: packaging requires a clean source tree at v$VERSION." >&2
    exit 1
fi
if [ "$("$BIN" --version)" != "ubiquitty-linux $VERSION (${SOURCE_REVISION:0:8})" ]; then
    echo "ERROR: the binary's build identity does not match the tagged source." >&2
    exit 1
fi
OUTPUT="$DIST/Ubiquitty-$VERSION-$ARCH.AppImage"
echo "==> packaging Ubiquitty $VERSION → $(basename "$OUTPUT")"

# 3. Lay out the AppDir.
rm -rf "$UBQ_BUILD_ROOT/linux-appdir"
# The binary and everything it opens from its own directory through
# /proc/self/exe: the renderer's SPIR-V shaders and every bundled font. CMake's
# install rules name the same lists the build stages, so the AppImage cannot
# carry a shorter list than the build directory does.
cmake --install "$UBQ_BUILD_ROOT/linux" --prefix "$APPDIR/usr"
# A shader the AppImage lacks fails the renderer's first frame, and the binary
# then draws on the CPU for the rest of the run with nothing but a log line to
# say so. Every shader source has its compiled form beside the binary, or no
# AppImage is built.
missingShaders=()
for shader in "$KIT_ROOT"/Source/Platform/Linux/shaders/*; do
    spv="$(basename "$shader").spv"
    [ -s "$APPDIR/usr/bin/$spv" ] || missingShaders+=("$spv")
done
if [ "${#missingShaders[@]}" -gt 0 ]; then
    echo "ERROR: the AppDir has no ${missingShaders[*]}; install glslc and build with UBIQUITTY_LINUX_GPU_SHADERS on." >&2
    exit 1
fi
# Each Noto release's own licence travels with its faces, beside the binary.
for notice in NotoSans-OFL.txt NotoColorEmoji-OFL.txt; do
    install -Dm644 "$CORE_ROOT/Resources/fonts/$notice" "$APPDIR/usr/bin/$notice"
done
# The updater uses its private shared libraries without changing the terminal
# process's library search path. Its notices and matching sources travel with it.
python3 "$TOOLS_ROOT/Scripts/appimage-support.py" stage "$SUPPORT" "$ARCH" "$APPDIR" "$VERSION" "$DIST"
# Third-party license texts ship inside the AppImage (redistribution compliance):
# the project notice + the per-dependency texts the bundled binary links/embeds.
DOCDIR="$APPDIR/usr/share/doc/ubiquitty"
python3 "$TOOLS_CORE_ROOT/Scripts/license_notices.py" --source "$ROOT" --core "$CORE_ROOT" --kit "$KIT_ROOT" --copy "$DOCDIR"
install -Dm644 "$ROOT/Resources/linux/org.ubiquitty.linux.desktop" \
    "$APPDIR/usr/share/applications/org.ubiquitty.linux.desktop"
# appimagetool wants the .desktop + icon at the AppDir root too.
cp "$APPDIR/usr/share/applications/org.ubiquitty.linux.desktop" "$APPDIR/org.ubiquitty.linux.desktop"

# Icon: the app icon's exports (Scripts/export-app-icon.py writes them from
# Resources/Icon/Ubiquitty.icon), installed under the name the .desktop file's
# Icon= key and the GtkApplication id share. Each hicolor size is ictool's own
# render at that size, so a small size is drawn for its grid rather than
# downsampled from a large one; the flat SVG is the scalable entry. A missing
# export stops the build: a desktop entry naming an icon that is not there
# shows a generic one with nothing reported.
ICON_SVG="$ROOT/Resources/Icon/Ubiquitty.svg"
ICON_RASTERS="$ROOT/Resources/Icon/Raster"
[ -f "$ICON_SVG" ] || { echo "ERROR: no desktop icon at $ICON_SVG" >&2; exit 1; }
for size in 16 24 32 48 64 128 256; do
    raster="$ICON_RASTERS/Ubiquitty-$size.png"
    [ -f "$raster" ] || { echo "ERROR: no ${size}px desktop icon at $raster" >&2; exit 1; }
    install -Dm644 "$raster" "$APPDIR/usr/share/icons/hicolor/${size}x${size}/apps/org.ubiquitty.linux.png"
done
install -Dm644 "$ICON_SVG" "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.ubiquitty.linux.svg"
cp "$ICON_RASTERS/Ubiquitty-256.png" "$APPDIR/org.ubiquitty.linux.png"
cp "$ICON_RASTERS/Ubiquitty-256.png" "$APPDIR/.DirIcon"

# AppRun: put the bundled tools on PATH and exec the binary (relies on host GTK4).
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$PATH"
exec "$HERE/usr/bin/ubiquitty-linux" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# 4. Build the AppImage with update info embedded. -u writes the .zsync and
# stamps the AppImage so the updater knows where to fetch deltas.
UPDATE_INFO="zsync|https://ubiquitty.org/download/linux/$ARCH.AppImage.zsync"
rm -f "$OUTPUT" "$OUTPUT.zsync"
( cd "$DIST" && ARCH="$ARCH" "$TOOLS/appimagetool.AppImage" \
    --runtime-file "$SUPPORT/runtime" -u "$UPDATE_INFO" "$APPDIR" "$OUTPUT" )

[ -f "$OUTPUT" ] || { echo "ERROR: appimagetool produced no AppImage at $OUTPUT" >&2; exit 1; }
chmod +x "$OUTPUT"
if [ "$(env -u APPIMAGE_EXTRACT_AND_RUN "$OUTPUT" --appimage-updateinformation)" != "$UPDATE_INFO" ]; then
    echo "ERROR: the AppImage does not carry the requested update address." >&2
    exit 1
fi
echo "==> built $(basename "$OUTPUT") ($(du -h "$OUTPUT" | cut -f1))"
[ -s "$OUTPUT.zsync" ] || { echo "ERROR: no .zsync produced." >&2; exit 1; }
