// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_linux_color_emoji — the GTK frontend's colour half of the raster seam.
//
// Two questions, and they fail differently. `hasColorGlyphs` is about the
// SYSTEM: it answers whether an emoji face was found at all, and a machine with
// none must answer false rather than allocate a colour sheet nothing can fill.
// `rasterizeColorCluster` is about one cluster, and a face that covers a code
// point only in outline form must decline it so the mono path draws it instead.
//
// The colour assertion is what makes this more than a smoke test. FreeType
// returns a PRE-MULTIPLIED BGRA bitmap and the seam is specified in straight
// RGBA, so a backend that memcpy'd the bitmap would produce pixels that pass
// every "is it non-empty" check and darken every partially transparent edge —
// which on an emoji is its whole outline. Asserting saturation catches a raster
// that is present and wrong, which is the failure a byte count cannot see.
//
// The environment is a precondition rather than an assumption: the container
// carries fonts-noto-color-emoji (Scripts/run-linux.sh), and where it does not,
// the system case reports that instead of failing an assertion about a font
// nobody installed.
//
// Every colour case names the format the kept face draws through — COLRv1,
// COLRv0, CBDT or sbix — so a run's output says which colour path it
// exercised, and a run with none says that in the same place. A vacuous pass
// therefore never reads as a working colour path.

#include "Platform/Linux/FreeTypeRasterizer.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {

constexpr int fontPixelSize = 32;
constexpr int slotInPixels = 32;
constexpr std::uint32_t grinningFace = 0x1F600;
constexpr std::uint32_t latinA = 'a';

Ubiquitty::Linux::FreeTypeRasterizer makeRasterizer()
{
    return { fontPixelSize, "monospace", std::string(), std::string(), std::string() };
}

/// A rasterizer that knows where the bundled fonts are, the way the app's
/// does, so the colour face it keeps is the shipped COLRv1 file and not
/// whatever the host installed. The directory comes from the build, absolute:
/// `__FILE__` is repo-relative under the compiler cache and would name a path
/// that resolves against nothing where the test runs.
Ubiquitty::Linux::FreeTypeRasterizer makeBundledRasterizer()
{
    return { fontPixelSize, "monospace", std::string(), std::string(UBQ_BUNDLED_FONTS_DIR) + "/SymbolsNerdFontMono-Regular.ttf", std::string() };
}

/// How many pixels carry colour rather than grey.
///
/// A channel spread is what separates an emoji from a coverage glyph promoted
/// to RGBA: grey has its three channels within a few units of each other no
/// matter how bright it is.
///
/// - Parameter pixels: An RGBA8 slot.
/// - Returns: The count of pixels whose channels differ by more than 40.
int saturatedPixels(const std::vector<std::uint8_t>& pixels)
{
    int saturated = 0;
    for (std::size_t i = 0; i + 3 < pixels.size(); i += 4) {
        if (pixels[i + 3] < 16)
            continue;
        const std::uint8_t high = std::max({ pixels[i], pixels[i + 1], pixels[i + 2] });
        const std::uint8_t low = std::min({ pixels[i], pixels[i + 1], pixels[i + 2] });
        if (high - low > 40)
            ++saturated;
    }
    return saturated;
}

/// How many pixels are not fully transparent.
///
/// - Parameter pixels: An RGBA8 slot.
/// - Returns: The count of pixels with a non-trivial alpha.
int opaquePixels(const std::vector<std::uint8_t>& pixels)
{
    int opaque = 0;
    for (std::size_t i = 0; i + 3 < pixels.size(); i += 4) {
        if (pixels[i + 3] > 16)
            ++opaque;
    }
    return opaque;
}

} // namespace

TEST(theSystemColourFaceIsFoundWhenOneIsInstalled)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeRasterizer();

    // Not an assertion about the host's font set — a machine with no emoji font
    // is a legitimate configuration and must answer false rather than crash or
    // claim a sheet it cannot fill. What is asserted is that the answer is
    // usable either way: false means every later case is vacuous and says so.
    if (!rasterizer.hasColorGlyphs()) {
        std::printf("    (no colour face on this system — the colour cases below are vacuous here)\n");
        CHECK(rasterizer.colorGlyphFormat() == Ubiquitty::Linux::ColorGlyphFormat::None);
        return;
    }
    CHECK(rasterizer.hasColorGlyphs());
    // A kept face has a named format: `None` beside a true `hasColorGlyphs`
    // would be a face kept without the probe that names it.
    CHECK(rasterizer.colorGlyphFormat() != Ubiquitty::Linux::ColorGlyphFormat::None);
    CHECK(!rasterizer.colorFacePath().empty());
    std::printf("    colour face: %s (%s)\n", rasterizer.colorFacePath().c_str(),
        Ubiquitty::Linux::colorGlyphFormatName(rasterizer.colorGlyphFormat()));
}

