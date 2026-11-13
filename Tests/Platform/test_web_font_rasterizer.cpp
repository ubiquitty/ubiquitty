// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_web_font_rasterizer.cpp — the browser rasterizer's mapping of its text
// engine's answers (Platform/Web/WebFontRasterizer.cpp), driven natively
// through the ForTest host seam: the constructor's metric mapping, the
// family routing the inventory probes feed, the draw-then-fallback ladder,
// the colour-cluster path, the scaled re-rasterization, and the run shaping
// the ligature sheet draws grid text with. The stand-in engine records what
// it was asked, so every assertion is about what this file itself sent across
// the seam or made of the reply — the drawing stays the browser's.

#include "Platform/Web/WebFontRasterizer.h"

#include "Core/Rendering/Font/FontRoute.h"
#include "Core/Rendering/FontMetrics.h"
#include "Core/Rendering/LigatureSheet.h"
#include "Core/Rendering/SizedMaster.h"
#include "Core/Rendering/UnifontRasterizer.h"

#include <array>
#include <cmath>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

using namespace Ubiquitty;
using Web::WebFontRasterizer;

namespace {

// The rasteriser under test configures no fallback families; the routing
// those would drive is the policy's own subject, tested against the policy.
const Ubiquitty::Rendering::Font::FontFallbackPreferences noPreferences
    = Ubiquitty::Rendering::Font::FontFallbackPreferences::none();

constexpr int enginePixelSize = 16;
constexpr std::uint8_t engineCoverageByte = 0xC8;
constexpr std::uint32_t glyphTheEngineLacks = 'B';

// What the stand-in engine was last asked, for assertions about the request.
struct EngineLog {
    std::string lastFamily;
    double lastPixelSize = 0;
    double lastHorizontalScale = 0;
    double lastBaseline = 0;
    int lastCSSWeight = 0;
    int lastIsItalic = 0;
    double lastPenX = 0;
    int lastIsTextPictograph = 0;
    int colorCalls = 0;
    int clusterCalls = 0;
    std::vector<std::uint32_t> lastDrawnCluster;
    int proportionalMeasureCalls = 0;
    int proportionalDrawCalls = 0;
    int lastProportionalCount = 0;
    double lastProportionalHorizontalScale = 0;
    std::vector<std::uint32_t> lastProbeCluster;
    Rendering::Font::Presentation lastProbePresentation = Rendering::Font::Presentation::Default;
    bool lastProbeRequiresOwnFace = false;
    std::vector<double> lastOffsetsX;
    std::vector<double> lastOffsetsY;
    int shapeRunCalls = 0;
    int lastBandHeight = 0;
    int drawShapedRunCalls = 0;
    std::vector<std::uint32_t> lastDrawnRun;
    std::vector<double> lastNaturalPensX;
    std::vector<double> lastPlacedPensX;
} engineLog;

int fakePrimaryFamily(char* familyOut, int capacity)
{
    const char family[] = "TestFace";
    const int length = static_cast<int>(sizeof(family) - 1);
    if (capacity <= length)
        return 0;
    std::memcpy(familyOut, family, sizeof(family));
    return length;
}

// A uniform face: every sampled character advances the same, which is what the
// engine a terminal wants answers.
int fakeMeasure(int pixelSize, int, int characterCount, double* advances, int* ascent, int* descent, int* xHeight)
{
    for (int i = 0; i < characterCount; ++i)
        advances[i] = static_cast<double>(pixelSize / 2);
    *ascent = pixelSize * 3 / 4;
    *descent = pixelSize / 4;
    *xHeight = pixelSize / 2;
    return 1;
}

// The face a browser substitutes when it does not have the family asked for: it
// reports success, and the only trace of the substitution is that the advances
// stop agreeing. Widths taken from Helvetica's printable-ASCII range.
int fakeProportionalMeasure(int pixelSize, int firstCharacter, int characterCount, double* advances, int* ascent, int* descent, int* xHeight)
{
    for (int i = 0; i < characterCount; ++i) {
        const int character = firstCharacter + i;
        const bool isNarrow = character == ' ' || character == 'i' || character == 'l' || character == '.';
        advances[i] = isNarrow ? static_cast<double>(pixelSize) * 0.19 : static_cast<double>(pixelSize) * 0.55;
    }
    *ascent = pixelSize * 3 / 4;
    *descent = pixelSize / 4;
    *xHeight = pixelSize / 2;
    return 1;
}

int fakeDrawGlyph(const char* family, int codePoint, double pixelSize, double horizontalScale, double, int cssWeight, int isItalic, double penX, double baseline, int slotWidth, int slotHeight, int isTextPictograph, std::uint8_t* coverageOut)
{
    engineLog.lastIsTextPictograph = isTextPictograph;
    engineLog.lastFamily = family;
    engineLog.lastPenX = penX;
    engineLog.lastPixelSize = pixelSize;
    engineLog.lastHorizontalScale = horizontalScale;
    engineLog.lastBaseline = baseline;
    engineLog.lastCSSWeight = cssWeight;
    engineLog.lastIsItalic = isItalic;
    if (static_cast<std::uint32_t>(codePoint) == glyphTheEngineLacks)
        return 0;
    std::memset(coverageOut, engineCoverageByte, static_cast<std::size_t>(slotWidth) * static_cast<std::size_t>(slotHeight));
    return 1;
}

int fakeDrawCluster(const char*, const std::uint32_t* codePoints, int count, int, int, int, int, int slotWidth, int slotHeight, int isTextPictograph, std::uint8_t* coverageOut)
{
    engineLog.lastIsTextPictograph = isTextPictograph;
    ++engineLog.clusterCalls;
    engineLog.lastDrawnCluster.assign(codePoints, codePoints + count);
    std::memset(coverageOut, engineCoverageByte, static_cast<std::size_t>(slotWidth) * static_cast<std::size_t>(slotHeight));
    return 1;
}

int fakeDrawColorCluster(const char* family, const std::uint32_t*, int, int slotInPixels, std::uint8_t* pixelsOut)
{
    engineLog.lastFamily = family;
    engineLog.colorCalls++;
    std::memset(pixelsOut, 0x77, static_cast<std::size_t>(slotInPixels) * static_cast<std::size_t>(slotInPixels) * 4);
    return 1;
}

// The probes: the engine's family exists and covers everything below the
// box-drawing block, so U+2500 routes missing and exercises the empty-family
// fallback while letters route to the primary.
int fakeProbeCoverage(const char*, int codePoint) { return codePoint < 0x2500 || (codePoint >= 0xFE70 && codePoint <= 0xFEFC) ? 1 : 0; }
int fakeFamilyIsPresent(const char*) { return 1; }

int fakeProbeCluster(const char* family, std::span<const std::uint32_t> codePoints, Rendering::Font::Presentation presentation, bool requireOwnFace) // bool-ok: Implements the browser probe's named-face coverage predicate.
{
    engineLog.lastProbeCluster.assign(codePoints.begin(), codePoints.end());
    engineLog.lastProbePresentation = presentation;
    engineLog.lastProbeRequiresOwnFace = requireOwnFace;
    if (codePoints.empty() || codePoints.front() == 0x2500) {
        return 0;
    }
    const bool isEmojiStack = std::string_view(family).find("Noto Color Emoji") != std::string_view::npos;
    return presentation == Rendering::Font::Presentation::Emoji ? isEmojiStack : !isEmojiStack;
}

// A proportional engine whose advances differ per code point. A stand-in that
// answered one width for every character would pass for a monospace face, and
// the placement under test would be indistinguishable from the grid's.
int fakeMeasureProportional(const char* family, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, double* advancesOut)
{
    engineLog.lastFamily = family;
    engineLog.lastPixelSize = pixelSize;
    engineLog.lastCSSWeight = cssWeight;
    engineLog.proportionalMeasureCalls++;
    for (int index = 0; index < count; ++index) {
        // 'i' narrow, 'W' wide, everything else in between — enough that a run
        // measured per code point and a run measured as a block differ.
        const std::uint32_t codePoint = codePoints[index];
        const double fraction = codePoint == 'i' ? 0.25 : (codePoint == 'W' ? 0.9 : 0.5);
        advancesOut[index] = static_cast<double>(pixelSize) * fraction;
    }
    return count;
}

int fakeDrawProportional(const char* family, const std::uint32_t*, const double* offsetsX, const double* offsetsY, int count, int pixelSize,
    double horizontalScale, int cssWeight, int baseline, int stripWidth, int stripHeight, std::uint8_t* coverageOut)
{
    engineLog.lastFamily = family;
    engineLog.lastPixelSize = pixelSize;
    engineLog.lastProportionalHorizontalScale = horizontalScale;
    engineLog.lastCSSWeight = cssWeight;
    engineLog.lastBaseline = baseline;
    engineLog.proportionalDrawCalls++;
    engineLog.lastProportionalCount = count;
    engineLog.lastOffsetsX.assign(offsetsX, offsetsX + count);
    engineLog.lastOffsetsY.assign(offsetsY, offsetsY + count);
    std::memset(coverageOut, engineCoverageByte, static_cast<std::size_t>(stripWidth) * static_cast<std::size_t>(stripHeight));
    return 1;
}

// The advance the stand-in engine shapes a run at, off the cell its metric
// probe reports: a run laid on the face's own advance drifts a quarter pixel a
// cell, so a draw that puts every glyph on its cell has to have been handed
// both pens. A sum of quarters is exact in binary, so the pens compare exactly.
constexpr double engineRunAdvance = 7.75;

// A face with one coding ligature, `=>`, drawn the way JetBrains Mono draws it:
// two contextual forms, one per cell, so the count and the clusters are the
// characters' and only the ink changed.
int fakeShapeRun(const char* family, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, int bandHeight, int baseline, double* advancesOut,
    std::uint8_t* contextualFormsOut)
{
    engineLog.lastFamily = family;
    engineLog.lastPixelSize = pixelSize;
    engineLog.lastCSSWeight = cssWeight;
    engineLog.lastBaseline = baseline;
    engineLog.lastBandHeight = bandHeight;
    engineLog.shapeRunCalls++;
    for (int index = 0; index < count; ++index) {
        advancesOut[index] = engineRunAdvance;
        contextualFormsOut[index] = 0;
    }
    for (int index = 0; index + 1 < count; ++index) {
        if (codePoints[index] == '=' && codePoints[index + 1] == '>') {
            contextualFormsOut[index] = 1;
            contextualFormsOut[index + 1] = 1;
        }
    }
    return count;
}

int fakeDrawShapedRun(const char* family, const std::uint32_t* codePoints, const double* naturalPensX, const double* placedPensX, int count, int pixelSize,
    int cssWeight, int baseline, int stripWidth, int stripHeight, std::uint8_t* coverageOut)
{
    engineLog.lastFamily = family;
    engineLog.lastPixelSize = pixelSize;
    engineLog.lastCSSWeight = cssWeight;
    engineLog.lastBaseline = baseline;
    engineLog.drawShapedRunCalls++;
    engineLog.lastDrawnRun.assign(codePoints, codePoints + count);
    engineLog.lastNaturalPensX.assign(naturalPensX, naturalPensX + count);
    engineLog.lastPlacedPensX.assign(placedPensX, placedPensX + count);
    std::memset(coverageOut, engineCoverageByte, static_cast<std::size_t>(stripWidth) * static_cast<std::size_t>(stripHeight));
    return 1;
}

void installFakeEngine()
{
    engineLog = {};
    Web::ForTest::WebFontHost host;
    host.primaryFamily = fakePrimaryFamily;
    host.measure = fakeMeasure;
    host.drawGlyph = fakeDrawGlyph;
    host.drawCluster = fakeDrawCluster;
    host.drawColorCluster = fakeDrawColorCluster;
    host.measureProportional = fakeMeasureProportional;
    host.drawProportional = fakeDrawProportional;
    host.shapeRun = fakeShapeRun;
    host.drawShapedRun = fakeDrawShapedRun;
    Web::ForTest::installWebFontHost(host);
    Web::ForTest::WebFontProbes probes;
    probes.probeCoverage = fakeProbeCoverage;
    probes.familyIsPresent = fakeFamilyIsPresent;
    probes.probeCluster = fakeProbeCluster;
    Web::ForTest::installWebFontProbes(probes);
}

} // namespace

