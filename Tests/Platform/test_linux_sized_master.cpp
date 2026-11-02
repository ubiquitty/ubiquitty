// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// test_linux_sized_master — a doubled row drawn by the software renderer over
// FreeType is the master Core selected, not the 1x raster stretched.
//
// The measure is a stem's weight: the coverage summed across one scanline
// through a vertical stroke. Stretching the 1x raster doubles it and blurs it
// across a resampled edge; a master drawn at the doubled width carries the 1x
// stem scaled by the stretch Core left after the width axis, and nothing else.

#include "Harness.h"

#include "Core/Cell.h"
#include "Core/Rendering/SizedMaster.h"
#include "Core/Rendering/SoftwareRenderer.h"
#include "Core/TermPalette.h"
#include "Platform/Linux/FreeTypeRasterizer.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace Ubiquitty;
using namespace Ubiquitty::Rendering;

namespace {

std::string bundled(const char* file)
{
    return std::string(UBQ_BUNDLED_FONTS_DIR) + "/" + file;
}

constexpr int fontPixelSize = 28;
constexpr int columns = 4;
constexpr int rows = 2;

// The stem weight, in pixels of full coverage, of the one glyph on `row`,
// along the scanline at the cell's vertical centre. The whole row is read, so
// a face that shapes the glyph into a neighbouring column still measures. Coverage is read back from the pixels as the distance
// of each pixel from the background toward the foreground.
double stemWeight(const std::vector<std::uint8_t>& pixels, int width, int cellHeight, int row)
{
    const int y = row * cellHeight + cellHeight / 2;
    const auto green = [&](int x) { return static_cast<int>(pixels[(static_cast<std::size_t>(y) * width + x) * 4 + 1]); };
    const int background = green(width - 1);
    double weight = 0.0;
    for (int x = 0; x < width; ++x)
        weight += std::abs(green(x) - background) / 255.0;
    return weight;
}

struct Rendered {
    std::vector<std::uint8_t> pixels;
    int width = 0;
    int height = 0;
    int cellWidth = 0;
    int cellHeight = 0;
};

// Row 0 holds `codePoint` on a DECDWL row; row 1 holds it on a plain row.
Rendered renderDoubledOverPlain(GlyphRasterizer& rasterizer, std::uint32_t codePoint)
{
    TermPalette palette;
    palette.seedDefaults();
    std::vector<Cell> grid(static_cast<std::size_t>(rows) * columns, defaultBlankCell);
    for (Cell& cell : grid) {
        cell.pen.foregroundIndex = 0;
        cell.pen.backgroundIndex = 15;
    }
    grid[0].codePoint = codePoint;
    grid[columns].codePoint = codePoint;
    const std::uint8_t lineAttributes[rows] = { lineAttributeDoubleWidth, lineAttributeNormal };
    BuildInputs input;
    input.cells = grid.data();
    input.rows = rows;
    input.columns = columns;
    input.palette = &palette;
    input.lineAttributes = lineAttributes;
    SoftwareRenderer renderer(rasterizer);
    Rendered out;
    out.cellWidth = cellDimension(rasterizer.cellMetrics().cellWidth);
    out.cellHeight = cellDimension(rasterizer.cellMetrics().cellHeight);
    CHECK(renderer.render(input, out.pixels, out.width, out.height));
    return out;
}

void checkStemScalesByTheRemainder(GlyphRasterizer& rasterizer, const char* label)
{
    SizedTile doubled { 1, 0, 0 };
    doubled.widthScale = 2;
    const SizedMaster master = selectSizedMaster(rasterizer, FontFace::Regular, doubled);
    const Rendered rendered = renderDoubledOverPlain(rasterizer, '|');
    REQUIRE(rendered.width >= columns * rendered.cellWidth && rendered.height >= rows * rendered.cellHeight);
    const double plain = stemWeight(rendered.pixels, rendered.width, rendered.cellHeight, 1);
    const double wide = stemWeight(rendered.pixels, rendered.width, rendered.cellHeight, 0);
    std::printf("    %s: 1x stem %.3f px, doubled %.3f px, remainder %.3f, ratio %.3f\n", label, plain, wide, master.horizontalScale, wide / plain);
    REQUIRE(plain > 0.5);
    // Hinting rounds each stem to the pixel grid on its own, so the two can
    // disagree by the antialiased fraction of one edge pixel, and no more.
    CHECK_MSG(std::abs(wide - plain * master.horizontalScale) <= 0.35,
        "the doubled stem is the 1x stem scaled by the stretch alone");
}

} // namespace

