// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Source/Platform/Linux/FreeTypeRasterizer.cpp — see FreeTypeRasterizer.h.

#include "Platform/Linux/FreeTypeRasterizer.h"

#include "Core/Rendering/BundledFonts.h"
#include "Core/Rendering/CellLayout.h"
#include "Core/Rendering/Font/FontFallbackPolicy.h"
#include "Core/Rendering/Font/FontRoute.h"
#include "Core/Rendering/Font/FontRoutingSession.h"
#include "Core/Rendering/Font/ScriptClassifier.h"
#include "Core/Rendering/FontMetrics.h"
#include "Core/Rendering/GlyphTiling.h"
#include "Core/Rendering/RuleGeometry.h"
#include "Core/Rendering/SizedMaster.h"
#include "Core/Rendering/SubpixelPhase.h"
#include "Core/Unicode/Width.h"
#include "Platform/Linux/FontInventory.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <optional>
#include <strings.h>
#include <utility>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_ADVANCES_H
#include FT_BBOX_H
#include FT_OUTLINE_H

#include <hb-ft.h>
#include <hb.h>
#include FT_MULTIPLE_MASTERS_H
#include FT_COLOR_H
#include FT_TRUETYPE_TABLES_H

#include <fontconfig/fontconfig.h>

namespace Ubiquitty::Linux {

namespace {
int roundToInt(double v) { return static_cast<int>(std::lround(v)); }
// HarfBuzz names hb_glyph_info_t's field `codepoint`, though after shaping it
// holds a GLYPH index and not a code point. Read through one named accessor so
// the rest of this file speaks in glyphs and the library's name for it appears
// once.
unsigned int glyphIndexOf(const hb_glyph_info_t& info) { return info.codepoint; }

// An OpenType axis tag as the 32-bit big-endian word FreeType compares, which
// is what FT_MAKE_TAG builds. A tag shorter than four characters can match no
// axis, so it answers zero rather than a padded word that could collide.
std::uint32_t variationAxisTag(std::string_view tag)
{
    if (tag.size() != 4)
        return 0;
    return (static_cast<std::uint32_t>(static_cast<unsigned char>(tag[0])) << 24)
        | (static_cast<std::uint32_t>(static_cast<unsigned char>(tag[1])) << 16)
        | (static_cast<std::uint32_t>(static_cast<unsigned char>(tag[2])) << 8)
        | static_cast<std::uint32_t>(static_cast<unsigned char>(tag[3]));
}
// The colour palette index 0xFFFF resolves to. The colour seam carries no
// per-cell foreground — a slot is cached by cluster and shared by every cell
// that shows it — so the value is one neutral that reads on a dark theme and a
// light one alike.
constexpr ColorRGBA8 colorGlyphForeground { 0xB4, 0xB4, 0xB4, 0xFF };

// The code points a colour face is asked to draw before it is kept, tried in
// order until one it covers. Each is a colour glyph in every emoji face in
// circulation, so a face that lacks all four is not one this path is for.
constexpr std::array<std::uint32_t, 4> colorProbeCodePoints { 0x1F600, 0x2764, 0x1F44D, 0x1F60A };

// Whether a premultiplied BGRA raster has colour in it rather than coverage
// replicated across three channels. A glyph FreeType could not colour arrives
// in a BGRA container as an even grey, and `pixel_mode` reports colour for it.
//
// Which value the threshold takes changes nothing over a wide range, measured
// rather than assumed: swept against Noto Color Emoji, every value from 8 to
// 250 accepts the identical set of glyphs, and only 254 starts rejecting real
// emoji. A face whose palette is genuinely near-grey would change that, and
// the sweep is what a reader should redo rather than trust.
[[nodiscard]] bool rasterCarriesColour(const unsigned char* pixels, unsigned int width, unsigned int rows, long pitch)
{
    for (unsigned int y = 0; y < rows; ++y) {
        const unsigned char* row = pixels + static_cast<long>(y) * pitch;
        for (unsigned int x = 0; x < width; ++x) {
            const unsigned char* pixel = row + x * 4;
            if (pixel[3] <= 8)
                continue;
            const unsigned char high = std::max({ pixel[0], pixel[1], pixel[2] });
            const unsigned char low = std::min({ pixel[0], pixel[1], pixel[2] });
            if (high - low > 8)
                return true;
        }
    }
    return false;
}

// Whether a premultiplied BGRA raster has any ink in it.
//
// The painter's verdict on a COLRv1 glyph, where colour is the wrong question:
// the canvas holds exactly what the paint graph drew, in the palette the face
// chose, and a face may choose greys. Noto Color Emoji draws every family
// sequence as a grey keycap carrying black figures, so a colour test refuses
// the glyph the shaper composed, and the mono path, which has no glyph for a
// five-code-point cluster, leaves the cell blank. Only a graph that painted
// nothing is a decline.
[[nodiscard]] bool rasterCarriesInk(std::span<const std::uint8_t> premultipliedBGRA)
{
    for (std::size_t index = 3; index < premultipliedBGRA.size(); index += 4) {
        if (premultipliedBGRA[index] != 0)
            return true;
    }
    return false;
}

// One pre-multiplied BGRA pixel to the straight RGBA the seam is specified in.
// Blending pre-multiplied data as if it were straight darkens every partially
// transparent edge — which on an emoji is its whole outline.
void writeStraightRGBA(std::uint8_t* destination, std::uint32_t blue, std::uint32_t green, std::uint32_t red, std::uint32_t alpha)
{
    const auto unmultiply = [alpha](std::uint32_t channel) -> std::uint8_t {
        return alpha ? static_cast<std::uint8_t>(std::min<std::uint32_t>(255, (channel * 255 + alpha / 2) / alpha)) : 0;
    };
    destination[0] = unmultiply(red);
    destination[1] = unmultiply(green);
    destination[2] = unmultiply(blue);
    destination[3] = static_cast<std::uint8_t>(std::min<std::uint32_t>(255, alpha));
}

[[nodiscard]] bool hasSfntTable(FT_FaceRec_* face, FT_ULong tag)
{
    FT_ULong length = 0;
    return FT_Load_Sfnt_Table(face, tag, 0, nullptr, &length) == 0 && length > 0;
}

/// Which way a reference rule runs, which says which edges of its outline
/// are the stroke's.
enum class RuleAxis : std::uint8_t {
    Horizontal,
    Vertical,
};

/// A reference rule's stroke edges, in pixels from the pen.
struct StrokeEdges {
    double low = 0;
    double high = 0;
};

/// Reads one reference rule's stroke edges from its unhinted outline.
///
/// - Parameters:
///   - face: The face at the size being drawn.
///   - codePoint: The reference, U+2500 or U+2502.
///   - axis: Which way the rule runs; a horizontal rule's edges are on y.
/// - Returns: The edges, or nothing when the face does not draw the
///   reference as an outline.
std::optional<StrokeEdges> referenceStrokeEdges(FT_FaceRec_* face, std::uint32_t codePoint, RuleAxis axis)
{
    const FT_UInt index = FT_Get_Char_Index(face, codePoint);
    if (index == 0 || FT_Load_Glyph(face, index, FT_LOAD_NO_HINTING) != 0 || face->glyph->format != FT_GLYPH_FORMAT_OUTLINE)
        return std::nullopt;
    FT_BBox bbox;
    if (FT_Outline_Get_BBox(&face->glyph->outline, &bbox) != 0)
        return std::nullopt;
    if (axis == RuleAxis::Horizontal)
        return StrokeEdges { static_cast<double>(bbox.yMin) / 64.0, static_cast<double>(bbox.yMax) / 64.0 };
    return StrokeEdges { static_cast<double>(bbox.xMin) / 64.0, static_cast<double>(bbox.xMax) / 64.0 };
}

/// Measures the face's box-family translation at its current size.
///
/// Core decides the translation from the reference rules; this reads the
/// facts it needs. Measured per raster rather than cached: it runs only when
/// an atlas slot faults, and a cache keyed on anything less than the face and
/// its current size would hand a scaled row or a fallback face another face's
/// offset. Loads into the face's glyph slot, so it runs before the glyph
/// being drawn is loaded.
///
/// - Parameter face: The face about to draw a box-drawing piece.
/// - Returns: The translation for every box-drawing outline of the face.
Rendering::BoxFamilyPixelOffset measureBoxFamilyPixelOffset(FT_FaceRec_* face)
{
    const StrokeEdges horizontal = referenceStrokeEdges(face, 0x2500, RuleAxis::Horizontal).value_or(StrokeEdges {});
    const StrokeEdges vertical = referenceStrokeEdges(face, 0x2502, RuleAxis::Vertical).value_or(StrokeEdges {});
    return Rendering::boxFamilyPixelOffset(horizontal.low, horizontal.high, vertical.low, vertical.high);
}

} // namespace

const char* colorGlyphFormatName(ColorGlyphFormat format)
{
    switch (format) {
    case ColorGlyphFormat::COLRv1:
        return "COLRv1";
    case ColorGlyphFormat::COLRv0:
        return "COLRv0";
    case ColorGlyphFormat::CBDT:
        return "CBDT";
    case ColorGlyphFormat::Sbix:
        return "sbix";
    case ColorGlyphFormat::None:
    default:
        return "none";
    }
}

// The resolved run, opaque to the header so HarfBuzz stays out of it.
struct FreeTypeRasterizer::CascadeRouting {
    CascadeRouting(int fontPixelSize, std::string family, std::string bundledFontDirectory, Rendering::FontMetrics::FallbackSizing sizing)
        : inventory(fontPixelSize, std::move(family), std::move(bundledFontDirectory), sizing)
    {
    }

    LinuxFontInventory inventory;
    Rendering::Font::FontRoutingSession session;
};

struct ShapingFeatures {
    std::vector<hb_feature_t> run;
    bool hasUserFeatures { false };
};

FreeTypeRasterizer::FreeTypeRasterizer(int fontPixelSize)
    : FreeTypeRasterizer(fontPixelSize, std::string(), std::string(), std::string())
{
}

FreeTypeRasterizer::FreeTypeRasterizer(int fontPixelSize, std::string family)
    : FreeTypeRasterizer(fontPixelSize, std::move(family), std::string(), std::string())
{
}

namespace {

// Core's resolved list, mapped onto the shaper's own type.
//
// The composition — which tags a suppression names, and that the reader's
// specification is appended after it so an explicit feature beats the toggle —
// is `Rendering::resolveFontFeatures`, because the browser arm needs the same
// rule and only the output type differs. What is local is the mapping below:
// the `0..UINT_MAX` range makes each setting apply to the whole run, which is
// the only span a cell-oriented shaper asks about.
std::vector<hb_feature_t> shapingFeatureRunFor(Ligatures ligatures, const std::string& specification)
{
    std::vector<hb_feature_t> features;
    for (const Rendering::FontFeatureSetting& setting : Rendering::resolveFontFeatures(ligatures, specification)) {
        features.push_back(hb_feature_t {
            hb_tag_from_string(setting.tag.c_str(), -1),
            static_cast<std::uint32_t>(setting.value),
            0,
            std::numeric_limits<unsigned int>::max(),
        });
    }
    return features;
}

} // namespace

FreeTypeRasterizer::FreeTypeRasterizer(int fontPixelSize, std::string family, std::string fallbackFontName, std::string bundledFallbackPath, std::string bundledPrimaryPath, int deviceScale, int lineSpacingInPixels, int trackingInPixels, int uprightWeight, int boldWeight, double widthPercent, std::string fontVariations, std::string fontFeatures, Ligatures ligatures, Preferences::FontRoutePreferences fallbackPreferences)
    : m_fontPixelSize(fontPixelSize > 0 ? fontPixelSize : 1)
    // Not clamped at zero the way line spacing is: tightening a wide face is
    // the reason character spacing exists, and Core's floor keeps the column
    // drawable at the negative end.
    , m_trackingInPixels(trackingInPixels)
    , m_uprightWeight(uprightWeight)
    , m_boldWeight(boldWeight)
    , m_widthPercent(widthPercent)
    // Parsed once: the specification is configuration and cannot change without
    // a new rasterizer, so re-reading the grammar per glyph would spend a parse
    // on an answer fixed at construction.
    , m_shapingFeatures(std::make_unique<ShapingFeatures>(shapingFeatureRunFor(ligatures, fontFeatures), !fontFeatures.empty()))
    , m_deviceScale(deviceScale > 0 ? deviceScale : 1)
    , m_lineSpacingInPixels(lineSpacingInPixels > 0 ? lineSpacingInPixels : 0)
    , m_family(std::move(family))
    , m_fallbackFontName(std::move(fallbackFontName))
    , m_bundledFallbackPath(std::move(bundledFallbackPath))
    , m_bundledPrimaryPath(std::move(bundledPrimaryPath))
    , m_fallbackPreferences(std::move(fallbackPreferences))
    , m_userAxes(Rendering::parseFontVariationSpecification(fontVariations))
{
    if (FT_Init_FreeType(&m_library) != 0) {
        m_library = nullptr;
        return;
    }
    // loadMatchedFace() leaves m_face null on every failure path; a null
    // face renders nothing until a later setFont succeeds. The glyph
    // fallback face is optional — a null one just skips the Nerd Font tier.
    (void)loadMatchedFace();
    (void)loadFallbackFace();
    // Optional in the same way: a system with no emoji font installed answers
    // false from hasColorGlyphs, and no caller allocates a colour sheet for it.
    (void)loadEmojiFace();

    // After both faces, because the overhang fold reads the fallback's bounding
    // box and the cell reads the primary's advances. Nothing below reopens
    // either, so this is the only place the two can be measured.
    m_cellMetrics = computeCellMetrics();
    m_faceMetrics = computeFaceMetrics();
    m_glyphOverhang = computeGlyphOverhang(m_cellMetrics);
}

FreeTypeRasterizer::~FreeTypeRasterizer()
{
    // Each shaper holds a reference to its face, so it goes first: destroying a
    // face under a live hb_font leaves the shaper pointing at freed memory.
    if (m_textShaper)
        hb_font_destroy(m_textShaper);
    for (hb_font_t* styled : { m_boldTextShaper, m_italicTextShaper, m_boldItalicTextShaper }) {
        if (styled)
            hb_font_destroy(styled);
    }
    // The cascade inventory holds references to the primary faces, released
    // before this rasterizer's library.
    m_cascade.reset();
    if (m_face)
        FT_Done_Face(m_face);
    if (m_boldFace)
        FT_Done_Face(m_boldFace);
    if (m_italicFace)
        FT_Done_Face(m_italicFace);
    if (m_boldItalicFace)
        FT_Done_Face(m_boldItalicFace);
    if (m_fallbackFace)
        FT_Done_Face(m_fallbackFace);
    if (m_emojiShaper)
        hb_font_destroy(m_emojiShaper);
    if (m_emojiFace)
        FT_Done_Face(m_emojiFace);
    if (m_proportionalRegularShaper)
        hb_font_destroy(m_proportionalRegularShaper);
    if (m_proportionalBoldShaper)
        hb_font_destroy(m_proportionalBoldShaper);
    if (m_proportionalRegularFace)
        FT_Done_Face(m_proportionalRegularFace);
    if (m_proportionalBoldFace)
        FT_Done_Face(m_proportionalBoldFace);
    if (m_library)
        FT_Done_FreeType(m_library);
}

void FreeTypeRasterizer::ensureProportionalFaces()
{
    if (m_didLoadProportionalFaces)
        return;
    m_didLoadProportionalFaces = true;
    if (!m_library || !m_face)
        return;
    // The shipped proportional face first, by path, so every host draws a run
    // in the same face: fontconfig's answer for the sans-serif alias is a
    // property of the machine — DejaVu Sans on one, Noto Sans on the next —
    // and a golden minted against it records the machine, not the renderer.
    // fontconfig is the route only where the bundle is absent; its bold comes
    // through its own weight match, so a family without one degrades to what
    // it substitutes rather than to nothing. A pair that fails its pixel size
    // is dropped whole.
    const std::string bundledRegular = bundledPath(Rendering::bundledFontFile("Noto Sans"));
    const std::string bundledBold = bundledPath(Rendering::bundledBoldFontFile("Noto Sans"));
    FT_FaceRec_* regular = nullptr;
    FT_FaceRec_* bold = nullptr;
    if (!bundledRegular.empty() && FT_New_Face(m_library, bundledRegular.c_str(), 0, &regular) != 0)
        regular = nullptr;
    if (regular && !bundledBold.empty() && FT_New_Face(m_library, bundledBold.c_str(), 0, &bold) != 0)
        bold = nullptr;
    if (!regular) {
        regular = loadFaceByPattern("sans-serif");
        bold = loadFaceByPattern("sans-serif:bold");
    }
    if (regular && FT_Set_Pixel_Sizes(regular, 0, static_cast<FT_UInt>(m_fontPixelSize)) != 0) {
        FT_Done_Face(regular);
        regular = nullptr;
    }
    if (bold && FT_Set_Pixel_Sizes(bold, 0, static_cast<FT_UInt>(m_fontPixelSize)) != 0) {
        FT_Done_Face(bold);
        bold = nullptr;
    }
    if (!regular) {
        if (bold)
            FT_Done_Face(bold);
        return;
    }
    m_proportionalRegularFace = regular;
    // Each member owns one FreeType reference; a missing bold borrows regular
    // at use, never through a second owning member released by the destructor.
    m_proportionalBoldFace = bold;
    m_proportionalRegularShaper = hb_ft_font_create_referenced(regular);
    m_proportionalBoldShaper = bold ? hb_ft_font_create_referenced(bold) : nullptr;
}

FT_FaceRec_* FreeTypeRasterizer::monoFace(Rendering::FontFace face) const
{
    if (Rendering::isItalic(face)) {
        if (Rendering::isBold(face) && m_boldItalicFace)
            return m_boldItalicFace;
        if (m_italicFace)
            return m_italicFace;
    }
    return (Rendering::isBold(face) && m_boldFace) ? m_boldFace : m_face;
}

FT_FaceRec_* FreeTypeRasterizer::proportionalFace(Rendering::FontFace face) const
{
    return Rendering::isBold(face) && m_proportionalBoldFace
        ? m_proportionalBoldFace
        : m_proportionalRegularFace;
}

hb_font_t* FreeTypeRasterizer::proportionalShaper(Rendering::FontFace face) const
{
    if (Rendering::isBold(face) && m_proportionalBoldShaper)
        return m_proportionalBoldShaper;
    return m_proportionalRegularShaper;
}

bool FreeTypeRasterizer::hasProportionalFace() const
{
    const std::scoped_lock hold(m_proportionalLock);
    const_cast<FreeTypeRasterizer*>(this)->ensureProportionalFaces();
    return m_proportionalRegularShaper != nullptr;
}

int FreeTypeRasterizer::shapeProportionalRun(std::span<const std::uint32_t> codePoints, Rendering::FontFace face,
    std::span<Ubiquitty::ProportionalShapedGlyph> out)
{
    const std::scoped_lock hold(m_proportionalLock);
    ensureProportionalFaces();
    hb_font_t* shaper = proportionalShaper(face);
    if (!shaper || codePoints.empty() || out.empty())
        return 0;
    hb_buffer_t* buffer = hb_buffer_create();
    if (!buffer)
        return 0;
    for (std::size_t i = 0; i < codePoints.size(); ++i)
        hb_buffer_add(buffer, codePoints[i], static_cast<unsigned int>(i));
    hb_buffer_set_content_type(buffer, HB_BUFFER_CONTENT_TYPE_UNICODE);
    hb_buffer_set_direction(buffer, HB_DIRECTION_LTR);
    hb_buffer_set_script(buffer, HB_SCRIPT_COMMON);
    hb_buffer_set_language(buffer, hb_language_get_default());
    hb_shape(shaper, buffer, m_shapingFeatures->run.data(), static_cast<unsigned int>(m_shapingFeatures->run.size()));
    unsigned int glyphCount = 0;
    const hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buffer, &glyphCount);
    const hb_glyph_position_t* positions = hb_buffer_get_glyph_positions(buffer, &glyphCount);
    if (!infos || !positions || glyphCount == 0 || glyphCount > out.size()) {
        hb_buffer_destroy(buffer);
        return 0;
    }
    for (unsigned int i = 0; i < glyphCount; ++i) {
        out[i].glyph = glyphIndexOf(infos[i]);
        // 26.6 kept whole, not shifted: the shaper's fraction is where the
        // face put the next glyph, and the rasteriser draws at it.
        out[i].advanceInPixels = static_cast<float>(positions[i].x_advance) / 64.0f;
        out[i].offsetXInPixels = static_cast<float>(positions[i].x_offset) / 64.0f;
        out[i].offsetYInPixels = static_cast<float>(positions[i].y_offset) / 64.0f;
        out[i].cluster = static_cast<std::uint16_t>(std::min<unsigned int>(infos[i].cluster, 0xFFFFu));
    }
    hb_buffer_destroy(buffer);
    return static_cast<int>(glyphCount);
}

