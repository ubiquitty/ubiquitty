#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-ios-ui-tests.sh — build and run the iOS XCUITest suite against the
# installed app on a simulator.
#
#   ./Scripts/run-ios-ui-tests.sh [APP_BUNDLE]
#   UI_TEST_TIMEOUT=600 ./Scripts/run-ios-ui-tests.sh
#   UBQ_IOS_DEVICE_TYPE="iPhone 16 Pro Max" ./Scripts/run-ios-ui-tests.sh
#                                   on a model whose landscape width is regular,
#                                   so the width-class case runs rather than
#                                   reporting itself skipped
#   UBQ_IOS_UI_ONLY=TerminalGestureUITests/testTerminalToolsAreVisible \
#       ./Scripts/run-ios-ui-tests.sh one case alone
#   Comma-separated case or class names select several focused cases.
#
# Exit 0 every case passed, 1 a case failed, 2 the run could not be set up.
#
# Why this is a script rather than an Xcode test target
#
# The app is built by CMake and Ninja; there is no .xcodeproj to hang a test
# target off, and the Xcode projects under build/xcode are generated. An
# XCUITest bundle does not actually need one: `xcodebuild test-without-building`
# takes an .xctestrun naming a test bundle, a runner app and the app under test,
# and Xcode ships the runner app as a template. So this script assembles the
# three pieces the same way Xcode would and hands them over.
#
#   1. the .xctest bundle          built by CMake (-DUBIQUITTY_IOS_UI_TESTS=ON)
#   2. <name>-Runner.app           the platform's XCTRunner.app, with the
#                                  bundle in PlugIns and the placeholders in
#                                  its Info.plist filled in
#   3. the .xctestrun              which points at 1, 2 and the app
#
# Two settings in there decide whether the run works at all, and each was
# found by a failure:
#
#   - DYLD_INSERT_LIBRARIES is left unset. libXCTestBundleInject.dylib is for
#     a unit test being injected into a host app; the UI runner links XCTest
#     itself, and injecting it too makes XCTest initialise twice and abort with
#     "Cannot initiate shared session more than once."
#   - the attachment lifetimes are set. A gesture takes a screenshot, and an
#     .xctestrun that does not say what to do with attachments leaves the
#     lifetime at -1, which XCTestCore refuses with "Internal lifetime -1 cannot
#     be converted into a public lifetime."
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"

BUILD="$UBQ_BUILD_ROOT/ios-iphonesimulator"
APP="${1:-$BUILD/Ubiquitty.app}"
# The budget follows the suite's size rather than standing at one number: a
# fixed budget runs out as the suite grows, with no case failing, and a run cut
# short reads as a gate failure for a suite that was passing. Ninety seconds a
# case allows for the slowest case under a loaded machine, with the boot and
# the install on top; a single case asked for by name keeps a floor.
declaredCases=$(cat "$ROOT/Source/Platform/iOS/UITest/"*.swift | grep -cE '^    func test[A-Za-z0-9_]*\(\)' || true)
TIMEOUT="${UI_TEST_TIMEOUT:-$(( 300 + 90 * ${declaredCases:-0} ))}"
# The device this checkout owns, booted for this run and shut down when it
# ends; see Scripts/ios-simulator.sh.
# shellcheck source=Scripts/ios-simulator.sh
. "$KIT_ROOT/Scripts/ios-simulator.sh"
DEVICE_NAME="$(ubq_ios_device_name)"
BUNDLE_NAME="UbiquittyUITests"
STAGE="$BUILD/uitest"

command -v xcrun >/dev/null 2>&1 || { echo "run-ios-ui-tests: xcrun not on PATH" >&2; exit 2; }
DEVELOPER="$(xcode-select -p)"
PLATFORM="$DEVELOPER/Platforms/iPhoneSimulator.platform/Developer"
TEMPLATE="$PLATFORM/Library/Xcode/Agents/XCTRunner.app"
[ -d "$TEMPLATE" ] || { echo "run-ios-ui-tests: no XCTRunner template at $TEMPLATE" >&2; exit 2; }
[ -d "$APP" ] || { echo "run-ios-ui-tests: app bundle not found: $APP (build it with ./Scripts/build-ios.sh --sdk iphonesimulator)" >&2; exit 2; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null)"
[ -n "$BUNDLE_ID" ] || { echo "run-ios-ui-tests: no CFBundleIdentifier in $APP/Info.plist" >&2; exit 2; }