TEST(testAbsentEngineFallsBackWholesale)
{
    // No hooks installed yet: the constructor measures nothing and adopts the
    // fallback's metrics, and every raster goes to the fallback.
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    CHECK(rasterizer.cellMetrics().cellWidth == fallback.cellMetrics().cellWidth);
    CHECK(rasterizer.cellMetrics().cellHeight == fallback.cellMetrics().cellHeight);
}

// Tracking widens the pitch by Core's rule and nothing else: the cell a
// tracked face reports is the untracked one plus the spacing, as on the
// FreeType and CoreText arms, so `font.character_spacing` lays the grid out
// the same way whichever face the page loaded.
TEST(testTrackingWidensThePitchByCoresRule)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer plain(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    WebFontRasterizer tracked(fallback, enginePixelSize, 0, 3, noPreferences, 1);
    CHECK(plain.isAvailable());
    CHECK(tracked.cellMetrics().cellWidth
        == static_cast<float>(Rendering::FontMetrics::trackedCellAdvance(plain.cellMetrics().cellWidth, 3)));
    CHECK(tracked.cellMetrics().cellHeight == plain.cellMetrics().cellHeight);
}

// Bold and italic reach the engine, because in a browser they reach it or they
// do not happen. `WebFontInventory` answers one family handle for every style,
// so the family string carries neither — a browser picks the member by CSS.
// This seam is the only place that names one.
//
// Asserted against the REGULAR draw rather than against a constant alone: the
// four faces sharing one family means every one of them produces a valid draw
// call with a plausible family, so "it drew" separates nothing. What separates
// them is that the request differs.
TEST(testBoldAndItalicFacesReachTheEngine)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(enginePixelSize) * enginePixelSize);
    const auto draw = [&](Rendering::FontFace face, std::uint32_t weight) {
        rasterizer.rasterizeGlyph('A', face, weight, enginePixelSize, enginePixelSize, coverage.data());
    };

    draw(Rendering::FontFace::Regular, 0);
    const int regularWeight = engineLog.lastCSSWeight;
    CHECK(regularWeight == 400);
    CHECK(engineLog.lastIsItalic == 0);

    // A bold face with no SGR weight asks for the face's own bold. The number is
    // Core's, so this pins the two arms agreeing rather than a literal here.
    draw(Rendering::FontFace::Bold, 0);
    CHECK(engineLog.lastCSSWeight == Rendering::Font::faceOwnBoldWeight);
    CHECK(engineLog.lastCSSWeight > regularWeight);
    CHECK(engineLog.lastIsItalic == 0);

    draw(Rendering::FontFace::Italic, 0);
    CHECK(engineLog.lastIsItalic == 1);
    CHECK(engineLog.lastCSSWeight == regularWeight);

    draw(Rendering::FontFace::BoldItalic, 0);
    CHECK(engineLog.lastIsItalic == 1);
    CHECK(engineLog.lastCSSWeight == Rendering::Font::faceOwnBoldWeight);

    // An SGR 1:n weight outranks the face, so a bold cell carrying one draws at
    // the requested coordinate rather than at bold. Without that ordering the
    // two would compound, or the explicit request would be dropped.
    draw(Rendering::FontFace::Bold, 2);
    CHECK(engineLog.lastCSSWeight == 300);
    draw(Rendering::FontFace::Regular, 7);
    CHECK(engineLog.lastCSSWeight == 800);
}

