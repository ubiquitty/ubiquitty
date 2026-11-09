#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# package-macos.sh — zip the signed Ubiquitty.app for handing to friends.
#
# Produces $UBQ_BUILD_ROOT/share/Ubiquitty.zip containing Ubiquitty.app plus a README that
# tells the recipient how to get past Gatekeeper (the app is signed but not
# notarized, so macOS blocks it on first launch on someone else's Mac).
#
# Output lives in $UBQ_BUILD_ROOT/share, not $UBQ_BUILD_ROOT/dist: dist is the
# release staging area generate_appcast scans, and an unversioned zip there
# breaks it.
#
# Uses ditto, which preserves the bundle's code signature through zipping —
# a plain `zip -r` can mangle it, and a broken signature won't run on Apple
# Silicon even after the quarantine flag is removed.
#
#   ./Scripts/package-macos.sh                 package the default build
#   ./Scripts/package-macos.sh path/to.app     package a specific bundle
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
APP="${1:-$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/Ubiquitty.app}"
OUT="$UBQ_BUILD_ROOT/share"
STAGE="$OUT/Ubiquitty"
ZIP="$OUT/Ubiquitty.zip"

if [ ! -d "$APP" ]; then
    echo "No app at: $APP" >&2
    echo "  Build it first: ./Scripts/build-macos.sh --release" >&2
    exit 1
fi
# shellcheck source=Scripts/release-bundle.sh
. "$ROOT/Scripts/release-bundle.sh"
require_release_bundle "$APP"

# A broken signature won't launch on Apple Silicon regardless of quarantine, so
# refuse to ship one. Ad-hoc is fine (still runs once quarantine is stripped).
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "Signature on $APP is missing or broken." >&2
    echo "  Rebuild (./Scripts/build-macos.sh --release) so it gets signed, then retry." >&2
    exit 1
fi
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "Signed by: ${AUTHORITY:-ad-hoc}"

rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Ubiquitty.app"   # ditto preserves the signature; cp -R does not

cat > "$STAGE/README.txt" <<'EOF'
Ubiquitty — first launch

macOS blocks this the first time because it isn't from the App Store and
isn't notarized by Apple. Allow it once with EITHER of these:

Option A — point and click
  1. Double-click Ubiquitty. macOS refuses — that's expected, click through it.
  2. Open System Settings > Privacy & Security, scroll down, and click
     "Open Anyway" next to the Ubiquitty message.
  3. Confirm. Ubiquitty opens normally from then on.

Option B — one Terminal command
  1. Put Ubiquitty.app wherever you like (e.g. your Applications folder).
  2. In Terminal, run (adjust the path to where you put it):
        xattr -dr com.apple.quarantine /Applications/Ubiquitty.app
     If it says "Operation not permitted", put "sudo " in front.
  3. Double-click Ubiquitty. It opens normally from then on.

The block is only because the app isn't signed by a paid Apple developer
account — nothing is wrong with it.
EOF

# Third-party license texts travel with the distribution (redistribution
# compliance): the project notice + the per-dependency texts ride beside the .app.
python3 "$CORE_ROOT/Scripts/license_notices.py" --source "$ROOT" --core "$CORE_ROOT" --kit "$KIT_ROOT" --copy "$STAGE"

ditto -c -k --keepParent "$STAGE" "$ZIP"
echo "Packaged: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  Send that zip. The recipient unzips it and follows README.txt."
