#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# archive-macos.sh — build, sign, notarize, verify and archive the macOS app in
# one step, from the commit this checkout stands on.
#
#   ./Scripts/archive-macos.sh                  fetch Sparkle, build, notarize, archive
#   ./Scripts/archive-macos.sh --allow-dirty    archive uncommitted changes too (marked dirty)
#   ./Scripts/archive-macos.sh --existing       archive the app the last run notarized,
#                                               without building or notarizing again
#   ./Scripts/archive-macos.sh --profile NAME   notarytool keychain profile
#                                               (default: ubiquitty-notary)
#
# Before building it checks what would otherwise fail late: a clean tree, a
# "Developer ID Application" identity, and a provisioning profile authorizing
# the app's keychain access group. notarize-macos.sh checks the notary profile.
# It fetches the pinned Sparkle framework, so the build embeds it, then runs
# notarize-macos.sh: a distribution-signed build, notarization, stapling and a
# zip. It refuses to archive a bundle that is not what a release ships:
# Developer ID signed, notarized and stapled, carrying the keychain access
# group, Sparkle and its update key, and built from this commit.
#
# The archive goes outside the build root, so a later build or a build-root
# cleanup cannot replace it:
#
#   $UBQ_ARCHIVE_ROOT/<version>-<build>-<commit>-<UTC time>/
#     <App>-<version>.zip        the notarized, stapled app, as a person gets it
#     <App>.app.dSYM.zip         the symbols that read this build's crash reports
#     archive.json               commit, versions, identity, team, profile,
#                                notary submission, toolchain and checksums
#     SHA256SUMS
#     build.log                  the build and notarization output
#
# UBQ_ARCHIVE_ROOT defaults to ~/Library/Developer/Ubiquitty/Archives.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"

PROFILE="ubiquitty-notary"
ALLOW_DIRTY=0
EXISTING=0
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --existing) EXISTING=1 ;;
        --profile)
            shift
            [ $# -gt 0 ] || { echo "--profile requires a name" >&2; exit 2; }
            PROFILE="$1" ;;
        --profile=*) PROFILE="${1#--profile=}" ;;
        -h|--help) sed -n '5,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "archive-macos.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

APP_NAME="${UBIQUITTY_APP_NAME:-Ubiquitty}"
APP="$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/$APP_NAME.app"
ARCHIVE_ROOT="${UBQ_ARCHIVE_ROOT:-$HOME/Library/Developer/Ubiquitty/Archives}"
BUNDLE_ID="org.ubiquitty.Ubiquitty"

fail() {
    echo "archive-macos.sh: $*" >&2
    exit 1
}

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
DIRTY=0
if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    DIRTY=1
    [ "$ALLOW_DIRTY" = "1" ] || fail "the tree has uncommitted changes; commit them, or pass --allow-dirty to archive them marked dirty."
fi

# The identity the build will sign with, and the team it names.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[ -n "$IDENTITY" ] || fail "no \"Developer ID Application\" identity in the keychain. Create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates."
TEAM_ID="$(printf '%s\n' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
[ -n "$TEAM_ID" ] || fail "cannot read the team from \"$IDENTITY\"."

# A profile for TEAM.BUNDLE (or TEAM.*), where build-macos.sh looks for one.
# Without it the app ships without its keychain access group, and keeps no
# remote window across a restart.
PROFILE_FILE="${UBIQUITTY_PROVISIONING_PROFILE:-}"
if [ -z "$PROFILE_FILE" ]; then
    SCRATCH="$(mktemp -d)"
    trap 'rm -rf "$SCRATCH"' EXIT
    for candidate in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile \
            "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile; do
        [ -f "$candidate" ] || continue
        security cms -D -i "$candidate" -o "$SCRATCH/profile.plist" 2>/dev/null || continue
        identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$SCRATCH/profile.plist" 2>/dev/null || true)"
        case "$identifier" in
            "$TEAM_ID.$BUNDLE_ID"|"$TEAM_ID.*") PROFILE_FILE="$candidate"; break ;;
        esac
    done
fi
[ -n "$PROFILE_FILE" ] && [ -f "$PROFILE_FILE" ] \
    || fail "no provisioning profile authorizes $TEAM_ID.$BUNDLE_ID. Create a Developer ID profile for $BUNDLE_ID at developer.apple.com ▸ Profiles, and put it in ~/Library/Developer/Xcode/UserData/Provisioning Profiles, or set UBIQUITTY_PROVISIONING_PROFILE."

LOG="$UBQ_BUILD_ROOT/archive-macos.log"
if [ "$EXISTING" = "0" ]; then
    "$ROOT/Scripts/fetch-sparkle.sh"
    "$ROOT/Scripts/notarize-macos.sh" --profile "$PROFILE" 2>&1 | tee "$LOG"
elif [ ! -f "$LOG" ]; then
    echo "archive-macos.sh: no log of a previous run at $LOG; the archive records no notary submission." >&2
fi

# What a release ships, checked on the bundle itself.
[ -d "$APP" ] || fail "$APP not found."
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
BUILD_IDENTITY="$(plist UBBuildIdentity)"
[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "the bundle is not $BUNDLE_ID."
case "$BUILD_IDENTITY" in
    *"(${COMMIT:0:8},"*|*"(${COMMIT:0:8})"*) ;;
    *) fail "the app says it was built from \"$BUILD_IDENTITY\", not ${COMMIT:0:8}; build it from this commit." ;;
