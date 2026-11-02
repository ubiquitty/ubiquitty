// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The classify bench's C++ arm, which ClassifyBench.swift times beside the
// Swift arms. It is the floor the Swift arms are measured against, so it stays
// C++; the harness around it is Swift.

#include <cstdint>

namespace CppClassify {

/// Sums both row flags over a stream of code points, with the predicate
/// inlined into the loop.
///
/// - Parameters:
///   - codePoints: The stream, borrowed for the call.
///   - count: Code points in the stream.
/// - Returns: The flag count, so neither flag can be optimised away.
std::uint64_t run(const std::uint32_t* codePoints, long count);

} // namespace CppClassify