bool FreeTypeRasterizer::rasteriseProportionalRun(std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, Rendering::FontFace face,
    int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut)
{
    const std::scoped_lock hold(m_proportionalLock);
    ensureProportionalFaces();
    FT_FaceRec_* drawn = proportionalFace(face);
    if (!drawn)
        return false;
    return drawProportionalRunWithFace(drawn, glyphs, stripWidthInPixels, stripHeightInPixels, coverageOut);
}

bool FreeTypeRasterizer::rasteriseSizedProportionalRun(std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, Rendering::FontFace face,
    const Rendering::SizedMaster& master, int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut)
{
    if (master.isIdentity())
        return rasteriseProportionalRun(glyphs, face, stripWidthInPixels, stripHeightInPixels, coverageOut);
    const std::scoped_lock hold(m_proportionalLock);
    ensureProportionalFaces();
    FT_FaceRec_* drawn = proportionalFace(face);
    if (!drawn || !m_face)
        return false;
    // Measured before the resize, in case the proportional face is the
    // primary: the 1x strip's baseline, taken `scale` times.
    const Rendering::RasterScale scale = master.scale;
    const int baselineY = std::min(scale.scaled(primaryBaselineY(scale.unscaled(stripHeightInPixels))), stripHeightInPixels);
    FT_Size_RequestRec request {};
    request.type = FT_SIZE_REQUEST_TYPE_NOMINAL;
    request.height = static_cast<FT_Long>(std::lround(static_cast<double>(m_fontPixelSize) * 64.0 * scale.value()));
    if (FT_Request_Size(drawn, &request) != 0)
        return false;
    const bool isDrawn = drawProportionalRunWithFace(drawn, glyphs, stripWidthInPixels, stripHeightInPixels, coverageOut, master, baselineY);
    (void)FT_Set_Pixel_Sizes(drawn, 0, static_cast<FT_UInt>(m_fontPixelSize));
    return isDrawn;
}

bool FreeTypeRasterizer::drawProportionalRunWithFace(FT_FaceRec_* face, std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs,
    int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut, const Rendering::SizedMaster& master, std::optional<int> baselineOverride)
{
    if (stripWidthInPixels <= 0 || stripHeightInPixels <= 0)
        return false;
    const std::size_t expected = static_cast<std::size_t>(stripWidthInPixels) * static_cast<std::size_t>(stripHeightInPixels);
    if (coverageOut.size() != expected)
        return false;
    std::ranges::fill(coverageOut, std::uint8_t { 0 });
    if (!m_face || !face)
        return false;
    const int baselineY = baselineOverride ? *baselineOverride : primaryBaselineY(stripHeightInPixels);
    FT_Matrix stretch { static_cast<FT_Fixed>(std::lround(master.horizontalScale * 65536.0)), 0, 0, 65536 };
    FT_Matrix* const stretchOrNull = master.horizontalScale != 1.0 ? &stretch : nullptr;
    double penX = 0.0;
    bool didLoadGlyph = false;
    for (const Ubiquitty::ProportionalShapedGlyph& shaped : glyphs) {
        const double x = penX + static_cast<double>(shaped.offsetXInPixels);
        const double y = static_cast<double>(shaped.offsetYInPixels);
        const double wholeX = std::floor(x);
        const double wholeY = std::floor(y);
        // The fraction goes into the outline before it is rasterised, so the
        // ink is drawn at the shaper's position and not at the nearest whole
        // pixel. FreeType applies the delta after hinting, so the hinted shape
        // is the one that moves. Reset after, because the transform is a
        // property of the face and would ride into the next load.
        //
        // Light hinting, which snaps vertically and leaves the horizontal
        // alone. Normal hinting snaps stems sideways and widens them, and a
        // glyph whose ink has moved a pixel from where the shaper's advance
        // put it opens the gap on one side and closes it on the other — the
        // shaper measured the unhinted outline, and the drawn one has to be
        // that outline horizontally or the two disagree about every letter.
        FT_Vector delta {
            .x = static_cast<FT_Pos>(std::lround((x - wholeX) * 64.0)),
            .y = static_cast<FT_Pos>(std::lround((y - wholeY) * 64.0)),
        };
        FT_Set_Transform(face, stretchOrNull, &delta);
        const bool isLoaded = shaped.glyph != 0 && FT_Load_Glyph(face, shaped.glyph, FT_LOAD_TARGET_LIGHT) == 0
            && (face->glyph->format == FT_GLYPH_FORMAT_BITMAP || FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) == 0);
        FT_Set_Transform(face, nullptr, nullptr);
        if (isLoaded) {
            didLoadGlyph = true;
            const FT_GlyphSlot slot = face->glyph;
            const FT_Bitmap& bitmap = slot->bitmap;
            const int inkWidth = static_cast<int>(bitmap.width);
            const int inkHeight = static_cast<int>(bitmap.rows);
            const int startX = static_cast<int>(wholeX) + slot->bitmap_left;
            const int startY = baselineY - static_cast<int>(wholeY) - slot->bitmap_top;
            for (int sourceY = 0; sourceY < inkHeight; ++sourceY) {
                const int destinationY = startY + sourceY;
                if (destinationY < 0 || destinationY >= stripHeightInPixels)
                    continue;
                const unsigned char* source = bitmap.buffer + static_cast<long>(sourceY) * bitmap.pitch;
                for (int sourceX = 0; sourceX < inkWidth; ++sourceX) {
                    const int destinationX = startX + sourceX;
                    if (destinationX < 0 || destinationX >= stripWidthInPixels)
                        continue;
                    // The greater of the two, not a write: glyphs drawn at a
                    // fraction share edge pixels with their neighbours, and
                    // the later one overwriting the earlier would notch it.
                    std::uint8_t& destination = coverageOut[static_cast<std::size_t>(destinationY) * static_cast<std::size_t>(stripWidthInPixels)
                        + static_cast<std::size_t>(destinationX)];
                    destination = std::max(destination, static_cast<std::uint8_t>(source[sourceX]));
                }
            }
        }
        penX += static_cast<double>(shaped.advanceInPixels);
    }
    return didLoadGlyph;
}

// fc-match `pattern` (a family name) to a font file and FT_New_Face it into
// *outFace (UNSIZED — the caller sets the pixel size). The caller owns the
// returned face. Leaves *outFace null and returns false on any failure.
FT_FaceRec_* FreeTypeRasterizer::loadFaceByPattern(const char* pattern)
{
    if (!m_library)
        return nullptr;
    if (FcInit() != FcTrue)
        return nullptr;

    FcConfig* config = FcConfigGetCurrent();
    FcPattern* pat = FcNameParse(reinterpret_cast<const FcChar8*>(pattern));
    if (!pat)
        return nullptr;
    FcConfigSubstitute(config, pat, FcMatchPattern);
    FcDefaultSubstitute(pat);

    FcResult result = FcResultNoMatch;
    FcPattern* matched = FcFontMatch(config, pat, &result);
    FcPatternDestroy(pat);
    if (!matched || result != FcResultMatch) {
        if (matched)
            FcPatternDestroy(matched);
        return nullptr;
    }

    FcChar8* file = nullptr;
    int faceIndex = 0;
    const bool haveFile = FcPatternGetString(matched, FC_FILE, 0, &file) == FcResultMatch && file != nullptr;
    int index = 0;
    if (FcPatternGetInteger(matched, FC_INDEX, 0, &index) == FcResultMatch)
        faceIndex = index;

    FT_FaceRec_* face = nullptr;
    if (haveFile)
        FT_New_Face(m_library, reinterpret_cast<const char*>(file), faceIndex, &face);
    FcPatternDestroy(matched);
    return face;
}

