#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# sign-sparkle.sh — code-sign the embedded Sparkle.framework's nested code,
# inner-to-outer, so the outer app signature can seal the bundle.
#
#   ./Scripts/sign-sparkle.sh <App.app> <identity> [extra codesign flags…]
#
# Sparkle ships nested executables (two XPC services, the Autoupdate helper, and
# Updater.app) that each need their own signature. `codesign --deep` would do it
# in the WRONG order and corrupt the XPC service signatures (Sparkle's docs are
# explicit about this), so we sign each component explicitly, innermost first,
# then the framework itself. The caller signs the app bundle afterwards.
#
# Extra flags are forwarded to every codesign call — release builds pass
# `--options runtime --timestamp` for a hardened, notarizable signature; the dev
# build passes nothing. No-op (success) when the app has no Sparkle.framework,
# so a Sparkle-less build can call it unconditionally.
#
set -euo pipefail

APP="${1:?usage: sign-sparkle.sh <App.app> <identity> [extra codesign flags…]}"
ID="${2:?missing signing identity}"
shift 2
EXTRA=("$@")

FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$FW" ]; then
    echo "sign-sparkle: no Sparkle.framework in $APP — nothing to sign."
    exit 0
fi

# Resolve the versioned dir via the Current symlink (it's "B" today, but don't
# hardcode it); fall back to the sole Versions/<Letter> dir.
V="$FW/Versions/Current"
if [ ! -d "$V" ]; then
    V="$(/bin/ls -d "$FW"/Versions/[A-Z] 2>/dev/null | head -1)"
fi

# bash 3.2 (stock macOS) errors on "${EXTRA[@]}" when the array is empty under
# `set -u`; the +-expansion guards that.
sign() { codesign --force --sign "$ID" ${EXTRA[@]+"${EXTRA[@]}"} "$1"; }

for nested in \
    "$V/XPCServices/Downloader.xpc" \
    "$V/XPCServices/Installer.xpc" \
    "$V/Autoupdate" \
    "$V/Updater.app"; do
    [ -e "$nested" ] || continue
    sign "$nested"
done
sign "$FW"

echo "sign-sparkle: signed Sparkle.framework nested code with \"$ID\""
