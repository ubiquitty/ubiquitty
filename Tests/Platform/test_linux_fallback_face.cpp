// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

// test_linux_fallback_face — which file the glyph-fallback face is opened from.
//
// A family name cannot answer that question, and it is the question that
// matters: the Symbols Nerd Font this project ships and a copy a machine has
// installed carry the same family, and the two files are different builds. So
// the answer decides what every symbol and box cell draws, and a golden shared
// by two machines records whichever of them minted it.
//
// The case pins the rule the primary face already follows: a family the bundle
// table names opens the shipped file, without fontconfig being asked. Its
// control is a family the table does not name, which must reach the bundled
// default instead — the two are handed different files here precisely so that
// "the parameter always wins" cannot pass as "the table was consulted".
//
// Neither case depends on the host having a copy installed. Where one is
// installed, the case is what stops fontconfig answering; where none is, it
// still says the table was read, which is the property that makes the two
// machines agree.

#include "Core/Preferences/FontRoutePreferences.h"
#include "Core/Preferences/Preferences.h"
#include "Core/Rendering/BoxDrawingRasterizer.h"
#include "Core/Rendering/GlyphTiling.h"
#include "Platform/Linux/FontInventory.h"
#include "Platform/Linux/FreeTypeRasterizer.h"
#include <cmath>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <strings.h>
#include <unistd.h>
#include <vector>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H

namespace {

constexpr int fontPixelSize = 16;

/// The bundled directory, absolute, the way the app's rasterizer is given it.
///
/// From the build rather than from `__FILE__`, which the compiler cache
/// rewrites to a repo-relative path that resolves against nothing here.
///
/// - Parameter file: A file name inside the bundled font directory.
/// - Returns: The absolute path to it.
std::string bundled(const char* file)
{
    return std::string(UBQ_BUNDLED_FONTS_DIR) + "/" + file;
}

/// Owns an isolated bundle containing a regular proportional face and no bold.
class RegularOnlyBundle {
public:
    RegularOnlyBundle()
    {
        char pathTemplate[] = "/tmp/ubiquitty-regular-only-XXXXXX";
        if (const char* path = ::mkdtemp(pathTemplate)) {
            m_directory = path;
            m_hasRegular = ::symlink(bundled("NotoSans-Regular.ttf").c_str(),
                               (m_directory + "/NotoSans-Regular.ttf").c_str())
                == 0;
        }
    }

    ~RegularOnlyBundle()
    {
        if (!m_directory.empty()) {
            ::unlink((m_directory + "/NotoSans-Regular.ttf").c_str());
            ::rmdir(m_directory.c_str());
        }
    }

    RegularOnlyBundle(const RegularOnlyBundle&) = delete;
    RegularOnlyBundle& operator=(const RegularOnlyBundle&) = delete;

