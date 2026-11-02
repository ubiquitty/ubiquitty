// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/PangoRichText.h"

#include "Core/Rendering/OverlayGeometry.h"
#include "Core/RichText/Drawing.h"
#include "Core/RichText/ParagraphMetrics.h"

#include <pango/pangocairo.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <mutex>
#include <optional>
#include <random>
#include <string_view>
#include <unordered_map>

namespace Ubiquitty::Linux {
namespace {

struct ObjectRelease {
    void operator()(void* object) const { g_object_unref(object); }
};
template<typename T> using Object = std::unique_ptr<T, ObjectRelease>;
using FontDescription = std::unique_ptr<PangoFontDescription, decltype(&pango_font_description_free)>;
using Attributes = std::unique_ptr<PangoAttrList, decltype(&pango_attr_list_unref)>;
using Surface = std::unique_ptr<cairo_surface_t, decltype(&cairo_surface_destroy)>;
using Painter = std::unique_ptr<cairo_t, decltype(&cairo_destroy)>;

// Pango uses 1/1024 point with this context's 72-DPI resolution. Core uses
// 1/4096 point; rasterization scales once at the device boundary.
std::optional<std::uint32_t> units(std::int64_t value)
{
    const auto converted = value * 4;
    if (converted < 0 || converted >= std::numeric_limits<std::int32_t>::max())
        return std::nullopt;
    return static_cast<std::uint32_t>(converted);
}

// The generic family of each RichText::FamilyClass, in its enumeration order.
constexpr std::array<std::string_view, 3> genericFamilies { "sans-serif", "serif", "monospace" };

/// The Pango family list a class draws with: the configured family, then the
/// class's generic family, so a configured family the font map lacks still
/// draws in its class. Without the generic entry the font map substitutes its
/// default face, which is proportional: CoreText's always, and fontconfig's for
/// a name its aliases do not class.
///
/// - Parameter families: The configured family of each class.
/// - Returns: The comma-separated Pango family list of each class.
std::array<std::string, 3> fontListsFor(const std::array<std::string, 3>& families)
{
    std::array<std::string, 3> lists;
    for (std::size_t family = 0; family < families.size(); ++family) {
        lists[family] = families[family];
        if (families[family] != genericFamilies[family])
            lists[family].append(",").append(genericFamilies[family]);
    }
    return lists;
}

struct Paragraph {
    std::string text;
    std::vector<int> bytes { 0 };
    Object<PangoLayout> layout;