// fc-match the monospace family, load into FreeType, and size to the font pixel
// size. The cell is DERIVED from the face (cellMetrics()). True on success (m_face
// non-null).
bool FreeTypeRasterizer::loadMatchedFace()
{
    const char* familyPattern = m_family.empty() ? "monospace" : m_family.c_str();
    if (m_bundledPrimaryPath.empty()) {
        m_face = loadFaceByPattern(familyPattern);
        // Confirm the family, as the fallback below confirms its own:
        // fontconfig answers every pattern with its nearest match, so a family
        // nobody installed comes back as some other typeface and the grid
        // draws that one instead, saying nothing. A snapshot case could then
        // name a face only one machine carries and mint goldens of the
        // substitute everywhere else. A named family that does not resolve is
        // reported and refused; the caller's fallback then applies.
        if (m_face && !m_family.empty()) {
            const char* got = m_face->family_name;
            if (got == nullptr || strcasecmp(got, m_family.c_str()) != 0) {
                std::fprintf(stderr, "ubiquitty-linux: font family '%s' is not installed; fontconfig offered '%s'\n",
                    m_family.c_str(), got != nullptr ? got : "?");
                FT_Done_Face(m_face);
                m_face = nullptr;
            }
        }
    } else if (FT_New_Face(m_library, m_bundledPrimaryPath.c_str(), 0, &m_face) != 0)
        m_face = nullptr;
    if (!m_face)
        return false;

    // Record the family/style for diagnostics.
    const char* family = m_face->family_name != nullptr ? m_face->family_name : "?";
    const char* style = m_face->style_name != nullptr ? m_face->style_name : "";
    std::snprintf(m_faceName, sizeof(m_faceName), "%s %s", family, style);

    if (FT_Set_Pixel_Sizes(m_face, 0, static_cast<FT_UInt>(m_fontPixelSize)) != 0) {
        FT_Done_Face(m_face);
        m_face = nullptr;
        return false;
    }
    queryVariationAxes();
    // The family's bold member, when the table names one as a separate file.
    // Only a static family does: a variable face carries its weights on the
    // `wght` axis and the table leaves its bold entry empty, so this is the
    // table's answer rather than a test of the axis.
    //
    // Loaded after queryVariationAxes and before measureCellAdvance for the
    // reason the comment below gives: the cell is the primary's, measured
    // before any coordinate moves, and the bold member never contributes to it
    // — a monospaced family's two members share an advance, and if they did not
    // the grid would be the regular's either way.
    const std::string bundledBold = bundledPath(Rendering::bundledBoldFontFile(m_family));
    if (!bundledBold.empty()) {
        if (FT_New_Face(m_library, bundledBold.c_str(), 0, &m_boldFace) != 0)
            m_boldFace = nullptr;
        if (m_boldFace && FT_Set_Pixel_Sizes(m_boldFace, 0, static_cast<FT_UInt>(m_fontPixelSize)) != 0) {
            FT_Done_Face(m_boldFace);
            m_boldFace = nullptr;
        }
    }
    // The italic members the table names, sized as the bold one is. They
    // never contribute to the cell, which is the upright's.
    const auto openStyleFile = [&](std::string_view file) -> FT_FaceRec_* {
        const std::string path = bundledPath(file);
        FT_FaceRec_* styleFace = nullptr;
        if (path.empty() || FT_New_Face(m_library, path.c_str(), 0, &styleFace) != 0)
            return nullptr;
        if (FT_Set_Pixel_Sizes(styleFace, 0, static_cast<FT_UInt>(m_fontPixelSize)) != 0) {
            FT_Done_Face(styleFace);
            return nullptr;
        }
        return styleFace;
    };
    m_italicFace = openStyleFile(Rendering::bundledItalicFontFile(m_family));
    m_boldItalicFace = openStyleFile(Rendering::bundledBoldItalicFontFile(m_family));
    m_doesItalicShareAxes = false;
    if (m_italicFace && m_axisCount > 0 && (m_italicFace->face_flags & FT_FACE_FLAG_MULTIPLE_MASTERS) != 0) {
        FT_MM_Var* italicAxes = nullptr;
        if (FT_Get_MM_Var(m_italicFace, &italicAxes) == 0 && italicAxes) {
            m_doesItalicShareAxes = italicAxes->num_axis == m_axisCount;
            for (unsigned i = 0; m_doesItalicShareAxes && i < m_axisCount; ++i)
                m_doesItalicShareAxes = static_cast<std::uint32_t>(italicAxes->axis[i].tag) == m_axisTag[i];
            FT_Done_MM_Var(m_library, italicAxes);
        }
    }
    // Before any weight axis is applied, so the cell is the face's own and not
    // whichever variation coordinate the last glyph happened to leave set.
    measureCellAdvance();
    // Built from the sized face, so it reports the metrics the raster will use —
    // the same reason the emoji shaper is built after its strike is selected.
    m_textShaper = hb_ft_font_create_referenced(m_face);
    return true;
}

// Sample printable ASCII and let Core pick the cell. FT_LOAD_ADVANCE_ONLY skips
// the outline, so the sample costs a metrics lookup per character rather than a
// glyph load; it runs once per sized face either way.
void FreeTypeRasterizer::measureCellAdvance()
{
    m_cellAdvanceInPixels = 0;
    m_facePitch = Rendering::FontMetrics::FacePitch::Fixed;
    if (!m_face)
        return;

    std::array<double, Rendering::FontMetrics::probeCharacterCount> advances {};
    for (int i = 0; i < Rendering::FontMetrics::probeCharacterCount; ++i) {
        const FT_ULong character = static_cast<FT_ULong>(Rendering::FontMetrics::firstProbeCharacter) + static_cast<FT_ULong>(i);
        // A character the face lacks leaves its entry at 0, which Core reads as
        // "not sampled" rather than as a zero-width cell.
        if (FT_Load_Char(m_face, character, FT_LOAD_DEFAULT | FT_LOAD_ADVANCE_ONLY) != 0)
            continue;
        advances[i] = static_cast<double>(m_face->glyph->advance.x) / 64.0;
    }

    // The pitch is read from the outline's own advances, not the hinted ones:
    // a hinter rounds each glyph's advance to whole pixels on its own (an hdmx
    // table may even list them per size), so a monospace face can sample two
    // widths a pixel apart and read as proportional.
    std::array<double, Rendering::FontMetrics::probeCharacterCount> designAdvances {};
    for (int i = 0; i < Rendering::FontMetrics::probeCharacterCount; ++i) {
        const FT_UInt glyphIndex = FT_Get_Char_Index(m_face, static_cast<FT_ULong>(Rendering::FontMetrics::firstProbeCharacter) + static_cast<FT_ULong>(i));
        FT_Fixed advance = 0;
        if (glyphIndex != 0 && FT_Get_Advance(m_face, glyphIndex, FT_LOAD_NO_HINTING, &advance) == 0)
            designAdvances[i] = static_cast<double>(advance) / 65536.0;
    }
    m_facePitch = Rendering::FontMetrics::facePitch(designAdvances);

    // Which advance the cell is cut to is Core's: the widest for a fixed
    // face, the digit's for a proportional one.
    m_cellAdvanceInPixels = roundToInt(Rendering::FontMetrics::cellAdvance(m_facePitch, advances));
}

// Load the glyph-fallback face. A configured fallback_font name selects the file
// this project ships when the bundle table carries that family; otherwise it is
// fc-matched, and the answer kept only if fontconfig resolved that family (fc
// always returns its nearest match, so an uninstalled name would silently
// substitute an arbitrary face). Empty/unresolved ⇒ the bundled Symbols Nerd
// Font. Sized to the primary's pixel size so glyphs share its scale.
bool FreeTypeRasterizer::loadFallbackFace()
{
    if (!m_library)
        return false;

    // A shipped family opens the file this project carries, before fontconfig
    // is asked — the route the primary face takes through
    // bundledFontPathForFamily. Asking fontconfig first lets a machine that has
    // its own copy of a shipped family installed decide what the fallback
    // draws: there the pattern resolves to that file, everywhere else the
    // bundled one is opened, and a golden the two machines share records
    // whichever of them minted it. Every symbol and glyph-fallback case moved
    // between two boxes for that reason while the primary's route was already
    // pinned.
    if (!m_fallbackFontName.empty()) {
        const std::string shipped = bundledPath(Rendering::bundledFontFile(m_fallbackFontName));
        if (!shipped.empty() && FT_New_Face(m_library, shipped.c_str(), 0, &m_fallbackFace) != 0)
            m_fallbackFace = nullptr;
        if (m_fallbackFace)
            m_bundledFallbackFaceSource = shipped;
    }

    if (!m_fallbackFace && !m_fallbackFontName.empty()
        && (m_fallbackFace = loadFaceByPattern(m_fallbackFontName.c_str())) != nullptr) {
        const char* got = m_fallbackFace->family_name;
        // Case-insensitive family-name confirmation: if fontconfig substituted a
        // different family, drop it so the bundled fallback is used instead.
        if (got == nullptr || strcasecmp(got, m_fallbackFontName.c_str()) != 0) {
            FT_Done_Face(m_fallbackFace);
            m_fallbackFace = nullptr;
        }
    }

    if (!m_fallbackFace && !m_bundledFallbackPath.empty()) {
        if (FT_New_Face(m_library, m_bundledFallbackPath.c_str(), 0, &m_fallbackFace) != 0)
            m_fallbackFace = nullptr;
        if (m_fallbackFace)
            m_bundledFallbackFaceSource = m_bundledFallbackPath;
    }

    if (!m_fallbackFace)
        return false;
    if (FT_Set_Pixel_Sizes(m_fallbackFace, 0, static_cast<FT_UInt>(m_fontPixelSize)) != 0) {
        FT_Done_Face(m_fallbackFace);
        m_fallbackFace = nullptr;
        m_bundledFallbackFaceSource.clear();
        return false;
    }
    return true;
}

void FreeTypeRasterizer::queryVariationAxes()
{
    m_wghtAxisIndex = -1;
    m_wdthAxisIndex = -1;
    m_axisCount = 0;
    if (!m_face || (m_face->face_flags & FT_FACE_FLAG_MULTIPLE_MASTERS) == 0)
        return; // not a variable font — weight is ignored, like a non-VF on macOS
    FT_MM_Var* mmVar = nullptr;
    if (FT_Get_MM_Var(m_face, &mmVar) != 0 || !mmVar)
        return;
    const unsigned axes = mmVar->num_axis < static_cast<FT_UInt>(maxVariationAxes) ? mmVar->num_axis : maxVariationAxes;
    m_axisCount = axes;
    const FT_ULong wghtTag = FT_MAKE_TAG('w', 'g', 'h', 't');
    const FT_ULong wdthTag = FT_MAKE_TAG('w', 'd', 't', 'h');
    for (unsigned i = 0; i < axes; ++i) {
        const FT_Var_Axis& axis = mmVar->axis[i];
        m_axisDefault[i] = static_cast<double>(axis.def) / 65536.0; // 16.16 fixed → design units
        // Every axis by tag and range, not only the two below: `font.variations`
        // can name any tag the face carries, and each clamps against its OWN
        // range — a `slnt` of -6 clamped to the weight axis's 100..800 would be
        // dropped to 100 and drawn as a weight.
        m_axisTag[i] = static_cast<std::uint32_t>(axis.tag);
        m_minCoordinate[i] = static_cast<double>(axis.minimum) / 65536.0;
        m_maxCoordinate[i] = static_cast<double>(axis.maximum) / 65536.0;
        if (axis.tag == wghtTag) {
            m_wghtAxisIndex = static_cast<int>(i);
            m_minWght = static_cast<double>(axis.minimum) / 65536.0;
            m_wghtDefault = static_cast<double>(axis.def) / 65536.0;
            m_maxWght = static_cast<double>(axis.maximum) / 65536.0;
        }
        if (axis.tag == wdthTag) {
            m_wdthAxisIndex = static_cast<int>(i);
            m_minWdth = static_cast<double>(axis.minimum) / 65536.0;
            m_wdthDefault = static_cast<double>(axis.def) / 65536.0;
            m_maxWdth = static_cast<double>(axis.maximum) / 65536.0;
        }
    }
    FT_Done_MM_Var(m_library, mmVar);
}

// The 'wght' coordinate a cell draws at.
//
// The number is Core's (`weightForFace`): an SGR 1:n weight, else on the bold
// face `font.bold_weight` or the heavier of the face's own bold and the
// upright, else the body variation, `font.weight`, or the upright weight.
// This arm only places it, clamped to what
// the face's fvar offers, so a face whose axis stops at 700 asked for 900 draws
// at 700 rather than refusing the setting.
double FreeTypeRasterizer::resolvedWeightAxis(Rendering::FontFace face, std::uint32_t sgrWeight) const
{
    if (m_wghtAxisIndex < 0)
        return m_wghtDefault; // no axis to place: the coordinate is unused
    const std::uint8_t sgr = static_cast<std::uint8_t>(sgrWeight > 7 ? 0 : sgrWeight);
    Rendering::Font::WeightSettings weights { m_uprightWeight, m_boldWeight };
    for (const Rendering::FontVariationSetting& axis : m_userAxes) {
        if (axis.tag == "wght") {
            weights.uprightVariation = axis.value;
            break;
        }
    }
    const double weight = Rendering::Font::weightForFace(face, sgr, weights);
    return std::clamp(weight, m_minWght, m_maxWght);
}

// The 'wdth' coordinate the configured width resolves to.
//
// The axis is percent-of-normal by specification, which is the same unit the
// setting is written in, so the percent goes on the axis directly rather than
// through the OS/2 class — `widthClassFromPercent` serves a matcher picking
// among static members, and a variable face has no members to pick.
//
// Clamped to what the face's fvar offers, for the reason the weight is: a
// setting past the axis draws at the end of it rather than being dropped.
double FreeTypeRasterizer::configuredWidthAxis() const
{
    if (m_wdthAxisIndex < 0)
        return m_wdthDefault;
    return std::clamp(Rendering::Font::widthForSetting(m_widthPercent), m_minWdth, m_maxWdth);
}

double FreeTypeRasterizer::effectiveWidthAxis() const
{
    for (const Rendering::FontVariationSetting& axis : m_userAxes) {
        if (axis.tag == "wdth")
            return std::clamp(axis.value, m_minWdth, m_maxWdth);
    }
    return configuredWidthAxis();
}

Rendering::WidthAxisRoom FreeTypeRasterizer::widthAxisRoom(Rendering::FontFace face) const
{
    if (!m_face || m_wdthAxisIndex < 0 || monoFace(face) != m_face)
        return {};
    return { effectiveWidthAxis(), m_maxWdth };
}

double FreeTypeRasterizer::cellAdvanceAtWidthAxis(Rendering::FontFace face, double coordinate)
{
    if (!m_face || m_wdthAxisIndex < 0 || monoFace(face) != m_face || !(coordinate > 0.0))
        return 0.0;
    applyWeightAxis(face, 0, coordinate);
    const FT_UInt glyphIndex = FT_Get_Char_Index(m_face, '0');
    double advance = 0.0;
    if (glyphIndex != 0 && FT_Load_Glyph(m_face, glyphIndex, FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP) == 0)
        advance = static_cast<double>(m_face->glyph->linearHoriAdvance) / 65536.0;
    applyWeightAxis(face, 0);
    return advance;
}