# The .xctest bundle, built by the same CMake that built the app so it cannot
# drift from the SDK or deployment target the app was compiled against.
XCTEST="$BUILD/$BUNDLE_NAME.xctest"
if [ ! -d "$XCTEST" ]; then
    echo "run-ios-ui-tests: no $BUNDLE_NAME.xctest in $BUILD" >&2
    echo "run-ios-ui-tests: build it with ./Scripts/build-ios.sh --sdk iphonesimulator --ui-tests" >&2
    exit 2
fi
# The APP older than app sources is the same fault one level up: a lane that
# checks only the test bundle's freshness drives a stale Ubiquitty.app the
# smoke runner refuses, reports passes, and says nothing about the thing under
# test.
#
# Same sources the smoke runner watches, for the same reason — a lane that
# answers about a binary predating the change is worse than one that does not
# run, because it answers confidently.
# UITest/ is excluded from the APP's sweep: the app does not compile the test
# sources, so ninja never relinks it for a test-only edit, and including them
# here reddens this check for every test change until an unrelated app rebuild.
# The bundle-staleness check below is the one that watches the test sources.
APP_STALE="$(find "$ROOT/Source/Platform/iOS" "$KIT_ROOT/Source/UbiquittyKit" "$KIT_ROOT/Source/UbiquittyRenderKit" \
    "$CORE_ROOT/Source/Core" "$CORE_ROOT/Source/PAL" "$CORE_ROOT/Source/Base" \
    -type f \( -name '*.swift' -o -name '*.cpp' -o -name '*.h' -o -name '*.mm' \) \
    ! -path "$ROOT/Source/Platform/iOS/UITest/*" \
    -newer "$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)" \
    -print 2>/dev/null | head -1)"
if [ -n "$APP_STALE" ]; then
    echo "run-ios-ui-tests: $APP is older than ${APP_STALE#"$ROOT/"} — rebuild it with ./Scripts/build-ios.sh --sdk iphonesimulator --ui-tests" >&2
    exit 2
fi

# A bundle older than its source is the previous build, and it passes or fails
# for the previous build's reasons.
#
# This catches only the case where the source is NEWER. It is not the whole of
# staleness: a source file restored with `mv` or `cp -p` keeps its original
# timestamp, so it can be older than a bundle built from different text
# entirely, and ninja will not rebuild it either. Nothing here can see that —
# the count of executed cases at the end is what does, by comparing what ran
# against what the suite declares.
STALE="$(find "$ROOT/Source/Platform/iOS/UITest" -type f -name '*.swift' \
    -newer "$XCTEST/$BUNDLE_NAME" -print 2>/dev/null | head -1)"
if [ -n "$STALE" ]; then
    echo "run-ios-ui-tests: $BUNDLE_NAME.xctest is older than ${STALE#"$ROOT/"} — rebuild it" >&2
    exit 2
fi

# ----------------------------------------------------------------------
# The runner app.
rm -rf "$STAGE"
mkdir -p "$STAGE"
RUNNER="$STAGE/$BUNDLE_NAME-Runner.app"
cp -R "$TEMPLATE" "$RUNNER" || { echo "run-ios-ui-tests: could not copy the XCTRunner template" >&2; exit 2; }
mv "$RUNNER/XCTRunner" "$RUNNER/$BUNDLE_NAME-Runner"
mkdir -p "$RUNNER/PlugIns"
cp -R "$XCTEST" "$RUNNER/PlugIns/"
# The template's Info.plist carries $(WRAPPEDPRODUCTNAME) placeholders that Xcode
# would substitute. Nothing substitutes them here, so they are set outright.
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleExecutable $BUNDLE_NAME-Runner" \
    -c "Set :CFBundleName $BUNDLE_NAME-Runner" \
    -c "Set :CFBundleIdentifier $BUNDLE_ID.uitests.xctrunner" \
    "$RUNNER/Info.plist" >/dev/null \
    || { echo "run-ios-ui-tests: could not fill in the runner's Info.plist" >&2; exit 2; }
# Ad-hoc, which is what a simulator accepts; a device run would need a real
# identity here.
#
# WITH the template's entitlements, and that is not optional. The runner needs
# com.apple.security.get-task-allow to be identifiable as an XPC peer; signed
# without it, the app under test takes an EXC_GUARD the moment automation
# attaches — it is the app that dies, inside
# _BSBundleIDForXPCConnectionAndIKnowWhatImDoingISwear, failing to resolve who
# is calling it. That reads as "the app crashed on this screen" and sends you
# looking through your own code for a fault that is in the signature.
ENTITLEMENTS="$RUNNER/RunnerEntitlements.plist"
[ -f "$ENTITLEMENTS" ] || { echo "run-ios-ui-tests: the XCTRunner template has no RunnerEntitlements.plist" >&2; exit 2; }
codesign --force --sign - --timestamp=none "$RUNNER/PlugIns/$BUNDLE_NAME.xctest" >/dev/null 2>&1
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$RUNNER" >/dev/null 2>&1 \
    || { echo "run-ios-ui-tests: could not sign the runner" >&2; exit 2; }
codesign -d --entitlements - --xml "$RUNNER" 2>/dev/null | grep -q 'get-task-allow' \
    || { echo "run-ios-ui-tests: the runner signed without get-task-allow — automation would kill the app" >&2; exit 2; }

# ----------------------------------------------------------------------
# The live-daemon credential, passed through only when the caller supplies it.
#
# The QUIC attach case needs a REAL daemon and a REAL key, so it cannot be an
# unconditional gate: it would pass on the one machine that has both and fail on
# every other. The key comes from the environment rather than the source,
# because a private key in version control is a worse problem than a conditional
# test.
#
#   UBQ_LIVE_SSH_HOST=127.0.0.1 UBQ_LIVE_SSH_USER=me \
#   UBQ_LIVE_SSH_KEY_FILE=/path/to/pem ./Scripts/run-ios-ui-tests.sh
#
# UBQ_LIVE_SSH_PORT (optional, default 22) points the case at an sshd of its
# own, so a run can reach a throwaway daemon instead of the machine's own.
# Scripts/run-ios-live-lane.sh sets all four for a private loopback listener
# whose host is built from this checkout, which is what the app accepts.
#
# With none of them set the case still RUNS and reports itself skipped, so the
# executed-count check below is unaffected. Dropping it from the count instead
# would let a real failure hide behind "that one is off today".
LIVE_HOST_ENTRIES=""
if [ -n "${UBQ_LIVE_SSH_HOST:-}" ] && [ -n "${UBQ_LIVE_SSH_USER:-}" ] && [ -f "${UBQ_LIVE_SSH_KEY_FILE:-}" ]; then
    LIVE_KEY_TEXT="$(/usr/bin/python3 -c 'import sys, xml.sax.saxutils as x; print(x.escape(open(sys.argv[1]).read()))' "$UBQ_LIVE_SSH_KEY_FILE")"
    LIVE_HOST_ENTRIES="      <key>UBQ_LIVE_SSH_HOST</key><string>${UBQ_LIVE_SSH_HOST}</string>
      <key>UBQ_LIVE_SSH_USER</key><string>${UBQ_LIVE_SSH_USER}</string>
      <key>UBQ_LIVE_SSH_KEY</key><string>${LIVE_KEY_TEXT}</string>
      <key>UBQ_LIVE_SSH_PORT</key><string>${UBQ_LIVE_SSH_PORT:-22}</string>
"
    echo "run-ios-ui-tests: live QUIC case enabled against ${UBQ_LIVE_SSH_USER}@${UBQ_LIVE_SSH_HOST}:${UBQ_LIVE_SSH_PORT:-22}"
else
    echo "run-ios-ui-tests: live QUIC case will report itself skipped — set UBQ_LIVE_SSH_HOST, UBQ_LIVE_SSH_USER and UBQ_LIVE_SSH_KEY_FILE to enable it" >&2
fi

# The width-class case turns the device, which changes the app's width class
# only on a model whose landscape width is regular. On any other it runs and
# reports itself skipped, which the count below accepts — so the skip is named
# here, where a person reading the run looks, rather than only in the log.
case "$(ubq_ios_device_type)" in
    *"Pro Max"* | *"Plus"*) ;;
    *) echo "run-ios-ui-tests: width-class case will report itself skipped on $(ubq_ios_device_type) — set UBQ_IOS_DEVICE_TYPE to a Pro Max or Plus model to run it" >&2 ;;
esac

# ----------------------------------------------------------------------
# The .xctestrun. __TESTROOT__ and __PLATFORMS__ are expanded by xcodebuild.
XCTESTRUN="$STAGE/$BUNDLE_NAME.xctestrun"
cat > "$XCTESTRUN" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>$BUNDLE_NAME</key>
  <dict>
    <key>IsUITestBundle</key><true/>
    <key>IsXCTRunnerHostedTestBundle</key><true/>
    <key>ProductModuleName</key><string>$BUNDLE_NAME</string>
    <key>TestBundlePath</key><string>__TESTHOST__/PlugIns/$BUNDLE_NAME.xctest</string>
    <key>TestHostPath</key><string>__TESTROOT__/$BUNDLE_NAME-Runner.app</string>
    <key>UITargetAppPath</key><string>$APP</string>
    <key>SystemAttachmentLifetime</key><string>deleteOnSuccess</string>
    <key>UserAttachmentLifetime</key><string>deleteOnSuccess</string>
    <key>TestingEnvironmentVariables</key>
    <dict>
${LIVE_HOST_ENTRIES}      <key>DYLD_FRAMEWORK_PATH</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Frameworks</string>
      <key>DYLD_LIBRARY_PATH</key>
      <string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib</string>
    </dict>
  </dict>
</dict></plist>
PLIST

# ----------------------------------------------------------------------
# The device: the one this checkout owns, booted for the run.
ubq_ios_device_acquire run-ios-ui-tests || exit 2
DEVICE="$UBQ_IOS_DEVICE"
xcrun simctl install "$DEVICE" "$APP" >/dev/null 2>&1 \
    || { echo "run-ios-ui-tests: could not install $APP on $DEVICE_NAME" >&2; exit 2; }
# The suite adds a host on its first run and finds it on the next. Starting from
# a known-empty app removes the difference between those two, and with it a case
# that passes only on a machine that has run it before.
xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$DEVICE" "$APP" >/dev/null 2>&1

# Launches the installed app once with test-build-only arguments and prints
# what it wrote. Passes when the launch exits 0 and printed <verdict>.
runTestBuildCheck() { # <verdict> <launch argument...>
    /usr/bin/python3 - "$DEVICE" "$BUNDLE_ID" "$@" <<'PY'
import subprocess
import sys

device, bundle, verdict = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    result = subprocess.run(
        ["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process",
         device, bundle, *sys.argv[4:]],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
except subprocess.TimeoutExpired as expired:
    output = expired.stdout or ""
    print(output if isinstance(output, str) else output.decode("utf-8", "replace"), end="")
    print(f"run-ios-ui-tests: {sys.argv[4]} timed out; rebuild with --ui-tests", file=sys.stderr)
    sys.exit(1)
print(result.stdout, end="")
sys.exit(0 if result.returncode == 0 and verdict in result.stdout and " FAIL" not in result.stdout else 1)
PY
}

# These test-build-only checks run here rather than in the ordinary smoke
# battery, which runs the release build: that build has neither Core's
# question-injection door nor the cold-resume fixture, so a flag naming either
# reaches an app that never answers it.
#
# The structure consent check drives Core's consent queue through the real iOS
# model before the external gesture suite starts.
if ! runTestBuildCheck "structure-consent: -- PASS" --check-structure-consent; then
    echo "run-ios-ui-tests: the Core-to-model structure consent check failed" >&2
    exit 1
fi

# The cold-resume check seals a workspace picture into protected storage and
# restores it into a new owner before any network, in one process and then
# across a relaunch: the write launch exits holding no owner, and the read
# launch finds the descriptor and secret with no path that could rebuild them.
#
# Every key, authorization and descriptor the check writes is named by a fresh
# random host or client identity, so nothing a previous run left in the
# device's keychain (which outlives the uninstall above) can be the item it
# collides with. A refusal names its step; the free space beside it is the
# one shared condition a run does not reset, so it is printed with the failure.
coldResumeFailed() { # <message>
    echo "run-ios-ui-tests: $1" >&2
    df -h "$HOME/Library/Developer/CoreSimulator/Devices/$DEVICE" 2>/dev/null | tail -1 \
        | awk '{ print "run-ios-ui-tests: free space on the device volume: " $4 }' >&2
    exit 1
}
# The cold-resume checks seal into storage that needs Complete protection,
# the precondition of the Kit's protected-file suite, and are gated by the same
# probe (Tests/Platform/test_ios_protected_file_probe.swift), built here with an
# entry point and run on the device. Only a measured class other than Complete
# skips them, by name and with the class; a probe that reads back no class
# fails the run, and a device that applies Complete runs them in full.
probeDirectory="$(mktemp -d "${TMPDIR:-/tmp}/ubq-ios-protection-probe.XXXXXX")"
printf 'import Foundation\nexit(completeProtectionApplies() ? 0 : 1)\n' >"$probeDirectory/main.swift"
xcrun --sdk iphonesimulator swiftc -O -warnings-as-errors -target "$(uname -m)-apple-ios17.0-simulator" \
    "$KIT_ROOT/Tests/Platform/test_ios_protected_file_probe.swift" "$probeDirectory/main.swift" \
    -o "$probeDirectory/probe" >"$probeDirectory/build.log" 2>&1 || {
    cat "$probeDirectory/build.log" >&2
    echo "run-ios-ui-tests: the protection probe did not build" >&2
    exit 1
}
probeStatus=0
probe="$(xcrun simctl spawn "$DEVICE" "$probeDirectory/probe" 2>&1)" || probeStatus=$?
printf '%s\n' "$probe"
readBack="$(sed -n 's/^probe: a file written with Complete protection reads back //p' <<<"$probe" | head -n 1)"
complete="NSURLFileProtectionComplete"
if [ "$probeStatus" -eq 0 ] && [ "$readBack" = "$complete" ]; then
    if ! runTestBuildCheck "cold-resume: -- PASS" --check-cold-resume; then
        coldResumeFailed "the protected cold-resume check failed"
    fi
    coldHost="$(uuidgen)"
    coldWrite="$(runTestBuildCheck "cold-resume: -- PASS" --check-cold-resume --cold-resume-phase write "$coldHost")" || {
        printf '%s\n' "$coldWrite"
        coldResumeFailed "the cold-resume write launch failed"
    }
    printf '%s\n' "$coldWrite"
    coldClient="$(sed -nE 's/.*process write client=([0-9A-F-]+) PASS.*/\1/p' <<<"$coldWrite" | head -1)"
    if [ -z "$coldClient" ] || ! runTestBuildCheck "cold-resume: -- PASS" --check-cold-resume \
        --cold-resume-phase read "$coldHost" --cold-resume-client "$coldClient"; then
        coldResumeFailed "the cold-resume relaunch did not restore the written workspace"
    fi
