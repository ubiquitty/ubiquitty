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
# equivalents), otherwise the library this checkout carries, as library_kit_root
# and library_core_root name it. The app carries one Core: the one its Kit pins.

# library_kit_root <checkout> — the Kit a checkout of the app carries: its
# Libraries/ubiquitty-kit when that path exists, else the checkout itself, which
# then holds every repository. The submodule is chosen by existing and not by
# being populated, so an uninitialised one fails on the missing files instead of
# judging the app's tree as the library's.
library_kit_root() {
    if [ -e "$1/Libraries/ubiquitty-kit" ]; then
        printf '%s' "$1/Libraries/ubiquitty-kit"
    else
        printf '%s' "$1"
    fi
}

# library_core_root <checkout> — the Core a checkout of the app carries: the Kit
# submodule's own Libraries/ubiquitty-core when the checkout has that submodule,
# else the checkout itself. Chosen by the Kit submodule existing, for the reason
# library_kit_root gives.
library_core_root() {
    if [ -e "$1/Libraries/ubiquitty-kit" ]; then
        printf '%s' "$1/Libraries/ubiquitty-kit/Libraries/ubiquitty-core"
    else
        printf '%s' "$1"
    fi
}

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_ROOT="${UBQ_CORE_ROOT:-${UBIQUITTY_CORE_SOURCE_DIR:-$(library_core_root "$APP_ROOT")}}"
KIT_ROOT="${UBQ_KIT_ROOT:-${UBIQUITTY_KIT_SOURCE_DIR:-$(library_kit_root "$APP_ROOT")}}"

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
