// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "TerminalFixture.h"

#include "Core/Accessibility/TextProjection.h"
#include "Core/RichText/Blocks.h"
#include "Core/RichText/Drawing.h"
#include "Core/RichText/RTFReader.h"
#include "Core/Terminal.h"
#include "Core/Unicode/UTF8Encoder.h"
#include "Platform/Linux/PangoRichText.h"

#include <pango/pangocairo.h>

#include <algorithm>
#include <array>
#include <memory>
#include <string>

namespace {

using namespace Ubiquitty;

struct FontMapRelease {
    void operator()(PangoFontMap* map) const { g_object_unref(map); }
};

struct Fixture {
    Linux::PangoRichText renderer;
    Terminal terminal;
    Rendering::CellMetrics metrics { .cellWidth = 8, .cellHeight = 18, .baselineFromTop = 14 };
    Rendering::TerminalFrameInputs frame;

    Fixture()
    {
        resize(terminal, 12, 80);
        terminal.typography.shaper = renderer.shaper();
        terminal.typography.fontCatalog = renderer.fontCatalog();
        publish();
    }

    void publish(double size = 12, double scale = 1, double monospaceSize = 12)
    {
        terminal.typography.facts = std::make_shared<const RichText::TypographyFacts>(renderer.configure("DejaVu Sans Mono", "DejaVu Sans", metrics, size, monospaceSize, scale));
        ++terminal.typography.epoch;
    }

    void place(std::string_view text, std::string_view keys = "w=30:h=4")
    {
        UbiquittyTest::feed(terminal, "\x1b[H\x1b]7404;g=1:C=1:i=1:" + std::string(keys) + ";{\\rtf1\\fs24 " + std::string(text) + "}\x1b\\");
    }

    std::vector<std::uint8_t> draw(std::span<const IntRect> occlusions = {})
    {
        Rendering::TerminalSnapshotOptions options;
        options.drawCursor = false;
        CHECK(frame.capture(terminal, options, metrics, {}));
        const int width = static_cast<int>(metrics.cellWidth) * terminal.columns;
        const int height = static_cast<int>(metrics.cellHeight) * terminal.rows;
        std::vector<std::uint8_t> pixels(static_cast<std::size_t>(width) * height * 4);
        renderer.composite(frame, pixels, width, height, occlusions);
        return pixels;
    }

    const RichText::Layout& layout()
    {
        return RichText::layoutOf(terminal, terminal.richTextBlocks.blocks(RichText::activeScreen(terminal)).front());
    }
};

} // namespace

TEST(nativeParagraphsWrapByTheirFontAndReportTerminalBaselines)
{
    Fixture fixture;
    fixture.place("iiiiiiiiiiiiiiiiiiiiiiiiiiiiii", "w=10:h=8");
    REQUIRE(fixture.terminal.richTextBlocks.blocks(RichText::activeScreen(fixture.terminal)).size() == 1);
    CHECK(fixture.layout().isShaped());
    CHECK_EQ(fixture.layout().line(0).height, 18u * 4096);
    CHECK_EQ(fixture.layout().line(0).baseline, 14u * 4096);
    const auto narrowLines = fixture.layout().visibleLineCount();
    fixture.place("WWWWWWWWWWWWWWWWWWWWWWWWWWWWWW", "w=10:h=8");
    CHECK(fixture.layout().isShaped());
    CHECK(fixture.layout().visibleLineCount() > narrowLines);
    UbiquittyTest::feed(fixture.terminal, "\x1b]7404;a=q:i=12:w=10:h=8:g=1;{\\rtf1 measured words}\x1b\\");
    std::array<char, 4096> reply {};
    const auto count = UbiquittyTest::drain(fixture.terminal, reply);
    const std::string response(reply.data(), static_cast<std::size_t>(count));
    CHECK(response.find(":Q=1") != std::string::npos);
    CHECK(response.find(":V=1") != std::string::npos);
}