elif [ "$probeStatus" -ne 0 ] && [[ "$readBack" == NSURLFileProtection* ]] && [ "$readBack" != "$complete" ]; then
    skip="run-ios-ui-tests: cold resume SKIPPED — this simulator does not apply Complete protection: a file written with it reads back $readBack"
    echo "$skip"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning title=iOS cold resume skipped::$skip"
    fi
else
    echo "run-ios-ui-tests: the protection probe (exit $probeStatus) read back '${readBack:-nothing}', so cold resume has no verdict" >&2
    exit 1
fi
rm -rf "$probeDirectory"

echo "run-ios-ui-tests: $BUNDLE_NAME against $BUNDLE_ID on $DEVICE_NAME"
LOG="$STAGE/xcodebuild.log"
# UBQ_IOS_UI_ONLY names cases or classes to run alone (xcodebuild's
# -only-testing form, e.g. TerminalGestureUITests/testTerminalToolsAreVisible),
# for the edit-run loop on one case; unset, the whole bundle runs.
ONLY=()
if [ -n "${UBQ_IOS_UI_ONLY:-}" ]; then
    IFS=',' read -r -a selections <<< "$UBQ_IOS_UI_ONLY"
    for selection in "${selections[@]}"; do
        ONLY+=("-only-testing:$BUNDLE_NAME/$selection")
    done
