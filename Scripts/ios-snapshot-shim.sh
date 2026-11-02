#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Runs the snapshot protocol inside the iOS simulator application and copies
# its PNG out of the sandbox. The Python harness can therefore treat UIKit as
# another renderer arm without teaching case discovery about simctl.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
APP="$UBQ_BUILD_ROOT/ios-iphonesimulator/Ubiquitty.app"
EXECUTABLE="$APP/Ubiquitty"
# The device this checkout owns, booted for this run and shut down when it
# ends; see Scripts/ios-simulator.sh. The snapshot harness renders many cases
# through this shim in one run and sets UBQ_IOS_KEEP_BOOTED for the batch.
# shellcheck source=Scripts/ios-simulator.sh
. "$ROOT/Scripts/ios-simulator.sh"
BUNDLE_ID="org.ubiquitty.Ubiquitty"

if [ "${1:-}" = "--print-render-binary" ]; then
    printf '%s\n' "$EXECUTABLE"
    exit 0
fi

OUTPUT=""
SCALE=""
SIZED_TEXT=""
UNFOCUSED=""
PASSTHROUGH=()
CONFIG=""
FEED=""
FEED_FILE=""
ROWS=""
COLUMNS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --snapshot) OUTPUT="${2:-}"; shift 2 ;;
        --snapshot-backend)
            [ "${2:-}" = "ios" ] || { echo "ios-snapshot: backend must be ios" >&2; exit 2; }
            shift 2
            ;;
        --config) CONFIG="${2:-}"; shift 2 ;;
        --feed) FEED="${2:-}"; shift 2 ;;
        --feed-file) FEED_FILE="${2:-}"; shift 2 ;;
        --rows) ROWS="${2:-}"; shift 2 ;;
        --columns) COLUMNS="${2:-}"; shift 2 ;;
        --draws-sized-text) SIZED_TEXT="--draws-sized-text"; shift ;;
        --unfocused) UNFOCUSED="--unfocused"; shift ;;
        # Passed through to the app, which states the configuration flags
        # through Core's helper and applies the post-feed actions as the
        # macOS driver does. --bg-image waits on a backdrop pass of its own.
        --bg-opacity | --tek-color-mode | --tek-beam | --tek-bg | --padding-x | --padding-y | --select-rect | --search | --view-offset)
            [ $# -ge 2 ] || { echo "ios-snapshot: $1 needs a value" >&2; exit 2; }
            PASSTHROUGH+=("$1" "$2"); shift 2 ;;
        --tek-glow | --clear-to-mark | --clear-preserve-input) PASSTHROUGH+=("$1"); shift ;;
        --scale) SCALE="${2:-}"; shift 2 ;;
        *) echo "ios-snapshot: unsupported argument: $1" >&2; exit 2 ;;
    esac
done

[ -x "$EXECUTABLE" ] || {
    echo "ios-snapshot: $EXECUTABLE is missing; build it with ./Scripts/build-ios.sh --sdk iphonesimulator" >&2
    exit 2
}
[ -n "$OUTPUT" ] && [ -f "$CONFIG" ] && [ -n "$ROWS" ] && [ -n "$COLUMNS" ] || {
    echo "ios-snapshot: snapshot, config, rows, and columns are required" >&2
    exit 2
}
[ -z "$FEED_FILE" ] || [ -f "$FEED_FILE" ] || {
    echo "ios-snapshot: feed file does not exist: $FEED_FILE" >&2
    exit 2
}

# A --feed value carries the registry's escapes and a --feed-file carries
# bytes; the app decodes the first through Core's own decoder, so this script
# holds no second grammar for what an escape means.
FEED_ESCAPED="--feed-is-escaped"
if [ -n "$FEED_FILE" ]; then
    FEED_ESCAPED=""
    FEED_BASE64="$(/usr/bin/python3 - "$FEED_FILE" <<'PY'
import base64
import sys
print(base64.b64encode(open(sys.argv[1], "rb").read()).decode("ascii"))
PY
)"
else
    FEED_BASE64="$(/usr/bin/python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode("utf-8")).decode("ascii"))' "$FEED")"
fi

ubq_ios_device_acquire ios-snapshot || exit 2
DEVICE="$UBQ_IOS_DEVICE"
xcrun simctl install "$DEVICE" "$APP" >/dev/null 2>&1
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
CONTAINER_OUTPUT="$CONTAINER/Documents/ubiquitty-ios-snapshot.png"
rm -f "$CONTAINER_OUTPUT"
# The case's configuration, inside the sandbox where the app can open it. The
# app parses it with Core's own reader, so this script names no setting: a flag
# per setting is a list that silently omits whatever was added last, and the
# omission is a picture rather than an error.
CONTAINER_CONFIG="$CONTAINER/Documents/ubiquitty-ios-snapshot.toml"
cp "$CONFIG" "$CONTAINER_CONFIG"

set +e
# The frame clock pinned at tick zero, where a fresh terminal's cursor is
# solid. Unpinned, the cursor's blink phases from the app's own launch, which
# on the simulator outlasts the post-activity hold, so each render caught the
# block at whatever point of its fade the launch happened to reach.
LAUNCH_OUTPUT="$(SIMCTL_CHILD_UBIQUITTY_FAKE_TICKS=0 xcrun simctl launch --console-pty --terminate-running-process \
    "$DEVICE" "$BUNDLE_ID" \
    --ios-snapshot \
    --rows "$ROWS" \
    --columns "$COLUMNS" \
    --feed-base64 "$FEED_BASE64" \
    $FEED_ESCAPED \
    $SIZED_TEXT \
    $UNFOCUSED \
    ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"} \
    --scale "${SCALE:-2}" \
    --config "$CONTAINER_CONFIG" 2>&1)"
LAUNCH_STATUS=$?
set -e
printf '%s\n' "$LAUNCH_OUTPUT"
if [ "$LAUNCH_STATUS" -ne 0 ] || ! grep -q -- 'ios-snapshot: -- PASS' <<<"$LAUNCH_OUTPUT"; then
    echo "ios-snapshot: simulator render failed" >&2
    exit 1
fi
[ -f "$CONTAINER_OUTPUT" ] || { echo "ios-snapshot: app wrote no PNG" >&2; exit 1; }
cp "$CONTAINER_OUTPUT" "$OUTPUT"
