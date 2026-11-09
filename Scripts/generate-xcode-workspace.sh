#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Generate the Xcode projects collected by Ubiquitty.xcworkspace.
#
# Each CMake frontend has its own cache because UBIQUITTY_FRONTEND selects a
# different target graph. The workspace keeps those independent projects open
# together without making Xcode's derived data part of the source tree.
#
# The iOS arm is the same Core rendered through the Apple-shared Swift layer.
# Like build-ios.sh it is a cross build: CMAKE_SYSTEM_NAME=iOS plus an SDK and
# an arch. Unlike build-ios.sh it is one project for both SDKs, configured for
# iphoneos: Xcode picks the SDK from the destination when a build starts, so a
# project that named one could be built for the other only by breaking. The
# SDK-bound products — the SwiftPM archive, the metallib, the icon, the QUIC
# archives — live under a directory per SDK that the project names through
# $(PLATFORM_NAME). The iOS branch of CMakeLists.txt says how.
#
# UbiquittyIOS.xcworkspace names the iOS project alone. It is the workspace an
# --ios-only run leaves to open, and the one Xcode Cloud archives from: the full
# workspace also names three projects such a run does not generate, and
# xcodebuild cannot list a workspace naming a project that is not there.
#
# UBIQUITTY_IOS_BUILD_NUMBER, when set, is the iOS app's CFBundleVersion for an
# App Store Connect upload; the iOS branch of CMakeLists.txt says why it is an
# input of its own. Unset, the app carries the version's bundle integer.
#
# --device-only builds the iOS project's QUIC dependencies for iphoneos alone,
# for an archive that never builds for the simulator, as Xcode Cloud's does
# (ci_scripts/ci_post_clone.sh). Such a project cannot link for a simulator.
#
# The run ends with Scripts/check-xcode-workspace.py over what was written, so
# a project a destination cannot build, or an archive App Store Connect would
# refuse, is reported here rather than by Xcode.
#
# Usage:
#   ./Scripts/generate-xcode-workspace.sh
#   ./Scripts/generate-xcode-workspace.sh --without-quic
#   ./Scripts/generate-xcode-workspace.sh --without-ios
#   ./Scripts/generate-xcode-workspace.sh --ios-only
#   ./Scripts/generate-xcode-workspace.sh --ios-only --device-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

# The deployment target has one home: a binary built for a newer floor than the
# app's Info.plist declares installs on a machine that cannot launch it.
# The checkout holding the deployment floors is CORE_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$root/Scripts/library-scripts.sh"
UBQ_MACOS_MIN="$(sed -n 's/^cxx=//p' "$CORE_ROOT/Scripts/macos-deployment-target.txt")"
buildRoot="$root/build/xcode"
quic=ON
withIOS=1
deviceOnly=OFF

while [ $# -gt 0 ]; do
    case "$1" in
        --without-quic) quic=OFF ;;
        --without-ios) withIOS=0 ;;
        --ios-only) withIOS=2 ;;
        --device-only) deviceOnly=ON ;;
        -h|--help)
            sed -n '5,42p' "$0"
            exit 0
            ;;
        *)
            echo "unknown option: $1 (see --help)" >&2
            exit 2
            ;;
    esac
    shift
done

if ! cmake --help 2>/dev/null | grep -q 'Xcode'; then
    echo "CMake's Xcode generator is unavailable. Select a full Xcode installation first." >&2
    exit 1
fi

