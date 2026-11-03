#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# check-font-catalogue.sh — the Swift font catalogue answers Core correctly.
#
# The catalogue fills Rendering::Font::FontInventoryTable, a table of C function
# pointers Core's routing calls through. Everything about that arrangement
# compiles whether or not it is wired correctly: an entry pointing at the wrong
# member, a handle that does not survive a round trip, and a string_view over
# storage that has already died are all well-typed. So the seam is driven here
# rather than inspected.
#
# It runs outside the app because the catalogue needs no Metal device, no window
# and no terminal — CoreText and a header-only Core type are the whole
# dependency. A check that costs a second is one that runs; a check behind an app
# build is one that runs after the mistake has been committed.
#
# The cascade case is the one that cannot be arranged: Menlo carries no CJK, so
# an answer for U+4E2D has to come from the system's own fallback chain, and a
# catalogue whose cascade returned a fixed handle fails only this check.
#
# Its subject is the font seam, which is the half Core routes through.
# Rasterisation, atlas slots and the frame are outside it, so a green run here
# says nothing about them.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Build output lives outside the checkout; see Scripts/build-root.sh.
# shellcheck source=Scripts/build-root.sh
. "$ROOT/Scripts/build-root.sh"
cd "$ROOT"

SWIFT_DIRECTORY="$ROOT/Source/UbiquittyRenderKit"
OUT="${TMPDIR:-/tmp}/ubiquitty-font-catalogue-driver"

# The same interop flags the app's Swift compile uses. A driver built under
# different flags proves the catalogue works in a configuration nothing ships.
#
# One list, read by both passes below. A second spelling for the type-check pass
# would be a mirror of this one, and a mirror is what put seventeen source names
# against a directory of twenty-five.
SWIFT_ARGUMENTS=(
    -O -wmo -enforce-exclusivity=unchecked
    -module-name FontCatalogueDriver
    -package-name ubiquitty
    -cxx-interoperability-mode=default
    -Xcc -std=c++23
    -I"$SWIFT_DIRECTORY"
    -I"$ROOT/Source"
    -I"$ROOT/Source/Platform/Apple"
    -I"$ROOT/Source/Platform/macOS"
    -framework CoreText
    -framework CoreGraphics
    "$SWIFT_DIRECTORY/FontFaces.swift"
    "$SWIFT_DIRECTORY/ShippedResources.swift"
    "$SWIFT_DIRECTORY/FontCatalogue.swift"
    "$ROOT/Scripts/drive-font-catalogue.swift"
)

# shellcheck source=Scripts/swift-driver-typecheck.sh
source "$ROOT/Scripts/swift-driver-typecheck.sh"
swift_driver_typecheck_if_requested check-font-catalogue "${SWIFT_ARGUMENTS[@]}"

# FontFaces resolves the reader's features through Core's one grammar, so the
# driver links the portable Core archive the sibling drivers link — proving
# the faces against a parser nothing ships is what an inline stub would do.
CORE_BUILD="$UBQ_BUILD_ROOT/core"
if [[ ! -f "$CORE_BUILD/libubiquitty-core.a" ]]; then
    echo "check-font-catalogue: $CORE_BUILD/libubiquitty-core.a is missing." >&2
    echo "  Build it first: Scripts/build-core-snapshot.sh" >&2
    exit 2
fi
# shellcheck source=Scripts/build-provenance.sh
source "$ROOT/Scripts/build-provenance.sh"
build_provenance_require "$ROOT" "$CORE_BUILD" "check-font-catalogue" "Scripts/build-core-snapshot.sh"

xcrun swiftc "${SWIFT_ARGUMENTS[@]}" \
    "$CORE_BUILD/libubiquitty-core.a" \
    "$CORE_BUILD/libubiquitty-core-model.a" \
    -o "$OUT"

"$OUT" "$ROOT/Resources/fonts"
