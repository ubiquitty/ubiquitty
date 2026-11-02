// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/FontInventory.h"

#include "Core/Rendering/BundledFonts.h"
#include "Core/Unicode/Width.h"
#include "Platform/Linux/BundledFontDirectory.h"
#include "Platform/Linux/ColorGlyphPainter.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <strings.h>
#include <utility>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H
#include FT_TRUETYPE_TABLES_H
#include <hb-ft.h>
#include <hb.h>

namespace Ubiquitty::Linux {

namespace {

// HarfBuzz's codepoint field contains a face-local glyph index after shaping.
unsigned int glyphIndexOf(const hb_glyph_info_t& glyph)
{
    return static_cast<const hb_glyph_info_t&>(glyph).codepoint;
}

bool containsLastResort(const std::string& family) { return strcasestr(family.c_str(), "lastresort") != nullptr || strcasestr(family.c_str(), "last resort") != nullptr; }

bool isUnifontFamily(const std::string& family) { return strcasestr(family.c_str(), "unifont") != nullptr; }

std::string faceFamily(FT_Face face) { return (face && face->family_name) ? std::string(face->family_name) : std::string(); }

std::string facePostScriptName(FT_Face face)
{
    const char* name = face ? FT_Get_Postscript_Name(face) : nullptr;
    return name ? std::string(name) : faceFamily(face);
}

bool isBoldStyle(Rendering::Font::FontStyle style)
{
    return style == Rendering::Font::FontStyle::Bold || style == Rendering::Font::FontStyle::BoldItalic;
}

int fontWeight(const Rendering::Font::FontFamilyRequest& request)
{
    return static_cast<int>(Rendering::Font::weightForFace(static_cast<Rendering::FontFace>(request.style), request.variableWeight, {}));
}

void addStyle(FcPattern* pattern, const Rendering::Font::FontFamilyRequest& request)
{
    FcPatternAddInteger(pattern, FC_WEIGHT, FcWeightFromOpenType(fontWeight(request)));
    const bool isItalic = request.style == Rendering::Font::FontStyle::Italic || request.style == Rendering::Font::FontStyle::BoldItalic;
    FcPatternAddInteger(pattern, FC_SLANT, isItalic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN);
}

bool setFaceSize(FT_Face face, int fontPixelSize)
{
    if (FT_Set_Pixel_Sizes(face, 0, static_cast<FT_UInt>(fontPixelSize)) == 0) {
        return true;
    }
    if (face->num_fixed_sizes <= 0) {
        return false;
    }
    int best = 0;
    for (int index = 1; index < face->num_fixed_sizes; ++index) {
        if (std::abs(face->available_sizes[index].height - fontPixelSize) < std::abs(face->available_sizes[best].height - fontPixelSize)) {
            best = index;
        }
    }
    return FT_Select_Size(face, best) == 0;
}

Rendering::FontMetrics::FallbackMetrics fallbackMetrics(FT_Face face)
{
    if (!face || !face->units_per_EM)
        return {};
    const double em = face->units_per_EM;
    const auto* table = static_cast<const TT_OS2*>(FT_Get_Sfnt_Table(face, ft_sfnt_os2));
    const auto letterHeight = [&](char32_t letter) {
        const FT_UInt glyph = FT_Get_Char_Index(face, letter);
        if (!glyph || FT_Load_Glyph(face, glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING) != 0)
            return 0.0;
        return static_cast<double>(face->glyph->metrics.height) / em;
    };
    return {
        table && table->version >= 2 && table->version != 0xffff && table->sxHeight > 0 ? table->sxHeight / em : letterHeight(U'x'),
        table && table->version >= 2 && table->version != 0xffff && table->sCapHeight > 0 ? table->sCapHeight / em : letterHeight(U'H'),
        face->height / em
    };
}

bool rendersColorGlyph(FT_Face face, unsigned int glyph)
{
    if (!FT_HAS_COLOR(face)) {
        return false;
    }
    if (ColorGlyphPainter::hasPaintGraph(face, glyph)) {
        constexpr int edge = 16;
        std::array<std::uint8_t, edge * edge * 4> canvas {};
        ColorGlyphPainter painter;
        const double scale = static_cast<double>(edge) / std::max(1, static_cast<int>(face->size->metrics.y_ppem));
        return painter.paint(face, glyph, { 180, 180, 180, 255 }, { canvas, edge, edge }, { 0.0, edge * 0.25, scale }).has_value();
    }
    if (FT_Load_Glyph(face, glyph, FT_LOAD_COLOR | FT_LOAD_RENDER) != 0) {
        return false;
    }
    const FT_Bitmap& bitmap = face->glyph->bitmap;
    return bitmap.pixel_mode == FT_PIXEL_MODE_BGRA && bitmap.width > 0 && bitmap.rows > 0;
}

} // namespace

LinuxFontInventory::LinuxFontInventory(int fontPixelSize, std::string primaryFamily,
    std::string bundledFontDirectory, Rendering::FontMetrics::FallbackSizing fallbackSizing)
    : m_fontPixelSize(fontPixelSize > 0 ? fontPixelSize : 16)
    , m_fallbackSizing(fallbackSizing)
    , m_primaryFamily(std::move(primaryFamily))
    , m_bundledFontDirectory(std::move(bundledFontDirectory))
{
    if (FT_Init_FreeType(&m_library) != 0)
        m_library = nullptr;
}

LinuxFontInventory::~LinuxFontInventory()
{
    for (FaceRecord& record : m_faces) {
        if (record.face)
            FT_Done_Face(record.face);
    }
    if (m_library)
        FT_Done_FreeType(m_library);
}

void LinuxFontInventory::setPrimaryFaces(FT_FaceRec_* regular, FT_FaceRec_* bold)
{
    const auto retain = [&](FT_Face face) -> Rendering::Font::FontHandle {
        if (!face || FT_Reference_Face(face) != 0) {
            return {};
        }
        return rememberFace(face, faceFamily(face), facePostScriptName(face));
    };
    m_primary[0] = retain(regular);
    m_primary[1] = bold && bold != regular ? retain(bold) : m_primary[0];
    m_primary[2] = m_primary[0];
    m_primary[3] = m_primary[1];
}

Rendering::Font::FontHandle LinuxFontInventory::primaryFont(Rendering::Font::FontStyle style, std::uint8_t variableWeight)
{
    Rendering::Font::FontHandle& primary = m_primary[static_cast<std::size_t>(style)];
    if (!primary.isValid()) {
        primary = loadFamily({ m_primaryFamily.empty() ? "monospace" : std::string_view(m_primaryFamily), style, variableWeight }, false);
    }
    return primary;
}

Rendering::Font::FontHandle LinuxFontInventory::validateFamily(const Rendering::Font::FontFamilyRequest& request)
{
    if (request.family.empty())
        return {};
    return loadFamily(request, true);
}

Rendering::Font::GlyphProbeResult LinuxFontInventory::glyphForCodePoint(Rendering::Font::FontHandle handle, std::uint32_t codePoint)
{
    FaceRecord* record = recordFor(handle);
    if (!record || !record->face)
        return {};
    FT_UInt glyph = FT_Get_Char_Index(record->face, codePoint);
    return { handle, { glyph }, glyph != 0, record->lastResort };
}

Rendering::Font::CascadeResult LinuxFontInventory::cascadeForCodePoint(const Rendering::Font::CascadeRequest& request)
{
    return cascadeForRun(request);
}

Rendering::Font::CascadeResult LinuxFontInventory::cascadeForRun(const Rendering::Font::CascadeRequest& request)
{
    const Rendering::Font::FontHandle font = loadCascade(request);
    const Rendering::Font::GlyphProbeResult probe = glyphForCluster(font, request.codePoints, request.presentation);
    return { probe.font, probe.glyph, probe.present, probe.lastResort };
}

Rendering::Font::GlyphProbeResult LinuxFontInventory::glyphForCluster(Rendering::Font::FontHandle handle, std::span<const std::uint32_t> codePoints, Rendering::Font::Presentation presentation)
{
    using Rendering::Font::Presentation;
    FT_Face face = faceFor(handle);
    if (!face || codePoints.empty() || (presentation == Presentation::Text && FT_HAS_COLOR(face))) {
        return {};
    }
    const std::unique_ptr<hb_font_t, decltype(&hb_font_destroy)> shaper(hb_ft_font_create_referenced(face), hb_font_destroy);
    const std::unique_ptr<hb_buffer_t, decltype(&hb_buffer_destroy)> buffer(hb_buffer_create(), hb_buffer_destroy);
    for (std::size_t index = 0; index < codePoints.size(); ++index) {
        hb_buffer_add(buffer.get(), codePoints[index], static_cast<unsigned int>(index));
    }
    hb_buffer_set_content_type(buffer.get(), HB_BUFFER_CONTENT_TYPE_UNICODE);
    // Unconsumed joiners and tags must remain visible to the coverage proof;
    // otherwise an unsupported sequence can look like its covered lead glyph.
    hb_buffer_set_flags(buffer.get(), HB_BUFFER_FLAG_PRESERVE_DEFAULT_IGNORABLES);
    hb_buffer_guess_segment_properties(buffer.get());
    hb_shape(shaper.get(), buffer.get(), nullptr, 0);
    unsigned int count = 0;
    const hb_glyph_info_t* glyphs = hb_buffer_get_glyph_infos(buffer.get(), &count);
    unsigned int firstGlyph = 0;
    unsigned int visibleGlyphs = 0;
    for (unsigned int index = 0; index < count; ++index) {
        if (glyphIndexOf(glyphs[index]) == 0) {
            return {};
        }
        const unsigned int cluster = glyphs[index].cluster;
        if (cluster < codePoints.size() && Unicode::Width::isInvisibleFormat(codePoints[cluster])) {
            continue;
        }
        if (!firstGlyph) {
            firstGlyph = glyphIndexOf(glyphs[index]);
        }
        ++visibleGlyphs;
    }
    if (!firstGlyph || (presentation == Presentation::Emoji && (count != 1 || visibleGlyphs != 1 || !rendersColorGlyph(face, firstGlyph)))) {
        return {};
    }
    return { handle, { firstGlyph }, true, isLastResort(handle) };
}

bool LinuxFontInventory::isLastResort(Rendering::Font::FontHandle handle) const
{
    const FaceRecord* record = recordFor(handle);
    return record && record->lastResort;
}

std::string_view LinuxFontInventory::familyName(Rendering::Font::FontHandle handle) const
{
    const FaceRecord* record = recordFor(handle);
    return record ? std::string_view(record->family) : std::string_view();
}

std::string_view LinuxFontInventory::postScriptName(Rendering::Font::FontHandle handle) const
{
    const FaceRecord* record = recordFor(handle);
    return record ? std::string_view(record->postScriptName) : std::string_view();
}

Rendering::Font::FontHandle LinuxFontInventory::loadFamily(const Rendering::Font::FontFamilyRequest& request, bool requireExactFamily) // bool-ok: Validates the fontconfig family-match predicate.
{
    if (!m_library)
        return {};
    std::string familyString(request.family);
    // A family this project ships opens the file it ships, before fontconfig is
    // asked — the route the primary and glyph-fallback faces take. Asking
    // fontconfig first lets a machine carrying its own copy of a shipped family
    // decide what every cell routed here draws: there the pattern resolves to
    // that file, everywhere else to ours, and a golden the two machines share
    // records whichever of them minted it.
    std::string shipped = bundledFontPath(familyString, m_bundledFontDirectory);
    const std::string_view boldFile = Rendering::bundledBoldFontFile(request.family);
    if (isBoldStyle(request.style) && !boldFile.empty() && !shipped.empty()) {
        shipped = shipped.substr(0, shipped.find_last_of('/') + 1) + std::string(boldFile);
    }
    if (!shipped.empty()) {
        const Rendering::Font::FontHandle bundled = loadFile(shipped, 0, request, FontFileSource::Bundled);
        if (bundled.isValid()) {
            return bundled;
        }
    }
    if (FcInit() != FcTrue) {
        return {};
    }
    FcPattern* pattern = FcNameParse(reinterpret_cast<const FcChar8*>(familyString.c_str()));
    if (!pattern)
        return {};
    addStyle(pattern, request);
    FcConfigSubstitute(FcConfigGetCurrent(), pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);
    FcResult result = FcResultNoMatch;
    FcPattern* match = FcFontMatch(FcConfigGetCurrent(), pattern, &result);
    FcPatternDestroy(pattern);
    if (!match)
        return {};

    FcChar8* file = nullptr;
    FcChar8* resolvedFamily = nullptr;
    bool exact = false;
    for (int index = 0; FcPatternGetString(match, FC_FAMILY, index, &resolvedFamily) == FcResultMatch; ++index) {
        exact |= strcasecmp(reinterpret_cast<const char*>(resolvedFamily), familyString.c_str()) == 0;
    }
    if (requireExactFamily && !exact) {
        FcPatternDestroy(match);
        return {};
    }
    if (FcPatternGetString(match, FC_FILE, 0, &file) != FcResultMatch || !file) {
        FcPatternDestroy(match);
        return {};
    }

    int faceIndex = 0;
    FcPatternGetInteger(match, FC_INDEX, 0, &faceIndex);
    const Rendering::Font::FontHandle handle = loadFile(reinterpret_cast<const char*>(file), faceIndex, request, FontFileSource::System);
    FcPatternDestroy(match);
    return handle;
}

Rendering::Font::FontHandle LinuxFontInventory::loadCascade(const Rendering::Font::CascadeRequest& request)
{
    using namespace Rendering::Font;
    if (!m_library || request.codePoints.empty()) {
        return {};
    }
    const FontFamilyRequest style { {}, request.style, request.variableWeight };
    if (request.presentation == Presentation::Emoji) {
        const FontHandle bundled = loadFamily({ "Noto Color Emoji", request.style, request.variableWeight }, true);
        if (glyphForCluster(bundled, request.codePoints, request.presentation).present) {
            return bundled;
        }
    }
    if (FcInit() != FcTrue) {
        return {};
    }
    FcPattern* pattern = FcPatternCreate();
    if (!pattern)
        return {};
    // The configured family heads the pattern, so the sort starts where the
    // face that missed would have: fontconfig's aliases for a monospace family
    // rank the faces its own configuration pairs with it ahead of the rest.
    const std::string family = m_primaryFamily.empty() ? std::string("monospace") : m_primaryFamily;
    FcPatternAddString(pattern, FC_FAMILY, reinterpret_cast<const FcChar8*>(family.c_str()));
    FcCharSet* charset = FcCharSetCreate();
    if (charset) {
        for (const std::uint32_t codePoint : request.codePoints) {
            if (!Unicode::Width::isInvisibleFormat(codePoint)) {
                FcCharSetAddChar(charset, codePoint);
            }
        }
        FcPatternAddCharSet(pattern, FC_CHARSET, charset);
        FcCharSetDestroy(charset);
    }
    addStyle(pattern, style);
    if (!request.language.value.empty()) {
        std::string tag(request.language.value);
        FcPatternAddString(pattern, FC_LANG, reinterpret_cast<const FcChar8*>(tag.c_str()));
    }
    if (request.presentation == Presentation::Emoji) {
        FcPatternAddBool(pattern, FC_COLOR, FcTrue);
    }
    FcConfigSubstitute(FcConfigGetCurrent(), pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);
    FcResult result = FcResultNoMatch;
    const std::unique_ptr<FcFontSet, decltype(&FcFontSetDestroy)> fonts(FcFontSort(FcConfigGetCurrent(), pattern, FcFalse, nullptr, &result), FcFontSetDestroy);
    FcPatternDestroy(pattern);
    if (!fonts) {
        return {};
    }
    const bool wantsColor = request.presentation == Presentation::Emoji;
    for (int index = 0; index < fonts->nfont; ++index) {
        const FcPattern* candidate = fonts->fonts[index];
        // Scalable faces only: a bitmap strike draws at one size, and the
        // bitmap tier this cascade stands in front of is Unifont's.
        FcBool scalable = FcFalse;
        if (FcPatternGetBool(candidate, FC_SCALABLE, 0, &scalable) != FcResultMatch || scalable != FcTrue)
            continue;
        // A colour face for emoji presentation, a coverage face otherwise.
        FcBool color = FcFalse;
        if (FcPatternGetBool(candidate, FC_COLOR, 0, &color) != FcResultMatch)
            color = FcFalse;
        if ((color == FcTrue) != wantsColor)
            continue;
        unsigned char* candidateFamily = nullptr;
        FcPatternGetString(candidate, FC_FAMILY, 0, &candidateFamily);
        const std::string familyName = candidateFamily ? reinterpret_cast<const char*>(candidateFamily) : std::string();
        // Unifont is the backstop the rasterizer draws from its own copy once
        // every face here has missed, so an installed copy is not a cascade
        // answer: taken here it would draw ahead of a scalable face later in
        // the sort.
        if (isUnifontFamily(familyName) || containsLastResort(familyName))
            continue;
        // Coverage is read from the pattern before any face is opened. The
        // cascade runs on every fallback miss and the list is untrimmed, so a
        // character no installed face carries would otherwise open every
        // candidate in it, and each open face stays resident.
        FcCharSet* candidateCoverage = nullptr;
        if (FcPatternGetCharSet(candidate, FC_CHARSET, 0, &candidateCoverage) != FcResultMatch || !candidateCoverage)
            continue;
        bool isCovered = true;
        for (const std::uint32_t codePoint : request.codePoints) {
            if (!Unicode::Width::isInvisibleFormat(codePoint) && FcCharSetHasChar(candidateCoverage, codePoint) != FcTrue)
                isCovered = false;
        }
        if (!isCovered)
            continue;
        unsigned char* file = nullptr;
        int faceIndex = 0;
        FcPatternGetInteger(candidate, FC_INDEX, 0, &faceIndex);
        if (FcPatternGetString(candidate, FC_FILE, 0, &file) != FcResultMatch || !file) {
            continue;
        }
        const FontHandle font = loadFile(reinterpret_cast<const char*>(file), faceIndex, style, FontFileSource::System, request.baseFont);
        const GlyphProbeResult probe = glyphForCluster(font, request.codePoints, request.presentation);
        if (probe.present && !probe.lastResort) {
            return font;
        }
    }
    return {};
}

Rendering::Font::FontHandle LinuxFontInventory::loadFile(std::string file, int faceIndex, const Rendering::Font::FontFamilyRequest& request, FontFileSource fileSource, Rendering::Font::FontHandle sizingBase)
{
    if (!sizingBase.isValid())
        sizingBase = request.sizingBase;
    const auto sizing = request.sizing == Rendering::FontMetrics::FallbackSizing::Inherit ? m_fallbackSizing : request.sizing;
    for (const FaceRecord& record : m_faces) {
        if (record.file == file && record.faceIndex == faceIndex && record.style == request.style && record.variableWeight == request.variableWeight && record.sizingBase == sizingBase && record.sizing == sizing) {
            return record.handle;
        }
    }
    FT_Face face = nullptr;
    if (FT_New_Face(m_library, file.c_str(), faceIndex, &face) != 0) {
        return {};
    }
    if (!setFaceSize(face, m_fontPixelSize)) {
        FT_Done_Face(face);
        return {};
    }
    FT_MM_Var* variations = nullptr;
    if (FT_Get_MM_Var(face, &variations) == 0 && variations) {
        std::vector<FT_Fixed> coordinates(variations->num_axis);
        for (FT_UInt index = 0; index < variations->num_axis; ++index) {
            const FT_Var_Axis& axis = variations->axis[index];
            coordinates[index] = axis.tag == FT_MAKE_TAG('w', 'g', 'h', 't')
                ? std::clamp(static_cast<FT_Fixed>(fontWeight(request)) * 65536, axis.minimum, axis.maximum)
                : axis.def;
        }
        FT_Set_Var_Design_Coordinates(face, variations->num_axis, coordinates.data());
        FT_Done_MM_Var(m_library, variations);
    }
    if (sizing == Rendering::FontMetrics::FallbackSizing::MatchPrimary && !FT_HAS_COLOR(face)) {
        if (FT_Face base = faceFor(sizingBase)) {
            const double scale = Rendering::FontMetrics::fallbackScale(fallbackMetrics(base), fallbackMetrics(face));
            const auto height = static_cast<FT_F26Dot6>(std::lround(std::clamp(m_fontPixelSize * scale, 1.0, 4096.0) * 64.0));
            if (FT_Set_Char_Size(face, 0, height, 72, 72) != 0) {
                FT_Done_Face(face);
                return {};
            }
        }
    }
    const Rendering::Font::FontHandle handle = rememberFace(face, faceFamily(face), facePostScriptName(face), fileSource == FontFileSource::Bundled ? file : "");
    FaceRecord& record = m_faces.back();
    record.file = std::move(file);
    record.faceIndex = faceIndex;
    record.style = request.style;
    record.variableWeight = request.variableWeight;
    record.sizingBase = sizingBase;
    record.sizing = sizing;
    return handle;
}

Rendering::Font::FontHandle LinuxFontInventory::rememberFace(FT_FaceRec_* face, std::string family, std::string postScriptName,
    std::string bundledSource)
{
    Rendering::Font::FontHandle handle { static_cast<std::uint32_t>(m_faces.size() + 1), m_generation };
    // Read last-resort before the std::move(family) below: a braced-init list
    // evaluates left-to-right, so moving family first leaves containsLastResort
    // reading a moved-from string — the reject silently fails and tofu is kept.
    const bool lastResort = containsLastResort(family);
    m_faces.push_back({ handle, face, std::move(family), std::move(postScriptName), std::move(bundledSource), lastResort });
    return handle;
}

std::string_view LinuxFontInventory::bundledSourceFor(Rendering::Font::FontHandle handle) const
{
    const FaceRecord* record = recordFor(handle);
    return record ? std::string_view(record->bundledSource) : std::string_view();
}

FT_FaceRec_* LinuxFontInventory::faceFor(Rendering::Font::FontHandle handle) const
{
    const FaceRecord* record = recordFor(handle);
    return record ? record->face : nullptr;
}

LinuxFontInventory::FaceRecord* LinuxFontInventory::recordFor(Rendering::Font::FontHandle handle)
{
    if (!handle.isValid() || handle.value == 0 || handle.value > m_faces.size())
        return nullptr;
    FaceRecord& record = m_faces[handle.value - 1];
    return record.handle.generation == handle.generation ? &record : nullptr;
}

const LinuxFontInventory::FaceRecord* LinuxFontInventory::recordFor(Rendering::Font::FontHandle handle) const
{
    if (!handle.isValid() || handle.value == 0 || handle.value > m_faces.size())
        return nullptr;
    const FaceRecord& record = m_faces[handle.value - 1];
    return record.handle.generation == handle.generation ? &record : nullptr;
}

} // namespace Ubiquitty::Linux
