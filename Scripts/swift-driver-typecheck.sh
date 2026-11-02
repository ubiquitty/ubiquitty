#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# swift-driver-typecheck.sh — the half of a renderer driver that needs no device.
#
# A driver's build pass links Core and the app's compiled shaders and draws, so
# it needs a Metal device. Type-checking needs no archive, no metallib and no
# device, and it is where both driver breaks landed: an access level that moved
# with the module boundary, and a protocol that grew members the stubs never
# followed. Compile errors sit upstream of every assertion.
#
# A driver calls this with the one argument list its build pass also reads, minus
# the archives and the output path. A second spelling would be a mirror of the
# build line.

# Type-checks and exits when the caller asked for that pass, and returns
# otherwise so the driver goes on to build and draw.
#
# $1 is the driver's own name, for the verdict line. The rest are swiftc
# arguments — flags and sources, in the order the build pass passes them.
swift_driver_typecheck_if_requested() {
    if [[ -z "${UBIQUITTY_DRIVER_TYPECHECK_ONLY:-}" ]]; then
        return 0
    fi
    local label="$1"
    shift
    xcrun swiftc -typecheck "$@"
    # The verdict names this pass: worded like the drawing driver's, it would let
    # a type-check stand in for a run that drew.
    echo "$label: ok (type-checked; nothing linked, nothing drawn)"
    exit 0
}