// `font.weight` and `font.bold_weight` reach the draw. The browser names the
// weight on the context and nothing else does, so a rasterizer that does not
// carry them draws every configured face at 400 and 700 whatever is written.
TEST(testConfiguredWeightsReachTheEngine)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1, std::string(), { .upright = 200, .bold = 600 });
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(enginePixelSize) * enginePixelSize);
    const auto draw = [&](Rendering::FontFace face, std::uint32_t weight) {
        rasterizer.rasterizeGlyph('A', face, weight, enginePixelSize, enginePixelSize, coverage.data());
        return engineLog.lastCSSWeight;
    };
    CHECK(draw(Rendering::FontFace::Regular, 0) == 200);
    CHECK(draw(Rendering::FontFace::Italic, 0) == 200);
    CHECK(draw(Rendering::FontFace::Bold, 0) == 600);
    CHECK(draw(Rendering::FontFace::BoldItalic, 0) == 600);
    // An SGR weight still outranks both settings.
    CHECK(draw(Rendering::FontFace::Bold, 3) == 400);
}

// A user `wght` reaches the third tier alone, the same ordering the Linux arm
// applies to the same setting. The two arms fold it in Core, so a disagreement
// here is one setting drawing two weights.
//
// The seam carries weight and slant and nothing else, because a canvas font
// shorthand has no font-variation-settings: every other tag is baked into the
// face the page registers, so this test is about `wght` by construction rather
// than by omission.
TEST(testAUserWeightAxisReachesTheUprightCellAlone)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1, "wght=250");
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(enginePixelSize) * enginePixelSize);
    const auto draw = [&](Rendering::FontFace face, std::uint32_t weight) {
        rasterizer.rasterizeGlyph('A', face, weight, enginePixelSize, enginePixelSize, coverage.data());
        return engineLog.lastCSSWeight;
    };

    // Tier 3: no SGR weight and an upright face, so the specification wins over
    // the 400 the fold would otherwise answer.
    CHECK(draw(Rendering::FontFace::Regular, 0) == 250);

    // Tier 2: the bold face takes the bold weight. A specification naming the
    // body weight would make bold equal to the body by construction, so it is
    // dropped rather than applied.
    CHECK(draw(Rendering::FontFace::Bold, 0) == Rendering::Font::faceOwnBoldWeight);

    // Tier 1: an SGR weight is the running program naming one run, and a
    // configured axis cannot outrank it.
    CHECK(draw(Rendering::FontFace::Regular, 7) == 800);
    CHECK(draw(Rendering::FontFace::Regular, 2) == 300);

    // The control: without a specification the same three calls answer the fold
    // alone, so the assertions above are about the specification arriving rather
    // than about the fold.
    WebFontRasterizer plain(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    plain.rasterizeGlyph('A', Rendering::FontFace::Regular, 0, enginePixelSize, enginePixelSize, coverage.data());
    CHECK(engineLog.lastCSSWeight == 400);
}

TEST(testAHeavyUserWeightAxisSetsTheDefaultBoldFloor)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(enginePixelSize) * enginePixelSize);
    for (const int configuredWeight : { 0, 900 }) {
        WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1, "wght=800", { .upright = configuredWeight });
        for (const auto face : { Rendering::FontFace::Regular, Rendering::FontFace::Italic, Rendering::FontFace::Bold, Rendering::FontFace::BoldItalic }) {
            rasterizer.rasterizeGlyph('A', face, 0, enginePixelSize, enginePixelSize, coverage.data());
            CHECK_EQ(engineLog.lastCSSWeight, 800);
            rasterizer.rasterizeGlyph('A', face, 2, enginePixelSize, enginePixelSize, coverage.data());
            CHECK_EQ(engineLog.lastCSSWeight, 300);
        }
    }

    WebFontRasterizer explicitBold(fallback, enginePixelSize, 0, 0, noPreferences, 1, "wght=800", { .bold = 600 });
    explicitBold.rasterizeGlyph('A', Rendering::FontFace::Regular, 0, enginePixelSize, enginePixelSize, coverage.data());
    CHECK_EQ(engineLog.lastCSSWeight, 800);
    explicitBold.rasterizeGlyph('A', Rendering::FontFace::Bold, 0, enginePixelSize, enginePixelSize, coverage.data());
    CHECK_EQ(engineLog.lastCSSWeight, 600);
}

TEST(testUserWeightAxesClampToTheBrowserRange)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(enginePixelSize) * enginePixelSize);
    for (const auto* variation : { "wght=0", "wght=-100" }) {
        WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1, variation);
        rasterizer.rasterizeGlyph('A', Rendering::FontFace::Regular, 0, enginePixelSize, enginePixelSize, coverage.data());
        CHECK_EQ(engineLog.lastCSSWeight, 1);
        rasterizer.rasterizeGlyph('A', Rendering::FontFace::Bold, 0, enginePixelSize, enginePixelSize, coverage.data());
        CHECK_EQ(engineLog.lastCSSWeight, 700);
    }
    WebFontRasterizer heavy(fallback, enginePixelSize, 0, 0, noPreferences, 1, "wght=100000");
    for (const auto face : { Rendering::FontFace::Regular, Rendering::FontFace::Bold }) {
        heavy.rasterizeGlyph('A', face, 0, enginePixelSize, enginePixelSize, coverage.data());
        CHECK_EQ(engineLog.lastCSSWeight, 1000);
    }
}

TEST(testMetricsMapTheEngineReport)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 2);

    // advance -> cell width; ascent+descent -> cell height through the shared
    // cellLayout; the rule lift is the documented pixelSize/24.
    const Rendering::CellMetrics metrics = rasterizer.cellMetrics();
    CHECK(metrics.cellWidth == static_cast<float>(enginePixelSize / 2));
    CHECK(metrics.cellHeight >= static_cast<float>(enginePixelSize));
    CHECK(metrics.baselineFromTop > 0.0f && metrics.baselineFromTop < metrics.cellHeight);
    CHECK(metrics.underlineThickness > 0.0f);
    CHECK(metrics.underlineStrokeLift == static_cast<float>(enginePixelSize) / 24.0f);
    CHECK(rasterizer.faceMetrics().fontSize == enginePixelSize);
    CHECK(rasterizer.faceMetrics().ascent == static_cast<float>(enginePixelSize * 3 / 4));
}

// A proportional face the host really has is MEASURED, not refused: the grid
// gives every column the widest advance, which is the only thing a grid can do
// with unequal ones, and nothing overlaps.
//
// Whether a face is even and whether the host has it are separate questions,
// and only the second is a fault. An availability rule that reads unevenness as
// substitution answers the first while claiming the second, so it refuses a
// face the user chose.
TEST(testProportionalFaceIsMeasuredNotRefused)
{
    installFakeEngine();
    Web::ForTest::WebFontHost proportional;
    proportional.primaryFamily = fakePrimaryFamily;
    proportional.measure = fakeProportionalMeasure;
    proportional.drawGlyph = fakeDrawGlyph;
    Web::ForTest::installWebFontHost(proportional);

    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    CHECK_MSG(rasterizer.isAvailable(), "a face the host really has is usable however uneven it is");
    // The widest sampled advance, not the narrowest and not 'M': a cell cut to
    // anything less is a cell some glyph paints out of.
    const auto expected = static_cast<float>(std::lround(static_cast<double>(enginePixelSize) * 0.55));
    CHECK_MSG(rasterizer.cellMetrics().cellWidth == expected, "the cell is as wide as the face's widest column");
}

