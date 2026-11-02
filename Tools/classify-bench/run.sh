#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Build + run classify_bench: what BULK per-codepoint work costs in C++,
# ordinary Swift, and annotated Swift.
#
#   ./run.sh
#
# The companion to Tools/seam-bench, and it asks a different question.
# seam-bench times one seam CROSSING per item, so the call shape is the cost.
# This one puts the loop INSIDE each arm, so a crossing is amortised over
# millions of items instead of paid per item, and what is left is each
# compiler's code for the loop body. They measure different things, and
# reading either as "language X is slower" without naming the question is how
# a dispatch cost gets mistaken for a language cost.
#
# The workload is the fused row-flag predicate: one `codePoint < 128` branch
# answers both the ligature-operator and the may-need-shaping questions,
# because nothing below U+0590 shapes and nothing at or above 128 is an
# operator. It stands in for any bulk scalar pass over cells.
#
# macOS only: the harness reads the Darwin uptime clock.
#
# The harness (ClassifyBench.swift) is Swift and imports each arm as a module:
# the two Swift arms as Swift modules, the C++ arm (ClassifyCppArm.cpp) through
# this directory's module map.
#
# The two Swift arms are compiled as SEPARATE MODULES from one source, for the
# reason seam-bench states: `-enforce-exclusivity=unchecked` is a
# compilation-unit flag, so the only way to have one arm with dynamic
# exclusivity checks and one without is to compile them apart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/BuildClassifyBench"
HERE="$ROOT/Tools/classify-bench"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "classify-bench: macOS only (the harness reads the Darwin uptime clock)" >&2
    exit 2
fi

mkdir -p "$OUT"

SWIFT_COMMON=(
    -O -wmo -parse-as-library -swift-version 6 -warnings-as-errors
    -cxx-interoperability-mode=default -Xcc -std=c++23
    "-I$ROOT/Source" "-I$HERE" "-I$OUT"
)

xcrun swiftc "${SWIFT_COMMON[@]}" -module-name ClassifySafe \
    -emit-module -emit-module-path "$OUT/ClassifySafe.swiftmodule" \
    -c "$HERE/Classify.swift" -o "$OUT/ClassifySafe.o"
xcrun swiftc "${SWIFT_COMMON[@]}" -enforce-exclusivity=unchecked -module-name ClassifyFast \
    -emit-module -emit-module-path "$OUT/ClassifyFast.swiftmodule" \
    -c "$HERE/Classify.swift" -o "$OUT/ClassifyFast.o"

xcrun clang++ -std=c++23 -O2 -g -DNDEBUG -fno-exceptions -fno-rtti -Wall -Wextra -Werror \
    -I"$ROOT/Source" -I"$HERE" -c "$HERE/ClassifyCppArm.cpp" -o "$OUT/ClassifyCppArm.o"

xcrun swiftc "${SWIFT_COMMON[@]}" -module-name ClassifyHarness "$HERE/ClassifyBench.swift" \
    "$OUT/ClassifyCppArm.o" "$OUT/ClassifySafe.o" "$OUT/ClassifyFast.o" -o "$OUT/classify_bench"

# Repeated, because one run of each cannot tell a small difference between the
# arms from the machine: a single pass reads noise as signal.
RUNS="${RUNS:-7}"
for _ in $(seq 1 "$RUNS"); do
    "$OUT/classify_bench" | awk '/^(cpp_inline|swift_safe|swift_annotated)/ {print $1, $2}'
done | python3 "$HERE/summarise.py"