TEST(theKeptFaceIsTheFirstCandidateThatPassesTheDrawProbe)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeRasterizer();
    const auto candidates = rasterizer.emojiFaceCandidates();
    std::printf("    fontconfig offers %zu candidate(s) for emoji\n", candidates.size());

    // Re-derived from the public probe, candidate by candidate: the kept face
    // is the first that passes, every face before it fails, and a host where
    // none passes keeps none. A rasterizer that took fontconfig's first answer
    // and declined it would disagree here on any host whose first answer
    // fails the probe and a later one passes.
    std::string firstPassing;
    Ubiquitty::Linux::ColorGlyphFormat firstFormat = Ubiquitty::Linux::ColorGlyphFormat::None;
    for (const auto& [path, faceIndex] : candidates) {
        const auto format = Ubiquitty::Linux::FreeTypeRasterizer::probeColorFace(path, faceIndex, fontPixelSize);
        std::printf("      %s -> %s\n", path.c_str(), Ubiquitty::Linux::colorGlyphFormatName(format));
        if (format != Ubiquitty::Linux::ColorGlyphFormat::None) {
            firstPassing = path;
            firstFormat = format;
            break;
        }
    }
    CHECK(rasterizer.hasColorGlyphs() == !firstPassing.empty());
    CHECK(rasterizer.colorFacePath() == firstPassing);
    CHECK(rasterizer.colorGlyphFormat() == firstFormat);
}

TEST(theReportGlyphsRenderWithSaturatedColour)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeRasterizer();
    if (!rasterizer.hasColorGlyphs()) {
        std::printf("    (no colour face on this system — this case is vacuous here)\n");
        return;
    }
    std::printf("    format: %s\n", Ubiquitty::Linux::colorGlyphFormatName(rasterizer.colorGlyphFormat()));

    struct ReportGlyph {
        std::uint32_t codePoint;
        const char* name;
    };
    // A smiley, a smiley with tears, a hand, and a heart: gradients, a solid,
    // and a glyph that also exists as a text-presentation code point.
    const ReportGlyph glyphs[] = {
        { 0x1F600, "U+1F600 grinning face" },
        { 0x1F602, "U+1F602 face with tears of joy" },
        { 0x1F44D, "U+1F44D thumbs up" },
        { 0x2764, "U+2764 heavy black heart" },
    };
    for (const ReportGlyph& glyph : glyphs) {
        std::vector<std::uint8_t> pixels(static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
        const std::uint32_t cluster[] = { glyph.codePoint };
        const bool didDraw = rasterizer.rasterizeColorCluster(cluster, 1, slotInPixels, pixels.data());
        const int opaque = didDraw ? opaquePixels(pixels) : 0;
        const int saturated = didDraw ? saturatedPixels(pixels) : 0;
        std::printf("      %s: %s, %d opaque, %d saturated of %d\n", glyph.name, didDraw ? "drawn" : "declined",
            opaque, saturated, slotInPixels * slotInPixels);
        CHECK_MSG(didDraw, glyph.name);
        CHECK_MSG(saturated > 0, glyph.name);
    }
}

TEST(aColourClusterRastersInColourRatherThanGrey)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeRasterizer();
    if (!rasterizer.hasColorGlyphs())
        return;

    std::vector<std::uint8_t> pixels(static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
    const std::uint32_t cluster[] = { grinningFace };
    CHECK(rasterizer.rasterizeColorCluster(cluster, 1, slotInPixels, pixels.data()));

    // Ink first, so a blank slot fails here rather than passing the colour check
    // vacuously — zero saturated pixels out of zero drawn pixels is not a
    // monochrome raster, it is no raster.
    CHECK(opaquePixels(pixels) > 0);

    // And colour. A grinning face is yellow: a raster that came back grey is
    // either the mono path leaking onto the colour sheet or a pre-multiplied
    // bitmap copied through unconverted.
    CHECK(saturatedPixels(pixels) > 0);
}