// A proportional primary's glyphs are drawn at the slot's edge: the row's
// layout places each letter on screen (LetterLayout.h), so the raster keeps
// the face's own bearings, as an even face's does. The layout's shaper
// answers each letter's advance in the primary family at the pen's weight.
TEST(testProportionalPrimaryKeepsItsPlacementAndShapesItsLetters)
{
    installFakeEngine();
    Web::ForTest::WebFontHost proportional;
    proportional.primaryFamily = fakePrimaryFamily;
    proportional.measure = fakeProportionalMeasure;
    proportional.drawGlyph = fakeDrawGlyph;
    proportional.measureProportional = fakeMeasureProportional;
    Web::ForTest::installWebFontHost(proportional);
    Rendering::UnifontRasterizer fallback;
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(enginePixelSize) * enginePixelSize);
    {
        WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
        CHECK_MSG(rasterizer.primaryFacePitch() == Rendering::FontMetrics::FacePitch::Proportional, "uneven advances are a proportional face");
        CHECK(rasterizer.rasterizeGlyph('i', Rendering::FontFace::Regular, 0, enginePixelSize, enginePixelSize, coverage.data()));
        CHECK_MSG(engineLog.lastPenX == 0.0, "a narrow glyph is drawn at the slot's edge; the layout places it");
        CHECK(rasterizer.rasterizeGlyph('W', Rendering::FontFace::Regular, 0, enginePixelSize, enginePixelSize, coverage.data()));
        CHECK_MSG(engineLog.lastPenX == 0.0, "so is a wide one");
        const std::uint32_t text[] = { 'W', 'i', 'x' };
        std::array<Ubiquitty::ProportionalShapedGlyph, 7> shaped {};
        CHECK_EQ(rasterizer.shapePrimaryRun(text, Rendering::FontFace::Bold, 0, shaped), 3);
        CHECK_MSG(engineLog.lastFamily == "TestFace", "the run is measured in the primary family");
        CHECK_MSG(engineLog.lastCSSWeight == 700, "at the pen's weight");
        CHECK_MSG(shaped[0].advanceInPixels == static_cast<float>(enginePixelSize) * 0.9f, "W advances as the face measures it");
        CHECK_MSG(shaped[1].advanceInPixels == static_cast<float>(enginePixelSize) * 0.25f, "and i as it does");
        CHECK_MSG(shaped[2].cluster == 2, "each glyph names its letter");
    }
    installFakeEngine();
    WebFontRasterizer even(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    CHECK(even.rasterizeGlyph('i', Rendering::FontFace::Regular, 0, enginePixelSize, enginePixelSize, coverage.data()));
    CHECK_MSG(engineLog.lastPenX == 0.0, "an even face keeps its own placement");
    CHECK_MSG(even.primaryFacePitch() == Rendering::FontMetrics::FacePitch::Fixed, "and is fixed pitch");
}

// The other half of that pair: the host has no such family, so the inventory
// declines to resolve it and the fallback keeps the cell.
//
// A browser reports a successful measurement either way — it substitutes its
// default and measures that — so the measurement cannot carry this verdict and
// something else has to. Without it the terminal lays out against a face nobody
// selected, at metrics that look perfectly reasonable.
TEST(testSubstitutedFamilyFallsBack)
{
    installFakeEngine();
    Web::ForTest::WebFontProbes absent;
    absent.probeCoverage = fakeProbeCoverage;
    absent.familyIsPresent = [](const char*) { return 0; };
    Web::ForTest::installWebFontProbes(absent);

    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    CHECK_MSG(!rasterizer.isAvailable(), "a family the host does not have is not a face to lay out against");
    CHECK_MSG(rasterizer.cellMetrics().cellWidth == fallback.cellMetrics().cellWidth,
        "the substituted face leaves the fallback's cell standing");
}

TEST(testDrawLadderPerGlyph)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    std::vector<std::uint8_t> coverage(64 * 64);

    // A glyph the engine has: drawn by the engine, through the routed family,
    // at the metrics' baseline clamped into the slot.
    CHECK(rasterizer.rasterizeGlyph('A', Rendering::FontFace::Regular, 400, 16, 32, coverage.data()));
    CHECK(coverage[0] == engineCoverageByte);
    CHECK(engineLog.lastFamily == "TestFace");
    CHECK(engineLog.lastPixelSize == enginePixelSize);
    CHECK(engineLog.lastBaseline <= 32);

    // A glyph the engine's face lacks: the engine is asked, declines, and the
    // fallback draws — coverage is Unifont's ink, not the engine's fill.
    std::fill(coverage.begin(), coverage.end(), 0);
    CHECK(rasterizer.rasterizeGlyph(glyphTheEngineLacks, Rendering::FontFace::Regular, 400, 16, 32, coverage.data()));
    bool sawEngineFill = true;
    for (std::size_t index = 0; index < 16 * 32; ++index)
        sawEngineFill = sawEngineFill && coverage[index] == engineCoverageByte;
    CHECK(!sawEngineFill);

    // A code point the probes place outside every family: the route comes back
    // missing and the fallback draws without the engine being asked.
    engineLog.lastFamily.clear();
    CHECK(rasterizer.rasterizeGlyph(0x2500, Rendering::FontFace::Regular, 400, 16, 32, coverage.data()));
    CHECK(engineLog.lastFamily.empty());

    // The style reaches the router: bold and italic faces route too.
    CHECK(rasterizer.rasterizeGlyph('A', Rendering::FontFace::Bold, 700, 16, 32, coverage.data()));
    CHECK(rasterizer.rasterizeGlyph('A', Rendering::FontFace::Italic, 400, 16, 32, coverage.data()));
    CHECK(rasterizer.rasterizeGlyph('A', Rendering::FontFace::BoldItalic, 700, 16, 32, coverage.data()));
}

TEST(testColorClusterPath)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    std::vector<std::uint8_t> pixels(64 * 64 * 4);

    // An emoji cluster routes through the emoji stack and reaches the colour
    // draw; VS16 forces the colour presentation on a text-default lead.
    const std::uint32_t emoji[] = { 0x1F600 };
    engineLog.colorCalls = 0;
    CHECK(rasterizer.rasterizeColorCluster(emoji, 1, 32, pixels.data()));
    CHECK(engineLog.colorCalls == 1);
    CHECK(pixels[0] == 0x77);

    const std::uint32_t forcedColor[] = { 0x26A0, 0xFE0F };
    CHECK(rasterizer.rasterizeColorCluster(forcedColor, 2, 32, pixels.data()));
    CHECK(engineLog.lastProbeCluster == std::vector<std::uint32_t>({ 0x26A0, 0xFE0F }));
    CHECK(engineLog.lastProbePresentation == Rendering::Font::Presentation::Emoji);
    CHECK(!engineLog.lastProbeRequiresOwnFace);
    CHECK(engineLog.lastFamily.find("Noto Color Emoji") != std::string::npos);
    // A colour-pass call is already resolved by Core, including SGR 76's
    // override of a text selector and a text-default bare pictograph.
    const std::uint32_t forcedText[] = { 0x26A0, 0xFE0E };
    CHECK(rasterizer.rasterizeColorCluster(forcedText, 2, 32, pixels.data()));
    CHECK(engineLog.lastProbeCluster == std::vector<std::uint32_t>({ 0x26A0, 0xFE0F }));
    CHECK(engineLog.lastProbePresentation == Rendering::Font::Presentation::Emoji);
    CHECK(engineLog.lastFamily.find("Noto Color Emoji") != std::string::npos);
    const std::uint32_t barePictograph[] = { 0x26A0 };
    CHECK(rasterizer.rasterizeColorCluster(barePictograph, 1, 32, pixels.data()));
    CHECK(engineLog.lastProbeCluster == std::vector<std::uint32_t>({ 0x26A0, 0xFE0F }));
    CHECK(engineLog.lastProbePresentation == Rendering::Font::Presentation::Emoji);

    const std::uint32_t keycap[] = { '1', 0xFE0F, 0x20E3 };
    CHECK(rasterizer.rasterizeColorCluster(keycap, 3, 32, pixels.data()));
    CHECK(engineLog.lastProbeCluster == std::vector<std::uint32_t>({ '1', 0xFE0F, 0x20E3 }));
    CHECK(engineLog.lastProbePresentation == Rendering::Font::Presentation::Emoji);
    CHECK(engineLog.lastFamily.find("Noto Color Emoji") != std::string::npos);

    std::array<std::uint8_t, 16 * 32> textCoverage;
    CHECK(rasterizer.rasterizeGlyph(0x2B50, Rendering::FontFace::Regular, 400, 16, 32, textCoverage.data()));
    CHECK(engineLog.lastProbePresentation == Rendering::Font::Presentation::Text);
    CHECK(engineLog.lastFamily.find("Noto Color Emoji") == std::string::npos);

    // Degenerate arguments refuse before the seam.
    CHECK(!rasterizer.rasterizeColorCluster(nullptr, 1, 32, pixels.data()));
    CHECK(!rasterizer.rasterizeColorCluster(emoji, 0, 32, pixels.data()));
    CHECK(!rasterizer.rasterizeColorCluster(emoji, 1, 0, pixels.data()));
}

