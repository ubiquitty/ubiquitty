#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Xcode Cloud's post-clone step: turns a fresh clone into one that
# UbiquittyIOS.xcworkspace archives from.
#
# The workspace names a project that is generated rather than committed, so a
# clone has nothing to build until this runs. In order, it
#   1. installs CMake and Go with Homebrew, which the build image carries: CMake
#      writes the project, and the configure that writes it cross-builds the
#      QUIC dependencies, AWS-LC and ngtcp2, which need Go, Perl and the network;
#   2. fetches the history and tags a shallow clone leaves out, because the
#      version a build carries is counted from the nearest version tag
#      (Scripts/cmake/BuildVersion.cmake), and a clone that reaches none reads
#      the VERSION file instead;
#   3. generates the iOS project for the team the app is signed by, with Xcode
#      Cloud's build number as the app's CFBundleVersion. For an archive, which
#      builds for a device alone, the QUIC dependencies are built for iphoneos
#      only: the configure would otherwise build them for the simulator too, on
#      every run, for nothing.
#
# The build root, where the QUIC dependencies are built, is inside the clone
# beside the generated project, which links them by their path there.
#
# Xcode Cloud runs this from ci_scripts/, with CI_PRIMARY_REPOSITORY_PATH naming
# the clone and CI_BUILD_NUMBER the build. Run by hand with CI_BUILD_NUMBER set,
# it does the same to the checkout it is in.

set -euo pipefail

say()
{
    printf 'ci_post_clone: %s\n' "$*"
}

fail()
{
    printf 'ci_post_clone: %s\n' "$*" >&2
    exit 1
}

root="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
buildNumber="${CI_BUILD_NUMBER:-}"
[ -n "$buildNumber" ] || fail "CI_BUILD_NUMBER is unset; Xcode Cloud sets it, and a run by hand has to name one"

if [ -n "${CI_PRODUCT_PLATFORM:-}" ] && [ "$CI_PRODUCT_PLATFORM" != "iOS" ]; then
    fail "the workflow builds for $CI_PRODUCT_PLATFORM, and this prepares the iOS project only"
fi

# The team the app is signed by. A workflow under another team could not sign
# org.ubiquitty.Ubiquitty, and says so here rather than at the end of the archive.
team=5TC8J8TCS3
if [ -n "${CI_TEAM_ID:-}" ] && [ "$CI_TEAM_ID" != "$team" ]; then
    fail "Xcode Cloud signs for team $CI_TEAM_ID, and the app is signed by team $team"
fi

# Perl is part of macOS and is installed only if an image lacks it.
# HOMEBREW_NO_AUTO_UPDATE skips refreshing Homebrew itself before the install.
missing=()
for tool in cmake go perl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    command -v brew >/dev/null 2>&1 || fail "no Homebrew to install ${missing[*]} with"
    say "installing ${missing[*]} with Homebrew"
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install ${missing[@]+"${missing[@]}"}
fi
say "$(cmake --version | sed -n 1p); $(go version)"

cd "$root"
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    say "fetching the history and tags the shallow clone left out"
    git fetch --quiet --unshallow --tags \
        || fail "could not fetch the history and tags; without them the build reads its version from VERSION"
else
    say "fetching tags"
    git fetch --quiet --tags \
        || fail "could not fetch tags; without them the build reads its version from VERSION"
fi
say "version $("$root/Scripts/build-version.sh" version) ($("$root/Scripts/build-version.sh" identity))"

export UBQ_BUILD_ROOT="$root/build/xcode-cloud"
generation=(--ios-only)
if [ -n "${CI_XCODE_CLOUD:-}${CI:-}" ] && [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
    generation+=(--device-only)
fi
say "generating the iOS project (${generation[*]}) for team $team, CFBundleVersion $buildNumber, build root $UBQ_BUILD_ROOT"
UBIQUITTY_DEVELOPMENT_TEAM="$team" UBIQUITTY_IOS_BUILD_NUMBER="$buildNumber" \
    "$root/Scripts/generate-xcode-workspace.sh" "${generation[@]}"

# A tracked file changed by the steps above would make the build describe its
# tree as modified in the build identity it reports.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git status --short --untracked-files=no >&2
    fail "generating the project changed tracked files"
fi
say "ready: UbiquittyIOS.xcworkspace, scheme UbiquittyIOSApp"