fi
# The run must execute exactly the selected source cases. Comparing a focused
# run with the whole suite incorrectly fails every documented one-case run.
expected=$(/usr/bin/python3 - "$ROOT/Source/Platform/iOS/UITest" "${UBQ_IOS_UI_ONLY:-}" <<'PY'
from pathlib import Path
import re
import sys

cases = set()
for path in Path(sys.argv[1]).glob("*.swift"):
    current_class = None
    for line in path.read_text().splitlines():
        declaration = re.match(r"(?:final )?class (\w+): XCTestCase", line)
        if declaration:
            current_class = declaration[1]
        method = re.match(r"    func (test\w+)\(\)", line)
        if method and current_class:
            cases.add(current_class + "/" + method[1])
selected = set()
for selection in sys.argv[2].split(",") if sys.argv[2] else []:
    matches = {case for case in cases if case == selection or case.startswith(selection + "/")}
    if not matches:
        sys.exit("run-ios-ui-tests: unknown test selection: " + selection)
    selected.update(matches)
print(len(selected if sys.argv[2] else cases))
PY
) || exit 2
/usr/bin/python3 - "$TIMEOUT" "$LOG" xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" -destination "id=$DEVICE" ${ONLY[@]+"${ONLY[@]}"} <<'PY'
import subprocess
import sys