TEST(testTextPictographsUseCompleteOutlinesAndTextFontProbes)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    std::array<std::uint8_t, 32 * 64> coverage;
    for (const std::uint32_t symbol : { 0x2602, 0x2600, 0x2708, 0x2764, 0x2B50 }) {
        CHECK(rasterizer.rasterizeGlyph(symbol, Rendering::FontFace::Regular, 0, 8, 16, coverage.data()));
        CHECK_EQ(engineLog.lastIsTextPictograph, 1);
        CHECK(engineLog.lastProbeCluster == std::vector<std::uint32_t>({ symbol, 0xFE0E }));
        CHECK(engineLog.lastProbePresentation == Rendering::Font::Presentation::Text);
        CHECK_EQ(coverage[0], engineCoverageByte);

        // Core can force text even when the input includes an emoji selector.
        const std::uint32_t cluster[] = { symbol, 0xFE0F };
        CHECK(rasterizer.rasterizeCluster(cluster, 2, Rendering::FontFace::Regular, 0, 8, 16, coverage.data()));
        CHECK_EQ(engineLog.lastIsTextPictograph, 1);
        CHECK(engineLog.lastProbeCluster == std::vector<std::uint32_t>({ symbol, 0xFE0E }));
        CHECK(rasterizer.rasterizeGlyphScaled(symbol, Rendering::FontFace::Regular, 0, 2, 16, 32, coverage.data()));
        CHECK_EQ(engineLog.lastIsTextPictograph, 1);
    }
    // Letter bearings and combining marks keep the ordinary shaping path.
    CHECK(rasterizer.rasterizeGlyph('A', Rendering::FontFace::Italic, 0, 8, 16, coverage.data()));
    CHECK_EQ(engineLog.lastIsTextPictograph, 0);
    const std::uint32_t accented[] = { 'a', 0x301 };
    CHECK(rasterizer.rasterizeCluster(accented, 2, Rendering::FontFace::Regular, 0, 8, 16, coverage.data()));
    CHECK_EQ(engineLog.lastIsTextPictograph, 0);
}

TEST(testScaledRasterAsksTheEngineAtTheScaledSize)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    std::vector<std::uint8_t> coverage(128 * 128);

    // scale 1 is the plain path; past that the engine re-rasterizes at the
    // multiplied size instead of nearest-neighbour doubling.
    CHECK(rasterizer.rasterizeGlyphScaled('A', Rendering::FontFace::Regular, 400, 1, 16, 32, coverage.data()));
    CHECK(engineLog.lastPixelSize == enginePixelSize);
    CHECK(rasterizer.rasterizeGlyphScaled('A', Rendering::FontFace::Regular, 400, 2, 32, 64, coverage.data()));
    CHECK(engineLog.lastPixelSize == enginePixelSize * 2);

    // A scaled glyph the engine lacks falls to the base implementation.
    CHECK(rasterizer.rasterizeGlyphScaled(glyphTheEngineLacks, Rendering::FontFace::Regular, 400, 2, 32, 64, coverage.data()));

    // An OSC 66 fraction is drawn at its own size, not the nearest whole one:
    // 3/2 asks the engine for one and a half times the face's pixel size, and
    // the baseline moves by the same factor.
    CHECK(rasterizer.rasterizeGlyphScaled('A', Rendering::FontFace::Regular, 400, Rendering::RasterScale { 3, 2 }, 24, 48, coverage.data()));
    CHECK(engineLog.lastPixelSize == enginePixelSize * 1.5);
    CHECK(engineLog.lastBaseline != 0);
    CHECK(engineLog.lastHorizontalScale == 1.0);

    // A doubled row's master is drawn at the face's own size and stretched
    // across by the outline, by what Core left of the doubling.
    Rendering::SizedMaster doubled;
    doubled.widthScale = 2;
    doubled.horizontalScale = 2.0;
    CHECK(rasterizer.rasterizeSizedMaster('A', Rendering::FontFace::Regular, 400, doubled, 32, 32, coverage.data()));
    CHECK(engineLog.lastPixelSize == enginePixelSize);
    CHECK(engineLog.lastHorizontalScale == 2.0);
}

// A sized master's glyph stands where Core's pen puts it, as it does on every
// arm: its advance centred in the master and moved by the master's shift. The
// engine here advances an `A` half its pixel size, so at three times the size a
// master twice as wide as the glyph needs the glyph a quarter of the way in, and
// the shift moves it from there. A doubled row draws the pen in the space the
// stretch carries it from.
TEST(testSizedMasterPutsTheGlyphAtCoresPen)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    std::vector<std::uint8_t> coverage(512 * 128);

    Rendering::SizedMaster master;
    master.scale = Rendering::RasterScale { 3 };
    master.shiftX = 1.25;
    const double advance = enginePixelSize * 0.5 * 3;
    const int slotWidth = static_cast<int>(2 * advance);
    CHECK(rasterizer.rasterizeSizedMaster('A', Rendering::FontFace::Regular, 400, master, slotWidth, 128, coverage.data()));
    const Rendering::SubpixelPhase pen = Rendering::sizedMasterPen(slotWidth, advance, master);
    CHECK(std::fabs(engineLog.lastPenX - (pen.snappedPenX + static_cast<double>(pen.phase) / Rendering::sizedMasterPenGrid)) < 1e-9);
    CHECK_MSG(std::fabs(engineLog.lastPenX - (advance / 2 + 1.25)) < 1.0 / Rendering::sizedMasterPenGrid, "the advance is centred, then shifted");

    Rendering::SizedMaster doubled;
    doubled.scale = Rendering::RasterScale { 2 };
    doubled.widthScale = 2;
    doubled.horizontalScale = 2.0;
    doubled.shiftX = -0.5;
    const double doubledAdvance = enginePixelSize * 0.5 * 2 * 2.0;
    const int doubledSlotWidth = static_cast<int>(doubledAdvance) + 16;
    CHECK(rasterizer.rasterizeSizedMaster('A', Rendering::FontFace::Regular, 400, doubled, doubledSlotWidth, 128, coverage.data()));
    const Rendering::SubpixelPhase doubledPen = Rendering::sizedMasterPen(doubledSlotWidth, doubledAdvance, doubled);
    const double expected = (doubledPen.snappedPenX + static_cast<double>(doubledPen.phase) / Rendering::sizedMasterPenGrid) / 2.0;
    CHECK(std::fabs(engineLog.lastPenX - expected) < 1e-9);
    CHECK_MSG(std::fabs(engineLog.lastPenX - ((doubledSlotWidth - doubledAdvance) / 2.0 - 0.5) / 2.0) < 1.0 / Rendering::sizedMasterPenGrid, "the stretch carries the pen");
}