// JetBrains Mono has no width axis, so its doubled row is the face stretched
// across by the whole two, and the stem weighs twice the 1x stem.
TEST(testADoubledStemIsTheOneXStemTimesTheRemainderWithoutAnAxis)
{
    Linux::FreeTypeRasterizer rasterizer { fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf") };
    REQUIRE(rasterizer.ready());
    REQUIRE(!rasterizer.widthAxisRoom(FontFace::Regular).canWiden());
    checkStemScalesByTheRemainder(rasterizer, "JetBrains Mono");
}

// Monaspace Neon's width axis runs 100 to 125: the doubled row draws the face
// at 125 and stretches only the remaining 1.6, and the axis keeps its stems,
// so the doubled stem weighs 1.6 of the 1x one rather than two.
TEST(testADoubledStemIsTheOneXStemTimesTheRemainderAfterTheAxis)
{
    Linux::FreeTypeRasterizer rasterizer { fontPixelSize, "Monaspace Neon Var", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("MonaspaceNeonVar.ttf") };
    REQUIRE(rasterizer.ready());
    const WidthAxisRoom room = rasterizer.widthAxisRoom(FontFace::Regular);
    REQUIRE(room.canWiden());
    CHECK(std::abs(room.current - 100.0) < 1e-6);
    CHECK(std::abs(room.maximum - 125.0) < 1e-6);
    SizedTile doubled { 1, 0, 0 };
    doubled.widthScale = 2;
    const SizedMaster master = selectSizedMaster(rasterizer, FontFace::Regular, doubled);
    CHECK(std::abs(master.widthAxisCoordinate - 125.0) < 1e-6);
    CHECK_MSG(master.horizontalScale > 1.5 && master.horizontalScale < 1.75, "the axis carries a quarter of the doubling");
    checkStemScalesByTheRemainder(rasterizer, "Monaspace Neon Var");
}

namespace {

// The ink of a window, weighted by coverage: where, across the canvas, it stands.
double inkCentre(const std::vector<std::uint8_t>& window, int width, int height)
{
    double weight = 0.0;
    double moment = 0.0;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const double coverage = window[static_cast<std::size_t>(y) * width + x] / 255.0;
            weight += coverage;
            moment += coverage * (x + 0.5);
        }
    }
    return weight > 0.0 ? moment / weight : -1.0;
}

} // namespace

