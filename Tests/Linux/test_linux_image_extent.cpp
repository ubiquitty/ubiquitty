// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Core/GridBounds.h"
#include "Harness.h"
#include "Platform/Linux/ImageExtent.h"

#include <cstdint>

using Ubiquitty::Linux::ImageExtent;
using Ubiquitty::Linux::maxRenderTargetExtent;

namespace {

/// The most common desktop device: 16384 on every side.
constexpr ImageExtent commonDevice = maxRenderTargetExtent(16384, 16384, 16384, 16384, 16384);

} // namespace

TEST(aPageAsTallAsTheDeviceFitsAndOneRowMoreDoesNot)
{
    // Unifont's 16-pixel cell: the model's tallest page is exactly the limit.
    CHECK(commonDevice.containsGrid(80, Ubiquitty::maxRows, 8, 16));
    // A 17-pixel cell, an ordinary font at one device pixel per point: the
    // page DECSLPP can ask for is past the device's largest frame.
    CHECK(!commonDevice.containsGrid(80, Ubiquitty::maxRows, 8, 17));
    CHECK(commonDevice.containsGrid(80, 16384 / 17, 8, 17));
    CHECK(!commonDevice.containsGrid(80, 16384 / 17 + 1, 8, 17));
}

TEST(eachSideIsHeldToItsOwnLimit)
{
    constexpr ImageExtent wideDevice { 32768, 8192 };
    CHECK(wideDevice.containsGrid(1024, 64, 32, 128));
    CHECK(!wideDevice.containsGrid(1024, 65, 32, 128));
    CHECK(!wideDevice.containsGrid(1025, 64, 32, 128));
    CHECK(wideDevice.contains(32768, 8192));
    CHECK(!wideDevice.contains(32769, 1));
    CHECK(!wideDevice.contains(1, 8193));
}

TEST(aSideWhoseThirtyTwoBitProductWrapsIsStillRefused)
{
    constexpr ImageExtent unbounded { UINT32_MAX, UINT32_MAX };
    // The model's largest grid over the largest font's cell stays inside 32 bits.
    CHECK(unbounded.containsGrid(Ubiquitty::maxColumns, Ubiquitty::maxRows, 4096, 4096));
    // 65536 by 65536 is 2^32, which a 32-bit product wraps to zero: a side
    // that would then fit any device.
    CHECK(!unbounded.containsGrid(1 << 16, 1, 1 << 16, 1));
    CHECK(!unbounded.containsGrid(1, 1 << 16, 1, 1 << 16));
}

TEST(anEmptyGridOrCellHasNoFrameToFit)
{
    CHECK(!commonDevice.containsGrid(0, 24, 8, 16));
    CHECK(!commonDevice.containsGrid(80, 0, 8, 16));
    CHECK(!commonDevice.containsGrid(80, 24, 0, 16));
    CHECK(!commonDevice.containsGrid(80, 24, 8, -16));
    // An extent no device has answered for holds no grid at all.
    constexpr ImageExtent unanswered {};
    CHECK(!unanswered.containsGrid(1, 1, 1, 1));
}

TEST(aFramebufferOrViewportSmallerThanTheImageLimitNarrowsTheTarget)
{
    constexpr ImageExtent narrowFramebuffer = maxRenderTargetExtent(16384, 8192, 16384, 16384, 16384);
    CHECK_EQ(narrowFramebuffer.width, 8192u);
    CHECK_EQ(narrowFramebuffer.height, 16384u);
    constexpr ImageExtent shortViewport = maxRenderTargetExtent(16384, 16384, 16384, 16384, 4096);
    CHECK_EQ(shortViewport.width, 16384u);
    CHECK_EQ(shortViewport.height, 4096u);
    constexpr ImageExtent smallImages = maxRenderTargetExtent(4096, 16384, 16384, 32768, 32768);
    constexpr ImageExtent expected { 4096, 4096 };
    CHECK(smallImages == expected);
}

UBIQUITTY_TEST_MAIN()
