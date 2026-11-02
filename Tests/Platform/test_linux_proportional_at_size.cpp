// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// test_linux_proportional_at_size — a proportional run drawn past its size, at
// an OSC 66 scale or on a DECDHL pair, is the face rasterised at that size and
// not its own glyphs magnified.
//
// The reference for "at size" is a native render of the same face at the
// multiplied em: FreeType's own raster of the glyph at `s` times the pixel
// size. Each arm's scaled run is held to it within antialiasing tolerance,
// and the same comparison is made of the glyph at its own size magnified by
// nearest neighbour, so a tolerance that would let a stretch through fails the
// test's own control. The arms: the bitmap tier, whose proportional face is
// Noto Sans drawn from its strikes at 12 and 24 px and from its outlines at
// every other size, and the FreeType tier.
//
// The bitmap tier's monospace face, Unifont, has one design, 16 rows of
// pixels; past its size the only drawing true to it is whole-texel
// magnification, which is what a sized Unifont glyph gets, and is not what
// this test asks of the proportional face beside it.

#include "Harness.h"

#include "Core/Cell.h"
#include "Core/CellPen.h"
#include "Core/Rendering/ProportionalOutline.h"
#include "Core/Rendering/ProportionalStrike.h"
#include "Core/Rendering/SoftwareRenderer.h"
#include "Core/Rendering/UnifontRasterizer.h"
#include "Core/TermPalette.h"
#include "Core/TextSizeTable.h"
#include "Platform/Linux/FreeTypeRasterizer.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <span>
#include <string>
#include <vector>

using namespace Ubiquitty;
using namespace Ubiquitty::Rendering;

namespace {

std::string bundled(const char* file)
{
    return std::string(UBQ_BUNDLED_FONTS_DIR) + "/" + file;
}

// A coverage plane and the box its ink fills.
struct Plane {
    int width = 0;
    int height = 0;
    std::vector<std::uint8_t> coverage;
    int inkLeft = 0;
    int inkTop = 0;
    int inkRight = -1;
    int inkBottom = -1;

    void findInk()
    {
        inkLeft = width;
        inkTop = height;
        inkRight = -1;
        inkBottom = -1;
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                if (coverage[static_cast<std::size_t>(y) * width + x] < 8)
                    continue;
                inkLeft = std::min(inkLeft, x);
                inkTop = std::min(inkTop, y);
                inkRight = std::max(inkRight, x);
                inkBottom = std::max(inkBottom, y);
            }
        }
    }
    [[nodiscard]] int at(int x, int y) const
    {
        return x < 0 || y < 0 || x >= width || y >= height ? 0 : coverage[static_cast<std::size_t>(y) * width + x];
    }
};

// How far two pictures of one glyph are apart: the mean absolute coverage
// difference over the union of their inked boxes, aligned at the boxes' top
// left, in coverage levels of 255.
double meanDifference(const Plane& a, const Plane& b)
{
    const int width = std::max(a.inkRight - a.inkLeft, b.inkRight - b.inkLeft) + 1;
    const int height = std::max(a.inkBottom - a.inkTop, b.inkBottom - b.inkTop) + 1;
    if (width <= 0 || height <= 0)
        return 255.0;
    double total = 0.0;
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x)
            total += std::abs(a.at(a.inkLeft + x, a.inkTop + y) - b.at(b.inkLeft + x, b.inkTop + y));
    return total / (static_cast<double>(width) * height);
}

