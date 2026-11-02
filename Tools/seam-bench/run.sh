#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Build + run seam_bench: what one glyph-atlas seam crossing costs in C++,
# ordinary Swift, and annotated Swift.
#
#   ./run.sh [--cells N] [--reps N] [--trials N]
#   ./run.sh --disassemble          # also dump each arm's inner loop
#   ./run.sh --attribute            # rebuild the annotated arm under each flag
#                                   # subset, so the win is attributed and not
#                                   # argued
#
# macOS only: the Swift arms reach Core through the Apple module map.
#
# The harness (SeamBench.swift) is Swift and imports each arm as a module: the
# two Swift arms as Swift modules, the C++ arms (SeamCppArms.cpp) through this
# directory's module map.
#
# The two Swift arms are compiled as SEPARATE MODULES on purpose.
# `-enforce-exclusivity=unchecked` is a compilation-unit flag — no function can
# opt in or out of it — so the only way to have one arm with dynamic exclusivity
# checks and one without is to compile them apart. That constraint is part of
# what the bench reports: adopting the annotated arm's flag in the renderer
# would mean adopting it for every Swift file compiled beside it.
#
# Everything is built at -O -DNDEBUG. A Debug tree here would compare five arms
# at -O0, where the ARC and exclusivity calls the annotated arm exists to remove
# are all still present in the safe arm and unoptimised in every other.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/BuildSeamBench"
HERE="$ROOT/Tools/seam-bench"
SWIFT_MODULES="$ROOT/Source/Platform/Apple"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "seam-bench: macOS only (the Swift arms import Core through the Apple module map)" >&2
    exit 2
fi

disassemble=0
attribute=0
args=()
for a in "$@"; do
    case "$a" in
        --disassemble) disassemble=1 ;;
        --attribute) attribute=1 ;;
        *) args+=("$a") ;;
    esac
done

# The mangled names of the two Swift loops, which both the disassembly and the
# attribution sweep read. Spelled once: a rename that misses one of them would
# leave a check reporting on a symbol that no longer exists, and `objdump` says
# nothing about a symbol it cannot find.
SAFE_RUN='_$s8SeamSafe0bA0C3run4repss6UInt64Vs5Int32V_tF'
ANNOTATED_RUN='_$s13SeamAnnotated0bA0C3run4repss6UInt64Vs5Int32V_tF'

mkdir -p "$OUT"

# Shared by both Swift arms. -O and -wmo so the optimiser gets the same view of
# each arm it would get in a real build; without -wmo the safe arm's method call
# stays opaque and the comparison measures the build mode.
SWIFT_COMMON=(
    -O -wmo -parse-as-library -swift-version 6 -warnings-as-errors
    -cxx-interoperability-mode=default -Xcc -std=c++23
    "-I$SWIFT_MODULES" "-I$ROOT/Source" "-I$HERE" "-I$OUT"
)

# -emit-module is what lets the harness call these arms as ordinary Swift, each
# compiled under its own flags. SeamKeys.swift goes into both modules: one generator, so the two arms cannot
# drift apart, and no buffer pointer has to cross the boundary into the arm
# whose whole claim is that it contains no unsafe construct.
echo "seam-bench: compiling the safe Swift arm (every flag at its default)" >&2
xcrun swiftc "${SWIFT_COMMON[@]}" \
    -module-name SeamSafe -emit-module -emit-module-path "$OUT/SeamSafe.swiftmodule" \
    -c "$HERE/SeamSafe.swift" "$HERE/SeamKeys.swift" -o "$OUT/SeamSafe.o"

# -enforce-exclusivity=unchecked and not -Ounchecked: -Ounchecked IMPLIES the
# exclusivity relaxation, and this one leaves precondition and overflow traps
# in place. The sweep below builds the arm under both.
echo "seam-bench: compiling the annotated Swift arm (-enforce-exclusivity=unchecked)" >&2
xcrun swiftc "${SWIFT_COMMON[@]}" -enforce-exclusivity=unchecked \
    -module-name SeamAnnotated -emit-module -emit-module-path "$OUT/SeamAnnotated.swiftmodule" \
    -c "$HERE/SeamAnnotated.swift" "$HERE/SeamKeys.swift" -o "$OUT/SeamAnnotated.o"

echo "seam-bench: compiling the C++ arms" >&2
xcrun clang++ -std=c++23 -O2 -g -DNDEBUG -fno-exceptions -fno-rtti -Wall -Wextra -Werror \
    -I"$ROOT/Source" -I"$HERE" -c "$HERE/SeamCppArms.cpp" -o "$OUT/SeamCppArms.o"
