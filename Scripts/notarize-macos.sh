#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# notarize-macos.sh — produce a shareable, Gatekeeper-clean Ubiquitty.app:
# build with distribution signing, submit to Apple's notary service, staple
# the ticket, verify, and zip.
#
#   ./Scripts/notarize-macos.sh                 build + notarize + staple + zip
#   ./Scripts/notarize-macos.sh --skip-build    notarize the existing $UBQ_BUILD_ROOT/macos app
#   ./Scripts/notarize-macos.sh --profile NAME  notarytool keychain profile
#                                               (default: ubiquitty-notary)
#
# one-time setup (after Apple Developer Program enrollment):
#   1. Install the signing certificate: Xcode ▸ Settings ▸ Accounts ▸ your team ▸
#      Manage Certificates ▸ + ▸ "Developer ID Application" (or create it at
#      developer.apple.com ▸ Certificates and double-click the download). Verify:
#        security find-identity -v -p codesigning | grep "Developer ID"
#   2. Store notary credentials in the keychain. Create an app-specific password
#      at appleid.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords, then:
#        xcrun notarytool store-credentials ubiquitty-notary \
#          --apple-id you@example.com --team-id YOURTEAMID \
#          --password <the-app-specific-password>
#      (The team id is on developer.apple.com ▸ Membership.)
#
# Output: $UBQ_BUILD_ROOT/<App>-<version>.zip — notarized, stapled, opens cleanly on any
# Mac (no right-click-Open dance). The stapled .app itself also remains at the
# normal build path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
PROFILE="ubiquitty-notary"
SKIP_BUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1 ;;
        --profile)
            shift
            [ $# -gt 0 ] || { echo "--profile requires a name" >&2; exit 2; }
            PROFILE="$1" ;;
        --profile=*)  PROFILE="${1#--profile=}" ;;
        -h|--help)    sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "notarize-macos.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

APP_NAME="${UBIQUITTY_APP_NAME:-Ubiquitty}"
APP="$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/$APP_NAME.app"

# Fail at the first call when the one-time credential setup has not happened:
# notarytool's own error for a missing profile names the keychain, not the setup.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "ERROR: notarytool keychain profile \"$PROFILE\" is missing or not working." >&2
    echo "  One-time setup (needs an app-specific password from appleid.apple.com):" >&2
    echo "    xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "      --apple-id you@example.com --team-id YOURTEAMID --password <app-specific>" >&2
    exit 1
fi

if [ "$SKIP_BUILD" = "0" ]; then
    # Full build (helpers included — a shared app should be self-contained),
    # signed for distribution: Developer ID + hardened runtime + timestamp.
    "$ROOT/Scripts/build-macos.sh" --release-signing
fi

[ -d "$APP" ] || { echo "ERROR: $APP not found — build first." >&2; exit 1; }
# shellcheck source=Scripts/release-bundle.sh
. "$ROOT/Scripts/release-bundle.sh"
require_release_bundle "$APP"

# The notary service rejects anything not signed with Developer ID + hardened
# runtime; verify locally so a stale dev-signed build fails here, not minutes
# later in the upload.
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' | head -1)"
if [ -z "$AUTHORITY" ]; then
    echo "ERROR: $APP_NAME.app is not signed with a Developer ID Application identity" >&2
    echo "  (a dev-signed build?). Re-run: ./Scripts/build-macos.sh --release-signing" >&2
    exit 1
fi
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow" \
    && { echo "ERROR: bundle carries get-task-allow (a debug entitlement); notarization will reject it." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
SUBMIT_ZIP="$UBQ_BUILD_ROOT/$APP_NAME-$VERSION-notarize.zip"
DIST_ZIP="$UBQ_BUILD_ROOT/$APP_NAME-$VERSION.zip"

echo "Zipping for submission ($APP -> $SUBMIT_ZIP) ..."
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "Submitting to Apple's notary service (waits for the verdict; typically 1-5 min) ..."
SUBMIT_OUT="$(xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)"
SUBMISSION_ID="$(printf '%s\n' "$SUBMIT_OUT" | sed -n 's/^[[:space:]]*id: \([0-9a-f-]*\)$/\1/p' | head -1)"
if ! printf '%s\n' "$SUBMIT_OUT" | grep -q "status: Accepted"; then
    echo "ERROR: notarization was not accepted." >&2
    if [ -n "$SUBMISSION_ID" ]; then
        echo "  Fetching the notary log (lists every rejected file + reason):" >&2
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2 || true
    fi
    exit 1
fi

# Staple the ticket into the app so Gatekeeper passes offline too, then verify
# end-to-end exactly as a recipient's machine would.
echo "Stapling the notarization ticket ..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv --type execute "$APP" 2>&1 | sed 's/^/  /'

echo "Zipping the stapled app for distribution ..."
rm -f "$DIST_ZIP" "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP" "$DIST_ZIP"
echo
echo "Shareable: $DIST_ZIP"
echo "  (notarized + stapled — opens cleanly on any Mac)"