// The master is drawn where Core's placement says, at FreeType's own precision:
// a block anchored an eighth of a pixel further along draws its glyph an eighth
// of a pixel further along in the window, to the 64th FreeType moves an outline
// by, not to the whole pixel a cut alone could say. A box-drawing piece is the
// glyph that stands on the pen Core places.
TEST(testTheMasterStandsAtTheAnchorsSubpixelPen)
{
    Linux::FreeTypeRasterizer rasterizer { fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf") };
    REQUIRE(rasterizer.ready());
    const CellMetrics metrics = rasterizer.cellMetrics();
    constexpr int margin = 4;
    const int boxWidth = static_cast<int>(std::lround(metrics.cellWidth));
    const int boxHeight = static_cast<int>(std::lround(metrics.cellHeight));
    const SizedWindowCanvas canvas { boxWidth + 2 * margin, boxHeight + 2 * margin, margin, margin, 0.0f, 0.0f };
    std::vector<std::uint8_t> master;
    std::vector<std::uint8_t> window(static_cast<std::size_t>(canvas.width * canvas.height));
    SizedTile tile { 3, 1, 1 };
    double previous = 0.0;
    double first = 0.0;
    for (std::uint32_t phase = 0; phase < subpixelPhaseCount; ++phase) {
        REQUIRE(rasteriseSizedWindow(rasterizer, 0x2502, FontFace::Regular, 0, tile, phase, canvas, master, window));
        const double centre = inkCentre(window, canvas.width, canvas.height);
        REQUIRE(centre > 0.0);
        if (phase == 0)
            first = centre;
        const double moved = centre - first;
        const std::string where = "phase " + std::to_string(phase) + " moved the bar " + std::to_string(moved) + " pixels, not " + std::to_string(phase / 8.0);
        CHECK_MSG(std::fabs(moved - static_cast<double>(phase) / subpixelPhaseCount) < 0.1, where.c_str());
        CHECK(centre >= previous);
        previous = centre;
    }
}

// A letter is centred by its own ink, and takes the anchor's pen the same way:
// the fraction of Core's shift is moved into the outline, so the letter, like
// the box-drawing piece, moves an eighth of a pixel with each phase and not a
// whole pixel at the phase where the shift rounds over.
TEST(testALetterCentredByItsInkStandsAtTheAnchorsSubpixelPen)
{
    Linux::FreeTypeRasterizer rasterizer { fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf") };
    REQUIRE(rasterizer.ready());
    const CellMetrics metrics = rasterizer.cellMetrics();
    constexpr int margin = 4;
    const int boxWidth = static_cast<int>(std::lround(metrics.cellWidth));
    const int boxHeight = static_cast<int>(std::lround(metrics.cellHeight));
    const SizedWindowCanvas canvas { boxWidth + 2 * margin, boxHeight + 2 * margin, margin, margin, 0.0f, 0.0f };
    std::vector<std::uint8_t> master;
    std::vector<std::uint8_t> window(static_cast<std::size_t>(canvas.width * canvas.height));
    SizedTile tile { 3, 1, 1 };
    double first = 0.0;
    double worst = 0.0;
    for (std::uint32_t phase = 0; phase < subpixelPhaseCount; ++phase) {
        REQUIRE(rasteriseSizedWindow(rasterizer, 'I', FontFace::Regular, 0, tile, phase, canvas, master, window));
        const double centre = inkCentre(window, canvas.width, canvas.height);
        REQUIRE(centre > 0.0);
        if (phase == 0)
            first = centre;
        worst = std::max(worst, std::fabs(centre - first - static_cast<double>(phase) / subpixelPhaseCount));
    }
    const std::string where = "a letter strayed " + std::to_string(worst) + " pixels from the pen's phase";
    CHECK_MSG(worst < 0.1, where.c_str());
}

// A window that begins an advance along holds the block further left than one
// that begins a box along, and the glyph, centred in the extent the advances
// span, stands further left with it: the right end of a rule that runs the
// block's whole width lands where the block's geometry says, and not where a
// whole-box step would put it.
TEST(testWindowsStepByTheAdvanceOverFreeType)
{
    Linux::FreeTypeRasterizer rasterizer { fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf") };
    REQUIRE(rasterizer.ready());
    const CellMetrics metrics = rasterizer.cellMetrics();
    // A margin the rule's end stays inside, as the margin of a face with overhang is.
    constexpr int margin = 10;
    const int boxWidth = static_cast<int>(std::lround(metrics.cellWidth));
    const int boxHeight = static_cast<int>(std::lround(metrics.cellHeight));
    // Cells that advance a pixel less than the box: seven windows across, the
    // last begins six pixels before a whole-box step would put it, and the
    // glyph, centred in an extent seven pixels shorter, stands 3.5 further left.
    const float advance = static_cast<float>(boxWidth) - 1.0f;
    const SizedWindowCanvas stepped { boxWidth + 2 * margin, boxHeight + 2 * margin, margin, margin, 0.0f, advance };
    const SizedWindowCanvas boxed { boxWidth + 2 * margin, boxHeight + 2 * margin, margin, margin, 0.0f, 0.0f };
    std::vector<std::uint8_t> master;
    std::vector<std::uint8_t> window(static_cast<std::size_t>(stepped.width * stepped.height));
    const auto rightEnd = [&](const SizedWindowCanvas& canvas) -> int {
        SizedTile tile { 7, 3, 6 };
        if (!rasteriseSizedWindow(rasterizer, 0x2500, FontFace::Regular, 0, tile, 0, canvas, master, window))
            return -1;
        int end = -1;
        for (int y = 0; y < canvas.height; ++y) {
            for (int x = 0; x < canvas.width; ++x) {
                if (window[static_cast<std::size_t>(y) * canvas.width + x] >= 128)
                    end = std::max(end, x + 1);
            }
        }
        return end;
    };
    const int steppedEnd = rightEnd(stepped);
    const int boxedEnd = rightEnd(boxed);
    REQUIRE(steppedEnd > 0 && boxedEnd > 0);
    const std::string where = "the rule ends at " + std::to_string(steppedEnd) + " stepping by the advance and " + std::to_string(boxedEnd) + " by the box";
    CHECK_MSG(std::abs((steppedEnd - boxedEnd) - 2.5) <= 1.0, where.c_str());
}

UBIQUITTY_TEST_MAIN()