    [[nodiscard]] bool isReady() const { return m_hasRegular; }
    [[nodiscard]] std::string fallbackPath() const { return m_directory + "/SymbolsNerdFontMono-Regular.ttf"; }

private:
    std::string m_directory;
    bool m_hasRegular = false;
};

/// Registers the shipped font directory with fontconfig, so the system
/// cascade has scalable faces to answer from on every host rather than only on
/// one that installs them.
///
/// - Returns: True when fontconfig took the directory.
bool registerBundledFonts()
{
    if (FcInit() != FcTrue)
        return false;
    return FcConfigAppFontAddDir(FcConfigGetCurrent(), reinterpret_cast<const FcChar8*>(UBQ_BUNDLED_FONTS_DIR)) == FcTrue;
}

/// The `[font]` fallback preferences a configuration with one range map
/// builds.
///
/// - Parameters:
///   - codePoint: The single code point the range covers.
///   - family: The family the range routes to.
/// - Returns: The preferences, as the frontend hands them to the rasterizer.
Ubiquitty::Preferences::FontRoutePreferences rangeMapTo(std::uint32_t codePoint, const char* family)
{
    Ubiquitty::Preferences::Values config;
    Ubiquitty::Preferences::RangeMapEntry entry;
    entry.firstCodePoint = codePoint;
    entry.lastCodePoint = codePoint;
    entry.mode = "custom";
    entry.family = family;
    config.rangeMap.push_back(entry);
    return Ubiquitty::Preferences::buildFontRoutePreferences(config);
}

/// Whether fontconfig knows a scalable, monochrome face other than Unifont
/// that carries `codePoint`: the face the system cascade tier exists to reach.
///
/// - Parameter codePoint: The character to look for.
/// - Returns: True when such a face is installed.
bool hostHasScalableTextFaceFor(std::uint32_t codePoint)
{
    if (FcInit() != FcTrue)
        return false;
    FT_Library library = nullptr;
    if (FT_Init_FreeType(&library) != 0)
        return false;
    FcPattern* pattern = FcPatternCreate();
    FcPatternAddBool(pattern, FC_SCALABLE, FcTrue);
    FcPatternAddBool(pattern, FC_COLOR, FcFalse);
    FcObjectSet* objects = FcObjectSetBuild(FC_FAMILY, FC_FILE, FC_INDEX, nullptr);
    FcFontSet* fonts = FcFontList(nullptr, pattern, objects);
    bool found = false;
    for (int index = 0; fonts && index < fonts->nfont && !found; ++index) {
        unsigned char* family = nullptr;
        unsigned char* file = nullptr;
        int faceIndex = 0;
        if (FcPatternGetString(fonts->fonts[index], FC_FAMILY, 0, &family) != FcResultMatch || !family
            || strcasestr(reinterpret_cast<const char*>(family), "unifont")
            || FcPatternGetString(fonts->fonts[index], FC_FILE, 0, &file) != FcResultMatch || !file)
            continue;
        if (FcPatternGetInteger(fonts->fonts[index], FC_INDEX, 0, &faceIndex) != FcResultMatch)
            faceIndex = 0;
        FT_Face face = nullptr;
        if (FT_New_Face(library, reinterpret_cast<const char*>(file), faceIndex, &face) != 0)
            continue;
        found = FT_Get_Char_Index(face, codePoint) != 0;
        FT_Done_Face(face);
    }
    if (fonts)
        FcFontSetDestroy(fonts);
    FcObjectSetDestroy(objects);
    FcPatternDestroy(pattern);
    FT_Done_FreeType(library);
    return found;
}

/// How many coverage values lie strictly between empty and full.
///
/// An outline rasterised with antialiasing leaves partial coverage along every
/// edge; Unifont is a 1-bit face and leaves none.
///
/// - Parameter coverage: An R8 slot.
/// - Returns: The count of partially covered pixels.
int partialCoverage(const std::vector<std::uint8_t>& coverage)
{
    return static_cast<int>(std::ranges::count_if(coverage, [](std::uint8_t value) { return value != 0 && value != 255; }));
}

} // namespace

TEST(aCharacterThePrimaryLacksDrawsFromAScalableSystemFaceBeforeUnifont)
{
    // The configured family, then a scalable system face that carries the
    // character, then Unifont: CoreText's cascade order on macOS. None of
    // these is in the shipped monospace face or the symbol fallback, and
    // Unifont carries all of them. U+0250 is in the shipped Noto Sans and
    // U+263A in the shipped Monaspace Neon, so the fixture the cascade needs
    // ships with the test. U+263A is also in the colour emoji face, which a
    // text cell must not be handed. U+6771 needs an installed CJK face, Noto
    // Sans CJK on the Linux hosts this runs on.
    CHECK_MSG(registerBundledFonts(), "the shipped fonts are registered with fontconfig as the cascade's fixture");
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf")
    };
    CHECK(rasterizer.ready());
    const int width = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth)) * 2;
    const int height = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight));
    for (const std::uint32_t codePoint : { 0x0250u, 0x263Au, 0x6771u }) {
        CHECK_MSG(rasterizer.glyphIndexForCodePoint(codePoint) == 0, "the primary lacks it, so a fallback tier draws it");
        if (!hostHasScalableTextFaceFor(codePoint)) {
            std::printf("    no scalable text face carries U+%04X on this host\n", codePoint);
            CHECK_MSG(false, "a scalable text face carrying it is the fixture; U+6771 needs a CJK face installed, fonts-noto-cjk on Debian and Ubuntu");
            continue;
        }
        std::vector<std::uint8_t> coverage(static_cast<std::size_t>(width) * height, 0);
        CHECK(rasterizer.rasterizeGlyph(codePoint, Ubiquitty::Rendering::FontFace::Regular, 0, width, height, coverage.data()));
        CHECK_MSG(partialCoverage(coverage) > 0,
            "an antialiased outline, which the 1-bit Unifont backstop cannot produce");

        // The scaled raster takes the same face at its own size.
        std::vector<std::uint8_t> scaled(static_cast<std::size_t>(width) * height * 4, 0);
        CHECK(rasterizer.rasterizeGlyphScaled(codePoint, Ubiquitty::Rendering::FontFace::Regular, 0, 2, width * 2, height * 2, scaled.data()));
        CHECK_MSG(partialCoverage(scaled) > 0, "and at twice the size an outline drawn at that size");
    }

    // A private-use code point no configured face names stays on Unifont: the
    // cascade does not hand an icon slot to whichever face fills it.
    std::vector<std::uint8_t> privateUse(static_cast<std::size_t>(width) * height, 0);
    (void)rasterizer.rasterizeGlyph(0x10FFFD, Ubiquitty::Rendering::FontFace::Regular, 0, width, height, privateUse.data());
    CHECK_MSG(partialCoverage(privateUse) == 0, "a private-use code point is drawn by the 1-bit backstop");
}

