// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_linux_color_glyph_painter — the COLRv1 paint-graph rasteriser.
//
// The extension arithmetic is pure and tested as such. Everything else needs a
// COLRv1 face, found through fontconfig the way the frontend finds it; where
// the host has none, the face cases say so rather than pass on nothing.
//
// Orientation is the assertion a colour count cannot make. The canvas is y up
// and FreeType's clip box is y up, and a painter that flipped one of them
// would still produce a saturated, plausible-looking blob — just upside down.
// The clip box of a face glyph is not symmetric about its baseline, so ink
// landing inside the box's rows is what shows the two orientations agree.

#include "Platform/Linux/ColorGlyphPainter.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_COLOR_H

namespace {

constexpr int facePixelSize = 32;
constexpr int canvasEdge = 40;
constexpr std::uint32_t grinningFace = 0x1F600;
// Drawn through a `PaintComposite` node in Noto Color Emoji, which the painter
// declines.
constexpr std::uint32_t laptop = 0x1F4BB;

/// A FreeType library and the first face fontconfig offers for `emoji` that
/// carries a COLRv1 paint graph for U+1F600, or null faces when there is none.
class ColorFaceFixture {
public:
    ColorFaceFixture()
    {
        if (FT_Init_FreeType(&m_library) != 0) {
            m_library = nullptr;
            return;
        }
        if (FcInit() != FcTrue)
            return;
        FcPattern* pattern = FcNameParse(reinterpret_cast<const unsigned char*>("emoji"));
        if (!pattern)
            return;
        FcConfigSubstitute(FcConfigGetCurrent(), pattern, FcMatchPattern);
        FcDefaultSubstitute(pattern);
        FcResult result = FcResultNoMatch;
        FcFontSet* candidates = FcFontSort(FcConfigGetCurrent(), pattern, FcTrue, nullptr, &result);
        FcPatternDestroy(pattern);
        if (!candidates)
            return;
        for (int i = 0; i < candidates->nfont && !m_face; ++i) {
            unsigned char* file = nullptr;
            if (FcPatternGetString(candidates->fonts[i], FC_FILE, 0, &file) != FcResultMatch || !file)
                continue;
            int index = 0;
            (void)FcPatternGetInteger(candidates->fonts[i], FC_INDEX, 0, &index);
            FT_Face face = nullptr;
            if (FT_New_Face(m_library, reinterpret_cast<const char*>(file), index, &face) != 0)
                continue;
            if (FT_Set_Pixel_Sizes(face, 0, facePixelSize) == 0
                && Ubiquitty::Linux::ColorGlyphPainter::hasPaintGraph(face, FT_Get_Char_Index(face, grinningFace))) {
                m_face = face;
                m_path = reinterpret_cast<const char*>(file);
            } else {
                FT_Done_Face(face);
            }
        }
        FcFontSetDestroy(candidates);
    }

    ~ColorFaceFixture()
    {
        if (m_face)
            FT_Done_Face(m_face);
        if (m_library)
            FT_Done_FreeType(m_library);
    }

    ColorFaceFixture(const ColorFaceFixture&) = delete;
    ColorFaceFixture& operator=(const ColorFaceFixture&) = delete;

    [[nodiscard]] FT_Face face() const { return m_face; }
    [[nodiscard]] const std::string& path() const { return m_path; }

private:
    FT_Library m_library = nullptr;
    FT_Face m_face = nullptr;
    std::string m_path;
};

/// How many canvas pixels carry colour rather than grey, read after
/// un-multiplying so a dim edge counts by its hue and not its alpha.
int saturatedPixels(const std::vector<std::uint8_t>& premultipliedBGRA)
{
    int saturated = 0;
    for (std::size_t i = 0; i + 3 < premultipliedBGRA.size(); i += 4) {
        const unsigned int alpha = premultipliedBGRA[i + 3];
        if (alpha < 16)
            continue;
        const unsigned int blue = premultipliedBGRA[i] * 255 / alpha;
        const unsigned int green = premultipliedBGRA[i + 1] * 255 / alpha;
        const unsigned int red = premultipliedBGRA[i + 2] * 255 / alpha;
        if (std::max({ red, green, blue }) - std::min({ red, green, blue }) > 40)
            ++saturated;
    }
    return saturated;
}

/// Whether every pixel is a valid premultiplied one: no channel above alpha.
bool isPremultiplied(const std::vector<std::uint8_t>& premultipliedBGRA)
{
    for (std::size_t i = 0; i + 3 < premultipliedBGRA.size(); i += 4) {
        const std::uint8_t alpha = premultipliedBGRA[i + 3];
        if (premultipliedBGRA[i] > alpha || premultipliedBGRA[i + 1] > alpha || premultipliedBGRA[i + 2] > alpha)
            return false;
    }
    return true;
}

} // namespace