void FreeTypeRasterizer::applyWeightAxis(Rendering::FontFace face, std::uint32_t weight, double widthAxisOverride)
{
    // A face with a wdth axis and no wght one still has a coordinate to set, so
    // the guard is "no variable axes at all" rather than "no weight axis": the
    // narrower test would make a width setting inert on exactly the faces that
    // can honour it.
    // A user axis is reason enough to write even when neither named axis
    // exists: `font.variations` can name `slnt` on a face carrying no weight
    // and no width, and the narrower guard would make exactly that face inert.
    if (!m_face || m_axisCount == 0 || (m_wghtAxisIndex < 0 && m_wdthAxisIndex < 0 && m_userAxes.empty()))
        return;

    // The pair the named settings derive, then the user's axes folded over it
    // in Core: a tag in both takes the user's value, the precedence CSS gives
    // `font-variation-settings` over its high-level properties.
    //
    // Core's bold floor already includes the body variation. Applying the
    // user's `wght` again would replace that floor or an explicit bold weight.
    Rendering::FontVariationSettings derived;
    if (m_wdthAxisIndex >= 0)
        derived.push_back({ "wdth", configuredWidthAxis() });
    if (m_wghtAxisIndex >= 0)
        derived.push_back({ "wght", resolvedWeightAxis(face, weight) });
    // A family with no italic file whose upright carries a slant axis draws
    // its italic there, at the axis's most slanted end: the value its italic
    // instances name, and the one the CoreText arm places.
    if (Rendering::isItalic(face) && !m_italicFace) {
        for (unsigned i = 0; i < m_axisCount; ++i) {
            if (m_axisTag[i] == FT_MAKE_TAG('s', 'l', 'n', 't'))
                derived.push_back({ "slnt", m_minCoordinate[i] });
        }
    }
    //
    // A user `wght` reaches the third tier only. It overrides `font.weight` on
    // an upright cell and it is dropped on the other two: from the bold face,
    // because Core has already folded the body into the bold floor; and from
    // a cell carrying an SGR weight, because that is the running program naming
    // the weight of one run and a configured axis cannot outrank it. Every
    // tag besides wght — slnt, opsz, GRAD, custom — reaches both faces and
    // every cell, since none of them is the axis bold is expressed on.
    Rendering::FontVariationSettings userAxes = m_userAxes;
    const bool doesSGRNameWeight = weight >= 1 && weight <= 7;
    if (Rendering::isBold(face) || doesSGRNameWeight)
        std::erase_if(userAxes, [](const Rendering::FontVariationSetting& axis) { return axis.tag == "wght"; });
    Rendering::FontVariationSettings wanted = Rendering::mergeFontVariationSettings(derived, userAxes);
    // A sized master Core widened stands on the axis where it said, past the
    // configured and the user's width alike: that position was derived from them.
    if (widthAxisOverride > 0.0 && m_wdthAxisIndex >= 0) {
        std::erase_if(wanted, [](const Rendering::FontVariationSetting& axis) { return axis.tag == "wdth"; });
        wanted.push_back({ "wdth", widthAxisOverride });
    }

    // Every coordinate is restated from the face's defaults, because this API
    // does exactly that on each call: placing one axis alone resets every other
    // to its default, so the array below is the whole state of the face rather than an edit to it.
    std::array<double, maxVariationAxes> resolved {};
    for (unsigned i = 0; i < m_axisCount; ++i)
        resolved[i] = m_axisDefault[i];
    for (const Rendering::FontVariationSetting& axis : wanted) {
        const std::uint32_t tag = variationAxisTag(axis.tag);
        for (unsigned i = 0; i < m_axisCount; ++i) {
            if (m_axisTag[i] != tag)
                continue;
            // Clamped to the axis's own range: a value past the end draws at the
            // end rather than being dropped, so a hand-written specification
            // lands somewhere legible.
            resolved[i] = std::clamp(axis.value, m_minCoordinate[i], m_maxCoordinate[i]);
        }
    }

    // Keyed on the whole COORDINATE SET rather than on the request: two
    // different requests can resolve to one position, and re-setting it costs a
    // shaper invalidation per run for no change in what is drawn. The whole set
    // rather than the weight, because a user axis can move a coordinate the
    // weight did not.
    if (m_didApplyAxes && std::equal(resolved.begin(), resolved.begin() + m_axisCount, m_lastAppliedCoords.begin()))
        return;
    std::copy(resolved.begin(), resolved.begin() + m_axisCount, m_lastAppliedCoords.begin());
    m_didApplyAxes = true;
    ++m_axisGeneration;

    FT_Fixed coords[maxVariationAxes];
    for (unsigned i = 0; i < m_axisCount; ++i)
        coords[i] = static_cast<FT_Fixed>(resolved[i] * 65536.0);
    FT_Set_Var_Design_Coordinates(m_face, m_axisCount, coords);
    if (m_doesItalicShareAxes)
        FT_Set_Var_Design_Coordinates(m_italicFace, m_axisCount, coords);
}

// Derive the cell + decoration metrics from the FT face at its pixel size: the
// widest printable-ASCII advance = cell width, line height = cell height,
// ascender = baseline, FT underline_position/thickness (font units scaled by
// pixelSize/units_per_EM) = underline. No loaded face ⇒ the Unifont 8×16 metrics.
//
// Runs before any weight axis is applied, so the 'x' raster below is the face's
// own. Read on demand it would instead be whichever variation coordinate the
// last drawn glyph left set, which makes a bold run on screen a thing the
// strike position depends on.
Rendering::CellMetrics FreeTypeRasterizer::computeCellMetrics() const
{
    if (!m_face)
        return m_unifontFallback.cellMetrics();

    Rendering::CellMetrics m;

    // Cell width: measured with the face (measureCellAdvance), not here — this
    // is read on the frame path. A face that reported nothing usable leaves the
    // font pixel size standing in.
    //
    // The PITCH, tracking folded in, which is what the grid lays out on and
    // what the same field carries on macOS. The ink advance it was derived from
    // stays the face's own and reaches the slot through `glyphOverhang`: a slot
    // widened by tracking would stretch the glyph rather than space it, and one
    // narrowed by negative tracking would clip it.
    const double inkAdvance = m_cellAdvanceInPixels > 0 ? m_cellAdvanceInPixels : m_fontPixelSize;
    m.cellWidth = static_cast<float>(
        Rendering::FontMetrics::trackedCellAdvance(inkAdvance, static_cast<double>(m_trackingInPixels)));

    // Cell height: the face's line height (size->metrics.height, 26.6). If
    // the face reports 0 (rare bitmap strikes), use ascender - descender
    // (descender is negative, so subtract it).
    const FT_Size_Metrics& sm = m_face->size->metrics;
    int cellHeight = roundToInt(static_cast<double>(sm.height) / 64.0);
    if (cellHeight <= 0)
        cellHeight = roundToInt(static_cast<double>(sm.ascender - sm.descender) / 64.0);
    if (cellHeight <= 0)
        cellHeight = m_fontPixelSize;

    // Baseline from the cell top = the ascender (26.6).
    int baseline = roundToInt(static_cast<double>(sm.ascender) / 64.0);
    if (baseline <= 0 || baseline > cellHeight)
        baseline = cellHeight > 1 ? cellHeight - 1 : cellHeight;

    // The face's own height rather than ascent + descent: a face may set a line
    // height wider than its type, and taking the sum would close that gap. The
    // descent handed to Core is therefore what the face leaves below the
    // baseline within its own line, not its descender.
    const Rendering::CellLayout layout
        = Rendering::cellLayout(static_cast<float>(baseline), static_cast<float>(cellHeight - baseline), m_lineSpacingInPixels);
    m.cellHeight = layout.cellHeight;
    m.deviceScale = static_cast<float>(m_deviceScale);
    m.baselineFromTop = layout.baselineFromTop;
    cellHeight = static_cast<int>(layout.cellHeight);
    baseline = static_cast<int>(layout.baselineFromTop);

    // The face rule policy (RuleGeometry.h): the face's underline weight in
    // font units scaled to its pixel size, and the space below its baseline —
    // the descender plus whatever the line height leaves beyond ascent and
    // descent, which is the leading CoreText reports for the same face.
    Rendering::RuleFaceMetrics faceRules;
    if (m_face->units_per_EM > 0)
        faceRules.underlineThickness = static_cast<float>(
            static_cast<double>(m_face->underline_thickness) * m_fontPixelSize / m_face->units_per_EM);
    faceRules.descent = static_cast<float>(-static_cast<double>(sm.descender) / 64.0);
    faceRules.leading = static_cast<float>(std::max(0.0, (static_cast<double>(sm.height) - static_cast<double>(sm.ascender - sm.descender)) / 64.0));
    const Rendering::RuleGeometry rules = Rendering::ruleGeometry(static_cast<float>(m_fontPixelSize), static_cast<float>(m_deviceScale), faceRules);
    m.underlineThickness = rules.underlineThickness;

    // baseline + drop must stay inside the cell, which is the one bound Core
    // cannot apply: it does not know the box.
    float underlineDrop = rules.underlineDrop;
    const float maxDrop = static_cast<float>(cellHeight - baseline - 1);
    if (maxDrop > 0.0f && underlineDrop > maxDrop)
        underlineDrop = maxDrop;
    m.underlineDrop = underlineDrop;

    // A straight rule rises off the baseline by half a device pixel per 12 of
    // type, which is what macOS draws (FontGeometry.swift: 0.5 * deviceScale *
    // fontSize / 12, with its font size in points and this one already in device
    // pixels, so the two scale terms cancel). A face that leaves this at zero
    // draws its rule ON the baseline while the same text on Unifont lifts —
    // within one frontend, decided by which face happened to load.
    m.underlineStrokeLift = static_cast<float>(m_fontPixelSize) / 24.0f;

    m.underlineCurlyThickness = rules.curlyThickness;
    m.strikeThickness = rules.strikeThickness;

    // x-height: the bitmap height of 'x', which every face has and none decorates, so
    // the strike (baseline - xHeight*0.5) lands mid-glyph. Fall back to half
    // the baseline if 'x' is missing.
    int xHeight = 0;
    if (FT_Load_Char(m_face, 'x', FT_LOAD_RENDER) == 0 && m_face->glyph->bitmap.rows > 0)
        xHeight = static_cast<int>(m_face->glyph->bitmap.rows);
    m.xHeight = Rendering::xHeightForStrike(static_cast<float>(xHeight), static_cast<float>(baseline));

    // Decoration skip-ink is off: the Unifont path is a 1-bit bitmap face whose
    // coverage has no partial ink for the cut to follow.
    m.skipInk = false;
    return m;
}

Rendering::FaceMetrics FreeTypeRasterizer::computeFaceMetrics() const
{
    // No face of our own means the Unifont fallback is what draws, so its
    // measurements are the ones a consumer must have: reporting zeros here
    // would read as "no type-relative geometry" for a tier that has some.
    if (!m_face)
        return m_unifontFallback.faceMetrics();

    Rendering::FaceMetrics face;
    face.fontSize = m_fontPixelSize;
    const FT_Size_Metrics& sized = m_face->size->metrics;
    face.ascent = static_cast<float>(static_cast<double>(sized.ascender) / 64.0);
    // The descender is negative in FreeType's convention and the field is a
    // distance, so it is negated rather than subtracted from something.
    face.descent = static_cast<float>(-static_cast<double>(sized.descender) / 64.0);
    // The same integer halving every other rasterizer uses. A face that split
    // it differently would sit a pixel off the others at odd spacings.
    face.lineGapTopInPixels = static_cast<float>(m_lineSpacingInPixels / 2);

    // The bracket's ink box, baseline-relative and y-up in FreeType's metrics,
    // which is why the top is `horiBearingY` and the bottom is what the height
    // leaves below it. Unhinted, because the mark is geometry rather than text:
    // a hinted box moves with the pixel grid and would make the mark's centre
    // depend on the size in a way the face's design does not.
    if (FT_Load_Char(m_face, '[', FT_LOAD_NO_HINTING) == 0 && m_face->glyph != nullptr) {
        const FT_Glyph_Metrics& bracket = m_face->glyph->metrics;
        const double top = static_cast<double>(bracket.horiBearingY) / 64.0;
        const double bottom = static_cast<double>(bracket.height) / 64.0 - top;
        face.bracketInkTopInPixels = static_cast<float>(std::max(0.0, top));
        face.bracketInkBottomInPixels = static_cast<float>(std::max(0.0, bottom));
    }
    return face;
}

// The font-overhang metrics computeGlyphSlot folds into the overflow-pass slot
// margins. Bounding boxes are the face's GLOBAL bbox (face->bbox) scaled to atlas
// px — baseline-relative, y-up. No real face ⇒ zero overhang (slot = cell box).
// `cell` is the freshly measured cell rather than the stored one, so the pair
// cannot be assembled out of order.
Rendering::GlyphOverhangInputs FreeTypeRasterizer::computeGlyphOverhang(const Rendering::CellMetrics& m) const
{
    Rendering::GlyphOverhangInputs in;
    if (!m_face)
        return in;

    const FT_Size_Metrics& sm = m_face->size->metrics;
    // The face's own advance rather than the tracked pitch in `m.cellWidth`:
    // this sizes the slot, and a slot holds ink. Tracking moves the column the
    // ink sits in and leaves the glyph the size the face drew it.
    in.advanceWidth = m_cellAdvanceInPixels > 0 ? m_cellAdvanceInPixels : m_fontPixelSize;
    in.ascent = static_cast<double>(sm.ascender) / 64.0; // 26.6 -> px
    in.descent = static_cast<double>(-sm.descender) / 64.0; // descender is negative
    in.lineHeight = m.cellHeight;

    const double primaryScale = static_cast<double>(m_fontPixelSize) / (m_face->units_per_EM > 0 ? m_face->units_per_EM : 1);
    in.primaryBboxX = m_face->bbox.xMin * primaryScale;
    in.primaryBboxY = m_face->bbox.yMin * primaryScale;
    in.primaryBboxWidth = (m_face->bbox.xMax - m_face->bbox.xMin) * primaryScale;
    in.primaryBboxHeight = (m_face->bbox.yMax - m_face->bbox.yMin) * primaryScale;

    // The Nerd Font fallback has its OWN em, so scale by its units_per_EM. This is
    // the wide overhang the half-excess fold sizes the slot to.
    if (m_fallbackFace) {
        const double fallbackScale = static_cast<double>(m_fontPixelSize) / (m_fallbackFace->units_per_EM > 0 ? m_fallbackFace->units_per_EM : 1);
        in.hasFallback = true;
        in.fallbackBboxX = m_fallbackFace->bbox.xMin * fallbackScale;
        in.fallbackBboxY = m_fallbackFace->bbox.yMin * fallbackScale;
        in.fallbackBboxWidth = (m_fallbackFace->bbox.xMax - m_fallbackFace->bbox.xMin) * fallbackScale;
        in.fallbackBboxHeight = (m_fallbackFace->bbox.yMax - m_fallbackFace->bbox.yMin) * fallbackScale;
    }
    return in;
}

// The primary face's baseline = its rounded ascender (matching cellMetrics()),
// clamped into the slot. Fallback glyphs share this baseline so every face lines
// up with the text + underline/strike rules. m_face must be non-null.
int FreeTypeRasterizer::primaryBaselineY(int slotHeight) const
{
    const FT_Size_Metrics& sizeMetrics = m_face->size->metrics;
    int baselineY = roundToInt(static_cast<double>(sizeMetrics.ascender) / 64.0);
    // In a TALLER overflow slot the cell box is vertically centered, so shift the
    // baseline down by that margin to keep the glyph on the cell baseline. A
    // cell-tight slot (slotHeight == cellHeight) ⇒ no shift.
    int cellHeight = roundToInt(static_cast<double>(sizeMetrics.height) / 64.0);
    if (cellHeight <= 0)
        cellHeight = roundToInt(static_cast<double>(sizeMetrics.ascender - sizeMetrics.descender) / 64.0);
    if (cellHeight > 0 && slotHeight > cellHeight)
        baselineY += (slotHeight - cellHeight) / 2;
    if (baselineY <= 0 || baselineY > slotHeight)
        baselineY = slotHeight > 1 ? slotHeight - 1 : slotHeight;
    return baselineY;
}

// Load + render `codePoint` from `face` and center-blit its coverage into the
// slot at `baselineY`. Returns false (so the caller tries the next tier) when
// the face is null, lacks the glyph (FT_Get_Char_Index == 0 / ".notdef"), or
// FreeType fails to load/render it. A blank (empty bitmap, e.g. space) is a
// valid success — the pre-cleared buffer is already correct.
bool FreeTypeRasterizer::renderGlyphFromFace(FT_FaceRec_* face, std::uint32_t codePoint, int baselineY, int slotWidth, int slotHeight, std::uint8_t* coverageOut, const Rendering::SizedMaster& master)
{
    return renderGlyphAtCurrentCoordinates(face, codePoint, baselineY, slotWidth, slotHeight, coverageOut, master);
}