TEST(aCascadedBaseCarriesItsMarkAboveTheSameLetter)
{
    // A two-cell base the configured faces lack, with a combining acute. The
    // cascaded face draws the whole cluster, so the mark comes from the face
    // the base does, at its size, centred over the letter its unmarked twin
    // draws at the same place.
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf")
    };
    CHECK(rasterizer.ready());
    constexpr std::uint32_t hiragana = 0x3042;
    if (!hostHasScalableTextFaceFor(hiragana) || !hostHasScalableTextFaceFor(0x0301)) {
        std::printf("    no scalable face carries U+3042 with U+0301 on this host\n");
        CHECK_MSG(false, "a CJK face is the fixture, fonts-noto-cjk on Debian and Ubuntu");
        return;
    }
    const int width = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth)) * 2 + 4;
    const int height = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight)) + 8;
    std::vector<std::uint8_t> alone(static_cast<std::size_t>(width) * height, 0);
    CHECK(rasterizer.rasterizeGlyph(hiragana, Ubiquitty::Rendering::FontFace::Regular, 0, width, height, alone.data()));
    const std::array<std::uint32_t, 2> marked { hiragana, 0x0301 };
    std::vector<std::uint8_t> cluster(static_cast<std::size_t>(width) * height, 0);
    CHECK(rasterizer.rasterizeCluster(marked.data(), 2, Ubiquitty::Rendering::FontFace::Regular, 0, width, height, cluster.data()));

    bool isBaseKept = true;
    int extraInk = 0;
    for (std::size_t index = 0; index < cluster.size(); ++index) {
        isBaseKept = isBaseKept && cluster[index] >= alone[index];
        extraInk += cluster[index] > alone[index] ? 1 : 0;
    }
    CHECK_MSG(isBaseKept, "the marked cell draws its base exactly where the unmarked twin does");
    CHECK_MSG(extraInk > 0, "and adds the mark's ink");

    const auto inkColumns = [&](const std::vector<std::uint8_t>& coverage, const std::vector<std::uint8_t>* under) {
        int first = width;
        int last = -1;
        for (std::size_t index = 0; index < coverage.size(); ++index) {
            if (coverage[index] > 0 && (!under || coverage[index] > (*under)[index])) {
                first = std::min(first, static_cast<int>(index % static_cast<std::size_t>(width)));
                last = std::max(last, static_cast<int>(index % static_cast<std::size_t>(width)));
            }
        }
        return std::pair { first, last };
    };
    const auto [baseFirst, baseLast] = inkColumns(alone, nullptr);
    const auto [markFirst, markLast] = inkColumns(cluster, &alone);
    CHECK_MSG(std::abs((markFirst + markLast) - (baseFirst + baseLast)) <= 2, "and the mark is centred over the letter");
    const auto inkTop = [&](const std::vector<std::uint8_t>& coverage, const std::vector<std::uint8_t>* under) {
        for (std::size_t index = 0; index < coverage.size(); ++index) {
            if (coverage[index] > 0 && (!under || coverage[index] > (*under)[index]))
                return static_cast<int>(index / static_cast<std::size_t>(width));
        }
        return height;
    };
    CHECK_MSG(inkTop(cluster, &alone) < inkTop(alone, nullptr), "and it stands above the letter's top stroke, not inside it");

    // The face the cascade names for the cluster draws the acute this wide.
    Ubiquitty::Linux::LinuxFontInventory inventory(fontPixelSize, "JetBrains Mono", UBQ_BUNDLED_FONTS_DIR);
    Ubiquitty::Rendering::Font::CascadeRequest request;
    request.codePoints = marked;
    const Ubiquitty::Rendering::Font::CascadeResult routed = inventory.cascadeForRun(request);
    FT_FaceRec_* const markFace = routed.present ? inventory.faceFor(routed.font) : nullptr;
    CHECK_MSG(markFace && FT_Load_Char(markFace, 0x0301, FT_LOAD_RENDER) == 0, "the cascade names a face carrying the cluster");
    if (markFace) {
        const int designedWidth = static_cast<int>(markFace->glyph->bitmap.width);
        std::printf("    mark ink %d..%d, the routed face's acute %d wide\n", markFirst, markLast, designedWidth);
        CHECK_MSG(std::abs((markLast - markFirst + 1) - designedWidth) <= 1, "drawn from the face the base comes from, at its size");
    }
}

