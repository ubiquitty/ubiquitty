#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-ios-smokes.sh — run the iOS shell's --smoke-* battery on a simulator and
# fail on the first non-passing one.
#
# The flag list is DERIVED from SmokeLaunch.swift's dispatch, never copied, on
# the same terms as run-linux-smokes.sh: a smoke added to the shell is covered
# here with no second list to drift.
#
# A simulator rather than a headless binary, because each of these smokes
# exists for a fault only a live UIKit application has: no display cycle reaches
# a view that overrides no drawRect:, and a PAL seam with nothing installed in
# it drops what the terminal hands it. A harness that calls the render path or
# the writer itself passes in either case.
#
#   ./Scripts/run-ios-smokes.sh [APP_BUNDLE]
#   SMOKE_TIMEOUT=120 ./Scripts/run-ios-smokes.sh
#
# The first launch after an install on a freshly booted device pays the
# simulator's first-launch work, which on a hosted runner took longer than a
# smoke's whole budget, and whichever smoke ran first failed for it. One warm-up
# launch takes that cost before the timed smokes; it is reported on its own
# line, bounded by SMOKE_WARMUP_TIMEOUT rather than the smoke budget, and a
# warm-up that never comes back fails the run.
#
# A smoke is judged by the report file it writes in the app's data container
# (SmokeLaunch.report), never by the console: the console has lost the last
# lines a smoke printed before exiting. A smoke passes on the line naming it
# with "-- PASS" and no FAIL line. A file with no verdict line means the smoke
# ended before reaching one, and the crash report the system wrote, if any,
# is shown with it.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The checkouts holding the scripts this one runs, CORE_ROOT and KIT_ROOT.
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$CORE_ROOT/Scripts/build-root.sh"
APP="${1:-$UBQ_BUILD_ROOT/ios-iphonesimulator/Ubiquitty.app}"
SRC="$ROOT/Source/Platform/iOS/App/SmokeLaunch.swift"
TIMEOUT="${SMOKE_TIMEOUT:-120}"
WARMUP_TIMEOUT="${SMOKE_WARMUP_TIMEOUT:-600}"
# The device this checkout owns, booted for this run and shut down when it
# ends; see Scripts/ios-simulator.sh.
# shellcheck source=Scripts/ios-simulator.sh
. "$KIT_ROOT/Scripts/ios-simulator.sh"
DEVICE_NAME="$(ubq_ios_device_name)"

# GNU `timeout` is not part of macOS, so the smoke deadline is carried by the
# system Python already present on the Xcode hosts this script runs on.
runWithTimeout() { # <seconds> <command...>
    /usr/bin/python3 - "$@" <<'PY'
import subprocess
import sys

seconds = int(sys.argv[1])
command = sys.argv[2:]

def write(data):
    if not data:
        return
    if isinstance(data, bytes):
        sys.stdout.buffer.write(data)
    else:
        sys.stdout.write(data)

try:
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=seconds,
    )
    write(completed.stdout)
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired as error:
    write(error.stdout)
    sys.exit(124)
PY
}

# Prints each crash report the system wrote for the app since <marker> was
# made: the exception, the termination reason and the crashed thread's frames.
# simctl answers 0 for a launch whose process then died, so this is what says
# why a smoke reached no verdict.
crashReportsSince() { # <marker>
    local found=0 report
    while IFS= read -r report; do
        found=1
        echo "        crash report: $report"
        /usr/bin/python3 - "$report" <<'PY' | sed 's/^/          /'
import json
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as file:
    file.readline()
    body = file.read()
try:
    report = json.loads(body)
except ValueError:
    print(body[:4000])
    sys.exit(0)
exception = report.get("exception", {})
print("exception:", exception.get("type", "?"), exception.get("signal", ""), exception.get("subtype", ""))
termination = report.get("termination", {})
if termination:
    print("termination:", termination.get("namespace", "?"), termination.get("code", ""), termination.get("indicator", ""))
for lines in report.get("asi", {}).values():
    for line in lines:
        print("message:", line)
images = report.get("usedImages", [])
for thread in report.get("threads", []):
    if not thread.get("triggered"):
        continue
    print("crashed thread:", thread.get("name") or thread.get("queue") or thread.get("id", "?"))
    for frame in thread.get("frames", [])[:24]:
        index = frame.get("imageIndex")
        image = images[index].get("name", "?") if isinstance(index, int) and index < len(images) else "?"
        print(f"  {image}  {frame.get('symbol', hex(frame.get('imageOffset', 0)))}+{frame.get('symbolLocation', 0)}")
PY
    done < <(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -newer "$1" \
        \( -name "$(basename "$EXECUTABLE")-*.ips" -o -name "$(basename "$EXECUTABLE")_*.ips" \) 2>/dev/null)
    [ "$found" -eq 1 ] || echo "        crash report: none written since the launch"
}

# A missing app verdict can be the simulator exiting, rather than an app
# crash. Preserve the runtime's first failure before later launches obscure it.
simulatorDiagnostics() {
    echo "        simulator state:"
    xcrun simctl list devices | grep -F "$DEVICE" | sed 's/^/          /'
    echo "        CoreSimulator host log (last ten minutes):"
    runWithTimeout 30 /usr/bin/log show --last 10m --style compact \
        --predicate 'process == "CoreSimulatorService" OR process == "SimulatorTrampoline" OR process == "launchd_sim" OR process == "SimRenderServer"' \
        2>&1 | tail -100 | sed 's/^/          /'
    echo "        recent runtime crash reports:"
    find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -newer "$launchMarker" \
        \( -name 'CoreSimulatorService*' -o -name 'launchd_sim*' -o -name 'SimRenderServer*' -o -name 'SimulatorTrampoline*' \) \
        -print -exec head -c 12000 {} \; 2>/dev/null | sed 's/^/          /'
}

