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
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
APP="${1:-$UBQ_BUILD_ROOT/ios-iphonesimulator/Ubiquitty.app}"
SRC="$ROOT/Source/Platform/iOS/App/SmokeLaunch.swift"
TIMEOUT="${SMOKE_TIMEOUT:-120}"
# The device this checkout owns, booted for this run and shut down when it
# ends; see Scripts/ios-simulator.sh.
# shellcheck source=Scripts/ios-simulator.sh
. "$ROOT/Scripts/ios-simulator.sh"
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
STALE="$(find "$ROOT/Source/Platform/iOS" "$ROOT/Source/UbiquittyKit" "$ROOT/Source/UbiquittyRenderKit" \
    "$ROOT/Source/Core" "$ROOT/Source/PAL" "$ROOT/Source/Base" \
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
xcrun simctl install "$DEVICE" "$APP" >/dev/null 2>&1 \
    || { echo "run-ios-smokes: could not install $APP on $DEVICE_NAME" >&2; exit 2; }

echo "run-ios-smokes: $BUNDLE_ID on $DEVICE_NAME — ${#FLAGS[@]} tests, ${TIMEOUT}s each"
pass=0
fail=0
failed_flags=()
for flag in "${FLAGS[@]}"; do
    # simctl launch answers for the LAUNCH, not for the process, so the verdict
    # is the smoke's own printed line. Each smoke prints one and exits.
    out="$(runWithTimeout "$TIMEOUT" xcrun simctl launch --console-pty --terminate-running-process \
        "$DEVICE" "$BUNDLE_ID" "$flag")"
    rc=$?
    if [ "$rc" -eq 0 ] && grep -qE -- '-- PASS' <<<"$out" && ! grep -qE '\bFAIL' <<<"$out"; then
        printf '  ok    %s\n' "$flag"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s (rc=%d)\n' "$flag" "$rc"
        sed 's/^/        /' <<<"$out"
        fail=$((fail + 1))
        failed_flags+=("$flag")
    fi
done

echo "run-ios-smokes: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    echo "run-ios-smokes: FAILED — ${#failed_flags[@]} smoke(s): ${failed_flags[*]}" >&2
    exit 1
fi