TEST(aTextSelectorLeavesTheCharacterItsAloneFace)
{
    // U+2934 with VS15 is the arrow asked for as text, which it already is: the
    // selector routes nothing, so the cell draws the glyph the arrow alone
    // draws rather than one from a face chosen for carrying the selector too.
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf")
    };
    CHECK(rasterizer.ready());
    const int width = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth)) * 2;
    const int height = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight));
    for (const std::uint32_t arrow : { 0x2934U, 0x2602U }) {
        std::vector<std::uint8_t> alone(static_cast<std::size_t>(width) * height, 0);
        CHECK(rasterizer.rasterizeGlyph(arrow, Ubiquitty::Rendering::FontFace::Regular, 0, width, height, alone.data()));
        const std::array<std::uint32_t, 2> selected { arrow, 0xFE0E };
        std::vector<std::uint8_t> cluster(static_cast<std::size_t>(width) * height, 0);
        CHECK(rasterizer.rasterizeCluster(selected.data(), 2, Ubiquitty::Rendering::FontFace::Regular, 0, width, height, cluster.data()));
        CHECK_MSG(cluster == alone, "a text selector draws the character it follows unchanged");
    }
}

TEST(everyNerdFontIconDrawsFromTheBundledFaceWhateverFallbacksAreConfigured)
{
    // onefetch --nerd-fonts's language icons, with a glyph-fallback face and a
    // symbol family that carry none of them. Core routes a private-use
    // character the configured families lack to the bundled symbol face that
    // defines it, so each icon draws as an antialiased outline rather than as
    // Unifont's 1-bit box.
    CHECK_MSG(registerBundledFonts(), "the shipped fonts are registered with fontconfig");
    Ubiquitty::Preferences::Values config;
    config.symbolFallbackFont = "STIX Two Math";
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        fontPixelSize, "JetBrains Mono", "Noto Sans", bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf"), 1, 0, 0, 0, 0, 0.0, std::string(), std::string(),
        Ubiquitty::Linux::Ligatures::Enabled, Ubiquitty::Preferences::buildFontRoutePreferences(config)
    };
    CHECK(rasterizer.ready());
    const int width = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth)) * 2;
    const int height = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight));
    for (const std::uint32_t icon : { 0xE61DU, 0xE61EU, 0xE632U, 0xE755U, 0xE73CU, 0xF1183U }) {
        std::vector<std::uint8_t> coverage(static_cast<std::size_t>(width) * height, 0);
        CHECK(rasterizer.rasterizeGlyph(icon, Ubiquitty::Rendering::FontFace::Regular, 0, width, height, coverage.data()));
        std::printf("    U+%04X partial coverage %d\n", icon, partialCoverage(coverage));
        CHECK_MSG(partialCoverage(coverage) > 0, "the icon is the bundled face's outline");
    }
}

TEST(aFontRangeMapChangesTheFaceACellDrawsFrom)
{
    // The draw path routes its system cascade through the same policy and the
    // same configured preferences the route diagnostics do. U+0250 is in the
    // shipped Noto Sans and Monaspace Neon and in neither face below them, so a
    // range map naming one or the other is the only difference between the two
    // rasterizers, and the two shapes must differ in the cell.
    CHECK_MSG(registerBundledFonts(), "the shipped fonts are registered with fontconfig");
    const std::uint32_t turnedA = 0x0250;
    const auto inkFor = [&](const char* family) {
        Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
            fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
            bundled("JetBrainsMono[wght].ttf"), 1, 0, 0, 0, 0, 0.0, std::string(), std::string(),
            Ubiquitty::Linux::Ligatures::Enabled, rangeMapTo(turnedA, family)
        };
        const int width = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth)) * 2;
        const int height = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight));
        std::vector<std::uint8_t> coverage(static_cast<std::size_t>(width) * height, 0);
        if (!rasterizer.ready() || rasterizer.glyphIndexForCodePoint(turnedA) != 0
            || !rasterizer.rasterizeGlyph(turnedA, Ubiquitty::Rendering::FontFace::Regular, 0, width, height, coverage.data()))
            coverage.clear();
        return coverage;
    };

    const std::vector<std::uint8_t> noto = inkFor("Noto Sans");
    const std::vector<std::uint8_t> monaspace = inkFor("Monaspace Neon");
    CHECK_MSG(!noto.empty() && partialCoverage(noto) > 0, "the range-mapped Noto Sans draws an outline");
    CHECK_MSG(!monaspace.empty() && partialCoverage(monaspace) > 0, "the range-mapped Monaspace Neon draws an outline");
    CHECK_MSG(noto != monaspace, "and the range map decides which of the two the cell is drawn from");
}