// Every band of a sized block is cut from its own master at a whole row, and
// the bands step by the font's fractional line, so each master carries its own
// shift down. The engine draws each band's glyph on the baseline that shift
// moves it to, and the block's bands therefore stand on one baseline: on a row
// rounded to a whole one, each band's glyph lands as far from the next band's as
// the two roundings differ, and a diagonal stroke steps sideways at the join.
TEST(testEveryBandOfASizedBlockIsDrawnOnTheBlocksOneBaseline)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    constexpr float lineHeight = 15.6f;
    const Rendering::SizedWindowCanvas canvas { 12, 20, 2, 2, lineHeight, 7.6f };
    std::vector<std::uint8_t> master;
    std::vector<std::uint8_t> window(static_cast<std::size_t>(canvas.width * canvas.height));
    for (const std::uint8_t scale : { std::uint8_t { 2 }, std::uint8_t { 3 }, std::uint8_t { 5 }, std::uint8_t { 7 } }) {
        double first = 0.0;
        for (std::uint8_t band = 0; band < scale; ++band) {
            Rendering::SizedTile tile { scale, band, 0 };
            CHECK(Rendering::rasteriseSizedWindow(rasterizer, 'X', Rendering::FontFace::Regular, 0, tile, 0, canvas, master, window));
            const Rendering::SizedWindowCut cut = Rendering::planSizedWindow(Rendering::selectSizedMaster(rasterizer, Rendering::FontFace::Regular, tile), tile, 0, canvas);
            // The baseline in the block's own rows: band `band`'s window shows
            // the block from `band` lines down.
            const double inBlock = engineLog.lastBaseline - cut.sourceY + band * static_cast<double>(lineHeight);
            if (band == 0)
                first = inBlock;
            const std::string where = "s=" + std::to_string(scale) + " band " + std::to_string(band) + " stands its baseline "
                + std::to_string(inBlock - first) + " rows from band 0's";
            CHECK_MSG(std::fabs(inBlock - first) < 1e-6, where.c_str());
        }
    }
}

TEST(testProportionalRunKeepsTheFacesOwnAdvances)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    CHECK(rasterizer.hasProportionalFace());

    // 'i' and 'W' are the two extremes the stand-in face separates. A run whose
    // advances came back equal would be the grid face, which is the failure this
    // seam exists to make impossible.
    const std::uint32_t run[] = { 'W', 'i', 'x' };
    Ubiquitty::ProportionalShapedGlyph glyphs[3] {};
    const int count = rasterizer.shapeProportionalRun(run, Rendering::FontFace::Regular, glyphs);
    CHECK_EQ(count, 3);

    CHECK_MSG(glyphs[0].advanceInPixels > glyphs[2].advanceInPixels,
        "the wide glyph advances further than the middling one");
    CHECK_MSG(glyphs[2].advanceInPixels > glyphs[1].advanceInPixels,
        "the middling glyph advances further than the narrow one");

    // Each glyph names the code point it came from, in order: the seam maps ink
    // back to cells through the cluster, and a run that renumbered them would
    // place every cell's ink at another cell's column.
    for (int index = 0; index < count; ++index)
        CHECK_EQ(glyphs[index].cluster, index);

    // The pen stays the caller's. A shaper that accumulated one here would be a
    // second placement competing with the layout's.
    for (const auto& glyph : glyphs) {
        CHECK(glyph.offsetXInPixels == 0.0f);
        CHECK(glyph.offsetYInPixels == 0.0f);
    }
}

TEST(testProportionalRunAsksTheProportionalFamilyAndTheBoldWeight)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);

    const std::uint32_t run[] = { 'x' };
    Ubiquitty::ProportionalShapedGlyph glyphs[1] {};

    CHECK_EQ(rasterizer.shapeProportionalRun(run, Rendering::FontFace::Regular, glyphs), 1);
    // The CSS generic rather than the configured terminal family: a proportional
    // run asks the platform for its proportional face, which is the request the
    // FreeType arm makes of fontconfig.
    CHECK_MSG(engineLog.lastFamily == "sans-serif", "the proportional run asks for the platform's proportional face");
    CHECK_EQ(engineLog.lastCSSWeight, 400);

    CHECK_EQ(rasterizer.shapeProportionalRun(run, Rendering::FontFace::Bold, glyphs), 1);
    CHECK_MSG(engineLog.lastCSSWeight == 700, "bold reaches the engine as a CSS weight, not an SGR one");
}

TEST(testProportionalPreferencesReachBothMeasurementAndRaster)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    rasterizer.setProportionalFont("Configured Proportional", 24);
    const std::uint32_t run[] = { 'W', 'i' };
    Ubiquitty::ProportionalShapedGlyph glyphs[2] {};
    CHECK_EQ(rasterizer.shapeProportionalRun(run, Rendering::FontFace::Regular, glyphs), 2);
    CHECK(engineLog.lastFamily == "Configured Proportional");
    CHECK_EQ(engineLog.lastPixelSize, 24.0);
    std::array<std::uint8_t, 64 * 32> coverage {};
    CHECK(rasterizer.rasteriseProportionalRun(glyphs, Rendering::FontFace::Regular, 64, 32, coverage));
    CHECK(engineLog.lastFamily == "Configured Proportional");
    CHECK_EQ(engineLog.lastPixelSize, 24.0);
}

TEST(testProportionalRasterCarriesTheCallersPlacement)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);

    // Offsets the caller placed, which the raster must pass through untouched.
    Ubiquitty::ProportionalShapedGlyph glyphs[2] {};
    glyphs[0].glyph = 'W';
    glyphs[0].offsetXInPixels = 3.25f;
    glyphs[0].offsetYInPixels = 1.5f;
    glyphs[1].glyph = 'i';
    glyphs[1].offsetXInPixels = 17.75f;
    glyphs[1].offsetYInPixels = 0;

    constexpr int stripWidth = 32;
    constexpr int stripHeight = 20;
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(stripWidth) * stripHeight, 0);
    CHECK(rasterizer.rasteriseProportionalRun(glyphs, Rendering::FontFace::Regular, stripWidth, stripHeight, coverage));

    CHECK_EQ(engineLog.lastProportionalCount, 2);
    CHECK(engineLog.lastOffsetsX[0] == 3.25);
    CHECK(engineLog.lastOffsetsX[1] == 17.75);
    CHECK(engineLog.lastOffsetsY[0] == 1.5);
    CHECK_MSG(coverage[0] == engineCoverageByte, "the engine's coverage reaches the caller's strip");

    // One draw call for the whole run: the browser is asked once per strip, not
    // once per glyph, so a long label costs one boundary crossing.
    CHECK_EQ(engineLog.proportionalDrawCalls, 1);
}

// A proportional run past its size — a scaled run's master, a DECDHL pair's,
// a DECDWL row's — is drawn by the engine at that size, the face at real
// resolution, with the caller's master-pixel placement, on the baseline taken
// as many times; doubled across, the engine stretches the outlines rather than
// Core stretching a raster. Before this the master was refused, and the
// builder stretched the run's own glyphs.
TEST(testASizedProportionalRunIsDrawnByTheEngineAtTheMastersSize)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    Ubiquitty::ProportionalShapedGlyph glyphs[1] {};
    glyphs[0].glyph = 'W';
    glyphs[0].offsetXInPixels = 6.5f;
    std::vector<std::uint8_t> coverage(32 * 60, 0);

    CHECK(rasterizer.rasteriseProportionalRun(glyphs, Rendering::FontFace::Regular, 32, 20, std::span(coverage).first(32 * 20)));
    const int baseline = engineLog.lastBaseline;
    REQUIRE(baseline > 0);

    Rendering::SizedMaster tripled;
    tripled.scale = Rendering::RasterScale { 3 };
    engineLog.proportionalDrawCalls = 0;
    CHECK(rasterizer.rasteriseSizedProportionalRun(glyphs, Rendering::FontFace::Regular, tripled, 32, 60, coverage));
    CHECK_EQ(engineLog.proportionalDrawCalls, 1);
    CHECK_MSG(engineLog.lastPixelSize == enginePixelSize * 3, "the face at three times its size");
    CHECK_MSG(engineLog.lastBaseline == 3 * baseline, "on the baseline taken three times");
    CHECK(engineLog.lastProportionalHorizontalScale == 1.0);
    CHECK(engineLog.lastOffsetsX[0] == 6.5);
    CHECK_MSG(coverage[32 * 59] == engineCoverageByte, "the engine fills the whole master");

    Rendering::SizedMaster doubled;
    doubled.widthScale = 2;
    doubled.horizontalScale = 2.0;
    CHECK(rasterizer.rasteriseSizedProportionalRun(glyphs, Rendering::FontFace::Regular, doubled, 32, 20, std::span(coverage).first(32 * 20)));
    CHECK(engineLog.lastPixelSize == enginePixelSize);
    CHECK_MSG(engineLog.lastProportionalHorizontalScale == 2.0, "a DECDWL master stretches the outlines across");

    Rendering::SizedMaster fraction;
    fraction.scale = Rendering::RasterScale { 3, 2 };
    CHECK_MSG(!rasterizer.rasteriseSizedProportionalRun(glyphs, Rendering::FontFace::Regular, fraction, 32, 30, std::span(coverage).first(32 * 30)),
        "a fraction is no run's master");
}

