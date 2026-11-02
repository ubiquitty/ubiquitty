#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# test-linux-build-prerequisites.sh — the prerequisite check names what is
# missing and accepts what is present, against a PATH it cannot see past.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/Scripts/check-linux-build-prerequisites.sh"
# Resolved before the fixture clobbers PATH, and resolved rather than spelled:
# /usr/bin/bash is a Linux path, and on macOS the interpreter is /bin/bash. Naming
# it made every run here exit 127, which the first assertion below could not tell
# apart from the check correctly refusing an empty PATH — so the case reported a
# pass without the check ever executing, then died silently on the next grep.
BASH_BINARY="$(command -v bash)"
if [ -z "$BASH_BINARY" ]; then
    echo "SKIP: no bash on PATH to run the check with" >&2
    exit 0
fi
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/ubiquitty-linux-prerequisites.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

# The check runs with the fixture as its whole PATH and the compiler CXX names,
# so nothing of the host's toolchain reaches it. What it printed lands in a
# file named after the case, which a failing assertion quotes back.
runCheck() {
    PATH="$FIXTURE" CXX="$1" "$BASH_BINARY" "$CHECK" >"$FIXTURE/$2.out" 2>&1
}
fail() {
    echo "FAIL: $1" >&2
    if [ -n "${2:-}" ]; then
        echo "  what the check printed:" >&2
        sed 's/^/    /' "$FIXTURE/$2.out" >&2
    fi
    exit 1
}
# Each assertion names itself. A bare `grep … >/dev/null` under `set -e` exits
# with no message, so a case that fails that way never says why.
expectPrinted() {
    grep -F "$2" "$FIXTURE/$1.out" >/dev/null || fail "$3" "$1"
}
installStub() {
    printf '%s\n' '#!/bin/sh' "$2" >"$FIXTURE/$1"
    chmod +x "$FIXTURE/$1"
}

# An absolute inherited compiler remains reachable with an empty PATH. Every
# control owns its compiler command so no host toolchain enters the fixture.
compiler=fixture-cxx

if runCheck "$compiler" empty; then
    fail "an empty PATH passed the Linux prerequisite check"
fi
expectPrinted empty "missing prerequisites: cmake pkg-config $compiler" "the check did not name the missing tools"
expectPrinted empty "Ubuntu 26.04 and newer: sudo apt install" "the check named no way to install what is missing"

for tool in cmake "$compiler" 'compiler with spaces'; do
    installStub "$tool" 'exit 0'
done
installStub pkg-config 'case "$1" in --exists) exit 0 ;; --atleast-version=*) [ -z "${FIXTURE_OLD_GTK:-}" ] ;; --modversion) echo 4.14.2 ;; *) exit 1 ;; esac'

# glslc compiles the renderer's shaders, and its absence is named unless the
# build asked for a binary that renders on the CPU only.
if runCheck "$compiler" glslc-missing; then
    fail "a PATH without glslc passed the prerequisite check"
fi
expectPrinted glslc-missing "missing prerequisites: glslc" "the check did not name the missing glslc"
expectPrinted glslc-missing "UBIQUITTY_LINUX_GPU_SHADERS=OFF" "the check did not name the CPU-only opt-out"
# Every spelling CMake reads as false asks for the CPU-only binary, and one it
# reads as true still needs glslc.
for off in OFF off 0 No false n Ignore NOTFOUND glslc-NOTFOUND; do
    UBIQUITTY_LINUX_GPU_SHADERS="$off" runCheck "$compiler" "cpu-only-$off" \
        || fail "UBIQUITTY_LINUX_GPU_SHADERS=$off was refused for want of glslc" "cpu-only-$off"
done
for on in ON on 1 yes TRUE; do
    if UBIQUITTY_LINUX_GPU_SHADERS="$on" runCheck "$compiler" "gpu-$on"; then
        fail "UBIQUITTY_LINUX_GPU_SHADERS=$on passed without glslc" "gpu-$on"
    fi
done
installStub glslc 'exit 0'

runCheck "$compiler" present || fail "the check refused a PATH where every prerequisite is present" present
# A GTK below the floor CMakeLists.txt asks for is present, and still refused.
if FIXTURE_OLD_GTK=1 runCheck "$compiler" old-gtk; then
    fail "GTK 4.14 passed the prerequisite check" old-gtk
fi
expectPrinted old-gtk "missing prerequisites: GTK 4.16 or newer (this is 4.14.2)" "the check did not name the GTK floor"
runCheck "$FIXTURE/compiler with spaces" spaced || fail "the check refused an existing absolute compiler path containing spaces" spaced
if runCheck "$FIXTURE/missing compiler" absolute-missing; then
    fail "a missing absolute compiler passed the prerequisite check"
fi
expectPrinted absolute-missing "missing prerequisites: $FIXTURE/missing compiler" "the check did not name the missing absolute compiler"

installStub compiler-without-headers 'exit 1'
if runCheck compiler-without-headers headers-missing; then
    fail "unavailable Vulkan headers passed the prerequisite check"
fi
expectPrinted headers-missing "missing prerequisites: Vulkan headers" "the check did not identify unavailable Vulkan headers"
echo "PASS: the Linux prerequisite check names what is missing and accepts what is present"