TEST(aShippedFallbackFamilyOpensTheShippedFile)
{
    // The default handed in is a different file from the one the name
    // resolves to, so the assertion below can only pass by way of the table.
    const std::string defaultFile = bundled("NotoSans[wght].ttf");
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        fontPixelSize, "monospace", "Symbols Nerd Font Mono", defaultFile, std::string()
    };

    const std::string& source = rasterizer.bundledFallbackFaceSource();
    CHECK_MSG(source == bundled("SymbolsNerdFontMono-Regular.ttf"),
        "a family the bundle table names opens the file this project ships");
    CHECK_MSG(source != defaultFile,
        "and not the default it was handed, which is what the control turns on");
}

TEST(anUnshippedFallbackFamilyReachesTheBundledDefault)
{
    // The control. A name nothing ships cannot come from the table, and
    // fontconfig has no such family to offer, so the default is what is left.
    const std::string defaultFile = bundled("SymbolsNerdFontMono-Regular.ttf");
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        fontPixelSize, "monospace", "No Family By This Name", defaultFile, std::string()
    };

    CHECK_MSG(rasterizer.bundledFallbackFaceSource() == defaultFile,
        "a family the table does not name falls through to the bundled default");
}

TEST(aStaticFamilyDrawsItsBoldFromTheFileThatCarriesIt)
{
    // A family whose bold is a separate file has no `wght` axis to place, so
    // the weight machinery has nothing to move and a bold run comes out at the
    // body weight — the same colour as the text beside it, on an arm whose
    // CoreText twin draws it bold.
    //
    // Asserted as ink rather than as a path, because the path is not the claim:
    // a bold face that loaded and never reached the raster would satisfy any
    // question about which file is open.
    const std::string directory = std::string(UBQ_BUNDLED_FONTS_DIR);
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        32, "Monaspace Neon", std::string(),
        directory + "/SymbolsNerdFontMono-Regular.ttf",
        directory + "/MonaspaceNeon-Regular.otf"
    };

    constexpr int slot = 48;
    const auto inkOf = [&](Ubiquitty::Rendering::FontFace face) {
        std::vector<std::uint8_t> coverage(static_cast<std::size_t>(slot) * slot, 0);
        if (!rasterizer.rasterizeGlyph('m', face, 0, slot, slot, coverage.data()))
            return -1;
        int ink = 0;
        for (const std::uint8_t value : coverage)
            ink += value;
        return ink;
    };

    const int regular = inkOf(Ubiquitty::Rendering::FontFace::Regular);
    const int bold = inkOf(Ubiquitty::Rendering::FontFace::Bold);
    CHECK_MSG(regular > 0, "the shipped static family rasterises at all");
    CHECK_MSG(bold > 0, "and so does its bold");
    CHECK_MSG(bold > regular, "a bold cell carries more ink than the regular one");
}

TEST(aShippedFamilyDrawsItsItalicsFromItsOwnLetterforms)
{
    // A shipped family's italic cell draws the family's italic: from its
    // italic file, or for a family that carries its italic on a slant axis,
    // from that axis. Drawn upright, an SGR 3 run on this arm read as plain
    // text beside the CoreText arm's italic of the same file.
    //
    // Asserted as the lean of an upright stroke: the top half of an I's ink
    // sits to the right of its bottom half in an italic, and above it in no
    // upright face. Bold italic is the italic with more ink.
    const std::string directory = std::string(UBQ_BUNDLED_FONTS_DIR);
    struct Family {
        const char* name;
        const char* file;
    };
    for (const Family family : { Family { "JetBrains Mono", "JetBrainsMono[wght].ttf" },
             Family { "Monaspace Neon", "MonaspaceNeon-Regular.otf" },
             Family { "Monaspace Neon Var", "MonaspaceNeonVar.ttf" } }) {
        Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
            32, family.name, std::string(),
            directory + "/SymbolsNerdFontMono-Regular.ttf",
            directory + "/" + family.file
        };
        constexpr int slot = 48;
        struct Ink {
            int total = 0;
            double lean = 0.0;
        };
        const auto inkOf = [&](Ubiquitty::Rendering::FontFace face) {
            std::vector<std::uint8_t> coverage(static_cast<std::size_t>(slot) * slot, 0);
            Ink ink;
            if (!rasterizer.rasterizeGlyph('I', face, 0, slot, slot, coverage.data()))
                return ink;
            int firstRow = slot;
            int lastRow = -1;
            for (int row = 0; row < slot; ++row)
                for (int column = 0; column < slot; ++column)
                    if (coverage[static_cast<std::size_t>(row) * slot + column] != 0) {
                        firstRow = std::min(firstRow, row);
                        lastRow = std::max(lastRow, row);
                    }
            if (lastRow < firstRow)
                return ink;
            const int middle = (firstRow + lastRow) / 2;
            double weightTop = 0.0, sumTop = 0.0, weightBottom = 0.0, sumBottom = 0.0;
            for (int row = firstRow; row <= lastRow; ++row)
                for (int column = 0; column < slot; ++column) {
                    const int value = coverage[static_cast<std::size_t>(row) * slot + column];
                    ink.total += value;
                    (row < middle ? weightTop : weightBottom) += value;
                    (row < middle ? sumTop : sumBottom) += static_cast<double>(value) * column;
                }
            if (weightTop > 0.0 && weightBottom > 0.0)
                ink.lean = sumTop / weightTop - sumBottom / weightBottom;
            return ink;
        };
        const Ink regular = inkOf(Ubiquitty::Rendering::FontFace::Regular);
        const Ink italic = inkOf(Ubiquitty::Rendering::FontFace::Italic);
        const Ink boldItalic = inkOf(Ubiquitty::Rendering::FontFace::BoldItalic);
        const std::string name = family.name;
        CHECK_MSG(regular.total > 0 && italic.total > 0 && boldItalic.total > 0, (name + ": every style rasterises").c_str());
        CHECK_MSG(std::fabs(regular.lean) < 0.5, (name + ": the upright I stands upright: " + std::to_string(regular.lean)).c_str());
        CHECK_MSG(italic.lean > 1.0, (name + ": the italic I leans right: " + std::to_string(italic.lean)).c_str());
        CHECK_MSG(boldItalic.lean > 1.0, (name + ": and so does the bold italic: " + std::to_string(boldItalic.lean)).c_str());
        CHECK_MSG(boldItalic.total > italic.total, (name + ": the bold italic carries more ink than the italic").c_str());
    }
}