TEST(testProportionalRunRefusesRatherThanOverrunning)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);

    const std::uint32_t run[] = { 'a', 'b', 'c' };
    Ubiquitty::ProportionalShapedGlyph tooFew[2] {};
    CHECK_MSG(rasterizer.shapeProportionalRun(run, Rendering::FontFace::Regular, tooFew) == 0,
        "a destination smaller than the run is refused, not filled to its edge");

    Ubiquitty::ProportionalShapedGlyph glyphs[1] {};
    glyphs[0].glyph = 'a';
    std::vector<std::uint8_t> tooSmall(4, 0);
    CHECK_MSG(!rasterizer.rasteriseProportionalRun(glyphs, Rendering::FontFace::Regular, 32, 20, tooSmall),
        "a coverage span smaller than the strip is refused, not written past");
}

namespace {

using ShapedGlyph = Rendering::GlyphRasterizer::ShapedGlyph;

// A distilled row as the builder hands it to the sheet: every cell one
// regular pen, so the whole row is one run.
std::vector<Rendering::LigatureCell> ligatureRow(std::string_view text)
{
    std::vector<Rendering::LigatureCell> row;
    for (const char character : text) {
        Rendering::LigatureCell cell;
        cell.codePoint = static_cast<unsigned char>(character);
        row.push_back(cell);
    }
    return row;
}

} // namespace

// Grid text is shaped by the browser. A canvas names no glyph, so the engine
// reports which cells its whole-run drawing changed, and the answer names each
// glyph by its code point with the contextual bit on the changed ones: what the
// sheet compares against the isolated mapping, which is the code point alone.
// The base rasterizer refuses every run, which drew `=>` unfused on this arm
// beside the fused one the native arms draw.
TEST(testGridRunsAreShapedByTheEngine)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    CHECK_MSG(rasterizer.hasLigatureShaping(), "a page's face shapes runs, so the sheet is built over it");

    const std::uint32_t run[] = { 'a', '=', '>', 'b' };
    std::array<ShapedGlyph, 4> shaped {};
    REQUIRE(rasterizer.shapeTextRun(run, 0, shaped) == 4);
    CHECK_EQ(engineLog.shapeRunCalls, 1);
    CHECK(engineLog.lastFamily == "TestFace");
    CHECK_EQ(engineLog.lastCSSWeight, 400);
    CHECK_MSG(engineLog.lastBandHeight == static_cast<int>(rasterizer.cellMetrics().cellHeight), "the comparison reads the cell box");
    for (int index = 0; index < 4; ++index) {
        CHECK_EQ(shaped[static_cast<std::size_t>(index)].cluster, index);
        CHECK_EQ(shaped[static_cast<std::size_t>(index)].advanceInPixels, static_cast<int>(std::lround(engineRunAdvance)));
    }
    CHECK_MSG(shaped[0].glyph == 'a' && shaped[3].glyph == 'b', "a cell the face left alone is named by its code point");
    CHECK_MSG(shaped[1].glyph == ('=' | WebFontRasterizer::contextualFormBit), "the ligature's cells are named as another form");
    CHECK(shaped[2].glyph == ('>' | WebFontRasterizer::contextualFormBit));

    // The isolated mapping the sheet compares against: one character is its own
    // form, so it is measured and never drawn.
    const std::uint32_t equals[] = { '=' };
    std::array<ShapedGlyph, 4> isolated {};
    CHECK_EQ(rasterizer.shapeTextRun(equals, 0, isolated), 1);
    CHECK(isolated[0].glyph == '=');
    CHECK_EQ(isolated[0].cluster, 0);
    CHECK_MSG(engineLog.shapeRunCalls == 1, "a single code point costs no drawing");
}

// The defect end to end through Core's own sheet: the strip for `x => y` is
// drawn by the engine with every glyph on its cell, and the sheet hands each of
// the run's columns its slice. A stretch the face draws as its characters stays
// on the mono path, so a strip appears only where the face substituted.
TEST(testTheLigatureSheetDrawsTheFusionTheEngineShaped)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    const int cellWidth = static_cast<int>(rasterizer.cellMetrics().cellWidth);
    const int cellHeight = static_cast<int>(rasterizer.cellMetrics().cellHeight);
    Rendering::LigatureSheet sheet(cellWidth, cellHeight, 0, 0, &rasterizer);
    REQUIRE_MSG(sheet.isUsable(), "the sheet is built over a face that shapes");
    CHECK_MSG(sheet.participation() == Rendering::LigatureParticipation::OperatorRuns,
        "letters and digits keep their forms in this face, so only operator runs are shaped");

    const std::vector<Rendering::LigatureCell> row = ligatureRow("x => y");
    std::vector<Rendering::LigatureRun> runs(row.size());
    engineLog.drawShapedRunCalls = 0;
    sheet.shapeRow(row, static_cast<float>(cellWidth), runs);
    REQUIRE_MSG(engineLog.drawShapedRunCalls == 1, "the substituted run is drawn once");
    for (const Rendering::LigatureRun& run : runs) {
        CHECK_MSG(run.length == 6, "every column of the run takes its slice of the strip");
        CHECK(run.strip.present);
    }
    // The run as the sheet shapes it, a standing space at each row edge, and
    // every glyph placed on its own cell while the browser's own pens step by
    // the face's advance. The leading space stands a cell left of the row.
    CHECK(engineLog.lastDrawnRun == std::vector<std::uint32_t>({ ' ', 'x', ' ', '=', '>', ' ', 'y', ' ' }));
    REQUIRE(engineLog.lastPlacedPensX.size() == engineLog.lastDrawnRun.size());
    for (std::size_t index = 0; index < engineLog.lastPlacedPensX.size(); ++index) {
        CHECK(engineLog.lastPlacedPensX[index] == static_cast<double>((static_cast<int>(index) - 1) * cellWidth));
        CHECK(engineLog.lastNaturalPensX[index] == static_cast<double>(index) * engineRunAdvance);
    }
    CHECK_MSG(engineLog.lastCSSWeight == 400, "a regular run draws at the regular weight");
    const Rendering::AtlasGlyph strip = runs[0].strip;
    const std::size_t stripOrigin = static_cast<std::size_t>(strip.minUV.y) * static_cast<std::size_t>(sheet.widthInPixels())
        + static_cast<std::size_t>(strip.minUV.x);
    CHECK_MSG(sheet.coverage()[stripOrigin] == engineCoverageByte, "the engine's ink is what the strip holds");

    // The control: the face changes nothing in this stretch, so no strip is
    // drawn and its columns keep the mono path.
    const std::vector<Rendering::LigatureCell> unchanged = ligatureRow("ls -la");
    std::vector<Rendering::LigatureRun> plain(unchanged.size());
    engineLog.drawShapedRunCalls = 0;
    sheet.shapeRow(unchanged, static_cast<float>(cellWidth), plain);
    CHECK_EQ(engineLog.drawShapedRunCalls, 0);
    for (const Rendering::LigatureRun& run : plain)
        CHECK_EQ(run.length, 0);
}