[ -d "$APP" ] || { echo "run-ios-smokes: app bundle not found: $APP (build it with ./Scripts/build-ios.sh --sdk iphonesimulator)" >&2; exit 2; }
[ -f "$SRC" ] || { echo "run-ios-smokes: source not found: $SRC" >&2; exit 2; }
command -v xcrun >/dev/null 2>&1 || { echo "run-ios-smokes: xcrun not on PATH" >&2; exit 2; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null)"
[ -n "$BUNDLE_ID" ] || { echo "run-ios-smokes: no CFBundleIdentifier in $APP/Info.plist" >&2; exit 2; }
EXECUTABLE="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null)"
[ -x "$EXECUTABLE" ] || { echo "run-ios-smokes: no executable in $APP" >&2; exit 2; }

# A bundle older than the sources is the previous build, and it passes or fails
# for the previous build's reasons. A failed compile leaves the last good app in
# place, so without this the battery answers confidently about code that was
# never built.
STALE="$(find "$ROOT/Source/Platform/iOS" "$KIT_ROOT/Source/UbiquittyKit" "$KIT_ROOT/Source/UbiquittyRenderKit" \
    "$CORE_ROOT/Source/Core" "$CORE_ROOT/Source/PAL" "$CORE_ROOT/Source/Base" \
    -type f \( -name '*.swift' -o -name '*.cpp' -o -name '*.h' -o -name '*.mm' \) \
    -newer "$EXECUTABLE" -print 2>/dev/null | head -1)"
if [ -n "$STALE" ]; then
    echo "run-ios-smokes: $APP is older than ${STALE#"$ROOT/"} — build it with ./Scripts/build-ios.sh --sdk iphonesimulator" >&2
    exit 2
fi

FLAGS=()
while IFS= read -r flag; do
    FLAGS+=("$flag")
done < <(grep -oE '"(--smoke[a-z0-9-]+)"' "$SRC" | grep -oE -- '--smoke[a-z0-9-]+' | sort -u)

[ "${#FLAGS[@]}" -gt 0 ] || { echo "run-ios-smokes: no --smoke flags found in $SRC" >&2; exit 2; }

ubq_ios_device_acquire run-ios-smokes || exit 2
DEVICE="$UBQ_IOS_DEVICE"
installOutput="$(xcrun simctl install "$DEVICE" "$APP" 2>&1)"
installStatus=$?
if [ "$installStatus" -ne 0 ]; then
    echo "run-ios-smokes: could not install $APP on $DEVICE_NAME (exit $installStatus)" >&2
    printf '%s\n' "$installOutput" >&2
    xcrun simctl list runtimes >&2
    /usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP/Info.plist" >&2
    exit 2
fi

echo "run-ios-smokes: $BUNDLE_ID on $DEVICE_NAME — ${#FLAGS[@]} tests, ${TIMEOUT}s each"
warmupStart=$SECONDS
warmup="$(runWithTimeout "$WARMUP_TIMEOUT" xcrun simctl launch --terminate-running-process "$DEVICE" "$BUNDLE_ID")"
rc=$?
if [ "$rc" -ne 0 ]; then
    printf '  FAIL  warm-up launch (rc=%d, %ds)\n' "$rc" $((SECONDS - warmupStart))
    sed 's/^/        /' <<<"$warmup"
    echo "run-ios-smokes: FAILED — the warm-up launch never came back, so no smoke ran" >&2
    exit 1
fi
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
printf '  warm-up launch: ok (%ds)\n' $((SECONDS - warmupStart))
pass=0
fail=0
failed_flags=()
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data 2>/dev/null)"
[ -d "$CONTAINER/tmp" ] || { echo "run-ios-smokes: no data container for $BUNDLE_ID on $DEVICE_NAME" >&2; exit 2; }
REPORT="$CONTAINER/tmp/smoke-report.txt"
launchMarker="$(mktemp -t run-ios-smokes)"
for flag in "${FLAGS[@]}"; do
    # simctl launch answers for the LAUNCH, not for the process, so the verdict
    # is the smoke's own line in its report file. Each smoke writes one and
    # exits; --console-pty is what makes the launch wait for that exit.
    name="${flag#--smoke-}"
    rm -f "$REPORT"
    touch "$launchMarker"
    out="$(runWithTimeout "$TIMEOUT" xcrun simctl launch --console-pty --terminate-running-process \
        "$DEVICE" "$BUNDLE_ID" "$flag")"
    rc=$?
    report="$(cat "$REPORT" 2>/dev/null)"
    if [ "$rc" -eq 0 ] && grep -qxF -- "$name: -- PASS" <<<"$report" && ! grep -qE '\bFAIL' <<<"$report"; then
        printf '  ok    %s\n' "$flag"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s (rc=%d)\n' "$flag" "$rc"
        echo "        report:"
        sed 's/^/          /' <<<"$report"
        echo "        console:"
        sed 's/^/          /' <<<"$out"
        if ! grep -qxE -- "$name: -- (PASS|FAIL)" <<<"$report"; then
            echo "        no verdict in the report: the smoke ended before reaching one"
            crashReportsSince "$launchMarker"
            simulatorDiagnostics
        fi
        fail=$((fail + 1))
        failed_flags+=("$flag")
        state="$(ubq_ios_device_lookup "$DEVICE_NAME")"
        if [ "${state##* }" != Booted ]; then
            echo "run-ios-smokes: simulator left Booted state; remaining smokes are unexecuted" >&2
            break
        fi
    fi
done
rm -f "$launchMarker" "$REPORT"

echo "run-ios-smokes: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    echo "run-ios-smokes: FAILED — ${#failed_flags[@]} smoke(s): ${failed_flags[*]}" >&2
    exit 1
fi