xcrun clang++ -std=c++23 -O2 -g -DNDEBUG -fno-exceptions -fno-rtti \
    -I"$ROOT/Source" -c "$ROOT/Source/Core/Rendering/GlyphSlotCache.cpp" -o "$OUT/GlyphSlotCache.o"

# The harness drives the link, so the Swift runtime and its rpaths come in
# without being spelled out here.
linkHarness() {
    xcrun swiftc "${SWIFT_COMMON[@]}" -module-name SeamHarness "$HERE/SeamBench.swift" \
        "$OUT/SeamCppArms.o" "$OUT/GlyphSlotCache.o" "$OUT/SeamSafe.o" "$OUT/SeamAnnotated.o" \
        -o "$OUT/seam_bench"
}
echo "seam-bench: linking the Swift harness" >&2
linkHarness

if [ "$disassemble" = "1" ]; then
    echo >&2
    # Read the OBJECT files, not the linked binary. In the linked image a call
    # to a runtime entry point goes through a stub, and objdump prints that
    # stub's address against whatever symbol happens to precede it — every one
    # of these calls reads as `_swift_runtimeSupportsNoncopyableTypes+0x...`,
    # which names the wrong function with total confidence. The relocations in
    # the .o say who is actually being called.
    dumpArm() { # label, object, symbol
        echo "=== $1 ===" >&2
        objdump -dr --disassemble-symbols="$3" "$2" > "$OUT/$1.asm" 2>/dev/null || return 0
        printf '  %s instructions\n' "$(grep -cE '^[[:space:]]*[0-9a-f]+:' "$OUT/$1.asm")" >&2
        printf '  calls: %s\n' \
            "$(grep -oE '_swift_(retain|release|beginAccess|endAccess)|_ZN9Ubiquitty[A-Za-z0-9_]*' \
               "$OUT/$1.asm" | sort | uniq -c | tr -s ' ' | tr '\n' ' ')" >&2
    }
    for symbol in runCppInline runCppVirtual; do
        real=$(nm "$OUT/SeamCppArms.o" | awk -v s="$symbol" '$3 ~ s {print $3; exit}')
        [ -n "$real" ] && dumpArm "$symbol" "$OUT/SeamCppArms.o" "$real"
    done
    dumpArm swift_safe "$OUT/SeamSafe.o" "$SAFE_RUN"
    dumpArm swift_annotated "$OUT/SeamAnnotated.o" "$ANNOTATED_RUN"
    echo >&2
fi

if [ "$attribute" = "1" ]; then
    echo >&2
    echo "seam-bench: the annotated arm under each flag subset" >&2
    for flags in "" "-Ounchecked" "-enforce-exclusivity=unchecked" "-Ounchecked -enforce-exclusivity=unchecked"; do
        # shellcheck disable=SC2086
        xcrun swiftc "${SWIFT_COMMON[@]}" $flags -module-name SeamAnnotated \
            -emit-module -emit-module-path "$OUT/SeamAnnotated.swiftmodule" \
            -c "$HERE/SeamAnnotated.swift" "$HERE/SeamKeys.swift" -o "$OUT/SeamAnnotated.o" 2>/dev/null
        linkHarness 2>/dev/null
        guards=$(objdump -dr --disassemble-symbols="$ANNOTATED_RUN" "$OUT/SeamAnnotated.o" 2>/dev/null \
                 | grep -c 'swift_beginAccess' || true)
        printf '%-42s ' "${flags:-(neither)}" >&2
        "$OUT/seam_bench" --trials 5 --reps 300 2>/dev/null \
            | awk -v g="$guards" '/swift_annotated/ {printf "%8.3f ns  %+8s vs cpp   beginAccess in loop: %s\n", $2, $4, g}' >&2
    done
    echo >&2
    echo "seam-bench: rebuilding at the arm's own flags" >&2
    xcrun swiftc "${SWIFT_COMMON[@]}" -enforce-exclusivity=unchecked -module-name SeamAnnotated \
        -emit-module -emit-module-path "$OUT/SeamAnnotated.swiftmodule" \
        -c "$HERE/SeamAnnotated.swift" "$HERE/SeamKeys.swift" -o "$OUT/SeamAnnotated.o"
    linkHarness
    echo >&2
fi

# `${args[@]+...}` because bash 3.2 — the version macOS ships — treats an empty
# array as unset under `set -u`, so the plain expansion aborts the script on the
# no-argument invocation, which is the documented one.
exec "$OUT/seam_bench" ${args[@]+"${args[@]}"}