// Pango wraps each paragraph at the width its indents leave and spaces its
// lines by the paragraph's properties, through the same rules Core's table
// layout uses; the ink lands at each line's indent.
TEST(nativeParagraphsTakeTheirIndentsAndSpacing)
{
    Fixture fixture;
    UbiquittyTest::feed(fixture.terminal, "\x1b[H\x1b]7404;C=1:i=1:w=20:h=8;{\\rtf1\\fs24\\li480\\fi-240\\ri240\\sb240\\sl-480 "
                                          "aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa\\par\\pard b}\x1b\\");
    const auto& layout = fixture.layout();
    REQUIRE(layout.isShaped());
    REQUIRE(layout.lineCount() >= 3);
    constexpr std::uint32_t point = 4096;
    // Eight-point cells: 160 points wide. The first line starts twelve points
    // in and wraps at 136; the others start at 24 and wrap at 124.
    CHECK_EQ(layout.line(0).origin, 12 * point);
    CHECK_EQ(layout.line(1).origin, 24 * point);
    CHECK(layout.line(0).width <= 136 * point);
    CHECK(layout.line(1).width <= 124 * point);
    // Exactly 24 points a line, the first twelve taller for the space before.
    CHECK_EQ(layout.line(0).height, 36 * point);
    CHECK(layout.line(0).baseline > 12 * point);
    CHECK_EQ(layout.line(1).top, 36 * point);
    CHECK_EQ(layout.line(1).height, 24 * point);
    const auto pixels = fixture.draw();
    const int width = 8 * 80;
    const auto inkBetween = [&](int top, int bottom, int left, int right) {
        for (int y = top; y < bottom; ++y) {
            for (int x = left; x < right; ++x) {
                if (pixels[(static_cast<std::size_t>(y) * width + x) * 4 + 3] != 0)
                    return true;
            }
        }
        return false;
    };
    CHECK(!inkBetween(0, 12, 0, 160));
    CHECK(!inkBetween(12, 36, 0, 12));
    CHECK(inkBetween(12, 36, 12, 40));
    CHECK(!inkBetween(36, 60, 0, 24));
    CHECK(inkBetween(36, 60, 24, 52));
}

// Pango wraps in the content box the padding leaves, and its lines and ink
// sit inside the padding.
TEST(nativeParagraphsSitInsideTheirPadding)
{
    Fixture fixture;
    UbiquittyTest::feed(fixture.terminal, "\x1b[H\x1b]7404;C=1:i=1:w=20:h=8:p=6,10,6,20;{\\rtf1\\fs24 aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa}\x1b\\");
    REQUIRE(fixture.terminal.richTextBlocks.blocks(RichText::activeScreen(fixture.terminal)).size() == 1);
    const auto& layout = fixture.layout();
    REQUIRE(layout.isShaped());
    REQUIRE(layout.lineCount() >= 2);
    constexpr std::uint32_t point = 4096;
    CHECK_EQ(layout.line(0).origin, 20 * point);
    CHECK_EQ(layout.line(0).top, 6 * point);
    // 160 points less 30 of side padding.
    CHECK(layout.line(0).width <= 130 * point);
    const auto pixels = fixture.draw();
    const int width = 8 * 80;
    const auto inkBetween = [&](int top, int bottom, int left, int right) {
        for (int y = top; y < bottom; ++y) {
            for (int x = left; x < right; ++x) {
                if (pixels[(static_cast<std::size_t>(y) * width + x) * 4 + 3] != 0)
                    return true;
            }
        }
        return false;
    };
    CHECK(!inkBetween(0, 6, 0, 160));
    CHECK(!inkBetween(0, 100, 0, 20));
    CHECK(inkBetween(6, 30, 20, 60));
}

