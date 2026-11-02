// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The classify bench's C++ arm: the two row predicates that shipped separately,
// fused into one branch on codePoint < 128.

#include "ClassifyCppArm.h"

#include "Core/Unicode/Joining.h"

namespace {

struct RowBits {
    bool needsShaping;
    bool mayLigate;
};

[[gnu::always_inline]] inline RowBits classifyCpp(std::uint32_t codePoint)
{
    constexpr std::uint64_t lowMask = 0xfc00ec6a00000000ull;
    constexpr std::uint64_t highMask = 0x50000000d0000001ull;
    if (codePoint < 128) {
        const std::uint64_t mask = codePoint < 64 ? lowMask : highMask;
        return { false, ((mask >> (codePoint & 63)) & 1u) != 0 };
    }
    return { Ubiquitty::Unicode::mayNeedShaping(codePoint), false };
}

} // namespace

namespace CppClassify {

std::uint64_t run(const std::uint32_t* codePoints, long count)
{
    std::uint64_t n = 0;
    for (long i = 0; i < count; ++i) {
        const RowBits bits = classifyCpp(codePoints[i]);
        n += (bits.needsShaping ? 1u : 0u) + (bits.mayLigate ? 1u : 0u);
    }
    return n;
}

} // namespace CppClassify