// FreeType's raster of `codePoint` in a Noto Sans file at `pixelSize`,
// unhinted or light-hinted, on a plane with its ink found.
Plane freeTypeGlyph(const char* file, std::uint32_t codePoint, int pixelSize, FT_Int32 hinting)
{
    Plane plane;
    FT_Library library = nullptr;
    FT_Face face = nullptr;
    if (FT_Init_FreeType(&library) != 0)
        return plane;
    if (FT_New_Face(library, bundled(file).c_str(), 0, &face) == 0 && FT_Set_Pixel_Sizes(face, 0, static_cast<FT_UInt>(pixelSize)) == 0
        && FT_Load_Char(face, codePoint, hinting) == 0 && FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) == 0) {
        const FT_Bitmap& bitmap = face->glyph->bitmap;
        plane.width = static_cast<int>(bitmap.width) + 4;
        plane.height = static_cast<int>(bitmap.rows) + 4;
        plane.coverage.assign(static_cast<std::size_t>(plane.width) * plane.height, 0);
        for (unsigned y = 0; y < bitmap.rows; ++y)
            for (unsigned x = 0; x < bitmap.width; ++x)
                plane.coverage[static_cast<std::size_t>(y + 2) * plane.width + x + 2] = bitmap.buffer[static_cast<long>(y) * bitmap.pitch + x];
    }
    if (face)
        FT_Done_Face(face);
    FT_Done_FreeType(library);
    plane.findInk();
    return plane;
}

// The glyph magnified `factor` times by nearest neighbour: what a renderer
// that stretches the glyph at its own size draws.
Plane magnified(const Plane& small, int factor)
{
    Plane plane;
    plane.width = small.width * factor;
    plane.height = small.height * factor;
    plane.coverage.assign(static_cast<std::size_t>(plane.width) * plane.height, 0);
    for (int y = 0; y < plane.height; ++y)
        for (int x = 0; x < plane.width; ++x)
            plane.coverage[static_cast<std::size_t>(y) * plane.width + x] = static_cast<std::uint8_t>(small.at(x / factor, y / factor));
    plane.findInk();
    return plane;
}

// The glyph magnified `factor` times by bilinear interpolation between its
// pixel centres: what a renderer that samples the glyph at its own size with
// a linear filter draws.
Plane bilinear(const Plane& small, int factor)
{
    Plane plane;
    plane.width = small.width * factor;
    plane.height = small.height * factor;
    plane.coverage.assign(static_cast<std::size_t>(plane.width) * plane.height, 0);
    for (int y = 0; y < plane.height; ++y) {
        for (int x = 0; x < plane.width; ++x) {
            const double sourceX = (x + 0.5) / factor - 0.5;
            const double sourceY = (y + 0.5) / factor - 0.5;
            const int left = static_cast<int>(std::floor(sourceX));
            const int top = static_cast<int>(std::floor(sourceY));
            const double fractionX = sourceX - left;
            const double fractionY = sourceY - top;
            const double value = (1 - fractionY) * ((1 - fractionX) * small.at(left, top) + fractionX * small.at(left + 1, top))
                + fractionY * ((1 - fractionX) * small.at(left, top + 1) + fractionX * small.at(left + 1, top + 1));
            plane.coverage[static_cast<std::size_t>(y) * plane.width + x] = static_cast<std::uint8_t>(std::lround(std::clamp(value, 0.0, 255.0)));
        }
    }
    plane.findInk();
    return plane;
}

// The run `text` at claim `cells` and OSC 66 scale `scale`, drawn by the
// portable renderer over `rasterizer` from the home cell, white on black;
// its green channel is the coverage, its ink found. A `scale` of zero draws
// the run on a DECDHL pair instead, both rows.
struct RunText {
    static inline std::vector<std::uint32_t> text;
    static int resolve(const Cell* cell, std::span<std::uint32_t> codePoints, void*)
    {
        if (!cell || cellPen(*cell).attributes.contains(VT::Attribute::WideContinuation) || codePoints.size() < text.size())
            return 0;
        std::copy(text.begin(), text.end(), codePoints.begin());
        return static_cast<int>(text.size());
    }
};