TEST(nativeGraphemeCaretsPreserveCombiningEmojiAndBidi)
{
    Fixture fixture;
    fixture.place("é 😀 مرحبا ffi 漢字", "w=50:h=4");
    CHECK(fixture.layout().isShaped());
    CHECK_EQ(fixture.layout().graphemeEnd(0), 2u);
    CHECK(fixture.layout().continuesGrapheme(1));
    const auto& block = fixture.terminal.richTextBlocks.blocks(RichText::activeScreen(fixture.terminal)).front();
    RichText::ShapedText shape;
    const auto shaper = fixture.renderer.shaper();
    const RichText::ShapeRequest request { .width = 50, .height = 4, .lineMode = RichText::LineMode::Terminal };
    CHECK(shaper.function(shaper.context, &block.document, &request, fixture.terminal.typography.facts.get(), &shape));
    CHECK(std::ranges::any_of(shape.spans, [](const auto& span) { return span.leading > span.trailing; }));
    const auto pixels = fixture.draw();
    CHECK(std::ranges::any_of(pixels, [](auto byte) { return byte != 0; }));
}

TEST(unpublishedRTFFamiliesKeepTheirMonospaceClassInMeasureAndPaint)
{
    Fixture fixture;
    fixture.place("{\\fonttbl{\\f0\\fswiss Sans;}{\\f1\\fmodern Mono;}}\\f0 prose {\\f1 iiiWWW}");
    fixture.draw();
    const auto styles = fixture.frame.richTextDrawing(0).styles();
    CHECK(std::ranges::any_of(styles, [](const auto& style) { return style.familyClass == RichText::FamilyClass::Monospace; }));
    const auto& layout = fixture.layout();
    const auto first = layout.rightEdge(6) - layout.rightEdge(5);
    const auto last = layout.rightEdge(11) - layout.rightEdge(10);
    CHECK_EQ(first, last);
}

TEST(nativeFontCatalogPagesTheActualMapAndPinsItsRevision)
{
    Fixture fixture;
    const auto facts = *fixture.terminal.typography.facts;
    REQUIRE(facts.fontCatalogScope == RichText::FontCatalogScope::System);
    CHECK_EQ(facts.faceCount, 12u);
    const auto provider = fixture.renderer.fontCatalog();
    RichText::FontCatalogQuery query { .count = 7, .rendererRevision = facts.rendererRevision };
    std::vector<std::string> actual;
    std::uint32_t total = 0;
    do {
        RichText::FontCatalogPage page;
        REQUIRE(provider.function(provider.context, &query, &facts, &page));
        REQUIRE(page.status == RichText::FontCatalogStatus::Ready);
        REQUIRE(RichText::isFontCatalogPage(query, page));
        CHECK(page.scope == RichText::FontCatalogScope::System);
        if (!query.offset)
            total = page.total;
        CHECK_EQ(page.total, total);
        for (const auto& family : page.families)
            actual.emplace_back(family.familyName());
        query.offset += static_cast<std::uint32_t>(page.families.size());
    } while (query.offset < total);
    REQUIRE(!actual.empty());
    CHECK(std::ranges::is_sorted(actual));
    CHECK(std::ranges::unique(actual).begin() == actual.end());

    const std::unique_ptr<PangoFontMap, FontMapRelease> map(pango_cairo_font_map_new());
    PangoFontFamily** families = nullptr;
    int count = 0;
    pango_font_map_list_families(map.get(), &families, &count);
    const auto releaseFamilies = [](PangoFontFamily** value) { g_free(value); };
    const std::unique_ptr<PangoFontFamily*, decltype(releaseFamilies)> heldFamilies(families, releaseFamilies);
    std::vector<std::string> expected;
    for (int index = 0; index < count; ++index) {
        const std::string_view family = pango_font_family_get_name(families[index]);
        if (RichText::isFontCatalogFamily(family) && family.find(',') == std::string_view::npos)
            expected.emplace_back(family);
    }
    std::ranges::sort(expected);
    const auto duplicates = std::ranges::unique(expected);
    expected.erase(duplicates.begin(), duplicates.end());
    CHECK(actual == expected);

    query.offset = total + 1;
    RichText::FontCatalogPage invalid;
    REQUIRE(provider.function(provider.context, &query, &facts, &invalid));
    CHECK(invalid.status == RichText::FontCatalogStatus::Invalid);
    CHECK_EQ(invalid.total, 0u);
    query.offset = 0;
    fixture.renderer.invalidateFonts();
    RichText::FontCatalogPage stale;
    REQUIRE(provider.function(provider.context, &query, &facts, &stale));
    CHECK(stale.status == RichText::FontCatalogStatus::Stale);
    fixture.publish();
    RichText::FontCatalogPage retired;
    REQUIRE(provider.function(provider.context, &query, fixture.terminal.typography.facts.get(), &retired));
    CHECK(retired.status == RichText::FontCatalogStatus::Stale);
}