bool FreeTypeRasterizer::renderGlyphAtCurrentCoordinates(FT_FaceRec_* face, std::uint32_t codePoint, int baselineY, int slotWidth, int slotHeight, std::uint8_t* coverageOut, const Rendering::SizedMaster& master)
{
    if (!face)
        return false;
    const unsigned donor = Rendering::stemDonor(codePoint);
    const unsigned drawnCodePoint = donor ? donor : codePoint;
    const FT_UInt glyphIndex = FT_Get_Char_Index(face, drawnCodePoint);
    if (glyphIndex == 0)
        return false;
    const bool isUnhinted = Rendering::rastersFromUnhintedOutline(codePoint);
    const Rendering::BoxFamilyPixelOffset familyOffset = isUnhinted ? measureBoxFamilyPixelOffset(face) : Rendering::BoxFamilyPixelOffset {};
    // The stretch across is applied after hinting, so the hinted stems are the
    // ones that widen, by exactly the master's horizontal scale. Reset after,
    // because the transform is a property of the face and would ride into the
    // next load.
    const bool isStretched = master.horizontalScale != 1.0;
    if (isStretched) {
        FT_Matrix stretch { static_cast<FT_Fixed>(std::lround(master.horizontalScale * 65536.0)), 0, 0, 65536 };
        FT_Set_Transform(face, &stretch, nullptr);
    }
    const bool isLoaded = FT_Load_Glyph(face, glyphIndex, isUnhinted ? FT_LOAD_NO_HINTING : FT_LOAD_DEFAULT) == 0;
    if (isStretched)
        FT_Set_Transform(face, nullptr, nullptr);
    if (!isLoaded)
        return false;
    const Rendering::RasterScale rasterScale = master.scale;
    const int cellHeight = std::min(slotHeight, rasterScale.scaled(roundToInt(cellMetrics().cellHeight)));
    const int marginY = (slotHeight - cellHeight) / 2;
    const int marginX = std::max(0, (slotWidth - master.horizontalMagnification().scaled(roundToInt(m_cellAdvanceInPixels))) / 2);
    const auto& metrics = face->glyph->metrics;
    const auto fit = Rendering::fitTilingGlyph(drawnCodePoint,
        static_cast<double>(metrics.horiBearingY - metrics.height) / 64.0,
        static_cast<double>(metrics.height) / 64.0, slotHeight - marginY - cellHeight, cellHeight);
    const bool outline = face->glyph->format == FT_GLYPH_FORMAT_OUTLINE;
    if (fit.isApplicable && outline) {
        FT_Matrix transform { 65536, 0, 0, static_cast<FT_Fixed>(std::lround(fit.verticalScale * 65536)) };
        FT_Vector translation { static_cast<FT_Pos>(marginX * 64),
            static_cast<FT_Pos>(std::lround(fit.baseline * fit.verticalScale * 64)) };
        FT_Outline_Transform(&face->glyph->outline, &transform);
        FT_Outline_Translate(&face->glyph->outline, translation.x, translation.y);
    }
    if (isUnhinted && outline)
        FT_Outline_Translate(&face->glyph->outline, static_cast<FT_Pos>(std::lround(familyOffset.x * 64)),
            static_cast<FT_Pos>(std::lround(familyOffset.y * 64)));
    // A master's pen is Core's (sizedMasterPen), its fraction moved into the
    // outline before it is rasterised: the pen's own, and the master's shift
    // down, which Core folds into the pen across. A glyph the face does not
    // place keeps its centring, by the ink it would have drawn unshifted, and
    // takes the shift across as a whole-pixel move of that placement plus its
    // fraction moved into the outline, so it stands where Core's shift says to
    // the same 64th.
    std::optional<Rendering::SubpixelPhase> masterPen;
    struct InkPlacement {
        int left = 0;
        int width = 0;
        int wholeShift = 0;
    };
    std::optional<InkPlacement> unshiftedInk;
    const bool isShifted = !master.isIdentity() && outline && !fit.isApplicable;
    if (isShifted && Rendering::keepsFacePlacement(codePoint)) {
        const double advance = static_cast<double>(face->glyph->advance.x) / 64.0;
        masterPen = Rendering::sizedMasterPen(slotWidth, advance, master);
        FT_Outline_Translate(&face->glyph->outline, static_cast<FT_Pos>(masterPen->phase * 64 / Rendering::sizedMasterPenGrid),
            -static_cast<FT_Pos>(std::lround(64.0 * master.shiftY)));
    } else if (isShifted && (master.shiftX != 0.0 || master.shiftY != 0.0)) {
        // The pixels the outline would cover unshifted, which FreeType takes
        // from the control box rounded outward.
        FT_BBox bbox;
        FT_Outline_Get_CBox(&face->glyph->outline, &bbox);
        const long leftColumn = bbox.xMin >> 6;
        const long rightColumn = (bbox.xMax + 63) >> 6;
        const double wholeShift = std::floor(master.shiftX);
        unshiftedInk = InkPlacement { static_cast<int>(leftColumn), static_cast<int>(rightColumn - leftColumn), static_cast<int>(wholeShift) };
        FT_Outline_Translate(&face->glyph->outline, static_cast<FT_Pos>(std::lround(64.0 * (master.shiftX - wholeShift))),
            -static_cast<FT_Pos>(std::lround(64.0 * master.shiftY)));
    }
    if (face->glyph->format != FT_GLYPH_FORMAT_BITMAP && FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) != 0)
        return false;

    const FT_GlyphSlot slot = face->glyph;
    const FT_Bitmap& bitmap = slot->bitmap;
    const int bw = static_cast<int>(bitmap.width);
    const int bh = static_cast<int>(bitmap.rows);
    if (bw == 0 || bh == 0)
        return true;

    // bitmap_top = rows of ink above the baseline (top row at baselineY -
    // bitmap_top). Core places it horizontally; the bounds checks clamp a wide
    // glyph's overflow instead of spilling into neighbours.
    const int destTop = fit.isApplicable ? slotHeight - slot->bitmap_top : baselineY - slot->bitmap_top;
    // An unhinted load keeps the advance's fraction, which the hinted one
    // rounds; the pen is the whole-pixel advance either way, so an unhinted
    // piece is placed exactly where the hinted one was.
    const double unroundedAdvance = static_cast<double>(slot->advance.x) / 64.0;
    const double penAdvance = isUnhinted ? std::round(unroundedAdvance) : unroundedAdvance;
    // A proportional primary's letter stands at the slot's pen: the row's
    // layout places the slot at the letter's own pen, so the ink keeps the
    // face's bearing from the margin rather than being centred in a cell it
    // was never cut for. A doubled master of such a letter stands at the
    // magnified pen, the cell slot's margin scaled as the builder scales it
    // when it steps the master's windows from the letter's pen; the margin
    // this slot computes for itself is the centring one and differs from it
    // by the headroom column's half, which the whole-pixel pen must not carry.
    const bool isProportionalLetter = m_facePitch == Rendering::FontMetrics::FacePitch::Proportional
        && (face == m_face || face == m_boldFace || face == m_italicFace || face == m_boldItalicFace)
        && !Rendering::keepsFacePlacement(codePoint);
    const Rendering::RasterScale across = master.horizontalMagnification();
    const int letterPenX = across.scaled(std::max(0, (across.unscaled(slotWidth) - roundToInt(m_cellAdvanceInPixels)) / 2));
    const int inkLeft = unshiftedInk ? unshiftedInk->left : slot->bitmap_left;
    const int inkWidth = unshiftedInk ? unshiftedInk->width : bw;
    const int unshiftedPenX = fit.isApplicable ? slot->bitmap_left + (outline ? 0 : marginX)
        : masterPen                            ? masterPen->snappedPenX + slot->bitmap_left
        : isProportionalLetter                 ? letterPenX + inkLeft
                                               : Rendering::rasterLeftInSlot(codePoint, slotWidth, inkLeft, inkWidth, penAdvance);
    // The shifted bitmap's own left edge replaces the unshifted one the
    // placement was made for, which carries the fraction.
    const int penX = unshiftedInk ? unshiftedPenX + unshiftedInk->wholeShift + slot->bitmap_left - inkLeft : unshiftedPenX;
    const bool isFittedBitmap = fit.isApplicable && !outline;
    for (int row = 0; row < (isFittedBitmap ? slotHeight : bh); ++row) {
        const int destinationY = isFittedBitmap ? row : destTop + row;
        if (destinationY < 0 || destinationY >= slotHeight)
            continue;
        const int sy = isFittedBitmap
            ? static_cast<int>(std::floor(slot->bitmap_top - ((slotHeight - destinationY - 0.5) / fit.verticalScale - fit.baseline)))
            : row;
        if (sy < 0 || sy >= bh) {
            continue;
        }
        const unsigned char* src = bitmap.buffer + static_cast<long>(sy) * bitmap.pitch;
        for (int sx = 0; sx < bw; ++sx) {
            const int dx = penX + sx;
            if (dx < 0 || dx >= slotWidth)
                continue;
            coverageOut[static_cast<std::size_t>(destinationY) * slotWidth + dx] = bitmap.pixel_mode == FT_PIXEL_MODE_MONO
                ? ((src[sx / 8] & (0x80 >> (sx % 8))) ? 255 : 0)
                : src[sx];
        }
    }
    if (Rendering::tilesOnTextPen(codePoint)) {
        Rendering::TilingCoverage({ coverageOut, static_cast<std::size_t>(slotWidth) * slotHeight },
            slotWidth, slotHeight, marginX, slotWidth - marginX, marginY, marginY + cellHeight)
            .finish(codePoint, drawnCodePoint);
    }
    return true;
}

FT_FaceRec_* FreeTypeRasterizer::cascadeFace(std::uint32_t codePoint)
{
    const unsigned donor = Rendering::stemDonor(codePoint);
    const std::uint32_t routed = donor ? donor : codePoint;
    return cascadeFace(std::span<const std::uint32_t>(&routed, 1));
}

FT_FaceRec_* FreeTypeRasterizer::cascadeFace(std::span<const std::uint32_t> codePoints)
{
    if (!m_library || !m_face || codePoints.empty())
        return nullptr;
    if (!m_cascade) {
        // The directory the fallback face was handed, so a family this project
        // ships opens the shipped file here exactly as it does for the primary.
        const std::size_t slash = m_bundledFallbackPath.find_last_of('/');
        std::string directory = slash == std::string::npos ? std::string() : m_bundledFallbackPath.substr(0, slash);
        m_cascade = std::make_unique<CascadeRouting>(m_fontPixelSize, m_family, std::move(directory),
            m_fallbackPreferences.shouldMatchFallbackSize ? Rendering::FontMetrics::FallbackSizing::MatchPrimary : Rendering::FontMetrics::FallbackSizing::Nominal);
        m_cascade->inventory.setPrimaryFaces(m_face, m_boldFace);
    }
    Rendering::Font::FontFallbackPolicy policy(m_cascade->inventory,
        { m_cascade->session.han, m_cascade->session.script, m_cascade->session.generic, m_cascade->session.emoji,
            m_cascade->session.symbol, m_cascade->session.rangeMap, m_cascade->session.negative });
    Rendering::Font::FontRequest request;
    request.codePoints = codePoints;
    request.script = Rendering::Font::classifyScript(codePoints.front());
    request.presentation = Rendering::Font::Presentation::Text;
    // Upright regular, whatever the cell's style: a fallback face is drawn
    // unweighted, as the glyph-fallback tier is, so a style in the key would
    // only split one answer across four cache entries.
    request.style = Rendering::Font::FontStyle::Regular;
    request.preferenceGeneration = m_fallbackPreferences.generation;
    const Rendering::Font::GlyphRoute route = policy.route(request, m_fallbackPreferences.view());
    if (Rendering::Font::isMissing(route) || route.font == m_cascade->inventory.primaryFont(Rendering::Font::FontStyle::Regular, 0))
        return nullptr;
    return m_cascade->inventory.faceFor(route.font);
}

bool FreeTypeRasterizer::rasterizeCluster(const std::uint32_t* codePoints, int count, Rendering::FontFace face, std::uint32_t weight, int slotWidth, int slotHeight, std::uint8_t* coverageOut)
{
    const auto overprint = [&] { return GlyphRasterizer::rasterizeCluster(codePoints, count, face, weight, slotWidth, slotHeight, coverageOut); };
    if (count < 2 || !codePoints || !m_face || slotWidth <= 0 || slotHeight <= 0)
        return overprint();
    const std::uint32_t base = codePoints[0];
    if (Rendering::tilesOnTextPen(base) || FT_Get_Char_Index(monoFace(face), base) != 0
        || (m_fallbackFace && FT_Get_Char_Index(m_fallbackFace, base) != 0))
        return overprint();
    // A selector or joiner carries no glyph and its presentation is already
    // decided, so it neither routes the cluster nor makes one: a base with
    // only those after it draws exactly as it does alone.
    std::vector<std::uint32_t> routed;
    routed.reserve(static_cast<std::size_t>(count));
    for (int index = 0; index < count; ++index) {
        if (!Unicode::Width::isInvisibleFormat(codePoints[index]))
            routed.push_back(codePoints[index]);
    }
    if (routed.size() < 2)
        return overprint();
    FT_FaceRec_* const cascaded = cascadeFace(std::span<const std::uint32_t>(routed));
    if (!cascaded)
        return overprint();

    const std::unique_ptr<hb_font_t, decltype(&hb_font_destroy)> shaper(hb_ft_font_create_referenced(cascaded), hb_font_destroy);
    const std::unique_ptr<hb_buffer_t, decltype(&hb_buffer_destroy)> buffer(hb_buffer_create(), hb_buffer_destroy);
    for (int index = 0; index < count; ++index)
        hb_buffer_add(buffer.get(), codePoints[index], static_cast<unsigned int>(index));
    // Each glyph keeps the index of the character it came from, so a mark's
    // combining class is read from the mark rather than from its base.
    hb_buffer_set_cluster_level(buffer.get(), HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
    hb_buffer_set_content_type(buffer.get(), HB_BUFFER_CONTENT_TYPE_UNICODE);
    hb_buffer_guess_segment_properties(buffer.get());
    hb_shape(shaper.get(), buffer.get(), nullptr, 0);
    unsigned int glyphCount = 0;
    const hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buffer.get(), &glyphCount);
    const hb_glyph_position_t* positions = hb_buffer_get_glyph_positions(buffer.get(), nullptr);
    if (!glyphCount || !infos || !positions)
        return overprint();

    std::ranges::fill(std::span(coverageOut, static_cast<std::size_t>(slotWidth) * slotHeight), std::uint8_t { 0 });
    const int baselineY = primaryBaselineY(slotHeight);
    // The pen starts where the base's ink lands when it is drawn alone,
    // centred in the slot, so a marked cell and its unmarked twin agree.
    double penX = 0.0;
    int baseInkLeft = 0;
    int baseInkWidth = 0;
    // The ink the cluster has stacked so far, which an unattached mark clears.
    int stackTop = 0;
    int stackBottom = 0;
    const int markGap = std::max(1, static_cast<int>(std::lround(m_fontPixelSize / 16.0)));
    hb_unicode_funcs_t* const unicode = hb_unicode_funcs_get_default();
    bool didDraw = false;
    for (unsigned int index = 0; index < glyphCount; ++index) {
        if (FT_Load_Glyph(cascaded, glyphIndexOf(infos[index]), FT_LOAD_DEFAULT) != 0)
            continue;
        if (cascaded->glyph->format != FT_GLYPH_FORMAT_BITMAP && FT_Render_Glyph(cascaded->glyph, FT_RENDER_MODE_NORMAL) != 0)
            continue;
        const FT_GlyphSlot slot = cascaded->glyph;
        const FT_Bitmap& bitmap = slot->bitmap;
        const int inkWidth = static_cast<int>(bitmap.width);
        const int inkHeight = static_cast<int>(bitmap.rows);
        if (index == 0) {
            penX = (slotWidth - inkWidth) / 2 - slot->bitmap_left - positions[0].x_offset / 64.0;
            baseInkLeft = (slotWidth - inkWidth) / 2;
            baseInkWidth = inkWidth;
        }
        // A mark the face attaches carries the offset its anchor gives it. A
        // mark it leaves unattached is centred over the base's ink and kept
        // clear of the ink stacked so far on its side: its bearing and height
        // assume a Latin lowercase base, which would stand it past a two-cell
        // letter's edge or inside its top stroke.
        const bool isUnattachedMark = index > 0 && positions[index].x_advance == 0 && positions[index].x_offset == 0
            && positions[index].y_offset == 0;
        const int left = isUnattachedMark
            ? baseInkLeft + (baseInkWidth - inkWidth) / 2
            : static_cast<int>(std::lround(penX + positions[index].x_offset / 64.0)) + slot->bitmap_left;
        int top = baselineY - static_cast<int>(std::lround(positions[index].y_offset / 64.0)) - slot->bitmap_top;
        if (isUnattachedMark && inkHeight > 0) {
            const hb_unicode_combining_class_t combiningClass = hb_unicode_combining_class(unicode,
                codePoints[std::min<int>(static_cast<int>(infos[index].cluster), count - 1)]);
            const bool isAbove = combiningClass == HB_UNICODE_COMBINING_CLASS_ABOVE
                || combiningClass == HB_UNICODE_COMBINING_CLASS_ABOVE_LEFT || combiningClass == HB_UNICODE_COMBINING_CLASS_ABOVE_RIGHT
                || combiningClass == HB_UNICODE_COMBINING_CLASS_ATTACHED_ABOVE || combiningClass == HB_UNICODE_COMBINING_CLASS_DOUBLE_ABOVE;
            const bool isBelow = combiningClass == HB_UNICODE_COMBINING_CLASS_BELOW
                || combiningClass == HB_UNICODE_COMBINING_CLASS_BELOW_LEFT || combiningClass == HB_UNICODE_COMBINING_CLASS_BELOW_RIGHT
                || combiningClass == HB_UNICODE_COMBINING_CLASS_ATTACHED_BELOW || combiningClass == HB_UNICODE_COMBINING_CLASS_DOUBLE_BELOW;
            if (isAbove)
                top = std::min(top, stackTop - markGap - inkHeight);
            else if (isBelow)
                top = std::max(top, stackBottom + markGap);
        }
        if (index == 0 || inkHeight > 0) {
            stackTop = index == 0 ? top : std::min(stackTop, top);
            stackBottom = index == 0 ? top + inkHeight : std::max(stackBottom, top + inkHeight);
        }
        for (int row = 0; row < inkHeight; ++row) {
            const int y = top + row;
            if (y < 0 || y >= slotHeight)
                continue;
            const unsigned char* source = bitmap.buffer + static_cast<long>(row) * bitmap.pitch;
            for (int column = 0; column < inkWidth; ++column) {
                const int x = left + column;
                if (x < 0 || x >= slotWidth)
                    continue;
                const std::uint8_t value = bitmap.pixel_mode == FT_PIXEL_MODE_MONO
                    ? ((source[column / 8] & (0x80 >> (column % 8))) ? 255 : 0)
                    : source[column];
                std::uint8_t& destination = coverageOut[static_cast<std::size_t>(y) * slotWidth + x];
                destination = std::max(destination, value);
            }
        }
        didDraw = didDraw || (inkWidth > 0 && inkHeight > 0);
        penX += positions[index].x_advance / 64.0;
    }
    return didDraw || overprint();
}

