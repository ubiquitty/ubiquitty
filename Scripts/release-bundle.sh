#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# shellcheck shell=bash
# release-bundle.sh — the bundle identifier an installed or shipped app
# carries, and the check that refuses any other.
#
# Sourced by the scripts that hand a bundle to a person:
# notarize-macos.sh, package-macos.sh and install-macos.sh. A development
# build carries org.ubiquitty.Ubiquitty.dev and a UI-test build
# org.ubiquitty.Ubiquitty.uitest (Source/Platform/macOS/CMakeLists.txt); a
# shipped one of those would keep its user's preferences, window state and
# notification routing under the wrong application, and no update feed would
# ever replace it. Only `build-macos.sh --release` and `--release-signing`
# produce the release identifier.

UBIQUITTY_RELEASE_BUNDLE_IDENTIFIER="org.ubiquitty.Ubiquitty"

# Prints a bundle's CFBundleIdentifier, or nothing when it has none.
#
# plistlib reads the XML and the binary form alike.
bundle_identifier() {
    python3 -c 'import plistlib, sys
with open(sys.argv[1], "rb") as plist:
    print(plistlib.load(plist).get("CFBundleIdentifier", ""))' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Exits 2 unless the bundle at $1 carries the release identifier.
require_release_bundle() {
    local app="$1"
    local identifier
    identifier="$(bundle_identifier "$app")"
    if [ "$identifier" != "$UBIQUITTY_RELEASE_BUNDLE_IDENTIFIER" ]; then
        echo "ERROR: $app carries the bundle identifier '${identifier:-none}', not $UBIQUITTY_RELEASE_BUNDLE_IDENTIFIER." >&2
        echo "  Only a release build is installed or shipped: ./Scripts/build-macos.sh --release" >&2
        exit 2
    fi
}