# The Apple Developer team the device project signs with.
#
# Xcode keeps the team in project.pbxproj, which every regeneration rewrites, so
# a team chosen in the UI is lost on the next run of this script. Naming it here
# is what makes it stick. UBIQUITTY_DEVELOPMENT_TEAM wins; otherwise the one
# team in the keychain is used, because a developer with a single Apple account
# should not have to configure anything. Several teams, or none, leaves it empty
# and Xcode asks — guessing between two accounts would sign with the wrong one.
if [ -z "${UBIQUITTY_DEVELOPMENT_TEAM:-}" ]; then
    # The common-name suffix identifies the certificate's developer, not its
    # team. Resolve the usable certificate by fingerprint and read its OU.
    teams="$(python3 "$root/Scripts/apple-development-teams.py")"
    if [ "$(printf '%s' "$teams" | grep -c .)" = "1" ]; then
        UBIQUITTY_DEVELOPMENT_TEAM="$teams"
        echo "generate-xcode-workspace: signing with team $UBIQUITTY_DEVELOPMENT_TEAM (from the keychain)"
    elif [ -n "$teams" ]; then
        echo "generate-xcode-workspace: several signing teams in the keychain; set UBIQUITTY_DEVELOPMENT_TEAM to pick one" >&2
    fi
fi

generateFrontend()
{
    local frontend="$1"
    local directory="$2"
    local projectName="$3"

    # The QUIC dependencies' prefix rides the override the build scripts take;
    # CMake's default is the checkout's build root.
    cmake -S "$root" -B "$buildRoot/$directory" -G Xcode \
        -DUBIQUITTY_CMAKE_PROJECT_NAME="$projectName" \
        -DUBIQUITTY_FRONTEND="$frontend" \
        -DUBIQUITTY_QUIC="$quic" \
        ${UBIQUITTY_QUIC_PREFIX:+"-DUBIQUITTY_QUIC_PREFIX=$UBIQUITTY_QUIC_PREFIX"} \
        -DCMAKE_OSX_SYSROOT=macosx \
        -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=macosx \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$UBQ_MACOS_MIN"
}

generateIOS()
{
    local directory="$1"
    local projectName="$2"
    local sdk

    for sdk in iphoneos iphonesimulator; do
        if ! xcrun --sdk "$sdk" --show-sdk-path >/dev/null 2>&1; then
            echo "generate-xcode-workspace: no $sdk SDK — skipping $projectName (needs full Xcode)" >&2
            return 0
        fi
    done
    # iphoneos, by name. It is the base SDK Xcode derives the simulator from,
    # so the project accepts both kinds of destination; iphonesimulator here
    # would make every target simulator-only. By name rather than by path so
    # the project survives an Xcode update that renames the SDK's directory.
    cmake -S "$root" -B "$buildRoot/$directory" -G Xcode \
        -DUBIQUITTY_CMAKE_PROJECT_NAME="$projectName" \
        -DUBIQUITTY_DEVELOPMENT_TEAM="${UBIQUITTY_DEVELOPMENT_TEAM:-}" \
        -DUBIQUITTY_IOS_BUILD_NUMBER="${UBIQUITTY_IOS_BUILD_NUMBER:-}" \
        -DUBIQUITTY_IOS_DEVICE_ONLY="$deviceOnly" \
        -DUBIQUITTY_FRONTEND=iOS \
        ${UBIQUITTY_QUIC_PREFIX:+"-DUBIQUITTY_QUIC_PREFIX=$UBIQUITTY_QUIC_PREFIX"} \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64
}

if [ "$withIOS" != "2" ]; then
    generateFrontend macOS macos UbiquittyMacOS
    generateFrontend Host host UbiquittyHost
    generateFrontend Agent agent UbiquittyAgent
fi

if [ "$withIOS" != "0" ]; then
    generateIOS ios UbiquittyIOS
    # The two per-SDK projects this one replaces. Left in place, they are
    # gigabytes nothing references; named, so removing them is one command.
    for superseded in ios-simulator ios-device; do
        if [ -d "$buildRoot/$superseded" ]; then
            echo "generate-xcode-workspace: $buildRoot/$superseded is from the per-SDK layout and is no longer used; remove it with: rm -rf '$buildRoot/$superseded'" >&2
        fi
    done
fi