esac
SIGNER="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' | head -1)"
[ -n "$SIGNER" ] || fail "the app is not signed with a Developer ID Application identity."
codesign --verify --deep --strict "$APP" || fail "the bundle's signature does not verify."
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
printf '%s' "$ENTITLEMENTS" | grep -q "$TEAM_ID.$BUNDLE_ID" \
    || fail "the app carries no keychain access group for $TEAM_ID.$BUNDLE_ID; the provisioning profile was not applied."
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$SPARKLE" ] || fail "Sparkle.framework is not embedded; the app could not update itself."
[ -n "$(plist SUPublicEDKey)" ] || fail "the app has no SUPublicEDKey; Sparkle could not verify an update."
xcrun stapler validate "$APP" >/dev/null || fail "no notarization ticket is stapled to the app."
GATEKEEPER="$(spctl -a -vv --type execute "$APP" 2>&1 || true)"
printf '%s\n' "$GATEKEEPER" | grep -q "source=Notarized Developer ID" \
    || fail "Gatekeeper does not accept the app as notarized: $GATEKEEPER"

DIST_ZIP="$UBQ_BUILD_ROOT/$APP_NAME-$VERSION.zip"
[ -f "$DIST_ZIP" ] || fail "$DIST_ZIP not found; notarize-macos.sh writes it."
SUBMISSION=""
[ -f "$LOG" ] && SUBMISSION="$(sed -n 's/^[[:space:]]*id: \([0-9a-f-]*\)$/\1/p' "$LOG" | tail -1)"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="$VERSION-$BUILD-${COMMIT:0:9}"
[ "$DIRTY" = "1" ] && NAME="$NAME-dirty"
DEST="$ARCHIVE_ROOT/$NAME-$STAMP"
mkdir -p "$DEST"
cp "$DIST_ZIP" "$DEST/"
if [ -d "$APP.dSYM" ]; then
    ditto -c -k --keepParent "$APP.dSYM" "$DEST/$APP_NAME.app.dSYM.zip"
else
    echo "archive-macos.sh: no dSYM beside the app; the archive cannot symbolicate crash reports." >&2
fi
[ -f "$LOG" ] && cp "$LOG" "$DEST/build.log"
(cd "$DEST" && shasum -a 256 -- *.zip > SHA256SUMS)

export APP_NAME BUNDLE_ID VERSION BUILD BUILD_IDENTITY COMMIT DIRTY STAMP SIGNER TEAM_ID \
    PROFILE_FILE SUBMISSION APP SPARKLE DEST ROOT
ARCHIVE_JSON="$DEST/archive.json" python3 - <<'EOF'
import json, os, plistlib, subprocess

environment = os.environ

def run(*command):
    return subprocess.run(command, capture_output=True, text=True).stdout.strip()

def plist(path):
    with open(path, "rb") as file:
        return plistlib.load(file)

profile = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", environment["PROFILE_FILE"]],
                                        capture_output=True).stdout)
info = plist(os.path.join(environment["APP"], "Contents", "Info.plist"))
sums = {}
for line in open(os.path.join(environment["DEST"], "SHA256SUMS")).read().splitlines():
    digest, name = line.split(None, 1)
    sums[name] = digest
record = {
    "app": environment["APP_NAME"],
    "bundle_identifier": environment["BUNDLE_ID"],
    "version": environment["VERSION"],
    "build": environment["BUILD"],
    "build_identity": environment["BUILD_IDENTITY"],
    "commit": environment["COMMIT"],
    "dirty": environment["DIRTY"] == "1",
    "describe": run("git", "-C", environment["ROOT"], "describe", "--tags", "--always", "--dirty"),
    "archived_at": environment["STAMP"],
    "signing_identity": environment["SIGNER"],
    "team": environment["TEAM_ID"],
    "provisioning_profile": {
        "name": profile.get("Name"),
        "uuid": profile.get("UUID"),
        "expires": profile["ExpirationDate"].isoformat() if "ExpirationDate" in profile else None,
    },
    "notary_submission": environment["SUBMISSION"] or None,
    "gatekeeper": "source=Notarized Developer ID",
    "sparkle_version": plist(os.path.join(environment["SPARKLE"], "Resources", "Info.plist")).get("CFBundleShortVersionString"),
    "sparkle_feed": info.get("SUFeedURL"),
    "sparkle_public_key": info.get("SUPublicEDKey"),
    "xcode": run("xcodebuild", "-version").replace("\n", " "),
    "sdk": run("xcrun", "--show-sdk-version"),
    "macos": run("sw_vers", "-productVersion") + " (" + run("sw_vers", "-buildVersion") + ")",
    "sha256": sums,
}
with open(environment["ARCHIVE_JSON"], "w") as file:
    json.dump(record, file, indent=2)
    file.write("\n")
EOF

echo
echo "Archived $APP_NAME $VERSION ($BUILD), ${COMMIT:0:9}$([ "$DIRTY" = "1" ] && echo ", dirty"):"
echo "  $DEST"
for file in "$DEST"/*; do echo "    $(basename "$file")"; done