seconds = int(sys.argv[1])
log = sys.argv[2]
command = sys.argv[3:]
try:
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, timeout=seconds)
    output, code = completed.stdout, completed.returncode
except subprocess.TimeoutExpired as expired:
    output, code = (expired.stdout or ""), 124
    if not isinstance(output, str):
        output = output.decode("utf-8", "replace")
with open(log, "w") as handle:
    handle.write(output)
sys.exit(code)
PY
rc=$?

# The verdict is read from the log rather than taken from the exit code alone.
# xcodebuild prints "Test Suite ... passed" for a suite that executed nothing —
# after a runner crash it relaunches, selects the cases it has not run, finds
# none, and reports three passing suites with "Executed 0 tests". A lane that
# believed that would be green for a suite it never ran.
passed=$(grep -cE "^Test Case '.*' passed" "$LOG" 2>/dev/null || true)
failed=$(grep -cE "^Test Case '.*' failed" "$LOG" 2>/dev/null || true)
# Skipped counts as EXECUTED, not as missing. A case that declines itself — the
# live QUIC attach, with no daemon configured — prints "skipped", and a count of
# passes alone would come up one short and fail the lane on every machine
# without credentials.
# The check is asking "did every declared case get to decide", and a skip is a
# decision. A case that vanished is what it is meant to catch.
skipped=$(grep -cE "^Test Case '.*' skipped" "$LOG" 2>/dev/null || true)

