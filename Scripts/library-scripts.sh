#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# library-scripts.sh — where the libraries an app script builds on are, for shell
# callers; Scripts/library_scripts.py answers the same for python callers.
#
# Sourced, not run, by a script of the app:
#
#     . "$(dirname "$0")/library-scripts.sh"
#     "$CORE_ROOT/Scripts/build-root.sh"
#
# Sets APP_ROOT, CORE_ROOT and KIT_ROOT. A root is the one a caller named
# (UBQ_CORE_ROOT, or UBIQUITTY_CORE_SOURCE_DIR as the build passes it, and the Kit's
# equivalents), otherwise Libraries/ubiquitty-core or Libraries/ubiquitty-kit under
# this checkout when that path exists, otherwise this checkout itself, so in a
# checkout holding every repository the three are one tree. The submodule is chosen
# by existing and not by being populated, so an uninitialised one fails on the
# missing files instead of judging the app's tree as the library's.

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_ROOT="${UBQ_CORE_ROOT:-${UBIQUITTY_CORE_SOURCE_DIR:-}}"
if [ -z "$CORE_ROOT" ]; then
    CORE_ROOT="$APP_ROOT"
    [ -e "$APP_ROOT/Libraries/ubiquitty-core" ] && CORE_ROOT="$APP_ROOT/Libraries/ubiquitty-core"
fi
KIT_ROOT="${UBQ_KIT_ROOT:-${UBIQUITTY_KIT_SOURCE_DIR:-}}"
if [ -z "$KIT_ROOT" ]; then
    KIT_ROOT="$APP_ROOT"
    [ -e "$APP_ROOT/Libraries/ubiquitty-kit" ] && KIT_ROOT="$APP_ROOT/Libraries/ubiquitty-kit"
fi

# locate_file <repository-relative path> — the path in the checkout that holds it:
# this one, then the Kit's, then Core's; this one's spelling when none does, so a
# missing file is reported where the app expects it.
locate_file() {
    local root
    for root in "$APP_ROOT" "$KIT_ROOT" "$CORE_ROOT"; do
        [ -e "$root/$1" ] && { printf '%s' "$root/$1"; return 0; }
    done
    printf '%s' "$APP_ROOT/$1"
}