// A bold run is shaped and drawn at the weight Core's rule gives the sheet's
// bold, as the FreeType arm reads it. The sheet shapes the run's characters one
// at a time between shaping the run and drawing it, and that weight must not
// become the strip's.
TEST(testAStripDrawsTheRunLastShapedAtItsWeight)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    const std::uint32_t run[] = { 'a', '=', '>', 'b' };
    std::array<ShapedGlyph, 4> shaped {};
    REQUIRE(rasterizer.shapeTextRun(run, 7, shaped) == 4);
    CHECK_EQ(engineLog.lastCSSWeight, 800);
    const std::uint32_t equals[] = { '=' };
    std::array<ShapedGlyph, 1> isolated {};
    CHECK_EQ(rasterizer.shapeTextRun(equals, 0, isolated), 1);

    constexpr int stripWidth = 64;
    constexpr int stripHeight = 20;
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(stripWidth) * stripHeight, 0);
    CHECK(rasterizer.rasteriseShapedRun(shaped, stripWidth, stripHeight, coverage));
    CHECK_MSG(engineLog.lastCSSWeight == 800, "the strip is drawn at the run's weight, not the isolated character's");
    CHECK(engineLog.lastDrawnRun == std::vector<std::uint32_t>({ 'a', '=', '>', 'b' }));
    CHECK_MSG(coverage[0] == engineCoverageByte, "the engine's coverage reaches the caller's strip");

    // A run other than the last one shaped has no weight or pens to draw at.
    std::array<ShapedGlyph, 4> other = shaped;
    other[3].glyph = 'c';
    CHECK(!rasterizer.rasteriseShapedRun(other, stripWidth, stripHeight, coverage));
    CHECK(!rasterizer.rasteriseShapedRun(std::span(shaped).first(3), stripWidth, stripHeight, coverage));
    // Nor does a strip whose buffer disagrees with its size.
    CHECK(!rasterizer.rasteriseShapedRun(shaped, stripWidth, stripHeight, std::span(coverage).first(coverage.size() - 1)));
}

TEST(testRunShapingRefusesWhatItCannotName)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    const std::uint32_t run[] = { 'a', '=', '>', 'b' };
    std::array<ShapedGlyph, 3> tooFew {};
    CHECK_MSG(rasterizer.shapeTextRun(run, 0, tooFew) == 0, "a destination shorter than the run is refused");
    std::array<ShapedGlyph, 80> roomy {};
    const std::uint32_t surrogate[] = { 'a', 0xD800 };
    CHECK_MSG(rasterizer.shapeTextRun(surrogate, 0, roomy) == 0, "a value that is no scalar has no name and no text");
    const std::vector<std::uint32_t> longRun(65, '=');
    CHECK_MSG(rasterizer.shapeTextRun(longRun, 0, roomy) == 0, "a run past every one the sheet asks for is refused");
    CHECK_MSG(engineLog.shapeRunCalls == 0, "and none of them reached the engine");

    // An engine that cannot shape leaves no run behind to draw.
    REQUIRE(rasterizer.shapeTextRun(run, 0, roomy) == 4);
    Web::ForTest::WebFontHost refusing;
    refusing.primaryFamily = fakePrimaryFamily;
    refusing.measure = fakeMeasure;
    refusing.measureProportional = fakeMeasureProportional;
    Web::ForTest::installWebFontHost(refusing);
    CHECK(rasterizer.shapeTextRun(run, 0, roomy) == 0);
    std::vector<std::uint8_t> coverage(64 * 20, 0);
    CHECK(!rasterizer.rasteriseShapedRun(std::span(roomy).first(4), 64, 20, coverage));
}

// `font.ligatures = false` with nothing named back on leaves the face no run
// to fuse, and the rasterizer says so before anything is drawn: a page whose
// face was registered without the descriptor fuses nothing all the same.
TEST(testLigaturesOffLeaveNothingToShape)
{
    using Substitution = WebFontRasterizer::RunSubstitution;
    CHECK(WebFontRasterizer::runSubstitutionFor(Rendering::Ligatures::Enabled, "") == Substitution::Possible);
    CHECK(WebFontRasterizer::runSubstitutionFor(Rendering::Ligatures::Enabled, "-calt") == Substitution::Possible);
    CHECK(WebFontRasterizer::runSubstitutionFor(Rendering::Ligatures::Disabled, "") == Substitution::Suppressed);
    CHECK(WebFontRasterizer::runSubstitutionFor(Rendering::Ligatures::Disabled, "-liga -calt") == Substitution::Suppressed);
    CHECK_MSG(WebFontRasterizer::runSubstitutionFor(Rendering::Ligatures::Disabled, "calt -calt") == Substitution::Suppressed,
        "a tag's last value is the one the descriptor carries");
    CHECK_MSG(WebFontRasterizer::runSubstitutionFor(Rendering::Ligatures::Disabled, "+calt") == Substitution::Possible,
        "a feature named on beats the toggle, as it does in the descriptor");
    CHECK(WebFontRasterizer::runSubstitutionFor(Rendering::Ligatures::Disabled, "ss01") == Substitution::Possible);

    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1, std::string(), {}, Substitution::Suppressed);
    CHECK(rasterizer.isAvailable());
    CHECK_MSG(!rasterizer.hasLigatureShaping(), "nothing can fuse, so no sheet is built for it");
    const std::uint32_t run[] = { 'a', '=', '>', 'b' };
    std::array<ShapedGlyph, 4> shaped {};
    CHECK_EQ(rasterizer.shapeTextRun(run, 0, shaped), 0);

    // A sheet over it all the same draws no strip for the run the engine
    // would have fused.
    const int cellWidth = static_cast<int>(rasterizer.cellMetrics().cellWidth);
    Rendering::LigatureSheet sheet(cellWidth, static_cast<int>(rasterizer.cellMetrics().cellHeight), 0, 0, &rasterizer);
    const std::vector<Rendering::LigatureCell> row = ligatureRow("x => y");
    std::vector<Rendering::LigatureRun> runs(row.size());
    sheet.shapeRow(row, static_cast<float>(cellWidth), runs);
    for (const Rendering::LigatureRun& published : runs)
        CHECK_EQ(published.length, 0);
    CHECK_MSG(engineLog.shapeRunCalls == 0 && engineLog.drawShapedRunCalls == 0, "the engine is never asked");
}

TEST(testCombiningClusterReachesTheFontAsOneShapingRequest)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    const std::uint32_t cluster[] = { 'Z', 0x0324, 0x0308 };
    std::vector<std::uint8_t> coverage(static_cast<std::size_t>(enginePixelSize) * enginePixelSize);
    CHECK(rasterizer.rasterizeCluster(cluster, 3, Rendering::FontFace::Regular, 0, enginePixelSize, enginePixelSize, coverage.data()));
    CHECK_EQ(engineLog.clusterCalls, 1);
    CHECK(engineLog.lastDrawnCluster == std::vector<std::uint32_t>(std::begin(cluster), std::end(cluster)));
    CHECK(std::ranges::all_of(coverage, [](std::uint8_t pixel) { return pixel == engineCoverageByte; }));
}

TEST(testCursivePresentationFormsReachBothCellEdges)
{
    installFakeEngine();
    Rendering::UnifontRasterizer fallback;
    WebFontRasterizer rasterizer(fallback, enginePixelSize, 0, 0, noPreferences, 1);
    std::vector<std::uint8_t> coverage(enginePixelSize * enginePixelSize);
    CHECK(rasterizer.rasterizeGlyph(0xFE91, Rendering::FontFace::Regular, 0, enginePixelSize, enginePixelSize, coverage.data()));
    CHECK_EQ(engineLog.lastHorizontalScale, 2.0);
}

UBIQUITTY_TEST_MAIN()