for line in $(grep -oE "^Test Case '.*' (passed|failed)" "$LOG" 2>/dev/null | sed 's/Test Case .-\[[^ ]* //;s/\]. /|/'); do
    printf '  %s\n' "$line" | sed 's/|passed/  ok/;s/|failed/  FAIL/'
done
grep -E "^\s+.*: error: -\[" "$LOG" 2>/dev/null | sed 's/^/        /'

echo "run-ios-ui-tests: $passed passed, $failed failed, $skipped skipped ($expected selected, $declaredCases declared)"

if [ "$rc" -eq 124 ]; then
    echo "run-ios-ui-tests: TIMED OUT after ${TIMEOUT}s — see $LOG" >&2
    exit 1
fi
if [ "$failed" -ne 0 ]; then
    # The names, not just the count. A verdict that says how many and defers to
    # a log for which sends the reader to the log to learn the first thing they
    # were going to ask.
    failed_names="$(grep -oE "^Test Case '.*' failed" "$LOG" 2>/dev/null \
        | sed "s/^Test Case .-\[[^ ]* //;s/\]. failed$//" | paste -sd' ' -)"
    echo "run-ios-ui-tests: FAILED — $failed case(s): ${failed_names:-unnamed}" >&2
    echo "run-ios-ui-tests: the run's output is in $LOG" >&2
    exit 1
fi
if [ "$((passed + skipped))" -ne "$expected" ]; then
    echo "run-ios-ui-tests: RAN $((passed + skipped)) of $expected selected case(s) — see $LOG" >&2
    echo "run-ios-ui-tests: a suite that reports no failures having run nothing is not a pass" >&2
    exit 1
fi
# This comparison cannot see a case that was deleted. Both numbers come
# from the same suite, so removing a case lowers them together and the run
# reports a confident "N passed (the suite declares N)": a branch reset that
# discards uncommitted cases leaves a green run with the surfaces they cover
# unchecked.
#
# Nothing inside one run can catch that; the count is only a floor against a
# stale bundle. What catches it is the case count being in version control, so a
# disappearance is a diff rather than a quieter green.
if [ "$rc" -ne 0 ]; then
    echo "run-ios-ui-tests: xcodebuild exited $rc with every case passing — see $LOG" >&2
    exit 1
fi
