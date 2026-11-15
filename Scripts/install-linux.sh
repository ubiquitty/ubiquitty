#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Install a complete Linux build into a versioned private directory. The public
# executable is a symlink, so replacing it never separates a running binary
# from the fonts and shaders it locates through /proc/self/exe.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${HOME}/.local"
BUILD_DIRECTORY=""
SHOULD_BUILD=1
WITH_OMARCHY=0
SET_DEFAULT=0
usage() {
    cat <<'HELP'
Usage: Scripts/install-linux.sh [options]

Build Release and install ubiquitty under ~/.local without sudo.
  --build-dir DIR       Use this CMake build directory
  --no-build            Install an existing build
  --prefix DIR          Installation prefix (default: ~/.local)
  --omarchy             Build without chrome; add Omarchy menu and theme hook
  --default-terminal    Also select Ubiquitty as default (implies --omarchy)
  -h, --help            Show this help

Previous versioned installations remain available for running processes.
HELP
}
while (($#)); do
    case "$1" in
        --build-dir|--prefix)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "Missing value for $1" >&2; exit 2; }
            if [ "$1" = --build-dir ]; then BUILD_DIRECTORY="$2"; else PREFIX="$2"; fi
            shift 2 ;;
        --no-build) SHOULD_BUILD=0; shift ;;
        --omarchy) WITH_OMARCHY=1; shift ;;
        --default-terminal) WITH_OMARCHY=1; SET_DEFAULT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[ "$(uname -s)" = Linux ] || { echo "Linux is required" >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
BUILD_DIRECTORY="${BUILD_DIRECTORY:-$UBQ_BUILD_ROOT/linux}"
PREFIX="$(realpath -m -- "$PREFIX")"
BUILD_DIRECTORY="$(realpath -m -- "$BUILD_DIRECTORY")"
if [ "$WITH_OMARCHY" = 1 ]; then
    command -v omarchy >/dev/null || { echo "--omarchy requires the omarchy command" >&2; exit 1; }
fi
if [ "$SHOULD_BUILD" = 1 ]; then
    if [ "$WITH_OMARCHY" = 1 ]; then
        UBIQUITTY_LINUX_BUILD_DIR="$BUILD_DIRECTORY" UBIQUITTY_LINUX_CHROMELESS=ON "$ROOT/Scripts/build-linux-gtk.sh" Release
    else
        UBIQUITTY_LINUX_BUILD_DIR="$BUILD_DIRECTORY" "$ROOT/Scripts/build-linux-gtk.sh" Release
    fi
fi
INTEGRATION_ROOT="$ROOT/Integrations/omarchy"
[ -x "$INTEGRATION_ROOT/scripts/package-local-build.sh" ] || {
    echo "Initialize the Omarchy integration: git submodule update --init Integrations/omarchy" >&2
    exit 1
}
# Distribution and desktop integration have one implementation in their own repo.
ARCHIVE="$("$INTEGRATION_ROOT/scripts/package-local-build.sh" \
    --source-root "$ROOT" --build-dir "$BUILD_DIRECTORY" \
    --output-dir "$BUILD_DIRECTORY/distribution" | tail -n 1)"
INSTALL_ARGUMENTS=("$ARCHIVE" --prefix "$PREFIX")
[ "$WITH_OMARCHY" = 0 ] || INSTALL_ARGUMENTS+=(--omarchy)
[ "$SET_DEFAULT" = 0 ] || INSTALL_ARGUMENTS+=(--default-terminal)
exec "$INTEGRATION_ROOT/scripts/install-ubiquitty.sh" "${INSTALL_ARGUMENTS[@]}"