TEST(theBundledColourFaceIsTheKeptOneAndDrawsAFlag)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeBundledRasterizer();
    // The shipped file first, whatever the host installed: this is the face
    // the goldens are minted with, on every machine.
    CHECK(rasterizer.hasColorGlyphs());
    CHECK_MSG(rasterizer.colorFacePath().ends_with("NotoColorEmoji-COLRv1.ttf"),
        "the kept colour face is the bundled COLRv1 file, not the host's");
    CHECK(rasterizer.colorGlyphFormat() == Ubiquitty::Linux::ColorGlyphFormat::COLRv1);

    // A flag is two regional indicators the face ligates into one glyph, and
    // in this build that glyph is a stripe glyph clipped into a wave with a
    // SRC_IN composite and shaded with a SOFT_LIGHT one. A painter without
    // the blend modes drew the face, the thumb and the heart and left the
    // flag blank, which no other glyph on the sheet could show.
    std::vector<std::uint8_t> pixels(static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
    const std::uint32_t japan[] = { 0x1F1EFu, 0x1F1F5u };
    CHECK(rasterizer.rasterizeColorCluster(japan, 2, slotInPixels, pixels.data()));
    CHECK(opaquePixels(pixels) > 0);
    CHECK(saturatedPixels(pixels) > 0);
}

TEST(aCodePointTheColourFaceLacksIsDeclined)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeRasterizer();
    if (!rasterizer.hasColorGlyphs())
        return;

    // The control for the case above. An emoji face has no Latin 'a', so this
    // must decline and leave the cluster to the mono path. Without it, a
    // backend that returned true for everything would pass the colour case on
    // the one code point it was tested with.
    std::vector<std::uint8_t> pixels(static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
    const std::uint32_t cluster[] = { latinA };
    CHECK(!rasterizer.rasterizeColorCluster(cluster, 1, slotInPixels, pixels.data()));
}

TEST(anAcceptedRasterAlwaysCarriesInk)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeRasterizer();
    if (!rasterizer.hasColorGlyphs())
        return;

    // The invariant, stated over a set rather than over one code point: whatever
    // this accepts has ink in it, so a slot is never spent on a blank.
    //
    // Ink and not colour: a face may draw a sequence in greys, and Noto Color
    // Emoji draws every family that way. Which clusters a given font composes
    // is a property of that font and not something to assert here.
    const std::uint32_t man[] = { 0x1F468 };
    const std::uint32_t family[] = { 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466 };
    const std::uint32_t couple[] = { 0x1F469, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F468 };
    const std::uint32_t technologist[] = { 0x1F468, 0x200D, 0x1F4BB };

    struct Cluster {
        const std::uint32_t* codePoints;
        int count;
    };
    const Cluster clusters[] = {
        { man, 1 },
        { family, 7 },
        { couple, 6 },
        { technologist, 3 },
    };

    int accepted = 0;
    for (const Cluster& cluster : clusters) {
        std::vector<std::uint8_t> pixels(static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
        if (!rasterizer.rasterizeColorCluster(cluster.codePoints, cluster.count, slotInPixels, pixels.data()))
            continue;
        ++accepted;
        CHECK(opaquePixels(pixels) > 0);
    }

    // And at least one was accepted, so the loop above is not passing by
    // declining everything.
    CHECK(accepted > 0);
}