std::string FreeTypeRasterizer::bundledPath(std::string_view file) const
{
    if (file.empty() || m_bundledFallbackPath.empty())
        return {};
    const std::size_t slash = m_bundledFallbackPath.find_last_of('/');
    if (slash == std::string::npos)
        return {};
    return m_bundledFallbackPath.substr(0, slash + 1) + std::string(file);
}

std::vector<std::pair<std::string, int>> FreeTypeRasterizer::emojiFaceCandidates() const
{
    std::vector<std::pair<std::string, int>> candidates;
    // The shipped emoji face first, for the reason the proportional face is:
    // fontconfig's "emoji" is whatever the machine installed, and the two
    // machines this renders on installed different builds of Noto — bitmap
    // strikes on one, COLRv1 outlines on the other — which no golden can
    // reconcile. The system list follows, for a bundle without the file.
    const std::string bundled = bundledPath(Rendering::bundledFontFile("Noto Color Emoji"));
    if (!bundled.empty())
        candidates.emplace_back(bundled, 0);
    if (FcInit() != FcTrue)
        return candidates;
    FcConfig* config = FcConfigGetCurrent();
    FcPattern* pattern = FcNameParse(reinterpret_cast<const unsigned char*>("emoji"));
    if (!pattern)
        return candidates;
    FcConfigSubstitute(config, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);
    FcResult result = FcResultNoMatch;
    // Trimmed: a face adding no coverage over the ones before it is one the
    // sort would never have handed `fc-match`, and there are hundreds.
    FcFontSet* sorted = FcFontSort(config, pattern, FcTrue, nullptr, &result);
    FcPatternDestroy(pattern);
    if (!sorted)
        return candidates;
    for (int i = 0; i < sorted->nfont; ++i) {
        unsigned char* file = nullptr;
        if (FcPatternGetString(sorted->fonts[i], FC_FILE, 0, &file) != FcResultMatch || !file)
            continue;
        int index = 0;
        if (FcPatternGetInteger(sorted->fonts[i], FC_INDEX, 0, &index) != FcResultMatch)
            index = 0;
        candidates.emplace_back(reinterpret_cast<const char*>(file), index);
    }
    FcFontSetDestroy(sorted);
    return candidates;
}

FT_FaceRec_* FreeTypeRasterizer::openSizedColorFace(FT_LibraryRec_* library, const char* path, int faceIndex, int fontPixelSize)
{
    FT_FaceRec_* loaded = nullptr;
    if (!library || !path || FT_New_Face(library, path, faceIndex, &loaded) != 0 || !loaded)
        return nullptr;
    // A face without the flag is an ordinary text face: fontconfig never
    // declines, and asked for a family nothing provides it offers the best
    // remaining match.
    if ((loaded->face_flags & FT_FACE_FLAG_COLOR) == 0) {
        FT_Done_Face(loaded);
        return nullptr;
    }
    if ((loaded->face_flags & FT_FACE_FLAG_SCALABLE) == 0 && loaded->num_fixed_sizes > 0) {
        int best = 0;
        int bestDelta = -1;
        for (int i = 0; i < loaded->num_fixed_sizes; ++i) {
            const int delta = std::abs(static_cast<int>(loaded->available_sizes[i].height) - fontPixelSize);
            if (bestDelta < 0 || delta < bestDelta) {
                bestDelta = delta;
                best = i;
            }
        }
        if (FT_Select_Size(loaded, best) != 0) {
            FT_Done_Face(loaded);
            return nullptr;
        }
    } else if (FT_Set_Pixel_Sizes(loaded, 0, static_cast<FT_UInt>(fontPixelSize)) != 0) {
        FT_Done_Face(loaded);
        return nullptr;
    }
    return loaded;
}

ColorGlyphFormat FreeTypeRasterizer::classifyColorFace(FT_FaceRec_* face)
{
    if (!face)
        return ColorGlyphFormat::None;
    FT_UInt probe = 0;
    for (const std::uint32_t codePoint : colorProbeCodePoints) {
        probe = FT_Get_Char_Index(face, codePoint);
        if (probe != 0)
            break;
    }
    if (probe == 0)
        return ColorGlyphFormat::None;

    // A COLRv1 face renders 0x0 through `FT_Render_Glyph`: the paint graph is
    // drawn by the painter or not at all, so the probe is a paint into a
    // small canvas and the answer is whether ink came back.
    if (ColorGlyphPainter::hasPaintGraph(face, probe)) {
        constexpr int probeEdge = 16;
        std::array<std::uint8_t, probeEdge * probeEdge * 4> canvas {};
        ColorGlyphPainter painter;
        const double scale = static_cast<double>(probeEdge) / static_cast<double>(std::max(1, static_cast<int>(face->size->metrics.y_ppem)));
        const auto result = painter.paint(face, probe, colorGlyphForeground, { canvas, probeEdge, probeEdge }, { 0.0, static_cast<double>(probeEdge) * 0.25, scale });
        if (!result)
            return ColorGlyphFormat::None;
        return rasterCarriesColour(canvas.data(), probeEdge, probeEdge, probeEdge * 4) ? ColorGlyphFormat::COLRv1 : ColorGlyphFormat::None;
    }

    if (FT_Load_Glyph(face, probe, FT_LOAD_COLOR | FT_LOAD_RENDER) != 0)
        return ColorGlyphFormat::None;
    const FT_Bitmap& bitmap = face->glyph->bitmap;
    if (bitmap.pixel_mode != FT_PIXEL_MODE_BGRA || bitmap.width == 0 || bitmap.rows == 0)
        return ColorGlyphFormat::None;
    if (!rasterCarriesColour(bitmap.buffer, bitmap.width, bitmap.rows, bitmap.pitch))
        return ColorGlyphFormat::None;
    // The raster is FreeType's; which table it came from is what the report
    // names, and a face whose table this cannot name is not vouched for.
    if (hasSfntTable(face, FT_MAKE_TAG('C', 'O', 'L', 'R')))
        return ColorGlyphFormat::COLRv0;
    if (hasSfntTable(face, FT_MAKE_TAG('C', 'B', 'D', 'T')))
        return ColorGlyphFormat::CBDT;
    if (hasSfntTable(face, FT_MAKE_TAG('s', 'b', 'i', 'x')))
        return ColorGlyphFormat::Sbix;
    return ColorGlyphFormat::None;
}

ColorGlyphFormat FreeTypeRasterizer::probeColorFace(const std::string& path, int faceIndex, int fontPixelSize)
{
    FT_LibraryRec_* library = nullptr;
    if (FT_Init_FreeType(&library) != 0)
        return ColorGlyphFormat::None;
    ColorGlyphFormat format = ColorGlyphFormat::None;
    if (FT_FaceRec_* face = openSizedColorFace(library, path.c_str(), faceIndex, fontPixelSize)) {
        format = classifyColorFace(face);
        FT_Done_Face(face);
    }
    FT_Done_FreeType(library);
    return format;
}

bool FreeTypeRasterizer::loadEmojiFace()
{
    // The shaper holds a reference to the face, so it goes first: destroying the
    // face under a live hb_font leaves the shaper pointing at freed memory.
    if (m_emojiShaper) {
        hb_font_destroy(m_emojiShaper);
        m_emojiShaper = nullptr;
    }
    if (m_emojiFace) {
        FT_Done_Face(m_emojiFace);
        m_emojiFace = nullptr;
    }
    m_colorGlyphFormat = ColorGlyphFormat::None;
    m_colorFacePath.clear();
    if (!m_library)
        return false;

    // Every candidate in fontconfig's order, keeping the first that draws.
    // `FT_FACE_FLAG_COLOR` says a face carries colour, not that this build can
    // draw it, and a host can rank a face this build declines ahead of one it
    // accepts; taking the first answer alone would leave the host monochrome.
    for (const auto& [path, faceIndex] : emojiFaceCandidates()) {
        FT_FaceRec_* loaded = openSizedColorFace(m_library, path.c_str(), faceIndex, m_fontPixelSize);
        if (!loaded)
            continue;
        const ColorGlyphFormat format = classifyColorFace(loaded);
        if (format == ColorGlyphFormat::None) {
            FT_Done_Face(loaded);
            continue;
        }
        m_emojiFace = loaded;
        m_colorGlyphFormat = format;
        m_colorFacePath = path;
        // The shaper is built from the sized face, so it reports the same
        // metrics the raster will use.
        m_emojiShaper = hb_ft_font_create_referenced(m_emojiFace);
        return true;
    }
    return false;
}

bool FreeTypeRasterizer::paintColorGlyphIntoSlot(unsigned int glyphIndex, int slotInPixels, std::uint8_t* pixelsOut)
{
    // The clip box at the face's size, 26.6 and y up, is what the glyph is
    // scaled and centred by; a glyph without one takes the face's box.
    double boxLeft = 0.0;
    double boxBottom = 0.0;
    double boxRight = 0.0;
    double boxTop = 0.0;
    FT_ClipBox clipBox;
    if (FT_Get_Color_Glyph_ClipBox(m_emojiFace, glyphIndex, &clipBox)) {
        boxLeft = clipBox.bottom_left.x / 64.0;
        boxBottom = clipBox.bottom_left.y / 64.0;
        boxRight = clipBox.top_right.x / 64.0;
        boxTop = clipBox.top_right.y / 64.0;
    } else {
        const double unitsToPixels = static_cast<double>(m_emojiFace->size->metrics.y_ppem) / static_cast<double>(std::max<FT_UShort>(1, m_emojiFace->units_per_EM));
        boxLeft = m_emojiFace->bbox.xMin * unitsToPixels;
        boxBottom = m_emojiFace->bbox.yMin * unitsToPixels;
        boxRight = m_emojiFace->bbox.xMax * unitsToPixels;
        boxTop = m_emojiFace->bbox.yMax * unitsToPixels;
    }
    const double boxWidth = boxRight - boxLeft;
    const double boxHeight = boxTop - boxBottom;
    if (!(boxWidth > 0.0) || !(boxHeight > 0.0))
        return false;
    const double scale = static_cast<double>(slotInPixels) / std::max(boxWidth, boxHeight);
    const ColorGlyphPlacement placement {
        .originX = (static_cast<double>(slotInPixels) - boxWidth * scale) / 2.0 - boxLeft * scale,
        .originY = (static_cast<double>(slotInPixels) - boxHeight * scale) / 2.0 - boxBottom * scale,
        .scale = scale,
    };

    const std::size_t canvasBytes = static_cast<std::size_t>(slotInPixels) * static_cast<std::size_t>(slotInPixels) * 4;
    if (m_colorCanvas.size() < canvasBytes)
        m_colorCanvas.resize(canvasBytes);
    std::span<std::uint8_t> canvas { m_colorCanvas.data(), canvasBytes };
    std::ranges::fill(canvas, 0);
    if (!m_colorGlyphPainter.paint(m_emojiFace, glyphIndex, colorGlyphForeground, { canvas, slotInPixels, slotInPixels }, placement))
        return false;
    if (!rasterCarriesInk(canvas))
        return false;

    for (std::size_t i = 0; i < canvasBytes; i += 4)
        writeStraightRGBA(pixelsOut + i, canvas[i], canvas[i + 1], canvas[i + 2], canvas[i + 3]);
    return true;
}