# The workspace that collects the generated projects. Committed as a thin
# wrapper: it contains only FileRefs to build/xcode/, which is gitignored.
# Xcode resolves `group:` locations relative to the workspace's own
# directory, so `build/xcode/...` is the path from the repo root.
workspace="$root/Ubiquitty.xcworkspace"
mkdir -p "$workspace"
cat > "$workspace/contents.xcworkspacedata" <<'WORKSPACE'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

<Workspace
   version = "1.0">
   <FileRef
      location = "group:build/xcode/macos/UbiquittyMacOS.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:build/xcode/host/UbiquittyHost.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:build/xcode/agent/UbiquittyAgent.xcodeproj">
   </FileRef>
   <FileRef
      location = "group:build/xcode/ios/UbiquittyIOS.xcodeproj">
   </FileRef>
</Workspace>
WORKSPACE

# The iOS project alone, committed and rewritten the same way. Its text must stay
# what is committed: a build reads a tracked file that differs from the commit
# as a modified tree, and says so in its build identity.
iosWorkspace="$root/UbiquittyIOS.xcworkspace"
mkdir -p "$iosWorkspace"
cat > "$iosWorkspace/contents.xcworkspacedata" <<'WORKSPACE'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

<Workspace
   version = "1.0">
   <FileRef
      location = "group:build/xcode/ios/UbiquittyIOS.xcodeproj">
   </FileRef>
</Workspace>
WORKSPACE

# When --without-ios, or an SDK this machine lacks, skips a frontend, a FileRef
# to its missing .xcodeproj breaks `xcodebuild -list`. The committed workspace
# keeps naming every frontend, so a partial run never leaves the checkout with a
# change; the partial run writes its pruned copy to build/xcode/, beside the
# projects it names, and that is the workspace to open. An --ios-only run has
# UbiquittyIOS.xcworkspace for that.
pruneWorkspace()
{
    local present=0
    local missing=0
    local contents
    contents="$(cat "$workspace/contents.xcworkspacedata")"
    for ref in \
        "build/xcode/macos/UbiquittyMacOS.xcodeproj" \
        "build/xcode/host/UbiquittyHost.xcodeproj" \
        "build/xcode/agent/UbiquittyAgent.xcodeproj" \
        "build/xcode/ios/UbiquittyIOS.xcodeproj"; do
        if [ -d "$root/$ref" ]; then
            present=$((present+1))
        else
            # Drop the whole FileRef element: its opening tag, its location
            # line and its closing tag.
            contents="$(printf '%s\n' "$contents" | awk -v ref="location = \"group:$ref\">" '
                /<FileRef$/ { held = $0; next }
                held != "" {
                    if (index($0, ref)) { skip = 1 } else { print held; print }
                    held = ""; next
                }
                skip && /<\/FileRef>/ { skip = 0; next }
                { print }
            ')"
            missing=$((missing+1))
        fi
    done
    if [ "$missing" -gt 0 ]; then
        # The pruned copy lives in build/xcode/, so its locations are relative
        # to that directory rather than to the repo root.
        workspace="$root/build/xcode/Ubiquitty.xcworkspace"
        mkdir -p "$workspace"
        printf '%s\n' "$contents" | sed 's#"group:build/xcode/#"group:#' > "$workspace/contents.xcworkspacedata"
        echo "Workspace pruned: $present projects present, $missing absent (see above for skipped SDKs); the committed workspace is unchanged." >&2
    fi
}
if [ "$withIOS" = "2" ]; then
    workspace="$iosWorkspace"
else
    pruneWorkspace
fi

# What was just written, held to what a destination needs of it. Here rather
# than only in a gate, because the person this protects is the one who ran the
# script and is about to open Xcode.
python3 "$root/Scripts/check-xcode-workspace.py" --workspace "$workspace"

echo
echo "Generated: $workspace"
echo "Open it with: open -a Xcode $workspace"
if [ "$withIOS" != "0" ]; then
    echo "iOS: select the UbiquittyIOSApp scheme and an iPhone, an iPad or a simulator."
    echo "     A simulator build is unsigned; a device build signs with the team named above."
fi