TEST(aZWJFamilyComposesIntoOneDrawnGlyph)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeBundledRasterizer();
    CHECK(rasterizer.colorGlyphFormat() == Ubiquitty::Linux::ColorGlyphFormat::COLRv1);

    // Man, ZWJ, woman, ZWJ, girl: five code points, one glyph in the face's
    // GSUB. The mono path has no glyph for the sequence, so a decline here is
    // a blank cell on screen.
    const std::uint32_t family[] = { 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 };
    std::vector<std::uint8_t> composed(static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
    CHECK_MSG(rasterizer.rasterizeColorCluster(family, 5, slotInPixels, composed.data()),
        "the family sequence is drawn from the colour face");
    CHECK(opaquePixels(composed) > 0);

    // The composed glyph, not the lead code point drawn under the cluster's
    // name: a shaper that split the run would hand back the man alone.
    const std::uint32_t man[] = { 0x1F468 };
    std::vector<std::uint8_t> lead(static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
    CHECK(rasterizer.rasterizeColorCluster(man, 1, slotInPixels, lead.data()));
    CHECK_MSG(composed != lead, "the sequence draws its own glyph, not its first person");

    // The face draws the family as a grey keycap with black figures. That is
    // its design rather than a failed colour load, and it is what a colour
    // test on the painted raster refused.
    CHECK(saturatedPixels(composed) == 0);
}

// An emoji ZWJ sequence composes through the same GSUB machinery a text
// ligature does, and `[font] ligatures` must not reach it.
//
// The setting is about programming ligatures in the primary text face. The
// emoji face uses ligature lookups to encode its sequences — a family is four
// code points and one glyph — so a suppression aimed at `=>` and applied to
// both faces would silently stop composing families, couples and skin tones,
// and the terminal would draw the pieces instead.
//
// Stated as a differential rather than as a list of clusters that must compose.
// Which sequences a given font carries is a property of that font: the case
// above asserts no such list, and that is why it cannot catch this — it
// `continue`s past a declined cluster, so a composition that stopped
// working still passes so long as one lone emoji is accepted. What is
// font-independent, and what this asserts, is that flipping a text setting
// changes nothing about which emoji clusters compose.
//
// The limit of what this establishes, since a green case invites the stronger
// reading: no mutation available here makes it fail. Suppressing
// `liga`, `clig`, `calt` and `ccmp` on the emoji shaper leaves every cluster
// composing to identical pixels, so the colour face reachable from this suite
// resolves ZWJ below the feature layer. This guards an invariant rather than
// reproducing a break, and it would earn its keep against a font that does
// gate its sequences on a feature — which is the case the seam is closed
// against, not one this suite can currently produce.
TEST(theLigatureSettingDoesNotReachTheEmojiFace)
{
    Ubiquitty::Linux::FreeTypeRasterizer ligated = makeRasterizer();
    if (!ligated.hasColorGlyphs()) {
        std::printf("    (no colour face on this system — this case is vacuous here)\n");
        return;
    }
    // The same face, one text setting apart.
    Ubiquitty::Linux::FreeTypeRasterizer suppressed { fontPixelSize, "monospace", std::string(),
        std::string(), std::string(), 1, 0, 0, 0, 0, 0.0, std::string(), std::string(),
        Ubiquitty::Linux::Ligatures::Disabled };
    CHECK(suppressed.hasColorGlyphs());

    const std::uint32_t man[] = { 0x1F468 };
    const std::uint32_t family[] = { 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466 };
    const std::uint32_t couple[] = { 0x1F469, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F468 };
    const std::uint32_t technologist[] = { 0x1F468, 0x200D, 0x1F4BB };
    struct Cluster {
        const std::uint32_t* codePoints;
        int count;
        const char* name;
    };
    const Cluster clusters[] = {
        { man, 1, "man" },
        { family, 7, "family" },
        { couple, 6, "couple" },
        { technologist, 3, "technologist" },
    };

    int composedEitherWay = 0;
    for (const Cluster& cluster : clusters) {
        std::vector<std::uint8_t> withLigatures(
            static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
        std::vector<std::uint8_t> without(
            static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
        const bool didLigatedAccept
            = ligated.rasterizeColorCluster(cluster.codePoints, cluster.count, slotInPixels, withLigatures.data());
        const bool didSuppressedAccept
            = suppressed.rasterizeColorCluster(cluster.codePoints, cluster.count, slotInPixels, without.data());
        CHECK_MSG(didLigatedAccept == didSuppressedAccept, cluster.name);
        if (!didLigatedAccept)
            continue;
        ++composedEitherWay;
        // And the same pixels, not merely the same verdict: a sequence that
        // composed to a DIFFERENT glyph under suppression would be accepted by
        // both and drawn wrong by one.
        CHECK_MSG(withLigatures == without, cluster.name);
    }

    // Multi-code-point sequences among them, so this is not passing on the lone
    // emoji alone — that one needs no ligature lookup and would agree however
    // badly the rest were broken.
    CHECK_MSG(composedEitherWay >= 2, "at least one ZWJ sequence composed, so the comparison is not vacuous");
}

TEST(aColourRasterRejectsAnEmptyOrNegativeSlot)
{
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer = makeRasterizer();

    std::vector<std::uint8_t> pixels(static_cast<std::size_t>(slotInPixels) * slotInPixels * 4, 0);
    const std::uint32_t cluster[] = { grinningFace };

    CHECK(!rasterizer.rasterizeColorCluster(cluster, 0, slotInPixels, pixels.data()));
    CHECK(!rasterizer.rasterizeColorCluster(cluster, 1, 0, pixels.data()));
    CHECK(!rasterizer.rasterizeColorCluster(nullptr, 1, slotInPixels, pixels.data()));
    CHECK(!rasterizer.rasterizeColorCluster(cluster, 1, slotInPixels, nullptr));
}

UBIQUITTY_TEST_MAIN()