TEST(padClampsRepeatWrapsAndReflectMirrors)
{
    using Ubiquitty::Linux::ColorLineExtend;
    using Ubiquitty::Linux::extendedColorLineParameter;

    CHECK(extendedColorLineParameter(-0.5, 0.0, 1.0, ColorLineExtend::Pad) == 0.0);
    CHECK(extendedColorLineParameter(1.5, 0.0, 1.0, ColorLineExtend::Pad) == 1.0);
    CHECK(extendedColorLineParameter(0.25, 0.0, 1.0, ColorLineExtend::Pad) == 0.25);

    CHECK(std::fabs(extendedColorLineParameter(1.25, 0.0, 1.0, ColorLineExtend::Repeat) - 0.25) < 1e-9);
    CHECK(std::fabs(extendedColorLineParameter(-0.25, 0.0, 1.0, ColorLineExtend::Repeat) - 0.75) < 1e-9);

    CHECK(std::fabs(extendedColorLineParameter(1.25, 0.0, 1.0, ColorLineExtend::Reflect) - 0.75) < 1e-9);
    CHECK(std::fabs(extendedColorLineParameter(2.25, 0.0, 1.0, ColorLineExtend::Reflect) - 0.25) < 1e-9);
    CHECK(std::fabs(extendedColorLineParameter(-0.25, 0.0, 1.0, ColorLineExtend::Reflect) - 0.25) < 1e-9);

    // A stop range that does not start at zero folds about its own ends.
    CHECK(std::fabs(extendedColorLineParameter(0.1, 0.2, 0.6, ColorLineExtend::Repeat) - 0.5) < 1e-9);

    // No range: every parameter is the one stop.
    CHECK(extendedColorLineParameter(7.0, 0.3, 0.3, ColorLineExtend::Repeat) == 0.3);
    CHECK(extendedColorLineParameter(7.0, 0.3, 0.3, ColorLineExtend::Reflect) == 0.3);
}

TEST(aCanvasOfTheWrongSizeIsRefusedBeforeTheFaceIsRead)
{
    Ubiquitty::Linux::ColorGlyphPainter painter;
    std::vector<std::uint8_t> tooSmall(static_cast<std::size_t>(canvasEdge) * canvasEdge * 4 - 4, 0);
    const auto result = painter.paint(nullptr, 0, {}, { tooSmall, canvasEdge, canvasEdge }, {});
    CHECK(!result.has_value());
    CHECK(result.error() == Ubiquitty::Linux::ColorGlyphPaintError::CanvasMismatch);

    std::vector<std::uint8_t> right(static_cast<std::size_t>(canvasEdge) * canvasEdge * 4, 0);
    const auto noFace = painter.paint(nullptr, 0, {}, { right, canvasEdge, canvasEdge }, {});
    CHECK(!noFace.has_value());
    CHECK(noFace.error() == Ubiquitty::Linux::ColorGlyphPaintError::NotAColorGlyph);
}

TEST(aGrinningFacePaintsSaturatedPremultipliedPixelsInsideItsClipBox)
{
    ColorFaceFixture fixture;
    if (!fixture.face()) {
        std::printf("    (no COLRv1 face on this system — this case is vacuous here)\n");
        return;
    }
    std::printf("    face: %s\n", fixture.path().c_str());
    FT_Face face = fixture.face();
    const FT_UInt glyph = FT_Get_Char_Index(face, grinningFace);

    // The clip box comes back in 26.6 at the face's size, y up from the
    // baseline. Placing the baseline so the box's bottom sits 2px above the
    // canvas edge pins where ink must land in canvas rows.
    FT_ClipBox clipBox;
    CHECK(FT_Get_Color_Glyph_ClipBox(face, glyph, &clipBox));
    const double boxLeft = clipBox.bottom_left.x / 64.0;
    const double boxBottom = clipBox.bottom_left.y / 64.0;
    const double boxRight = clipBox.top_right.x / 64.0;
    const double boxTop = clipBox.top_right.y / 64.0;
    CHECK(boxTop > boxBottom);
    // Asymmetric about the baseline, or a flip would land inside it too.
    CHECK(std::fabs(boxTop) - std::fabs(boxBottom) > 2.0);

    const double originX = 2.0 - boxLeft;
    const double originY = 2.0 - boxBottom;
    std::vector<std::uint8_t> canvas(static_cast<std::size_t>(canvasEdge) * canvasEdge * 4, 0);
    Ubiquitty::Linux::ColorGlyphPainter painter;
    const auto result = painter.paint(face, glyph, { 0xB4, 0xB4, 0xB4, 0xFF }, { canvas, canvasEdge, canvasEdge }, { originX, originY, 1.0 });
    CHECK(result.has_value());
    if (!result)
        return;

    const int saturated = saturatedPixels(canvas);
    std::printf("    U+1F600: %d saturated pixels of %d\n", saturated, canvasEdge * canvasEdge);
    CHECK(saturated > 100);
    CHECK(isPremultiplied(canvas));

    // Every inked pixel lies in the box: canvas row r spans y in
    // [edge - 1 - r, edge - r), y up. The box's own rows, with a pixel of
    // slack for anti-aliasing.
    const int topRow = static_cast<int>(std::floor(static_cast<double>(canvasEdge) - (originY + boxTop))) - 1;
    const int bottomRow = static_cast<int>(std::ceil(static_cast<double>(canvasEdge) - (originY + boxBottom)));
    const int leftColumn = static_cast<int>(std::floor(originX + boxLeft)) - 1;
    const int rightColumn = static_cast<int>(std::ceil(originX + boxRight));
    int inkOutside = 0;
    int inkInside = 0;
    for (int row = 0; row < canvasEdge; ++row) {
        for (int column = 0; column < canvasEdge; ++column) {
            const std::size_t index = (static_cast<std::size_t>(row) * canvasEdge + column) * 4;
            if (canvas[index + 3] < 16)
                continue;
            const bool isInside = row >= topRow && row <= bottomRow && column >= leftColumn && column <= rightColumn;
            if (isInside)
                ++inkInside;
            else
                ++inkOutside;
        }
    }
    CHECK(inkInside > 100);
    CHECK_MSG(inkOutside == 0, "ink outside the clip box means the canvas and the box disagree on orientation");

    // And the ink reaches the box's top half, so the assertion above is not
    // satisfied by a glyph drawn small enough to fit either way up.
    int inkAboveBaseline = 0;
    const int baselineRow = static_cast<int>(std::floor(static_cast<double>(canvasEdge) - originY));
    for (int row = 0; row < baselineRow; ++row) {
        for (int column = 0; column < canvasEdge; ++column) {
            if (canvas[(static_cast<std::size_t>(row) * canvasEdge + column) * 4 + 3] >= 16)
                ++inkAboveBaseline;
        }
    }
    CHECK(inkAboveBaseline > inkInside / 2);
}