unsigned int FreeTypeRasterizer::shapedGlyphForCluster(const std::uint32_t* codePoints, int count)
{
    if (!m_emojiFace)
        return 0;
    // One code point needs no shaping, and asking for it would build a buffer to
    // answer what the character map already knows.
    if (count == 1 || !m_emojiShaper)
        return FT_Get_Char_Index(m_emojiFace, codePoints[0]);

    hb_buffer_t* buffer = hb_buffer_create();
    if (!buffer)
        return FT_Get_Char_Index(m_emojiFace, codePoints[0]);
    for (int i = 0; i < count; ++i)
        hb_buffer_add(buffer, codePoints[i], static_cast<unsigned int>(i));
    hb_buffer_set_content_type(buffer, HB_BUFFER_CONTENT_TYPE_UNICODE);
    // Stated rather than guessed: `hb_buffer_guess_segment_properties` reads the
    // script off the first code point, and an emoji sequence beginning with a
    // ZWJ-joinable base can guess a script whose shaper reorders the run.
    hb_buffer_set_direction(buffer, HB_DIRECTION_LTR);
    hb_buffer_set_script(buffer, HB_SCRIPT_COMMON);
    hb_buffer_set_language(buffer, hb_language_get_default());
    // No features, where the other two calls take the text run.
    // `[font] ligatures` and `font.features` describe the primary text face; an
    // emoji sequence is not a typographic ligature a reader is toggling but how
    // this face encodes a family, a couple or a skin tone — four code points to
    // one glyph, through the same GSUB machinery. Handing a suppression aimed at
    // `=>` to this shaper is a category error whatever it happens to do.
    //
    // What it happens to do, measured against the colour face reachable here, is
    // nothing: suppressing `liga`, `clig`, `calt` and even `ccmp` leaves every
    // ZWJ cluster composing to identical pixels, so this face resolves them
    // below the feature layer. That is a property of one font rather than a
    // guarantee, which is why the seam is closed here rather than left open on
    // the evidence that today's font does not notice.
    hb_shape(m_emojiShaper, buffer, nullptr, 0);

    unsigned int glyphCount = 0;
    const hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buffer, &glyphCount);
    // Exactly one glyph means the sequence composed. More than one means the
    // face has no ligature for it and the shaper handed back the pieces —
    // drawing the first of those is the lead-code-point raster under another
    // name, which is what this returns to.
    // hb_glyph_info_t's `codepoint` holds a GLYPH index after shaping rather
    // than a code point; the field is HarfBuzz's and the name is its own.
    const unsigned int shaped
        = (glyphCount == 1 && infos) ? static_cast<const hb_glyph_info_t*>(infos)->codepoint : 0;
    hb_buffer_destroy(buffer);
    if (shaped != 0)
        return shaped;
    return FT_Get_Char_Index(m_emojiFace, codePoints[0]);
}

unsigned int FreeTypeRasterizer::glyphIndexForCodePoint(std::uint32_t codePoint) const
{
    if (!m_face)
        return 0;
    return FT_Get_Char_Index(m_face, static_cast<FT_ULong>(codePoint));
}

int FreeTypeRasterizer::shapeTextRun(std::span<const std::uint32_t> codePoints, std::uint32_t weight,
    std::span<ShapedGlyph> out)
{
    if (!m_face || !m_textShaper || codePoints.empty() || out.empty())
        return 0;

    // Shaped at the weight it will be drawn at. A variable face's substitutions
    // and advances are both allowed to differ by axis position, so measuring at
    // one weight and drawing at another is how a bold run comes out spaced for
    // the regular one. hb_ft_font caches the face's metrics, so it has to be
    // told the coordinates moved — without this the first weight shaped wins for
    // the lifetime of the shaper.
    const std::uint64_t previousGeneration = m_axisGeneration;
    // Upright: this seam carries no face, and the strip path it feeds is
    // upright text. A bold run reaches the axis through `rasterizeGlyph`, which
    // does carry one.
    applyWeightAxis(Rendering::FontFace::Regular, weight);
    if (m_axisGeneration != previousGeneration)
        hb_ft_font_changed(m_textShaper);

    hb_buffer_t* buffer = hb_buffer_create();
    if (!buffer)
        return 0;
    for (std::size_t i = 0; i < codePoints.size(); ++i)
        hb_buffer_add(buffer, codePoints[i], static_cast<unsigned int>(i));
    hb_buffer_set_content_type(buffer, HB_BUFFER_CONTENT_TYPE_UNICODE);
    // Stated rather than guessed, for the reason the emoji path states them: a
    // run beginning with an operator would have its script inferred from that
    // character, and a shaper chosen for the wrong script reorders the run.
    hb_buffer_set_direction(buffer, HB_DIRECTION_LTR);
    hb_buffer_set_script(buffer, HB_SCRIPT_COMMON);
    hb_buffer_set_language(buffer, hb_language_get_default());
    hb_shape(m_textShaper, buffer, m_shapingFeatures->run.data(), static_cast<unsigned int>(m_shapingFeatures->run.size()));

    unsigned int glyphCount = 0;
    const hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buffer, &glyphCount);
    const hb_glyph_position_t* positions = hb_buffer_get_glyph_positions(buffer, &glyphCount);
    if (!infos || !positions || glyphCount == 0 || glyphCount > out.size()) {
        // A run that shaped to more glyphs than the caller can hold shapes to
        // none. Writing the prefix would hand back a partial run that reads as a
        // whole one, and the cells past it would draw the wrong thing rather
        // than nothing.
        hb_buffer_destroy(buffer);
        return 0;
    }

    for (unsigned int i = 0; i < glyphCount; ++i) {
        // HarfBuzz reports positions in 26.6 fixed point.
        out[i].glyph = glyphIndexOf(infos[i]);
        // 26.6 kept whole, not shifted: the shaper's fraction is where the
        // face put the next glyph, and the rasteriser draws at it.
        out[i].advanceInPixels = static_cast<float>(positions[i].x_advance) / 64.0f;
        out[i].offsetXInPixels = static_cast<float>(positions[i].x_offset) / 64.0f;
        out[i].offsetYInPixels = static_cast<float>(positions[i].y_offset) / 64.0f;
        out[i].cluster = static_cast<std::uint16_t>(std::min<unsigned int>(infos[i].cluster, 0xFFFFu));
    }
    hb_buffer_destroy(buffer);
    return static_cast<int>(glyphCount);
}

int FreeTypeRasterizer::shapePrimaryRun(std::span<const std::uint32_t> codePoints, Rendering::FontFace face, std::uint32_t weight,
    std::span<Ubiquitty::ProportionalShapedGlyph> out)
{
    FT_FaceRec_* drawn = monoFace(face);
    if (!drawn || !m_textShaper || codePoints.empty() || out.empty())
        return 0;
    // A styled file's shaper is built on first use; the one face at the pen's
    // weight shapes through the text shaper, told when the axes moved, as
    // shapeTextRun tells it.
    hb_font_t* shaper = m_textShaper;
    if (drawn != m_face) {
        hb_font_t*& styled = drawn == m_boldFace ? m_boldTextShaper
            : drawn == m_italicFace              ? m_italicTextShaper
                                                 : m_boldItalicTextShaper;
        if (!styled)
            styled = hb_ft_font_create_referenced(drawn);
        shaper = styled;
    }
    if (!shaper)
        return 0;
    const std::uint64_t previousGeneration = m_axisGeneration;
    applyWeightAxis(face, weight);
    if (m_axisGeneration != previousGeneration)
        hb_ft_font_changed(shaper);

    hb_buffer_t* buffer = hb_buffer_create();
    if (!buffer)
        return 0;
    for (std::size_t i = 0; i < codePoints.size(); ++i)
        hb_buffer_add(buffer, codePoints[i], static_cast<unsigned int>(i));
    hb_buffer_set_content_type(buffer, HB_BUFFER_CONTENT_TYPE_UNICODE);
    hb_buffer_set_direction(buffer, HB_DIRECTION_LTR);
    hb_buffer_set_script(buffer, HB_SCRIPT_COMMON);
    hb_buffer_set_language(buffer, hb_language_get_default());
    // Kerning stays on; every ligature feature is off, so the glyphs the
    // builder draws from the mono sheet, one per letter, are the ones placed.
    static constexpr hb_feature_t lettersApart[] = {
        { HB_TAG('l', 'i', 'g', 'a'), 0, 0, static_cast<unsigned int>(-1) },
        { HB_TAG('c', 'l', 'i', 'g'), 0, 0, static_cast<unsigned int>(-1) },
        { HB_TAG('d', 'l', 'i', 'g'), 0, 0, static_cast<unsigned int>(-1) },
        { HB_TAG('c', 'a', 'l', 't'), 0, 0, static_cast<unsigned int>(-1) },
    };
    hb_shape(shaper, buffer, lettersApart, static_cast<unsigned int>(std::size(lettersApart)));
    unsigned int glyphCount = 0;
    const hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buffer, &glyphCount);
    const hb_glyph_position_t* positions = hb_buffer_get_glyph_positions(buffer, &glyphCount);
    if (!infos || !positions || glyphCount == 0 || glyphCount > out.size()) {
        hb_buffer_destroy(buffer);
        return 0;
    }
    for (unsigned int i = 0; i < glyphCount; ++i) {
        out[i].glyph = glyphIndexOf(infos[i]);
        // 26.6 kept whole: the fraction is where the face put the next letter.
        out[i].advanceInPixels = static_cast<float>(positions[i].x_advance) / 64.0f;
        out[i].offsetXInPixels = static_cast<float>(positions[i].x_offset) / 64.0f;
        out[i].offsetYInPixels = static_cast<float>(positions[i].y_offset) / 64.0f;
        out[i].cluster = static_cast<std::uint16_t>(std::min<unsigned int>(infos[i].cluster, 0xFFFFu));
    }
    hb_buffer_destroy(buffer);
    return static_cast<int>(glyphCount);
}

bool FreeTypeRasterizer::rasteriseShapedRun(std::span<const ShapedGlyph> glyphs, int stripWidthInPixels,
    int stripHeightInPixels, std::span<std::uint8_t> coverageOut)
{
    return drawShapedRun(glyphs, stripWidthInPixels, stripHeightInPixels, coverageOut, nullptr);
}

bool FreeTypeRasterizer::rasteriseShapedRunMeasured(std::span<const ShapedGlyph> glyphs, int stripWidthInPixels,
    int stripHeightInPixels, std::span<std::uint8_t> coverageOut, std::span<GlyphInkExtent> inkOut)
{
    // One extent per glyph or none at all: a short span silently dropping the
    // tail would hand the consumer a measured strip with unmeasured columns.
    if (inkOut.size() != glyphs.size())
        return false;
    return drawShapedRun(glyphs, stripWidthInPixels, stripHeightInPixels, coverageOut, inkOut.data());
}

bool FreeTypeRasterizer::drawShapedRun(std::span<const ShapedGlyph> glyphs, int stripWidthInPixels,
    int stripHeightInPixels, std::span<std::uint8_t> coverageOut, GlyphInkExtent* inkOut)
{
    return drawShapedRunWithFace(m_face, glyphs, stripWidthInPixels, stripHeightInPixels, coverageOut, inkOut);
}

bool FreeTypeRasterizer::drawShapedRunWithFace(FT_FaceRec_* face, std::span<const ShapedGlyph> glyphs, int stripWidthInPixels,
    int stripHeightInPixels, std::span<std::uint8_t> coverageOut, GlyphInkExtent* inkOut)
{
    if (stripWidthInPixels <= 0 || stripHeightInPixels <= 0)
        return false;
    const std::size_t expected = static_cast<std::size_t>(stripWidthInPixels) * static_cast<std::size_t>(stripHeightInPixels);
    // Refused rather than trusted, because the caller's dimensions and its
    // buffer are two statements of one fact and only this side can compare them.
    if (coverageOut.size() != expected)
        return false;
    std::ranges::fill(coverageOut, std::uint8_t { 0 });
    if (!m_face || !face)
        return false;

    const int baselineY = primaryBaselineY(stripHeightInPixels);
    int penX = 0;
    std::size_t glyphIndex = 0;
    for (const ShapedGlyph& shaped : glyphs) {
        if (inkOut != nullptr)
            inkOut[glyphIndex] = GlyphInkExtent {};
        // Loaded by GLYPH index: the shaper already resolved these, and a
        // second character-map lookup would undo the substitution that made
        // this a ligature.
        if (shaped.glyph != 0 && FT_Load_Glyph(face, shaped.glyph, FT_LOAD_DEFAULT) == 0) {
            if (face->glyph->format == FT_GLYPH_FORMAT_BITMAP || FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) == 0) {
                const FT_GlyphSlot slot = face->glyph;
                const FT_Bitmap& bitmap = slot->bitmap;
                const int inkWidth = static_cast<int>(bitmap.width);
                const int inkHeight = static_cast<int>(bitmap.rows);
                // A wide ligature glyph carries a negative left bearing and
                // reaches back over the cells its blanks left empty, so the
                // start column is allowed to be negative and the bounds check
                // below clips rather than the arithmetic.
                const int startX = penX + shaped.offsetXInPixels + slot->bitmap_left;
                const int startY = baselineY - shaped.offsetYInPixels - slot->bitmap_top;
                if (inkOut != nullptr && inkWidth > 0 && inkHeight > 0) {
                    // Clipped exactly as the pixels below are, so the extent
                    // never names a column the strip does not hold.
                    const int inkLeft = startX < 0 ? 0 : startX;
                    const int inkRight = startX + inkWidth > stripWidthInPixels ? stripWidthInPixels : startX + inkWidth;
                    if (inkRight > inkLeft)
                        inkOut[glyphIndex] = GlyphInkExtent { inkLeft, inkRight };
                }
                for (int sourceY = 0; sourceY < inkHeight; ++sourceY) {
                    const int destinationY = startY + sourceY;
                    if (destinationY < 0 || destinationY >= stripHeightInPixels)
                        continue;
                    const unsigned char* source = bitmap.buffer + static_cast<long>(sourceY) * bitmap.pitch;
                    for (int sourceX = 0; sourceX < inkWidth; ++sourceX) {
                        const int destinationX = startX + sourceX;
                        if (destinationX < 0 || destinationX >= stripWidthInPixels)
                            continue;
                        // Written, not blended: within one run the glyphs are
                        // laid out not to overlap, and a max() here would hide
                        // a layout fault by making two glyphs on one cell look
                        // like one bolder glyph.
                        coverageOut[static_cast<std::size_t>(destinationY) * static_cast<std::size_t>(stripWidthInPixels)
                            + static_cast<std::size_t>(destinationX)]
                            = source[sourceX];
                    }
                }
            }
        }
        penX += shaped.advanceInPixels;
        ++glyphIndex;
    }
    return true;
}

