// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The seam bench's two C++ arms, which SeamBench.swift times beside the Swift
// arms. The C++ arms are the floor every other call shape is measured against,
// so they stay C++; the harness around them is Swift.

#include <cstdint>

namespace CppSeam {

/// One arm's timed loop: the seconds it took and the checksum it folded.
struct ArmResult {
    double seconds;
    std::uint64_t checksum;
};

/// The floor: a direct call the compiler may inline.
///
/// - Parameters:
///   - cells: Keys per frame.
///   - reps: Frames.
/// - Returns: The loop's time and checksum; construction is outside the clock.
ArmResult runCppInline(int cells, int reps);

/// One indirect call per cell, through an abstract base.
///
/// - Parameters:
///   - cells: Keys per frame.
///   - reps: Frames.
/// - Returns: The loop's time and checksum; construction is outside the clock.
ArmResult runCppVirtual(int cells, int reps);

} // namespace CppSeam
