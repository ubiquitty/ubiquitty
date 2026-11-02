// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "Platform/Linux/FontSizing.h"

#include <limits>

using Ubiquitty::Linux::fontDPIFromSettings;
using Ubiquitty::Linux::fontPixelSize;
using Ubiquitty::Linux::fontPixelsPerPoint;

TEST(linuxFontsConvertPointsAtDisplayDPIAndBackingScale)
{
    CHECK_EQ(fontDPIFromSettings(-1), 96.0);
    CHECK_EQ(fontDPIFromSettings(0), 96.0);
    CHECK_EQ(fontDPIFromSettings(144 * 1024), 144.0);
    CHECK_EQ(fontPixelSize(12, 96, 1), 16);
    CHECK_EQ(fontPixelSize(12, 96, 2), 32);
    CHECK_EQ(fontPixelSize(12, 144, 1), 24);
    CHECK_EQ(fontPixelSize(12, 144, 2), 48);
    CHECK_EQ(fontPixelSize(12, 120, 2), 40);
}

TEST(linuxFontFractionsSurviveUntilDevicePixelRounding)
{
    CHECK_EQ(fontPixelSize(12.5, 96, 2), 33);
    CHECK_EQ(fontPixelSize(12.75, 96, 2), 34);
    CHECK_EQ(fontPixelSize(15.5, 72, 2), 31);
    CHECK_EQ(fontPixelSize(256, 768, 8), 4096);
    CHECK_EQ(fontPixelSize(12, std::numeric_limits<double>::quiet_NaN(), 1), 16);
    CHECK_NEAR(fontPixelsPerPoint(144, 2), 4.0, 0.0001);
}

UBIQUITTY_TEST_MAIN()