TEST(anUnavailableProportionalBoldBorrowsRegularThroughTeardown)
{
    RegularOnlyBundle bundle;
    CHECK(bundle.isReady());
    if (!bundle.isReady()) {
        return;
    }
    const std::array<std::uint32_t, 1> text = { 'W' };
    for (int iteration = 0; iteration < 16; ++iteration) {
        {
            Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
                fontPixelSize, "Monaspace Neon", std::string(),
                bundle.fallbackPath(), bundled("MonaspaceNeon-Regular.otf")
            };
            CHECK(rasterizer.hasProportionalFace());
            std::array<Ubiquitty::ProportionalShapedGlyph, 1> regular {};
            std::array<Ubiquitty::ProportionalShapedGlyph, 1> bold {};
            CHECK(rasterizer.shapeProportionalRun(text, Ubiquitty::Rendering::FontFace::Regular, regular) == 1);
            CHECK(rasterizer.shapeProportionalRun(text, Ubiquitty::Rendering::FontFace::Bold, bold) == 1);
            CHECK(regular[0].glyph != 0);
            CHECK(regular[0].glyph == bold[0].glyph);
            CHECK(regular[0].advanceInPixels == bold[0].advanceInPixels);
            std::vector<std::uint8_t> regularCoverage(32 * 32);
            std::vector<std::uint8_t> boldCoverage(32 * 32);
            CHECK(rasterizer.rasteriseProportionalRun(regular, Ubiquitty::Rendering::FontFace::Regular, 32, 32, regularCoverage));
            CHECK(rasterizer.rasteriseProportionalRun(bold, Ubiquitty::Rendering::FontFace::Bold, 32, 32, boldCoverage));
            CHECK(regularCoverage == boldCoverage);
            CHECK(std::ranges::any_of(regularCoverage, [](std::uint8_t value) { return value != 0; }));
        }
        CHECK_MSG(true, "the regular face survives both shaping paths and is released once");
    }
}

TEST(characterVariantsReachScalarGlyphsWithLigaturesDisabled)
{
    using namespace Ubiquitty::Rendering;
    std::vector<std::uint8_t> disabled;
    for (const char* features : { "-cv01", "cv01" }) {
        Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
            24, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
            bundled("JetBrainsMono[wght].ttf"), 1, 0, 0, 0, 0, 0, std::string(), features,
            Ubiquitty::Linux::Ligatures::Disabled
        };
        CHECK(rasterizer.ready());
        const int width = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth));
        const int height = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight));
        std::vector<std::uint8_t> scalar(width * height);
        std::vector<std::uint8_t> shapedCoverage(width * height);
        CHECK(rasterizer.rasterizeGlyph('l', FontFace::Regular, 0, width, height, scalar.data()));
        const std::array<std::uint32_t, 1> text { 'l' };
        std::array<Ubiquitty::Linux::FreeTypeRasterizer::ShapedGlyph, 8> shaped {};
        const int count = rasterizer.shapeTextRun(text, 0, shaped);
        CHECK(count > 0);
        CHECK(rasterizer.rasteriseShapedRun(std::span(shaped).first(count), width, height, shapedCoverage));
        CHECK(scalar == shapedCoverage);
        if (disabled.empty()) {
            CHECK(std::ranges::any_of(scalar, [](std::uint8_t value) { return value != 0; }));
            disabled = scalar;
        } else {
            CHECK(disabled != scalar);
        }
    }
}