TEST(installedRTFFamilyKeepsItsNativeFaceAcrossAllStylesAndDrawing)
{
    Fixture fixture;
    fixture.publish(18, 1, 9);
    const std::unique_ptr<PangoFontMap, FontMapRelease> map(pango_cairo_font_map_new());
    PangoFontFamily** families = nullptr;
    int familyCount = 0;
    pango_font_map_list_families(map.get(), &families, &familyCount);
    const auto releaseFamilies = [](PangoFontFamily** value) { g_free(value); };
    const std::unique_ptr<PangoFontFamily*, decltype(releaseFamilies)> heldFamilies(families, releaseFamilies);
    std::string family;
    for (int index = 0; index < familyCount; ++index) {
        const std::string_view candidate = pango_font_family_get_name(families[index]);
        if (pango_font_family_is_monospace(families[index]) && candidate != "Monospace" && candidate != "monospace"
            && RichText::isFontCatalogFamily(candidate) && candidate.find(',') == std::string_view::npos) {
            family = candidate;
            break;
        }
    }
    REQUIRE(!family.empty());
    std::string escapedFamily;
    for (const auto byte : family) {
        if (byte == '\\' || byte == '{' || byte == '}' || byte == ';')
            escapedFamily.push_back('\\');
        escapedFamily.push_back(byte);
    }
    const std::string table = R"({\fonttbl{\f0\fnil )" + escapedFamily + ";}}\\f0 ";
    for (const auto* attributes : { "", "\\b ", "\\i ", "\\b\\i " }) {
        fixture.place(table + attributes + "iiiiWWWW");
        const auto& layout = fixture.layout();
        REQUIRE(layout.isShaped());
        const auto first = layout.rightEdge(0);
        const auto last = layout.rightEdge(7) - layout.rightEdge(6);
        CHECK_EQ(first, last);
        const auto pixels = fixture.draw();
        CHECK(std::ranges::any_of(pixels, [](auto byte) { return byte != 0; }));
        const auto styles = fixture.frame.richTextDrawing(0).styles();
        REQUIRE(styles.size() == 1);
        CHECK(styles.front().nameView() == family);
        CHECK(styles.front().familyClass == RichText::FamilyClass::SansSerif);
        CHECK_EQ(styles.front().halfPoints, 36.0f);
    }
    fixture.place(R"({\fonttbl{\f0\fnil Ubiquitty Missing Native Font;}}\f0 iiiiWWWW)");
    const auto& fallback = fixture.layout();
    CHECK(fallback.rightEdge(0) != fallback.rightEdge(7) - fallback.rightEdge(6));
    const auto fallbackWidth = fallback.rightEdge(7);
    fixture.place(R"({\fonttbl{\f0\fnil )" + escapedFamily + ",serif;}}\\f0 iiiiWWWW");
    CHECK_EQ(fixture.layout().rightEdge(7), fallbackWidth);
}

TEST(retainedParagraphsReusePixelsThroughIdleAndUnrelatedTyping)
{
    Fixture fixture;
    fixture.place("Hello office! I'm ready. Let's type.");
    const auto first = fixture.draw();
    CHECK_EQ(fixture.renderer.rasterCount(), 1u);
    for (unsigned frame = 0; frame < 20; ++frame) {
        UbiquittyTest::feed(fixture.terminal, "\x1b[10;1Htyping");
        CHECK(first == fixture.draw());
    }
    CHECK_EQ(fixture.renderer.rasterCount(), 1u);
    fixture.place("{\\colortbl;\\red240\\green20\\blue20;}\\cf1 Hello office! I'm ready. Let's type.");
    CHECK(first != fixture.draw());
    CHECK_EQ(fixture.renderer.rasterCount(), 2u);
    fixture.metrics = { .cellWidth = 16, .cellHeight = 36, .baselineFromTop = 28 };
    fixture.publish(12, 2);
    const auto scaled = fixture.draw();
    CHECK(scaled.size() == first.size() * 4);
    CHECK_EQ(fixture.renderer.rasterCount(), 3u);
    CHECK(fixture.layout().isShaped());
}