    /// - Parameters:
    ///   - indent: The first line's indent from the others, in points; a
    ///     negative indent hangs the others instead, as Pango spells it.
    ///   - tabStops: Explicit tab positions from the layout's left edge, in
    ///     points; empty repeats `tabWidth`.
    Paragraph(PangoFontMap* fonts, std::span<const std::uint32_t> scalars, std::span<const RichText::DrawnStyle> styles,
        const std::array<std::string, 3>& families, double width, double tabWidth, double indent = 0, std::span<const double> tabStops = {})
    {
        for (const auto scalar : scalars) {
            std::array<char, 6> encoded {};
            const auto count = g_unichar_to_utf8(scalar, encoded.data());
            text.append(encoded.data(), static_cast<std::size_t>(count));
            bytes.push_back(static_cast<int>(text.size()));
        }
        Object<PangoContext> context(pango_font_map_create_context(fonts));
        pango_cairo_context_set_resolution(context.get(), 72);
        pango_context_set_round_glyph_positions(context.get(), false);
        layout.reset(pango_layout_new(context.get()));
        pango_layout_set_text(layout.get(), text.data(), static_cast<int>(text.size()));
        pango_layout_set_width(layout.get(), width < 0 ? -1 : static_cast<int>(std::lround(width * PANGO_SCALE)));
        pango_layout_set_wrap(layout.get(), PANGO_WRAP_WORD_CHAR);
        pango_layout_set_indent(layout.get(), static_cast<int>(std::lround(indent * PANGO_SCALE)));
        const auto stopCount = std::max<std::size_t>(tabStops.size(), 1);
        std::unique_ptr<PangoTabArray, decltype(&pango_tab_array_free)> tabs(pango_tab_array_new(static_cast<int>(stopCount), false), pango_tab_array_free);
        for (std::size_t index = 0; index < stopCount; ++index)
            pango_tab_array_set_tab(tabs.get(), static_cast<int>(index), PANGO_TAB_LEFT, static_cast<int>(std::lround((tabStops.empty() ? tabWidth : tabStops[index]) * PANGO_SCALE)));
        pango_layout_set_tabs(layout.get(), tabs.get());
        Attributes attributes(pango_attr_list_new(), pango_attr_list_unref);
        for (const auto& style : styles) {
            FontDescription font(pango_font_description_new(), pango_font_description_free);
            const auto& fallback = families[std::to_underlying(style.familyClass)];
            const auto requested = style.familyName();
            // Pango interprets commas as family-list separators, even inside a
            // FontDescription. Such names cannot select one literal family.
            auto* family = requested.empty() || requested.find(',') != std::string::npos ? nullptr : pango_font_map_get_family(fonts, requested.c_str());
            const std::string resolved = family ? std::string(pango_font_family_get_name(family)) + ',' + fallback : fallback;
            pango_font_description_set_family(font.get(), resolved.c_str());
            pango_font_description_set_size(font.get(), static_cast<int>(std::lround(style.halfPoints * PANGO_SCALE / 2)));
            pango_font_description_set_weight(font.get(), style.styles & 1 ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
            pango_font_description_set_style(font.get(), style.styles & 2 ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
            const auto add = [&](PangoAttribute* attribute) {
                attribute->start_index = static_cast<unsigned>(bytes[style.first]);
                attribute->end_index = static_cast<unsigned>(bytes[style.end]);
                pango_attr_list_insert(attributes.get(), attribute);
            };
            add(pango_attr_font_desc_new(font.get()));
            if (!style.isAutomaticColor)
                add(pango_attr_foreground_new(style.red * 257, style.green * 257, style.blue * 257));
            if (style.styles & 4)
                add(pango_attr_underline_new(PANGO_UNDERLINE_SINGLE));
            if (style.styles & 8)
                add(pango_attr_strikethrough_new(true));
        }
        pango_layout_set_attributes(layout.get(), attributes.get());
    }

    std::uint32_t scalar(int byte) const
    {
        return static_cast<std::uint32_t>(std::lower_bound(bytes.begin(), bytes.end(), byte) - bytes.begin());
    }
};

/// A block's paragraphs, one Pango layout each: a paragraph's indents set the
/// width its lines wrap at, which one layout cannot vary. Every layout keeps
/// its whole paragraph, so shaping context never stops at a wrapped line.
struct Paragraphs {
    struct Piece {
        std::uint32_t first = 0;
        Paragraph layout;
    };
    std::vector<Piece> pieces;

    /// - Parameters:
    ///   - width: The block's width in points; negative lays every line out
    ///     unwrapped.
    ///   - tabWidth: The tab interval, from the box's left edge, in points.
    Paragraphs(PangoFontMap* fonts, std::span<const std::uint32_t> scalars, std::span<const RichText::DrawnStyle> styles,
        const std::array<std::string, 3>& families, double width, double tabWidth)
    {
        const auto blockUnits = static_cast<std::uint32_t>(std::max(0.0, width) * 4096);
        for (std::uint32_t first = 0; first < scalars.size();) {
            const std::uint32_t end = RichText::paragraphEnd(scalars, first);
            RichText::Paragraph properties;
            for (const auto& style : styles) {
                if (style.first <= first && first < style.end)
                    properties = style.paragraph;
            }
            const RichText::LinePlace firstLine {};
            const RichText::LinePlace laterLine { .startsParagraph = false, .endsParagraph = true };
            const double firstStart = RichText::lineIndent(properties, firstLine) / 4096.0;
            const double laterStart = RichText::lineIndent(properties, laterLine) / 4096.0;
            const double origin = std::min(firstStart, laterStart);
            const double rightIndent = static_cast<double>(RichText::unitsOfTwips(properties.rightIndent)) / 4096;
            // Tabs stop on the box's grid, from this layout's origin, and a
            // hanging first line's first tab at the left indent.
            std::vector<double> stops;
            if (const auto hanging = RichText::hangingTabStop(properties, firstLine))
                stops.push_back(hanging / 4096.0 - origin);
            if (tabWidth > 0) {
                // Every stop a line of the widest block can reach, so Pango
                // never extrapolates past the grid.
                for (double stop = tabWidth; stops.size() < 160; stop += tabWidth) {
                    if (stop - origin > (stops.empty() ? 0 : stops.back()))
                        stops.push_back(stop - origin);
                }
            }
            std::vector<RichText::DrawnStyle> pieceStyles;
            for (auto style : styles) {
                if (style.end <= first || style.first >= end)
                    continue;
                style.first = std::max(style.first, first) - first;
                style.end = std::min(style.end, end) - first;
                pieceStyles.push_back(style);
            }
            const double pieceWidth = width < 0 ? -1 : std::max(0.0, static_cast<double>(blockUnits) / 4096 - origin - rightIndent);
            pieces.push_back({ first, Paragraph(fonts, scalars.subspan(first, end - first), pieceStyles, families, pieceWidth, tabWidth, firstStart - laterStart, stops) });
            first = end;
        }
    }

    /// Visits every line in source order with its scalar range.
    template<typename Visit>
    bool forEachLine(Visit&& visit) const
    {
        for (const Piece& piece : pieces) {
            const Paragraph& paragraph = piece.layout;
            for (auto* link = pango_layout_get_lines_readonly(paragraph.layout.get()); link; link = link->next) {
                auto* line = static_cast<PangoLayoutLine*>(link->data);
                const auto first = paragraph.scalar(line->start_index);
                const auto end = link->next ? paragraph.scalar(static_cast<PangoLayoutLine*>(link->next->data)->start_index) : static_cast<std::uint32_t>(paragraph.bytes.size() - 1);
                if (first == end)
                    continue;
                if (!visit(piece.first, paragraph, line, piece.first + first, piece.first + end))
                    return false;
            }
        }
        return true;
    }
};

std::vector<RichText::DrawnStyle> stylesOf(const RichText::Document& document, const RichText::ShapeRequest& request, const RichText::TypographyFacts& facts)
{
    std::vector<RichText::DrawnStyle> styles;
    for (const auto& run : document.runs) {
        RichText::DrawnStyle style;
        style.first = run.start;
        style.end = run.start + run.length;
        style.alignment = run.alignment;
        style.paragraph = run.paragraph;
        if (run.font != RichText::noFontEntry)
            style.setFont(document.fonts[run.font]);
        style.styles = run.styles;
        const auto size = facts.terminalSize(style.familyClass);
        style.halfPoints = run.halfPoints * (request.lineMode == RichText::LineMode::Terminal && size ? static_cast<float>(size) / 768 : 1);
        styles.push_back(style);
    }
    return styles;
}

struct Raster {
    std::uint64_t key = 0;
    int width = 0;
    int height = 0;
    std::vector<std::uint32_t> pixels;
};

} // namespace

struct PangoRichText::PangoStorage {
    std::mutex lock;
    Object<PangoFontMap> fonts { pango_cairo_font_map_new() };
    std::array<std::string, 3> families { "sans-serif", "serif", "monospace" };
    std::array<std::string, 3> fontLists { fontListsFor(families) };
    RichText::TypographyFacts facts;
    unsigned fontMapSerial = 0;
    FallibleVector<RichText::FontCatalogFamily> catalog;
    std::unordered_map<std::uint32_t, Raster> rasters;
    std::size_t rasterCount = 0;
};

PangoRichText::PangoRichText()
    : m_state(std::make_unique<PangoStorage>())
{
    std::random_device entropy;
    m_state->facts.rendererRevision = (std::uint64_t { entropy() } << 32) | entropy();
}
PangoRichText::~PangoRichText() = default;

void PangoRichText::invalidateFonts()
{
    const std::scoped_lock hold(m_state->lock);
    // A new map drops cached Fontconfig matches as well as paragraph context.
    // No native layout borrows the old map outside this lock.
    m_state->fonts.reset(pango_cairo_font_map_new());
    m_state->fontMapSerial = 0;
}

RichText::TypographyFacts PangoRichText::configure(std::string gridFamily, std::string proportionalFamily,
    const Rendering::CellMetrics& metrics, double size, double monospaceSize, double pixelsPerPoint)
{
    const std::scoped_lock hold(m_state->lock);
    const std::array<std::string, 3> families { proportionalFamily.empty() ? "sans-serif" : std::move(proportionalFamily), "serif", gridFamily.empty() ? "monospace" : std::move(gridFamily) };
    RichText::TypographyFacts facts;
    const auto metric = [](double value) { return static_cast<std::uint16_t>(std::clamp(std::lround(value * 64), 1l, static_cast<long>(RichText::maxCellSize))); };
    facts.cellWidth = metric(metrics.cellWidth / pixelsPerPoint);
    facts.cellHeight = metric(metrics.cellHeight / pixelsPerPoint);
    facts.baseline = std::min(facts.cellHeight, metric(metrics.baselineFromTop / pixelsPerPoint));
    facts.proportionalSize = metric(size);
    facts.monospaceSize = metric(monospaceSize);
    facts.shaping = 1;
    facts.rendersBlocks = 1;
    const auto fontMapSerial = pango_font_map_get_serial(m_state->fonts.get());
    if (families == m_state->families && m_state->facts.cellWidth == facts.cellWidth && m_state->facts.cellHeight == facts.cellHeight
        && m_state->facts.baseline == facts.baseline && m_state->facts.proportionalSize == facts.proportionalSize
        && m_state->facts.monospaceSize == facts.monospaceSize && m_state->fontMapSerial == fontMapSerial)
        return m_state->facts;
    facts.rendererRevision = m_state->facts.rendererRevision + 1;
    if (!facts.rendererRevision)
        facts.rendererRevision = 1;
    m_state->fontMapSerial = fontMapSerial;
    m_state->families = families;
    m_state->fontLists = fontListsFor(families);
    m_state->rasters.clear();
    PangoFontFamily** nativeFamilies = nullptr;
    int familyCount = 0;
    pango_font_map_list_families(m_state->fonts.get(), &nativeFamilies, &familyCount);
    const auto releaseFamilies = [](PangoFontFamily** value) { g_free(value); };
    const std::unique_ptr<PangoFontFamily*, decltype(releaseFamilies)> heldFamilies(nativeFamilies, releaseFamilies);
    FallibleVector<RichText::FontCatalogFamily> catalog;
    bool isCatalogReady = familyCount >= 0 && static_cast<bool>(catalog.tryReserve(static_cast<std::size_t>(familyCount)));
    for (int index = 0; isCatalogReady && index < familyCount; ++index) {
        const std::string_view name = pango_font_family_get_name(nativeFamilies[index]);
        if (!RichText::isFontCatalogFamily(name) || name.find(',') != std::string_view::npos)
            continue;
        RichText::FontCatalogFamily entry;
        entry.length = static_cast<std::uint8_t>(name.size());
        std::ranges::copy(name, entry.name.begin());
        isCatalogReady = static_cast<bool>(catalog.tryPushBack(std::move(entry)));
    }
    if (isCatalogReady) {
        std::ranges::sort(catalog, {}, &RichText::FontCatalogFamily::familyName);
        const auto duplicates = std::ranges::unique(catalog, {}, &RichText::FontCatalogFamily::familyName);
        catalog.erase(duplicates.begin(), duplicates.end());
        facts.fontCatalogScope = RichText::FontCatalogScope::System;
        m_state->catalog = std::move(catalog);
    } else {
        m_state->catalog.clear();
    }
    // Class metrics remain available for the documented non-native fallback.
    // They are measured from the same font map, never a Latin width heuristic.
    Object<PangoContext> context(pango_font_map_create_context(m_state->fonts.get()));
    pango_cairo_context_set_resolution(context.get(), 72);
    for (std::size_t family = 0; family < m_state->families.size(); ++family) {
        for (unsigned style = 0; style < 4; ++style) {
            auto& face = facts.faces[facts.faceCount++];
            face.familyClass = static_cast<RichText::FamilyClass>(family);
            face.styles = static_cast<std::uint8_t>(style);
            FontDescription font(pango_font_description_new(), pango_font_description_free);
            pango_font_description_set_family(font.get(), m_state->fontLists[family].c_str());
            pango_font_description_set_size(font.get(), 12 * PANGO_SCALE);
            pango_font_description_set_weight(font.get(), style & 1 ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
            pango_font_description_set_style(font.get(), style & 2 ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
            std::unique_ptr<PangoFontMetrics, decltype(&pango_font_metrics_unref)> native(pango_context_get_metrics(context.get(), font.get(), nullptr), pango_font_metrics_unref);
            const auto em = [](int value) { return static_cast<std::uint16_t>(std::clamp(value / 6, 1, 65535)); };
            face.ascent = em(pango_font_metrics_get_ascent(native.get()));
            face.descent = em(pango_font_metrics_get_descent(native.get()));
            face.lineHeight = em(pango_font_metrics_get_height(native.get()));
            face.averageAdvance = em(pango_font_metrics_get_approximate_char_width(native.get()));
            Object<PangoLayout> measure(pango_layout_new(context.get()));
            pango_layout_set_font_description(measure.get(), font.get());
            for (std::uint32_t scalar = RichText::firstTabledCodePoint; scalar <= RichText::lastTabledCodePoint; ++scalar) {
                std::array<char, 6> encoded {};
                const int count = g_unichar_to_utf8(scalar, encoded.data());
                pango_layout_set_text(measure.get(), encoded.data(), count);
                int width = 0;
                pango_layout_get_size(measure.get(), &width, nullptr);
                face.advances[scalar - RichText::firstTabledCodePoint] = static_cast<std::uint16_t>(std::clamp(width / 6, 0, 65535));
            }
        }
    }
    m_state->facts = facts;
    return facts;
}

RichText::FontCatalogProvider PangoRichText::fontCatalog()
{
    return { [](void* context, const RichText::FontCatalogQuery* query, const RichText::TypographyFacts* facts, RichText::FontCatalogPage* page) {
                auto& state = *static_cast<PangoStorage*>(context);
                const std::scoped_lock hold(state.lock);
                page->offset = query->offset;
                page->rendererRevision = state.facts.rendererRevision;
                page->scope = state.facts.fontCatalogScope;
                if (query->rendererRevision != state.facts.rendererRevision || facts->rendererRevision != state.facts.rendererRevision
                    || state.fontMapSerial != pango_font_map_get_serial(state.fonts.get())) {
                    page->status = RichText::FontCatalogStatus::Stale;
                    return true;
                }
                if (page->scope == RichText::FontCatalogScope::Unavailable)
                    return true;
                page->total = static_cast<std::uint32_t>(state.catalog.size());
                if (query->offset > page->total) {
                    page->status = RichText::FontCatalogStatus::Invalid;
                    page->total = 0;
                    return true;
                }
                page->status = RichText::FontCatalogStatus::Ready;
                for (std::size_t index = query->offset; index < state.catalog.size() && page->families.size() < query->count; ++index) {
                    if (!page->appendFamilyView(state.catalog[index].familyName()))
                        break;
                }
                return query->offset == page->total || !page->families.empty();
            },
        m_state.get() };
}

RichText::Shaper PangoRichText::shaper()
{
    return { [](void* context, const RichText::Document* document, const RichText::ShapeRequest* request, const RichText::TypographyFacts* facts, RichText::ShapedText* output) {
                auto& state = *static_cast<PangoStorage*>(context);
                const std::scoped_lock hold(state.lock);
                if (facts->rendererRevision != state.facts.rendererRevision || state.fontMapSerial != pango_font_map_get_serial(state.fonts.get()))
                    return false;
                const auto styles = stylesOf(*document, *request, *facts);
                // The content box: the rectangle less its padding. Positions
                // are the box's; Core moves them inside the padding.
                const double width = std::max(0.0, request->width * facts->cellWidth / 64.0 - request->padding.left - request->padding.right);
                const Paragraphs paragraphs(state.fonts.get(), document->text, styles, state.fontLists,
                    request->overflow == RichText::Overflow::Clip ? -1 : width, facts->cellWidth / 8.0);
                const auto blockWidth = static_cast<std::uint32_t>(width * 4096);
                std::uint32_t top = 0;
                std::uint32_t row = 0;
                return paragraphs.forEachLine([&](std::uint32_t pieceFirst, const Paragraph& paragraph, PangoLayoutLine* line, std::uint32_t first, std::uint32_t end) {
                    int attributeCount = 0;
                    const auto* boundaries = pango_layout_get_log_attrs_readonly(paragraph.layout.get(), &attributeCount);
                    if (attributeCount != static_cast<int>(paragraph.bytes.size()))
                        return false;
                    const RichText::LinePlace place = RichText::linePlace(document->text, first, end);
                    RichText::Paragraph properties;
                    for (const auto& style : styles) {
                        if (style.first <= pieceFirst && pieceFirst < style.end)
                            properties = style.paragraph;
                    }
                    PangoRectangle bounds {};
                    pango_layout_line_get_extents(line, nullptr, &bounds);
                    const auto measuredHeight = units(bounds.height);
                    const auto measuredBaseline = units(-static_cast<std::int64_t>(bounds.y));
                    const auto measuredWidth = units(bounds.width);
                    if (!measuredHeight || !measuredBaseline || !measuredWidth)
                        return false;
                    const auto naturalHeight = request->lineMode == RichText::LineMode::Terminal ? facts->cellHeight * 64u : *measuredHeight;
                    const auto naturalBaseline = request->lineMode == RichText::LineMode::Terminal ? facts->baseline * 64u : *measuredBaseline;
                    const RichText::LineBox box = RichText::lineBox(properties, naturalHeight, std::min(naturalBaseline, naturalHeight), place, request->lineMode);
                    constexpr auto limit = static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max());
                    if (box.height >= limit - top)
                        return false;
                    auto alignment = request->alignment;
                    for (const auto& style : styles) {
                        if (style.first <= first && style.end > first && style.alignment != RichText::Alignment::Unspecified)
                            alignment = style.alignment;
                    }
                    const auto available = RichText::lineWidth(properties, place, blockWidth);
                    const auto share = alignment == RichText::Alignment::Right ? 1.0 : alignment == RichText::Alignment::Center ? 0.5
                                                                                                                                : 0.0;
                    const auto origin = RichText::lineIndent(properties, place)
                        + static_cast<std::uint32_t>(std::max(0.0, static_cast<double>(available) - *measuredWidth) * share);
                    if (origin >= limit || *measuredWidth >= limit - origin)
                        return false;
                    output->appendLine({ first, end, top, box.height, box.baseline, origin, *measuredWidth });
                    for (auto scalar = first; scalar < end;) {
                        auto next = scalar + 1;
                        while (next < end && !boundaries[next - pieceFirst].is_cursor_position)
                            ++next;
                        int leading = 0;
                        int trailing = 0;
                        pango_layout_line_index_to_x(line, paragraph.bytes[scalar - pieceFirst], false, &leading);
                        pango_layout_line_index_to_x(line, paragraph.bytes[scalar - pieceFirst], true, &trailing);
                        const auto leadingEdge = static_cast<std::int64_t>(origin) + static_cast<std::int64_t>(leading) * 4;
                        const auto trailingEdge = static_cast<std::int64_t>(origin) + static_cast<std::int64_t>(trailing) * 4;
                        if (leadingEdge < 0 || trailingEdge < 0 || leadingEdge >= limit || trailingEdge >= limit)
                            return false;
                        output->appendSpan({ scalar, next, row, static_cast<std::int32_t>(leadingEdge), static_cast<std::int32_t>(trailingEdge) });
                        scalar = next;
                    }
                    top += box.height;
                    ++row;
                    return true;
                });
            },
        m_state.get() };
}

std::size_t PangoRichText::rasterCount() const
{
    const std::scoped_lock hold(m_state->lock);
    return m_state->rasterCount;
}

void PangoRichText::composite(const Rendering::TerminalFrameInputs& frame, std::span<std::uint8_t> rgba, int width, int height,
    std::span<const IntRect> occlusions, bool drawCaret) // bool-ok: the grid pass already owns cursor visibility.
{
    if (width <= 0 || height <= 0 || rgba.size() != static_cast<std::size_t>(width) * height * 4)
        return;
    const std::scoped_lock hold(m_state->lock);
    const auto quads = frame.richTextQuads();
    std::erase_if(m_state->rasters, [&](const auto& entry) {
        return std::ranges::none_of(quads, [&](const auto& quad) { return quad.serial == entry.first; });
    });
    const auto blend = [&](int x, int y, std::uint32_t pixel) {
        if (std::ranges::any_of(occlusions, [&](const auto& rect) {
                return x >= rect.origin.x && x < rect.origin.x + rect.size.width
                    && y >= rect.origin.y && y < rect.origin.y + rect.size.height;
            }))
            return;
        auto* destination = rgba.data() + (static_cast<std::size_t>(y) * width + x) * 4;
        const unsigned inverse = 255 - (pixel >> 24);
        for (unsigned channel = 0; channel < 3; ++channel)
            destination[channel] = static_cast<std::uint8_t>(((pixel >> (16 - channel * 8)) & 255) + (destination[channel] * inverse + 127) / 255);
        destination[3] = static_cast<std::uint8_t>((pixel >> 24) + (destination[3] * inverse + 127) / 255);
    };
    // Keep backgrounds out of the glyph cache: native selection belongs above
    // explicit RTF backgrounds and below text, without reshaping on each drag.
    for (std::size_t index = 0; index < quads.size(); ++index) {
        const auto& quad = quads[index];
        const auto& drawing = frame.richTextDrawing(index);
        const auto cell = frame.metrics();
        for (const auto& cluster : drawing.clusters()) {
            const auto& style = drawing.styles()[cluster.style];
            if (!style.hasBackground)
                continue;
            const auto pixel = 0xff000000u | (style.backgroundRed << 16) | (style.backgroundGreen << 8) | style.backgroundBlue;
            const auto fill = [&](float clipLeft, float clipTop, float clipRight, float clipBottom) {
                const int left = std::max(0, static_cast<int>(std::lround(std::max(clipLeft, quad.left + cluster.x * quad.pixelsPerUnitX))));
                const int right = std::min(width, static_cast<int>(std::lround(std::min(clipRight, quad.left + (cluster.x + cluster.advance) * quad.pixelsPerUnitX))));
                const int top = std::max(0, static_cast<int>(std::lround(std::max(clipTop, quad.top + cluster.top * quad.pixelsPerUnitY))));
                const int bottom = std::min(height, static_cast<int>(std::lround(std::min(clipBottom, quad.top + (cluster.top + cluster.height) * quad.pixelsPerUnitY))));
                for (int y = top; y < bottom; ++y) {
                    for (int x = left; x < right; ++x)
                        blend(x, y, pixel);
                }
            };
            if (drawing.visibleRects().empty())
                fill(quad.left, quad.top, quad.left + quad.width, quad.top + quad.height);
            for (const auto& clip : drawing.visibleRects())
                fill(quad.left + clip.x * cell.cellWidth, quad.top + clip.y * cell.cellHeight,
                    quad.left + (clip.x + clip.width) * cell.cellWidth, quad.top + (clip.y + clip.height) * cell.cellHeight);
        }
    }
    const auto drawSelection = [&] {
        for (const auto& highlight : frame.richTextHighlights()) {
            const auto alpha = static_cast<unsigned>(std::lround(highlight.alpha * 255));
            const auto pixel = (alpha << 24) | (static_cast<unsigned>(std::lround(highlight.red * alpha)) << 16) | (static_cast<unsigned>(std::lround(highlight.green * alpha)) << 8) | static_cast<unsigned>(std::lround(highlight.blue * alpha));
            for (int y = std::max(0, static_cast<int>(std::lround(highlight.top))); y < std::min(height, static_cast<int>(std::lround(highlight.top + highlight.height))); ++y) {
                for (int x = std::max(0, static_cast<int>(std::lround(highlight.left))); x < std::min(width, static_cast<int>(std::lround(highlight.left + highlight.width))); ++x)
                    blend(x, y, pixel);
            }
        }
    };
    if (frame.inputs().isSelectionBehindText)
        drawSelection();
    std::size_t retainedBytes = 0;
    for (std::size_t index = 0; index < quads.size(); ++index) {
        const auto& quad = quads[index];
        const auto& drawing = frame.richTextDrawing(index);
        auto& raster = m_state->rasters[quad.serial];
        const int rasterWidth = static_cast<int>(std::ceil(quad.width));
        const int rasterHeight = static_cast<int>(std::ceil(quad.height));
        const auto bytes = static_cast<std::size_t>(rasterWidth) * rasterHeight * 4;
        if (rasterWidth <= 0 || rasterHeight <= 0 || bytes > 64 * 1024 * 1024 - retainedBytes) {
            m_state->rasters.erase(quad.serial);
            continue;
        }
        retainedBytes += bytes;
        if (raster.key != quad.contentKey) {
            raster = { quad.contentKey, rasterWidth, rasterHeight, std::vector<std::uint32_t>(bytes / 4) };
            Surface surface(cairo_image_surface_create_for_data(reinterpret_cast<unsigned char*>(raster.pixels.data()), CAIRO_FORMAT_ARGB32, raster.width, raster.height, raster.width * 4), cairo_surface_destroy);
            Painter painter(cairo_create(surface.get()), cairo_destroy);
            if (cairo_status(painter.get()) != CAIRO_STATUS_SUCCESS)
                continue;
            const double scaleX = quad.pixelsPerUnitX * 4096;
            const double scaleY = quad.pixelsPerUnitY * 4096;
            cairo_scale(painter.get(), scaleX, scaleY);
            cairo_set_source_rgb(painter.get(), quad.red / 255.0, quad.green / 255.0, quad.blue / 255.0);
            // Keep the full paragraph for shaping. Core's line ranges choose
            // which Pango lines are drawn; scrolling only changes their origin.
            const Paragraphs paragraphs(m_state->fonts.get(), drawing.text(), drawing.styles(), m_state->fontLists,
                drawing.overflow() == RichText::Overflow::Clip ? -1 : std::max(0.0, quad.width / scaleX - drawing.padding().left - drawing.padding().right), drawing.cellWidth() / 512.0);
            const auto shaped = drawing.shapedLines();
            std::size_t next = 0;
            (void)paragraphs.forEachLine([&](std::uint32_t, const Paragraph&, PangoLayoutLine* line, std::uint32_t first, std::uint32_t) {
                while (next < shaped.size() && shaped[next].first < first)
                    ++next;
                if (next == shaped.size())
                    return false;
                if (shaped[next].first == first) {
                    cairo_move_to(painter.get(), shaped[next].origin / 4096.0, (shaped[next].top + shaped[next].baseline) / 4096.0);
                    pango_cairo_show_layout_line(painter.get(), line);
                }
                return true;
            });
            if (drawing.shapedLines().empty()) {
                // Layouts without native shaping retain Core's
                // geometry. Native wrap/clip always use complete shaped lines.
                for (const auto& cluster : drawing.clusters()) {
                    auto style = drawing.styles()[cluster.style];
                    const std::array<std::uint32_t, 1> ellipsis { 0x2026 };
                    const auto text = cluster.isEllipsis ? std::span<const std::uint32_t>(ellipsis) : drawing.text().subspan(cluster.first, cluster.end - cluster.first);
                    style.first = 0;
                    style.end = static_cast<std::uint32_t>(text.size());
                    Paragraph fragment(m_state->fonts.get(), text, { &style, 1 }, m_state->fontLists, -1, drawing.cellWidth() / 512.0);
                    cairo_move_to(painter.get(), cluster.x / 4096.0, cluster.baseline / 4096.0);
                    pango_cairo_show_layout_line(painter.get(), pango_layout_get_line_readonly(fragment.layout.get(), 0));
                }
            }
            cairo_surface_flush(surface.get());
            ++m_state->rasterCount;
        }
        const auto paint = [&](float left, float top, float right, float bottom) {
            const int originX = static_cast<int>(std::lround(quad.left));
            const int originY = static_cast<int>(std::lround(quad.top));
            for (int y = std::max({ 0, originY, static_cast<int>(std::lround(top)) }); y < std::min({ height, originY + raster.height, static_cast<int>(std::lround(bottom)) }); ++y) {
                for (int x = std::max({ 0, originX, static_cast<int>(std::lround(left)) }); x < std::min({ width, originX + raster.width, static_cast<int>(std::lround(right)) }); ++x)
                    blend(x, y, raster.pixels[static_cast<std::size_t>(y - originY) * raster.width + x - originX]);
            }
        };
        if (drawing.visibleRects().empty())
            paint(quad.left, quad.top, quad.left + quad.width, quad.top + quad.height);
        for (const auto& clip : drawing.visibleRects()) {
            const auto cell = frame.metrics();
            paint(quad.left + clip.x * cell.cellWidth, quad.top + clip.y * cell.cellHeight,
                quad.left + (clip.x + clip.width) * cell.cellWidth, quad.top + (clip.y + clip.height) * cell.cellHeight);
        }
    }
    if (!frame.inputs().isSelectionBehindText)
        drawSelection();
    const auto& in = frame.inputs();
    if (!drawCaret || in.cursor.row < 0 || in.cursor.shape != Cursor::Shape::Bar)
        return;
    Rendering::CursorQuadParameters parameters;
    parameters.column = in.cursor.column;
    parameters.vrow = in.cursor.row;
    parameters.columns = in.columns;
    parameters.rows = in.rows;
    parameters.shape = in.cursor.shape;
    parameters.blinkAlpha = in.cursor.mixA;
    parameters.focused = in.cursor.focused;
    parameters.cellWidthInPixels = frame.metrics().cellWidth;
    parameters.cellHeightInPixels = frame.metrics().cellHeight;
    parameters.origin = { in.originInPixels.x + in.cursor.richTextOffset * parameters.cellWidthInPixels, in.originInPixels.y };
    parameters.cursorRed = in.cursor.rgb.x;
    parameters.cursorGreen = in.cursor.rgb.y;
    parameters.cursorBlue = in.cursor.rgb.z;
    parameters.cursorAlpha = in.cursor.rgb.w;
    parameters.cellHeightPoints = in.cellHeightPoints;
    parameters.lineSpacingPoints = in.lineSpacingPoints;
    parameters.toolkitCaret = in.toolkitCaret;
    parameters.lineAttribute = in.cursor.lineAttribute;
    Rendering::OverlayQuad caret;
    if (!Rendering::buildCursorQuad(parameters, caret))
        return;
    const auto alpha = static_cast<unsigned>(std::lround(caret.alpha * 255));
    const auto pixel = (alpha << 24) | (static_cast<unsigned>(std::lround(caret.red * alpha)) << 16)
        | (static_cast<unsigned>(std::lround(caret.green * alpha)) << 8) | static_cast<unsigned>(std::lround(caret.blue * alpha));
    // Unfocused, the caret is the hollow outline: only its border ring, as
    // SoftwareRenderer::compositeOverlay keeps it.
    const int left = static_cast<int>(std::lround(caret.minX));
    const int top = static_cast<int>(std::lround(caret.minY));
    const int right = static_cast<int>(std::lround(caret.maxX));
    const int bottom = static_cast<int>(std::lround(caret.maxY));
    const int stroke = static_cast<int>(std::lround(caret.strokeWidth));
    for (int y = std::max(0, top); y < std::min(height, bottom); ++y) {
        for (int x = std::max(0, left); x < std::min(width, right); ++x) {
            if (stroke > 0 && x >= left + stroke && x < right - stroke && y >= top + stroke && y < bottom - stroke)
                continue;
            blend(x, y, pixel);
        }
    }
}

} // namespace Ubiquitty::Linux