TEST(tilingFallbackAndFontStemsReachTheCellWithoutEnteringAtlasMargins)
{
    using namespace Ubiquitty::Rendering;
    for (const char* family : { "Monaspace Neon", "JetBrains Mono" }) {
        for (int spacing : { 0, 5 }) {
            Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
                fontPixelSize, family, std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
                bundled(std::string(family) == "JetBrains Mono" ? "JetBrainsMono[wght].ttf" : "MonaspaceNeon-Regular.otf"), 1, spacing
            };
            CHECK(rasterizer.ready());
            const int cellWidth = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth));
            const int cellHeight = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight));
            constexpr int margin = 3;
            const int width = cellWidth + 2 * margin;
            const int height = cellHeight + 2 * margin;
            for (unsigned extension : { 0x239C, 0x239F, 0x23A2, 0x23A5, 0x23AE }) {
                std::vector<std::uint8_t> hook(width * height);
                std::vector<std::uint8_t> stem(width * height);
                CHECK(rasterizer.rasterizeGlyph(stemDonor(extension), FontFace::Regular, 0, width, height, hook.data()));
                CHECK(rasterizer.rasterizeGlyph(extension, FontFace::Regular, 0, width, height, stem.data()));
                CHECK(std::any_of(stem.begin(), stem.end(), [](auto value) { return value != 0; }));
                const auto seam = hook.begin() + (margin + cellHeight - 1) * width + margin;
                for (int row = margin; row < margin + cellHeight; ++row) {
                    CHECK(std::equal(seam, seam + cellWidth, stem.begin() + row * width + margin));
                }
                for (int row : { margin - 1, margin + cellHeight }) {
                    CHECK(std::all_of(stem.begin() + row * width + margin,
                        stem.begin() + row * width + margin + cellWidth, [](auto value) { return value == 0; }));
                }
            }
        }
    }
}

TEST(boxCornersStandOnTheColumnTheirVerticalsDo)
{
    // Through the decorator both Linux arms fault through, so the edge stretch
    // has carried every stroke to the cell's top and bottom rows, and those
    // rows say which columns a frame's vertical runs down. A corner whose ink
    // was centred lands half its arm away from the `│` in the next row.
    using namespace Ubiquitty::Rendering;
    enum class JoiningEdge {
        Bottom,
        Top
    };
    struct Piece {
        unsigned codePoint;
        unsigned vertical;
        JoiningEdge edge;
    };
    constexpr Piece pieces[] = {
        { 0x250C, 0x2502, JoiningEdge::Bottom }, // ┌
        { 0x2510, 0x2502, JoiningEdge::Bottom }, // ┐
        { 0x2514, 0x2502, JoiningEdge::Top }, // └
        { 0x2518, 0x2502, JoiningEdge::Top }, // ┘
        { 0x251C, 0x2502, JoiningEdge::Bottom }, // ├
        { 0x2524, 0x2502, JoiningEdge::Bottom }, // ┤
        { 0x252C, 0x2502, JoiningEdge::Bottom }, // ┬
        { 0x2534, 0x2502, JoiningEdge::Top }, // ┴
        { 0x2554, 0x2551, JoiningEdge::Bottom }, // ╔
        { 0x2557, 0x2551, JoiningEdge::Bottom }, // ╗
        { 0x255A, 0x2551, JoiningEdge::Top }, // ╚
        { 0x255D, 0x2551, JoiningEdge::Top }, // ╝
        { 0x2560, 0x2551, JoiningEdge::Bottom }, // ╠
        { 0x2563, 0x2551, JoiningEdge::Bottom }, // ╣
    };
    for (int spacing : { 0, 16 }) {
        Ubiquitty::Linux::FreeTypeRasterizer face {
            20, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
            bundled("JetBrainsMono[wght].ttf"), 1, spacing
        };
        CHECK(face.ready());
        BoxDrawingRasterizer boxes(face);
        const int cellWidth = static_cast<int>(std::lround(face.cellMetrics().cellWidth));
        const int cellHeight = static_cast<int>(std::lround(face.cellMetrics().cellHeight));
        constexpr int margin = 3;
        const int width = cellWidth + 2 * margin;
        const int height = cellHeight + 2 * margin;
        const auto inkedColumns = [&](unsigned codePoint, int row) {
            std::vector<std::uint8_t> coverage(static_cast<std::size_t>(width) * height, 0);
            std::vector<int> columns;
            if (!boxes.rasterizeGlyph(codePoint, FontFace::Regular, 0, width, height, coverage.data()))
                return columns;
            for (int column = margin; column < margin + cellWidth; ++column) {
                if (coverage[static_cast<std::size_t>(row) * width + column] >= 128)
                    columns.push_back(column);
            }
            return columns;
        };
        for (const Piece& piece : pieces) {
            const int row = piece.edge == JoiningEdge::Bottom ? margin + cellHeight - 1 : margin;
            const std::vector<int> vertical = inkedColumns(piece.vertical, row);
            CHECK(!vertical.empty());
            CHECK_MSG(inkedColumns(piece.codePoint, row) == vertical,
                "a box piece meets the vertical beside it on the same columns");
        }
    }
}