Plane renderRun(GlyphRasterizer& rasterizer, const std::u32string& text, int cells, int scale)
{
    RunText::text.assign(text.begin(), text.end());
    TermPalette palette;
    palette.seedDefaults();
    TextSizeTable table;
    TextSizeSpec spec {};
    spec.isProportional = 1;
    spec.scale = static_cast<std::uint8_t>(std::max(scale, 1));
    spec.runWidthCells = static_cast<std::uint16_t>(cells);
    const unsigned id = table.intern(spec);
    const bool isDoubleHeight = scale == 0;
    const int rows = isDoubleHeight ? 2 : std::max(scale, 1);
    const int claim = cells * (isDoubleHeight ? 1 : std::max(scale, 1));
    const int columns = claim + 2;
    std::vector<Cell> grid(static_cast<std::size_t>(rows) * columns, defaultBlankCell);
    for (Cell& cell : grid) {
        cell.pen.foregroundIndex = 15;
        cell.pen.backgroundIndex = 0;
    }
    for (int row = 0; row < rows; ++row) {
        for (int column = 0; column < claim; ++column) {
            Cell& cell = grid[static_cast<std::size_t>(row) * columns + column];
            cell.codePoint = column == 0 ? text.front() : wideContinuationSentinelCodePoint;
            Pen pen = cell.pen;
            pen.attributes.add(column == 0 ? VT::Attribute::Wide : VT::Attribute::WideContinuation);
            pen.extendedAttributes.setTextSizeSpecID(id);
            penSetTextBand(&pen, static_cast<std::uint8_t>(isDoubleHeight ? 0 : row));
            cellSetPen(cell, pen);
        }
        grid[static_cast<std::size_t>(row) * columns].setClusterID(1);
    }
    const std::vector<std::uint8_t> rowFlags(static_cast<std::size_t>(rows), static_cast<std::uint8_t>(RowFlag::Flowed));
    const std::uint8_t pairAttributes[2] = { lineAttributeDoubleHeightTop, lineAttributeDoubleHeightBottom };
    BuildInputs input;
    input.cells = grid.data();
    input.rows = rows;
    input.columns = columns;
    input.palette = &palette;
    input.textSizeTable = &table;
    input.rowFlags = rowFlags.data();
    input.lineAttributes = isDoubleHeight ? pairAttributes : nullptr;
    input.clusterResolver = &RunText::resolve;
    input.subpixelGlyphs = true;
    SoftwareRenderer renderer(rasterizer);
    std::vector<std::uint8_t> pixels;
    int width = 0;
    int height = 0;
    Plane plane;
    if (!renderer.render(input, pixels, width, height))
        return plane;
    plane.width = width;
    plane.height = height;
    plane.coverage.resize(static_cast<std::size_t>(width) * height);
    const int background = pixels[(static_cast<std::size_t>(height - 1) * width + width - 1) * 4 + 1];
    for (std::size_t index = 0; index < plane.coverage.size(); ++index)
        plane.coverage[index] = static_cast<std::uint8_t>(std::clamp(static_cast<int>(pixels[index * 4 + 1]) - background, 0, 255));
    plane.findInk();
    return plane;
}

// Holds `scaled` to the at-size reference within `tolerance` levels, and the
// glyph at its own size magnified to it beyond, so the tolerance is one a
// stretched run fails.
void checkAtSize(const Plane& scaled, const Plane& reference, const Plane& small, int factor, double tolerance, const std::string& label)
{
    REQUIRE_MSG(scaled.inkRight >= scaled.inkLeft, (label + ": the scaled run drew ink").c_str());
    REQUIRE_MSG(reference.inkRight >= reference.inkLeft, (label + ": the reference drew ink").c_str());
    const double atSize = meanDifference(scaled, reference);
    const double stretched = meanDifference(magnified(small, factor), reference);
    const double filtered = meanDifference(bilinear(small, factor), reference);
    std::printf("    %s: %.2f levels from the at-size reference; its own glyph magnified %.2f, filtered %.2f\n", label.c_str(), atSize, stretched, filtered);
    CHECK_MSG(atSize <= tolerance, (label + ": the scaled run is the face at size").c_str());
    CHECK_MSG(stretched > tolerance, (label + ": the control, its own glyph magnified, is not").c_str());
    CHECK_MSG(filtered > tolerance, (label + ": nor its own glyph magnified through a linear filter").c_str());
    CHECK_MSG(std::abs((scaled.inkRight - scaled.inkLeft) - (reference.inkRight - reference.inkLeft)) <= 1
            && std::abs((scaled.inkBottom - scaled.inkTop) - (reference.inkBottom - reference.inkTop)) <= 1,
        (label + ": its ink is the reference's size").c_str());
}

} // namespace

