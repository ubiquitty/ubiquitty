#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# check-wscons-compiles.sh — type-check the Wscons frontend on a host that has
# no wscons.
#
# Source/Platform/Wscons is the one frontend tree no build arm reaches.
# UBIQUITTY_FRONTEND=Wscons refuses to configure off OpenBSD/NetBSD, and no other
# target lists a Wscons translation unit — checked against every compile database
# this tree generates. So its calls into portable Core are checked by nobody
# else, and they rot the way unbuilt calls do: a call whose header the file
# never includes, an argument of a type the signature no longer takes, a
# two-argument call to a function that has become one span.
#
# What makes the check possible is how small the platform surface is: one header
# no host has, <dev/wscons/wsconsio.h>, and nine symbols out of it. Tests/Stubs
# declares those, so everything else — every Core call, every signature — is
# checked against the real headers.
#
# -fsyntax-only, never a link. The stub's ioctl numbers are placeholders, so a
# binary built against it would talk to the kernel in a language the kernel does
# not speak. This answers "do the calls agree with Core", which is the question
# that went unanswered, and nothing about whether the frontend runs.
#
#   ./Scripts/check-wscons-compiles.sh
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

CXX="${CXX:-c++}"
# Through the launcher, as the compile-launcher gate requires: an uncached
# syntax-only sweep is a slower suite nobody attributes to a change. Unquoted, so
# an empty launcher contributes no argument.
launcher="${UBQ_COMPILER_LAUNCHER-}"
STUBS="Tests/Stubs"

if [ ! -f "$STUBS/dev/wscons/wsconsio.h" ]; then
    echo "check-wscons: FAIL - $STUBS/dev/wscons/wsconsio.h is missing, so nothing was checked" >&2
    exit 1
fi

sources=$(find Source/Platform/Wscons -name '*.cpp' | sort)
if [ -z "$sources" ]; then
    echo "check-wscons: FAIL - no translation units found under Source/Platform/Wscons" >&2
    exit 1
fi

failed=0
checked=0
for source in $sources; do
    if $launcher $CXX -std=c++23 -fsyntax-only \
            -I Source -I Source/ThirdParty/simdutf -I "$STUBS" \
            -fno-exceptions -fno-rtti \
            -Wall -Wextra -Wno-deprecated-declarations -Wno-multichar -Wno-comment \
            "$source" 2>&1; then
        checked=$((checked + 1))
    else
        echo "check-wscons: FAIL - $source" >&2
        failed=$((failed + 1))
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "check-wscons: $failed of $((checked + failed)) translation unit(s) do not type-check." >&2
    echo "  A stub member this frontend started using is a failure here too — add it to" >&2
    echo "  $STUBS/dev/wscons/wsconsio.h with the type the kernel header gives it." >&2
    exit 1
fi

echo "check-wscons: ok ($checked translation unit(s) type-check against real Core headers)"