TEST(integralPiecesTheFacesLackAreFittedFromARoutedOutline)
{
    // JetBrains Mono and the Symbols Nerd Font ship none of the integral's
    // pieces. Core's routing names a system face that does, and each piece is
    // drawn from that outline fitted to the cell, as the parenthesis beside it
    // is. The bitmap tier draws them at its own 16-pixel design instead: a hook
    // a third of the row tall over a hairline stem.
    using namespace Ubiquitty::Rendering;
    constexpr int pixelSize = 32;
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        pixelSize, "JetBrains Mono", "Symbols Nerd Font Mono", bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf")
    };
    CHECK(rasterizer.ready());
    CHECK_MSG(rasterizer.glyphIndexForCodePoint(0x2320) == 0, "the primary face ships no integral piece");
    CHECK_MSG(hostHasScalableTextFaceFor(0x2320) && hostHasScalableTextFaceFor(0x2321),
        "a scalable system face carrying the integral's hooks is the fixture, DejaVu Sans on Debian and Ubuntu");

    const int width = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth));
    const int height = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight));
    const auto inkRows = [&](unsigned codePoint) {
        std::vector<std::uint8_t> coverage(static_cast<std::size_t>(width) * height);
        if (!rasterizer.rasterizeGlyph(codePoint, FontFace::Regular, 0, width, height, coverage.data()))
            return -1;
        int rows = 0;
        for (int row = 0; row < height; ++row) {
            const auto begin = coverage.begin() + static_cast<std::ptrdiff_t>(row) * width;
            rows += std::any_of(begin, begin + width, [](std::uint8_t value) { return value >= 128; }) ? 1 : 0;
        }
        return rows;
    };
    const int parenthesisHook = inkRows(0x239B);
    for (unsigned piece : { 0x2320, 0x23AE, 0x2321 }) {
        const int rows = inkRows(piece);
        CHECK_MSG(rows * 2 > height, "each integral piece fills most of the row, at the routed face's size");
        CHECK_MSG(rows * 4 >= parenthesisHook * 3, "and stands as tall as the parenthesis hook beside it");
    }
}

TEST(completeLinuxAssembliesConnectAtNativeAndScaledSizes)
{
    using namespace Ubiquitty::Rendering;
    const std::vector<std::vector<unsigned>> assemblies {
        { 0x2320, 0x23AE, 0x2321 },
        { 0x239B, 0x239C, 0x239D },
        { 0x23A1, 0x23A2, 0x23A3 },
        { 0x23A7, 0x23AA, 0x23A8, 0x23AA, 0x23A9 },
        { 0x23AB, 0x23AA, 0x23AC, 0x23AA, 0x23AD },
        { 0x23D0, 0x23D0 }
    };
    Ubiquitty::Linux::FreeTypeRasterizer rasterizer {
        fontPixelSize, "JetBrains Mono", std::string(), bundled("SymbolsNerdFontMono-Regular.ttf"),
        bundled("JetBrainsMono[wght].ttf"), 1, 7
    };
    CHECK(rasterizer.ready());
    CHECK(rasterizer.glyphIndexForCodePoint(0x239B) != 0);
    CHECK(rasterizer.glyphIndexForCodePoint(0x23A7) != 0);
    for (int scale : { 1, 2, 3 }) {
        const int width = static_cast<int>(std::lround(rasterizer.glyphOverhang().advanceWidth)) * scale;
        const int height = static_cast<int>(std::lround(rasterizer.cellMetrics().cellHeight)) * scale;
        for (const auto& assembly : assemblies) {
            std::vector<std::uint8_t> previous(width * height);
            std::vector<std::uint8_t> current(width * height);
            for (std::size_t piece = 0; piece < assembly.size(); ++piece) {
                CHECK(rasterizer.rasterizeGlyphScaled(assembly[piece], FontFace::Regular, 0, scale, width, height, current.data()));
                if (piece != 0) {
                    bool isJoined = false;
                    for (int column = 0; column < width; ++column) {
                        isJoined |= previous[(height - 1) * width + column] >= 128 && current[column] >= 128;
                    }
                    CHECK_MSG(isJoined, "each assembly shares solid coverage across its row boundary");
                }
                previous.swap(current);
            }
        }
    }
}

UBIQUITTY_TEST_MAIN()
