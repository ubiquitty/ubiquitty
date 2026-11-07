#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/library-scripts.sh
. "$ROOT/Scripts/library-scripts.sh"
RUN_REAL_GENERAL=0
if [[ "${1:-}" == "--real-general-pasteboard" && "$#" == 1 ]]; then
    RUN_REAL_GENERAL=1
elif [[ "$#" != 0 ]]; then
    echo "usage: $0 [--real-general-pasteboard]" >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo "ui_test_pasteboard_isolation: SKIP (requires AppKit)"
    exit 0
fi

ARTIFACTS="$(mktemp -d "${TMPDIR:-/tmp}/ubiquitty-pasteboard-isolation.XXXXXX")"
trap 'rm -rf "$ARTIFACTS"' EXIT
HELPER="$ROOT/Source/Platform/macOS/UITest/Swift/PasteboardIsolation.swift"
DRIVER="$ROOT/Tests/Platform/test_ui_pasteboard_isolation.swift"
WRITER="$(locate_file Source/Platform/macOS/App/TerminalView/SelectionPasteboard.swift)"
# The PAL clipboard seam, compiled in so the driver can call it by name: it is
# the one clipboard writer whose board is chosen inside it rather than passed
# to it, so isolation is the only thing keeping an OSC 52 payload off the
# operator's clipboard.
SEAM="$(locate_file Source/Platform/macOS/ClipboardPasteboard.swift)"

compile_driver() {
    xcrun swiftc -swift-version 6 -O -parse-as-library "$1" "$WRITER" "$SEAM" "$DRIVER" -o "$2"
}

compile_driver "$HELPER" "$ARTIFACTS/driver"
"$ARTIFACTS/driver" --ui-test
"$ARTIFACTS/driver" --ordinary
UBIQUITTY_DISPOSABLE_GUI_SESSION="ubiquitty-pasteboard-integration-v1" \
    "$ARTIFACTS/driver" --ui-test --ui-test-real-general-pasteboard --real-mode-control
for route in general named; do
    status=0
    if "$ARTIFACTS/driver" --ui-test "--disable-$route-route" >"$ARTIFACTS/$route.log" 2>&1; then
        echo "FAIL: disabled $route route escaped its negative control" >&2
        exit 1
    else
        status=$?
    fi
    if [[ "$status" != 1 ]] \
        || ! grep -F 'FAIL: negative route control detects sentinel access' "$ARTIFACTS/$route.log" >/dev/null \
        || ! grep -E '^clipboard isolation: [0-9]+ assertions, 2 failures$' "$ARTIFACTS/$route.log" >/dev/null; then
        cat "$ARTIFACTS/$route.log" >&2
        echo "FAIL: disabled $route route did not reach the safe sentinel control" >&2
        exit 1
    fi
    echo "clipboard isolation: disabled $route route rejected by safe sentinel control"
done

# Remove the second selector so refusal also proves the first was not installed.
python3 - "$HELPER" "$ARTIFACTS/MissingSelector.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
original = '("pasteboardWithName:", "uiTestPasteboardWithName:")'
assert source.count(original) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(original, '("missingIsolationSelector:", "uiTestPasteboardWithName:")'))
PY
compile_driver "$ARTIFACTS/MissingSelector.swift" "$ARTIFACTS/missing-selector"
"$ARTIFACTS/missing-selector" --ui-test --expect-install-refusal

status=0
if UBIQUITTY_DISPOSABLE_GUI_SESSION="" "$ARTIFACTS/driver" \
    --real-general-pasteboard --nonce refusal-control >"$ARTIFACTS/real-refusal.log" 2>&1; then
    echo "FAIL: real general-pasteboard integration ran without its disposable-session marker" >&2
    exit 1
else
    status=$?
fi
if [[ "$status" != 2 ]] \
    || ! grep -F 'REFUSED: real general-pasteboard integration requires a dedicated disposable GUI session' \
        "$ARTIFACTS/real-refusal.log" >/dev/null; then
    cat "$ARTIFACTS/real-refusal.log" >&2
    echo "FAIL: real general-pasteboard integration did not refuse an unmarked session" >&2
    exit 1
fi

if [[ "$RUN_REAL_GENERAL" == 1 ]]; then
    if [[ "${UBIQUITTY_DISPOSABLE_GUI_SESSION:-}" != "ubiquitty-pasteboard-integration-v1" ]]; then
        echo "REFUSED: --real-general-pasteboard requires UBIQUITTY_DISPOSABLE_GUI_SESSION=ubiquitty-pasteboard-integration-v1" >&2
        exit 2
    fi
    "$ARTIFACTS/driver" --real-general-pasteboard --nonce "$(uuidgen)"
else
    echo "real general-pasteboard integration: NOT RUN (requires --real-general-pasteboard in a marked disposable GUI session)"
fi
echo "ui_test_pasteboard_isolation: PASSED"