TEST(aScaledPaintCoversProportionallyMoreOfTheCanvas)
{
    ColorFaceFixture fixture;
    if (!fixture.face())
        return;
    FT_Face face = fixture.face();
    const FT_UInt glyph = FT_Get_Char_Index(face, grinningFace);

    const auto inkAtScale = [&](double scale) {
        std::vector<std::uint8_t> canvas(static_cast<std::size_t>(canvasEdge) * canvasEdge * 4, 0);
        Ubiquitty::Linux::ColorGlyphPainter painter;
        const auto result = painter.paint(face, glyph, {}, { canvas, canvasEdge, canvasEdge }, { 2.0, 8.0, scale });
        CHECK(result.has_value());
        int ink = 0;
        for (std::size_t i = 3; i < canvas.size(); i += 4)
            ink += canvas[i] >= 16;
        return ink;
    };
    const int full = inkAtScale(1.0);
    const int half = inkAtScale(0.5);
    CHECK(half > 0);
    // Half the scale is a quarter of the area, within anti-aliasing.
    CHECK(half * 3 < full);
    CHECK(half * 6 > full);
}

TEST(aGraphWithANodeThePainterDoesNotDrawIsDeclinedWhole)
{
    ColorFaceFixture fixture;
    if (!fixture.face())
        return;
    FT_Face face = fixture.face();
    const FT_UInt glyph = FT_Get_Char_Index(face, laptop);
    if (glyph == 0 || !Ubiquitty::Linux::ColorGlyphPainter::hasPaintGraph(face, glyph)) {
        std::printf("    (this face has no colour U+1F4BB — the decline case is vacuous here)\n");
        return;
    }
    std::vector<std::uint8_t> canvas(static_cast<std::size_t>(canvasEdge) * canvasEdge * 4, 0);
    Ubiquitty::Linux::ColorGlyphPainter painter;
    const auto result = painter.paint(face, glyph, {}, { canvas, canvasEdge, canvasEdge }, { 4.0, 8.0, 1.0 });
    // Not asserted to fail: a face may draw a laptop without a composite. What
    // is asserted is that an answer is one of the two the caller can act on —
    // drawn in full, or declined — never a success on an empty canvas.
    if (result.has_value()) {
        int ink = 0;
        for (std::size_t i = 3; i < canvas.size(); i += 4)
            ink += canvas[i] >= 16;
        CHECK(ink > 0);
        std::printf("    U+1F4BB drew without an unsupported node on this face\n");
        return;
    }
    CHECK(result.error() == Ubiquitty::Linux::ColorGlyphPaintError::UnsupportedPaint);
    std::printf("    U+1F4BB declined: UnsupportedPaint\n");
}

TEST(aGlyphWithoutAPaintGraphIsNotAColorGlyph)
{
    ColorFaceFixture fixture;
    if (!fixture.face())
        return;
    FT_Face face = fixture.face();
    // .notdef carries no paint graph in any face.
    CHECK(!Ubiquitty::Linux::ColorGlyphPainter::hasPaintGraph(face, 0));
    std::vector<std::uint8_t> canvas(static_cast<std::size_t>(canvasEdge) * canvasEdge * 4, 0);
    Ubiquitty::Linux::ColorGlyphPainter painter;
    const auto result = painter.paint(face, 0, {}, { canvas, canvasEdge, canvasEdge }, {});
    CHECK(!result.has_value());
    CHECK(result.error() == Ubiquitty::Linux::ColorGlyphPaintError::NotAColorGlyph);
}

UBIQUITTY_TEST_MAIN()