// The bitmap tier's outlines, drawn at a size, are FreeType's unhinted raster
// of the same outlines at that size, within the antialiasing of a pixel's
// edge; the 12 px strike magnified to the size is not.
TEST(theBitmapTiersOutlinesAreTheFaceRasterisedAtSize)
{
    for (const std::uint32_t codePoint : { U'o', U'g', U'W', U'e', U'S' }) {
        for (const int pixelSize : { 36, 48, 84 }) {
            Plane outline;
            outline.width = pixelSize * 2;
            outline.height = pixelSize * 2;
            outline.coverage.assign(static_cast<std::size_t>(outline.width) * outline.height, 0);
            CHECK(ProportionalOutline::rasterise(ProportionalStrike::Face::Regular, codePoint, pixelSize, 1.0, 8.0, pixelSize * 1.5,
                outline.width, outline.height, outline.coverage));
            outline.findInk();
            const Plane reference = freeTypeGlyph("NotoSans-Regular.ttf", codePoint, pixelSize, FT_LOAD_NO_HINTING);
            const Plane small = freeTypeGlyph("NotoSans-Regular.ttf", codePoint, 12, FT_LOAD_TARGET_LIGHT);
            checkAtSize(outline, reference, small, pixelSize / 12, 6.0, std::string("outline U+") + std::to_string(codePoint) + " at " + std::to_string(pixelSize) + " px");
        }
    }
}

// A run at scale 3 on the bitmap tier at scale 1, and on a DECDHL pair, is
// Noto Sans at 36 and 24 px: its letter is FreeType's at that size, not the
// 12 px strike's pixels tripled or doubled.
TEST(aBitmapTierRunAtAScaleIsTheProportionalFaceAtSize)
{
    UnifontRasterizer rasterizer(1);
    const Plane small = freeTypeGlyph("NotoSans-Regular.ttf", U'o', 12, FT_LOAD_TARGET_LIGHT);
    for (const int scale : { 3, 4 }) {
        const Plane scaled = renderRun(rasterizer, U"o", 2, scale);
        const Plane reference = freeTypeGlyph("NotoSans-Regular.ttf", U'o', 12 * scale, FT_LOAD_NO_HINTING);
        checkAtSize(scaled, reference, small, scale, 8.0, "bitmap tier s=" + std::to_string(scale));
    }
    const Plane pair = renderRun(rasterizer, U"o", 2, 0);
    const Plane pairReference = freeTypeGlyph("NotoSans-Regular.ttf", U'o', 24, FT_LOAD_TARGET_LIGHT);
    checkAtSize(pair, pairReference, small, 2, 8.0, "bitmap tier DECDHL");
}

// A run at a scale on the FreeType tier, and on a DECDHL pair, is the
// proportional face at the multiplied em: its letter is the letter the same
// rasterizer draws for a plain run at that pixel size.
TEST(aFreeTypeTierRunAtAScaleIsTheProportionalFaceAtSize)
{
    constexpr int pixelSize = 14;
    Linux::FreeTypeRasterizer base { pixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"), bundled("JetBrainsMono[wght].ttf") };
    REQUIRE(base.ready() && base.hasProportionalFace());
    const Plane small = renderRun(base, U"o", 2, 1);
    for (const int scale : { 2, 3 }) {
        Linux::FreeTypeRasterizer atSize { pixelSize * scale, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"), bundled("JetBrainsMono[wght].ttf") };
        REQUIRE(atSize.ready() && atSize.hasProportionalFace());
        const Plane scaled = renderRun(base, U"o", 2, scale);
        const Plane reference = renderRun(atSize, U"o", 2 * scale, 1);
        checkAtSize(scaled, reference, small, scale, 8.0, "FreeType tier s=" + std::to_string(scale));
        if (scale == 2) {
            const Plane pair = renderRun(base, U"o", 2, 0);
            checkAtSize(pair, reference, small, 2, 8.0, "FreeType tier DECDHL");
        }
    }
}

UBIQUITTY_TEST_MAIN()