TEST(proportionalSizeDoesNotEnlargeInlineMonospace)
{
    Fixture fixture;
    fixture.place("{\\fonttbl{\\f0\\fswiss ;}{\\f1\\fmodern ;}}\\f0 a{\\f1 MMMM}");
    const auto monoWidth = fixture.layout().rightEdge(4) - fixture.layout().rightEdge(0);
    const auto proseWidth = fixture.layout().rightEdge(0);
    fixture.publish(20, 1, 12);
    const auto& largerProse = fixture.layout();
    CHECK_EQ(largerProse.rightEdge(4) - largerProse.rightEdge(0), monoWidth);
    CHECK(largerProse.rightEdge(0) > proseWidth);
    fixture.draw();
    const auto styles = fixture.frame.richTextDrawing(0).styles();
    REQUIRE(styles.size() == 2);
    CHECK_EQ(styles[0].halfPoints, 40.0f);
    CHECK_EQ(styles[1].halfPoints, 24.0f);
    fixture.publish(20, 1, 16);
    CHECK(fixture.layout().rightEdge(4) - fixture.layout().rightEdge(0) > monoWidth);
    fixture.draw();
    CHECK_EQ(fixture.frame.richTextDrawing(0).styles()[1].halfPoints, 32.0f);
}

TEST(clipAndNativeChromeDoNotReflowOrRasterizeAgain)
{
    Fixture fixture;
    fixture.place("MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM", "w=30:h=4:r=0,0,5,4,10,0,20,4");
    const auto first = fixture.draw();
    const int width = 80 * 8;
    bool sawInk = false;
    for (int y = 0; y < 4 * 18; ++y) {
        for (int x = 0; x < 30 * 8; ++x) {
            const auto alpha = first[(static_cast<std::size_t>(y) * width + x) * 4 + 3];
            if (x >= 5 * 8 && x < 10 * 8)
                CHECK_EQ(alpha, 0);
            else
                sawInk |= alpha > 0;
        }
    }
    CHECK(sawInk);
    const std::array<IntRect, 1> menu { IntRect { { 0, 0 }, { 80, 72 } } };
    const auto obscured = fixture.draw(menu);
    CHECK(first != obscured);
    CHECK_EQ(fixture.renderer.rasterCount(), 1u);
    CHECK(first == fixture.draw());
    // Exercise actual lifecycle cleanup with a full erase, as a TUI restart does.
    UbiquittyTest::feed(fixture.terminal, "\x1b[2J");
    CHECK(std::ranges::none_of(fixture.draw(), [](auto byte) { return byte != 0; }));
}

TEST(selectionCoversExplicitBackgroundsAndTheCaretUsesNativeEdges)
{
    Fixture fixture;
    fixture.place(R"({\colortbl;\red200\green0\blue0;}\highlight1 office)", "w=30:h=2:k=3:M=1:D=1");
    const auto& block = fixture.terminal.richTextBlocks.blocks(RichText::activeScreen(fixture.terminal)).front();
    Rendering::TerminalSnapshotOptions options;
    std::array<RichText::BlockSelection, 1> selections { RichText::BlockSelection { block.serial, 0, 6 } };
    options.richTextSelections = selections;
    options.richTextSelectionCount = 1;
    options.style.platformSelectionColor = { 0, 0, 1, 1 };
    CHECK(fixture.frame.capture(fixture.terminal, options, fixture.metrics, {}));
    CHECK(fixture.frame.inputs().isSelectionBehindText);
    CHECK(fixture.frame.inputs().cursor.shape == Cursor::Shape::Bar);
    CHECK(fixture.frame.inputs().cursor.richTextOffset > 0);
    CHECK(fixture.frame.inputs().cursor.richTextOffset < 3);
    std::vector<std::uint8_t> pixels(640 * 216 * 4);
    fixture.renderer.composite(fixture.frame, pixels, 640, 216);
    const int end = static_cast<int>(fixture.layout().rightEdge(5) / 4096);
    // At the top edge there is background but no glyph ink. Every adjacent
    // selected grapheme shares its rounded edge with its neighbour.
    for (int x = 0; x < end; ++x) {
        CHECK(pixels[x * 4 + 2] > pixels[x * 4]);
        CHECK_EQ(pixels[x * 4 + 3], 255);
    }
    const auto withoutCaret = pixels;
    pixels.assign(pixels.size(), 0);
    fixture.renderer.composite(fixture.frame, pixels, 640, 216, {}, true);
    CHECK(pixels != withoutCaret);
    CHECK_EQ(fixture.renderer.rasterCount(), 1u);
}

