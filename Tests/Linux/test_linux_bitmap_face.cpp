// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_linux_bitmap_face.cpp — the Linux frontend's embedded bitmap face
// (Platform/Linux/BitmapFace.h), built at the spacing its native face shares.
//
// The bitmap tier's goldens are shared by every arm, and the portable
// reference widens the bitmap cell by `font.character_spacing`. A Linux face
// built without the spacing draws the unspaced pitch against those goldens,
// and a GNU Unifont reader on Linux gets no spacing at all.

#include "Core/Rendering/RenderConfiguration.h"
#include "Platform/Linux/BitmapFace.h"
#include "Platform/Linux/FontSizing.h"

#include <optional>

using Ubiquitty::Linux::emplaceBitmapFace;
using Ubiquitty::Linux::FaceSpacing;
using Ubiquitty::Linux::faceSpacing;
using Ubiquitty::Rendering::UnifontRasterizer;

TEST(linuxBitmapFaceCarriesTheCharacterSpacing)
{
    Ubiquitty::Rendering::RenderConfiguration configuration {};
    configuration.characterSpacingPoints = 1.25;
    configuration.lineSpacingPoints = 2.0;

    constexpr int deviceScale = 2;
    const FaceSpacing spacing = faceSpacing(configuration, deviceScale);
    CHECK_EQ(spacing.characterSpacingInPixels, 3);
    CHECK_EQ(spacing.lineSpacingInPixels, 4);

    constexpr double sizePoints = 14.0;
    std::optional<UnifontRasterizer> face;
    emplaceBitmapFace(face, sizePoints, deviceScale, spacing);
    REQUIRE(face.has_value());
    const int scale = Ubiquitty::Rendering::unifontScaleForRequestedSize(sizePoints, deviceScale);
    const UnifontRasterizer unspaced(scale);
    CHECK_NEAR(face->cellMetrics().cellWidth, unspaced.cellMetrics().cellWidth + 3.0f, 0.001f);
    CHECK_NEAR(face->cellMetrics().cellHeight, unspaced.cellMetrics().cellHeight + 4.0f, 0.001f);

    // A rebuild takes the new spacing, which is what a `[font]` edit relies on.
    emplaceBitmapFace(face, sizePoints, deviceScale, { .lineSpacingInPixels = 0, .characterSpacingInPixels = -2 });
    CHECK_NEAR(face->cellMetrics().cellWidth, unspaced.cellMetrics().cellWidth - 2.0f, 0.001f);
    CHECK_NEAR(face->cellMetrics().cellHeight, unspaced.cellMetrics().cellHeight, 0.001f);
}

TEST(linuxBitmapFaceUsesTheFontDPIForSizeAndSpacing)
{
    Ubiquitty::Rendering::RenderConfiguration configuration {};
    configuration.characterSpacingPoints = 1.5;
    configuration.lineSpacingPoints = 2.25;
    const double pixelsPerPoint = Ubiquitty::Linux::fontPixelsPerPoint(96, 2);
    const FaceSpacing spacing = faceSpacing(configuration, pixelsPerPoint);
    CHECK_EQ(spacing.characterSpacingInPixels, 4);
    CHECK_EQ(spacing.lineSpacingInPixels, 6);
    std::optional<UnifontRasterizer> face;
    emplaceBitmapFace(face, 12, pixelsPerPoint, spacing);
    CHECK_EQ(face->cellMetrics().cellWidth, 20.0f);
    CHECK_EQ(face->cellMetrics().cellHeight, 38.0f);

    configuration.lineSpacingPoints = -1.0;
    CHECK_EQ(faceSpacing(configuration, 2).lineSpacingInPixels, -1);
}

UBIQUITTY_TEST_MAIN()
