// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The seam bench's C++ arms. See SeamBench.swift for what the bench measures
// and why every arm must fold the same checksum.

#include "SeamCppArms.h"

#include "Core/Rendering/GlyphSlotCache.h"

#include <chrono>
#include <cstring>
#include <vector>

using Ubiquitty::Rendering::GlyphSlotCache;
using Ubiquitty::Rendering::GlyphSlotGeometry;
using Ubiquitty::Rendering::GlyphUV;

namespace {

// A mono atlas the size the macOS renderer builds: 128x128 slots.
constexpr int atlasColumns = 128;
constexpr int atlasCapacity = atlasColumns * 128;

GlyphSlotGeometry benchGeometry()
{
    GlyphSlotGeometry geometry {};
    geometry.columns = atlasColumns;
    geometry.slotWidthInPixels = 19;
    geometry.slotHeightInPixels = 34;
    geometry.glyphWidthInPixels = 17;
    geometry.glyphMarginInPixels.width = 1;
    geometry.glyphMarginInPixels.height = 1;
    return geometry;
}

// The keys one frame of ordinary terminal text asks for: a screen's worth of
// cells drawn from a small working set, which is what makes the cache a cache.
// A stream of distinct keys would measure eviction instead of the hit path the
// seam actually runs. SeamKeys.swift applies the same rule for the Swift arms;
// the checksum gate is what keeps the two from drifting apart unnoticed.
std::vector<std::uint32_t> buildKeyStream(int cellCount)
{
    static constexpr char alphabet[] = "The quick brown fox jumps over the lazy dog 0123456789 "
                                       "().,;:!?-_/\\[]{}<>=+*&^%$#@~`'\"|";
    constexpr int alphabetLength = static_cast<int>(sizeof alphabet - 1);
    std::vector<std::uint32_t> keys;
    keys.reserve(static_cast<std::size_t>(cellCount));
    // Four styles and four subpixel phases, folded the way monoGlyphKey folds
    // them, so the working set is a few hundred distinct keys rather than one
    // per character.
    for (int i = 0; i < cellCount; ++i) {
        const auto codePoint = static_cast<std::uint32_t>(alphabet[i % alphabetLength]);
        const auto face = static_cast<std::uint32_t>((i / 97) & 3);
        const auto phase = static_cast<std::uint32_t>(i & 3);
        keys.push_back((codePoint << 8) | (face << 4) | phase);
    }
    return keys;
}

// The seam's work, written once. Every arm reaches this same body; what
// differs is how the call gets here.
inline GlyphUV probe(GlyphSlotCache& cache, const GlyphSlotGeometry& geometry, std::uint32_t key)
{
    bool isFresh = false;
    const int slot = cache.slotForKey(key, &isFresh);
    if (slot < 0)
        return { 0.0f, 0.0f, 0.0f, 0.0f };
    return geometry.atlasRectForBuilder(slot, atlasCapacity);
}

inline std::uint64_t fold(std::uint64_t checksum, const GlyphUV& uv)
{
    std::uint32_t bits = 0;
    std::memcpy(&bits, &uv.minU, sizeof bits);
    checksum = checksum * 1099511628211ull + bits;
    std::memcpy(&bits, &uv.maxV, sizeof bits);
    return checksum * 1099511628211ull + bits;
}

using Clock = std::chrono::steady_clock;

double secondsSince(Clock::time_point start)
{
    return std::chrono::duration<double>(Clock::now() - start).count();
}

// One indirect call per cell: the abstract-base alternative to the table.
struct SeamInterface {
    virtual GlyphUV glyph(std::uint32_t key) = 0;
    virtual ~SeamInterface() = default;
};

struct CacheSeam final : SeamInterface {
    GlyphSlotCache cache { atlasCapacity, Ubiquitty::Rendering::recommendedHashBuckets(atlasCapacity), atlasColumns };
    GlyphSlotGeometry geometry = benchGeometry();
    GlyphUV glyph(std::uint32_t key) override { return probe(cache, geometry, key); }
};

} // namespace

namespace CppSeam {

// The floor. Nothing separates the loop from the probe, so the compiler sees
// the whole body and this is what any seam is measured against.
__attribute__((noinline)) ArmResult runCppInline(int cells, int reps)
{
    const std::vector<std::uint32_t> keys = buildKeyStream(cells);
    GlyphSlotCache cache(atlasCapacity, Ubiquitty::Rendering::recommendedHashBuckets(atlasCapacity), atlasColumns);
    const GlyphSlotGeometry geometry = benchGeometry();
    std::uint64_t checksum = 0;

    const auto start = Clock::now();
    for (int rep = 0; rep < reps; ++rep) {
        cache.beginFrame();
        for (int i = 0; i < cells; ++i)
            checksum = fold(checksum, probe(cache, geometry, keys[static_cast<std::size_t>(i)]));
    }
    return { secondsSince(start), checksum };
}

__attribute__((noinline)) ArmResult runCppVirtual(int cells, int reps)
{
    const std::vector<std::uint32_t> keys = buildKeyStream(cells);
    CacheSeam seam;
    SeamInterface& anonymous = seam;
    std::uint64_t checksum = 0;

    const auto start = Clock::now();
    for (int rep = 0; rep < reps; ++rep) {
        seam.cache.beginFrame();
        for (int i = 0; i < cells; ++i)
            checksum = fold(checksum, anonymous.glyph(keys[static_cast<std::size_t>(i)]));
    }
    return { secondsSince(start), checksum };
}

} // namespace CppSeam