TEST(aScrolledParagraphUsesTheSameFullSourceLineBreaks)
{
    Fixture fixture;
    constexpr std::string_view source = "first line\\par second line\\par third line";
    fixture.place(source, "w=30:h=3");
    const auto full = fixture.draw();
    const auto secondLineStart = fixture.layout().line(0).end;
    REQUIRE(secondLineStart == std::string_view("first line\n").size());
    const std::size_t rowBytes = 640 * 4 * 18;
    // An anchor inside the first source line keeps that line at the top;
    // anchors at or inside the second line select its complete native line.
    fixture.place(source, "w=30:h=2:v=1");
    const auto first = fixture.draw();
    CHECK_EQ(fixture.layout().firstVisibleLine(), 0u);
    CHECK(std::equal(first.begin(), first.begin() + 2 * rowBytes, full.begin()));
    for (const auto anchor : { secondLineStart, secondLineStart + 2 }) {
        fixture.place(source, "w=30:h=2:v=" + std::to_string(anchor));
        const auto scrolled = fixture.draw();
        CHECK(fixture.layout().isShaped());
        CHECK_EQ(fixture.layout().firstVisibleLine(), 1u);
        CHECK(std::equal(scrolled.begin(), scrolled.begin() + 2 * rowBytes, full.begin() + rowBytes));
    }
}

TEST(nativeEllipsisKeepsShapingAndSelectionOnGraphemeBoundaries)
{
    for (const auto* text : { "office ffi words that continue beyond the visible rectangle",
             "é é é é é é é é é é é é é é é é é é é é",
             "مرحبا بالعالم مرحبا بالعالم مرحبا بالعالم مرحبا بالعالم",
             "漢字かな漢字かな漢字かな漢字かな漢字かな漢字かな" }) {
        Fixture fixture;
        fixture.place(text, "w=12:h=1:o=e");
        const auto& layout = fixture.layout();
        REQUIRE(layout.isShaped());
        REQUIRE(layout.isElided());
        CHECK(!layout.isFitting());
        const auto& block = fixture.terminal.richTextBlocks.blocks(RichText::activeScreen(fixture.terminal)).front();
        CHECK(layout.copyableEnd() < block.document.text.size());
        CHECK_EQ(layout.shownCount(), layout.copyableEnd());
        const auto pixels = fixture.draw();
        CHECK(std::ranges::any_of(pixels, [](auto byte) { return byte != 0; }));
        const auto& drawing = fixture.frame.richTextDrawing(0);
        CHECK_EQ(drawing.text().back(), 0x2026u);
        CHECK_EQ(drawing.shapedLines().back().end, drawing.text().size());
        CHECK_EQ(layout.caretAt(10000000, 0) <= layout.copyableEnd(), true);
        CHECK(std::ranges::all_of(layout.shapedSpans(), [&](const auto& span) { return span.end <= layout.copyableEnd(); }));
        const auto measured = RichText::measure(block.document,
            { 12, 1, RichText::Overflow::Ellipsis, RichText::Alignment::Left, RichText::LineMode::Terminal }, fixture.terminal.typography);
        CHECK(measured.isShaped);
        CHECK(measured.height > 1);
        CHECK_EQ(measured.lineEnds.back(), block.document.text.size());
        REQUIRE(measured.geometry.elision);
        CHECK_EQ(measured.geometry.elisionEnd, layout.copyableEnd());
        RichText::LayoutCache remote;
        REQUIRE(remote.adopt(block, fixture.terminal.typography, measured.geometry));
        CHECK_EQ(remote.layoutOf(block, fixture.terminal.typography).copyableEnd(), layout.copyableEnd());
        std::string visible;
        for (const auto scalar : drawing.text())
            Unicode::appendUTF8(visible, scalar);
        fixture.place(visible, "w=12:h=1:o=w");
        CHECK(pixels == fixture.draw());
    }
}