bool FreeTypeRasterizer::rasterizeColorCluster(const std::uint32_t* codePoints, int count, int slotInPixels, std::uint8_t* pixelsOut)
{
    if (!m_emojiFace || !codePoints || count <= 0 || slotInPixels <= 0 || !pixelsOut)
        return false;

    // A ZWJ sequence is a LIGATURE in the font's GSUB table, so no character-map
    // lookup can reach it however wide the probe: the family emoji has no code
    // point of its own, only a substitution rule over the sequence that spells
    // it. Shaping the cluster is what turns those code points into the one
    // glyph, and it is why a lead-code-point raster draws a family as one
    // person.
    //
    // Core stops at cluster SEGMENTATION by design — `GraphemeBreak` says which
    // code points form one cluster, `FontFeatureSpecification` says which
    // OpenType features to request — and leaves substitution to whatever shaper
    // a frontend brings. macOS brings Core Text, the browser brings its own,
    // and this is HarfBuzz over the same face the raster loads from.
    const FT_UInt glyphIndex = shapedGlyphForCluster(codePoints, count);
    if (glyphIndex == 0)
        return false;
    // A COLRv1 glyph renders 0x0 through FreeType; the painter draws it. A
    // glyph the painter declines goes to the mono path, which draws the
    // outline the face keeps beside the graph.
    if (m_colorGlyphFormat == ColorGlyphFormat::COLRv1)
        return paintColorGlyphIntoSlot(glyphIndex, slotInPixels, pixelsOut);
    // A face of several strikes draws from the one Core picks for the square:
    // the nearest at or above it, reduced below, so a sized block's master is
    // never a small strike magnified while a larger one exists.
    if ((m_emojiFace->face_flags & FT_FACE_FLAG_SCALABLE) == 0 && m_emojiFace->num_fixed_sizes > 1) {
        std::array<int, 32> heights {};
        const int strikeCount = std::min(m_emojiFace->num_fixed_sizes, static_cast<int>(heights.size()));
        for (int index = 0; index < strikeCount; ++index)
            heights[static_cast<std::size_t>(index)] = m_emojiFace->available_sizes[index].height;
        const int strike = Rendering::colorStrikeForTarget(std::span<const int>(heights).first(static_cast<std::size_t>(strikeCount)), slotInPixels);
        if (strike >= 0 && FT_Select_Size(m_emojiFace, strike) != 0)
            return false;
    }
    if (FT_Load_Glyph(m_emojiFace, glyphIndex, FT_LOAD_COLOR | FT_LOAD_RENDER) != 0)
        return false;

    const FT_GlyphSlot slot = m_emojiFace->glyph;
    const FT_Bitmap& bitmap = slot->bitmap;
    // A face that answered FT_FACE_FLAG_COLOR can still hand back a monochrome
    // bitmap for a code point it covers only in outline form. That belongs on
    // the mono path, which already draws it, rather than on a colour sheet.
    if (bitmap.pixel_mode != FT_PIXEL_MODE_BGRA || bitmap.width == 0 || bitmap.rows == 0)
        return false;

    // The format is not the answer: `pixel_mode` reports colour for a glyph
    // FreeType could not colour. Noto Color Emoji's four-person family arrives
    // that way, as an even grey with more ink than the glyphs beside it, and
    // a colour slot for it would put a grey blob on the sheet while the mono
    // path, which draws the same coverage correctly, never sees the cluster.
    if (!rasterCarriesColour(bitmap.buffer, bitmap.width, bitmap.rows, bitmap.pitch))
        return false;

    for (int i = 0; i < slotInPixels * slotInPixels * 4; ++i)
        pixelsOut[i] = 0;

    // Box filter, averaging every source pixel that falls in a destination
    // pixel's footprint. A colour strike is one fixed size — Noto Color Emoji
    // ships a single 136x128 — so a terminal cell asks for a reduction of four
    // or five to one, and point sampling there keeps every fifth pixel and
    // discards the rest. That is what gives a scaled emoji hard stair-stepped
    // edges where the face drew a smooth one.
    //
    // Averaging happens in PRE-MULTIPLIED space, which is the one place the
    // pre-multiplied form is the useful one: a transparent pixel contributes
    // nothing to the colour sum because its colour is already scaled by its
    // alpha. Un-multiplying first and then averaging would let the arbitrary
    // colour under a fully transparent pixel bleed into its neighbours.
    const int sourceWidth = static_cast<int>(bitmap.width);
    const int sourceHeight = static_cast<int>(bitmap.rows);
    for (int y = 0; y < slotInPixels; ++y) {
        const int firstRow = (y * sourceHeight) / slotInPixels;
        const int lastRow = std::max(firstRow + 1, ((y + 1) * sourceHeight) / slotInPixels);
        for (int x = 0; x < slotInPixels; ++x) {
            const int firstColumn = (x * sourceWidth) / slotInPixels;
            const int lastColumn = std::max(firstColumn + 1, ((x + 1) * sourceWidth) / slotInPixels);

            std::uint32_t sumBlue = 0;
            std::uint32_t sumGreen = 0;
            std::uint32_t sumRed = 0;
            std::uint32_t sumAlpha = 0;
            std::uint32_t samples = 0;
            for (int sy = firstRow; sy < lastRow && sy < sourceHeight; ++sy) {
                const unsigned char* source = bitmap.buffer + static_cast<long>(sy) * bitmap.pitch;
                for (int sx = firstColumn; sx < lastColumn && sx < sourceWidth; ++sx) {
                    sumBlue += source[sx * 4 + 0];
                    sumGreen += source[sx * 4 + 1];
                    sumRed += source[sx * 4 + 2];
                    sumAlpha += source[sx * 4 + 3];
                    ++samples;
                }
            }
            if (samples == 0)
                continue;

            const std::uint32_t blue = sumBlue / samples;
            const std::uint32_t green = sumGreen / samples;
            const std::uint32_t red = sumRed / samples;
            const std::uint32_t alpha = sumAlpha / samples;
            // Straightened after the average, not before: averaging happens in
            // pre-multiplied space so a transparent pixel's colour cannot bleed.
            writeStraightRGBA(&pixelsOut[(static_cast<std::size_t>(y) * slotInPixels + x) * 4], blue, green, red, alpha);
        }
    }
    return true;
}

bool FreeTypeRasterizer::rasterizeSizedMaster(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, const Rendering::SizedMaster& master,
    int slotWidth, int slotHeight, std::uint8_t* coverageOut)
{
    if (master.isIdentity() || !m_face)
        return GlyphRasterizer::rasterizeSizedMaster(codePoint, face, weight, master, slotWidth, slotHeight, coverageOut);
    const Rendering::RasterScale scale = master.scale;

    // Measured before the resize, because the face carries its size: the
    // baseline the block must sit on is the one an unscaled cell would use,
    // taken `scale` times. Asked after, the ascent is already the scaled one
    // and multiplying it again puts the baseline off the master entirely.
    const int cellBaselineY = primaryBaselineY(scale.unscaled(slotHeight));

    // A whole scale is a whole pixel size. A fraction — OSC 66's `n`/`d` —
    // is drawn at exactly its size, requested in 26.6 pixels the way
    // FT_Set_Pixel_Sizes requests a whole one: the nearest whole size would
    // draw a different letter, and resampling one would draw a softer one.
    const auto scaledPixelSize = static_cast<FT_UInt>(m_fontPixelSize * scale.whole());
    const auto scaledPixelHeight = static_cast<FT_Long>(std::lround(static_cast<double>(m_fontPixelSize) * 64.0 * scale.value()));
    const auto setScaledSize = [&](FT_FaceRec_* target) {
        if (scale.isWhole())
            return FT_Set_Pixel_Sizes(target, 0, scaledPixelSize);
        FT_Size_RequestRec request {};
        request.type = FT_SIZE_REQUEST_TYPE_NOMINAL;
        request.width = 0;
        request.height = scaledPixelHeight;
        return FT_Request_Size(target, &request);
    };
    if (setScaledSize(m_face) != 0) {
        // A face that refuses the size — a bitmap strike with fixed sizes is the
        // one that does — keeps the base behaviour rather than losing the glyph.
        return GlyphRasterizer::rasterizeSizedMaster(codePoint, face, weight, master, slotWidth, slotHeight, coverageOut);
    }

    // The size is a property of the FT_Face, not of the call, so every later
    // raster reads whatever this left behind. Restored on every exit, including
    // the failing ones, which is what the guard is for.
    const auto restoreSize = [this, face, weight, &master] {
        if (master.widthAxisCoordinate > 0.0)
            applyWeightAxis(face, weight);
        (void)FT_Set_Pixel_Sizes(m_face, 0, static_cast<FT_UInt>(m_fontPixelSize));
        if (m_boldFace)
            (void)FT_Set_Pixel_Sizes(m_boldFace, 0, static_cast<FT_UInt>(m_fontPixelSize));
        if (m_italicFace)
            (void)FT_Set_Pixel_Sizes(m_italicFace, 0, static_cast<FT_UInt>(m_fontPixelSize));
        if (m_boldItalicFace)
            (void)FT_Set_Pixel_Sizes(m_boldItalicFace, 0, static_cast<FT_UInt>(m_fontPixelSize));
        if (m_fallbackFace)
            (void)FT_Set_Pixel_Sizes(m_fallbackFace, 0, static_cast<FT_UInt>(m_fontPixelSize));
    };

    for (int index = 0; index < slotWidth * slotHeight; ++index)
        coverageOut[index] = 0;

    const int baselineY = std::min(scale.scaled(cellBaselineY), slotHeight);

    applyWeightAxis(face, weight, master.widthAxisCoordinate);
    // The bold member carries its own size, as the fallback below does, so it
    // is scaled on the same terms rather than drawn at 1x into a slot `scale`
    // times as tall.
    FT_FaceRec_* const styled = monoFace(face);
    if (styled != m_face && setScaledSize(styled) != 0) {
        restoreSize();
        return GlyphRasterizer::rasterizeSizedMaster(codePoint, face, weight, master, slotWidth, slotHeight, coverageOut);
    }
    if (renderGlyphFromFace(styled, codePoint, baselineY, slotWidth, slotHeight, coverageOut, master)) {
        restoreSize();
        return true;
    }

    // The fallback face carries its own size, so it is scaled and restored on
    // the same terms rather than drawn at 1x into a slot `scale` times as tall.
    if (m_fallbackFace && setScaledSize(m_fallbackFace) == 0
        && renderGlyphFromFace(m_fallbackFace, codePoint, baselineY, slotWidth, slotHeight, coverageOut, master)) {
        restoreSize();
        return true;
    }

    // The system cascade at the scaled size, for the reason the faces above
    // take it: an outline drawn at its size, not a 1x raster stretched.
    if (FT_FaceRec_* cascaded = cascadeFace(codePoint)) {
        // The cascade may already be optically matched to the primary face.
        // Scale from that size and restore it, retaining fractional pixels.
        const FT_F26Dot6 originalHeight = FT_MulFix(cascaded->units_per_EM, cascaded->size->metrics.y_scale);
        const auto scaledHeight = static_cast<FT_F26Dot6>(std::lround(originalHeight * scale.value()));
        const bool drawn = FT_Set_Char_Size(cascaded, 0, scaledHeight, 72, 72) == 0
            && renderGlyphFromFace(cascaded, codePoint, baselineY, slotWidth, slotHeight, coverageOut, master);
        (void)FT_Set_Char_Size(cascaded, 0, originalHeight, 72, 72);
        if (drawn) {
            restoreSize();
            return true;
        }
    }

    restoreSize();
    if (Rendering::tilesOnTextPen(codePoint) && scale.isWhole() && master.widthScale == 1) {
        Rendering::UnifontRasterizer scaled(scale.whole());
        return scaled.rasterizeGlyphInCell(codePoint,
            std::min(slotWidth, roundToInt(m_cellAdvanceInPixels) * scale.whole()),
            std::min(slotHeight, roundToInt(cellMetrics().cellHeight) * scale.whole()), slotWidth, slotHeight,
            { coverageOut, static_cast<std::size_t>(slotWidth) * slotHeight });
    }
    // Unifont is a bitmap face, and duplicating its pixels is what scaling it
    // means — so the base implementation is the right one for this tier.
    return m_unifontFallback.rasterizeSizedMaster(codePoint, face, weight, master, slotWidth, slotHeight, coverageOut);
}

bool FreeTypeRasterizer::rasterizeGlyph(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, int slotWidth, int slotHeight, std::uint8_t* coverageOut)
{
    for (int i = 0; i < slotWidth * slotHeight; ++i)
        coverageOut[i] = 0;

    if (!m_face)
        return m_unifontFallback.rasterizeGlyph(codePoint, face, weight, slotWidth, slotHeight, coverageOut);

    // Fallback tiers share the PRIMARY baseline so every face lines up with the
    // text + underline / strike rules.
    const int baselineY = primaryBaselineY(slotHeight);
    // Tier 1 — the primary face. SGR 1:n weight selects the 'wght' variation
    // coordinate (VF faces only); the axis is set on the primary face only.
    applyWeightAxis(face, weight);
    if (m_shapingFeatures->hasUserFeatures && !Rendering::tilesOnTextPen(codePoint)
        && FT_Get_Char_Index(monoFace(face), codePoint)) {
        const std::unique_ptr<hb_font_t, decltype(&hb_font_destroy)> shaper(hb_ft_font_create_referenced(monoFace(face)), hb_font_destroy);
        const std::unique_ptr<hb_buffer_t, decltype(&hb_buffer_destroy)> buffer(hb_buffer_create(), hb_buffer_destroy);
        hb_buffer_add(buffer.get(), codePoint, 0);
        hb_buffer_set_content_type(buffer.get(), HB_BUFFER_CONTENT_TYPE_UNICODE);
        hb_buffer_guess_segment_properties(buffer.get());
        hb_shape(shaper.get(), buffer.get(), m_shapingFeatures->run.data(), static_cast<unsigned int>(m_shapingFeatures->run.size()));
        unsigned int glyphCount = 0;
        const auto* glyphs = hb_buffer_get_glyph_infos(buffer.get(), &glyphCount);
        const auto* positions = hb_buffer_get_glyph_positions(buffer.get(), nullptr);
        if (glyphCount && glyphs && positions) {
            std::vector<ShapedGlyph> shaped(glyphCount);
            const int margin = std::max(0, (slotWidth - roundToInt(m_cellAdvanceInPixels)) / 2);
            for (unsigned int index = 0; index < glyphCount; ++index) {
                shaped[index].glyph = glyphIndexOf(glyphs[index]);
                shaped[index].advanceInPixels = static_cast<float>(positions[index].x_advance) / 64;
                shaped[index].offsetXInPixels = margin + static_cast<float>(positions[index].x_offset) / 64;
                shaped[index].offsetYInPixels = static_cast<float>(positions[index].y_offset) / 64;
            }
            return drawShapedRunWithFace(monoFace(face), shaped, slotWidth, slotHeight,
                { coverageOut, static_cast<std::size_t>(slotWidth) * slotHeight }, nullptr);
        }
    }
    if (renderGlyphFromFace(monoFace(face), codePoint, baselineY, slotWidth, slotHeight, coverageOut)) {
        return true;
    }

    // Tier 2 — the glyph-fallback face (bundled Nerd Font icons, or a configured
    // fallback_font). A fixed Regular face: never weighted. Null when no fallback
    // loaded, in which case renderGlyphFromFace returns false and this is skipped.
    if (renderGlyphFromFace(m_fallbackFace, codePoint, baselineY, slotWidth, slotHeight, coverageOut)) {
        return true;
    }

    // Tier 3 — the scalable system face Core's fallback policy routes the code
    // point to, as CoreText's cascade answers on macOS: a face that draws the
    // character as text, at the cell's size. An assembly piece is fitted to the
    // cell from that outline, as the pieces the primary carries are.
    if (renderGlyphFromFace(cascadeFace(codePoint), codePoint, baselineY, slotWidth, slotHeight, coverageOut))
        return true;

    // The fallback's joining edges are the primary cell's, not the atlas margins.
    if (Rendering::tilesOnTextPen(codePoint)) {
        return m_unifontFallback.rasterizeGlyphInCell(codePoint,
            std::min(slotWidth, roundToInt(m_cellAdvanceInPixels)),
            std::min(slotHeight, roundToInt(cellMetrics().cellHeight)), slotWidth, slotHeight,
            { coverageOut, static_cast<std::size_t>(slotWidth) * slotHeight });
    }

    // Tier 4 — Unifont, the bitmap backstop for what no installed face carries.
    return m_unifontFallback.rasterizeGlyph(codePoint, face, weight, slotWidth, slotHeight, coverageOut);
}

} // namespace Ubiquitty::Linux