TEST(nativeEllipsisCanFillABoxTooNarrowForAnySourceText)
{
    Fixture fixture;
    fixture.place("WWWWWWWWWWWW", "w=1:h=1:o=e");
    const auto& layout = fixture.layout();
    REQUIRE(layout.isShaped());
    REQUIRE(layout.isElided());
    CHECK_EQ(layout.copyableEnd(), 0u);
    CHECK_EQ(layout.shownCount(), 0u);
    const auto pixels = fixture.draw();
    CHECK(std::ranges::any_of(pixels, [](auto byte) { return byte != 0; }));
    CHECK_EQ(fixture.frame.richTextDrawing(0).text().size(), 1u);
    CHECK_EQ(fixture.frame.richTextDrawing(0).text().front(), 0x2026u);
}

TEST(nativeFontInventoryChangesInvalidateTheRevisionEvenWithEqualDenseMetrics)
{
    Fixture fixture;
    const auto original = *fixture.terminal.typography.facts;
    REQUIRE(original.rendererRevision);
    REQUIRE(original.rendersBlocks == 1);
    const auto unchanged = fixture.renderer.configure("DejaVu Sans Mono", "DejaVu Sans", fixture.metrics, 12, 12, 1);
    CHECK(unchanged == original);
    fixture.place("unchanged fonts");
    const auto& document = fixture.terminal.richTextBlocks.blocks(RichText::activeScreen(fixture.terminal)).front().document;
    const RichText::ShapeRequest request { 20, 2 };
    RichText::ShapedText geometry;
    const auto shaper = fixture.renderer.shaper();
    REQUIRE(shaper.function(shaper.context, &document, &request, &original, &geometry));
    fixture.renderer.invalidateFonts();
    geometry = {};
    CHECK(!shaper.function(shaper.context, &document, &request, &original, &geometry));
    auto renewed = fixture.renderer.configure("DejaVu Sans Mono", "DejaVu Sans", fixture.metrics, 12, 12, 1);
    CHECK(renewed.rendererRevision != original.rendererRevision);
    const auto nextRevision = renewed.rendererRevision;
    renewed.rendererRevision = original.rendererRevision;
    CHECK(renewed == original);
    renewed.rendererRevision = nextRevision;
    REQUIRE(shaper.function(shaper.context, &document, &request, &renewed, &geometry));
    geometry = {};
    CHECK(!shaper.function(shaper.context, &document, &request, &original, &geometry));
}

TEST(nativeCoordinatesOutsideTheCaretRepresentationDeclineInsteadOfWrapping)
{
    Fixture fixture;
    fixture.place(std::string(RichText::maxCodePoints, 'W'));
    auto document = fixture.terminal.richTextBlocks.blocks(RichText::activeScreen(fixture.terminal)).front().document;
    for (auto& run : document.runs)
        run.halfPoints = RichText::maxHalfPoints;
    const auto shaper = fixture.renderer.shaper();
    const auto& facts = *fixture.terminal.typography.facts;
    const RichText::ShapeRequest request { 30, 2, RichText::Overflow::Clip };
    RichText::ShapedText geometry;
    CHECK(!shaper.function(shaper.context, &document, &request, &facts, &geometry));
    const auto measured = RichText::measure(document, request, fixture.terminal.typography);
    CHECK(!measured.isShaped);
}

UBIQUITTY_TEST_MAIN()
