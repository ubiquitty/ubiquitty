// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
#include "Platform/Web/WebRichText.h"

#include "Core/Codec/JSON.h"
#include "Core/Rendering/OverlayGeometry.h"
#include "Core/RichText/Drawing.h"
#include "Core/RichText/ParagraphMetrics.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <random>
#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#endif

namespace Ubiquitty::Web {
namespace {
using Codec::JSON::Value;

#ifdef __EMSCRIPTEN__
// clang-format off
EM_JS(int, webRichTextRegister, (), {
    if (!Module.ubiquittyRichText || Module.ubiquittyRichText.isDisposed) return 0;
    if (!Module.ubiquittyRichTextAdapters) Module.ubiquittyRichTextAdapters = new Map();
    const id = (Module.ubiquittyRichTextNextID || 0) + 1;
    Module.ubiquittyRichTextNextID = id;
    Module.ubiquittyRichTextAdapters.set(id, Module.ubiquittyRichText);
    return id;
});
EM_JS(void, webRichTextUnregister, (int id), {
    Module.ubiquittyRichTextAdapters?.get(id)?.dispose();
    Module.ubiquittyRichTextAdapters?.delete(id);
});
EM_JS(int, webRichTextGeneration, (int id), {
    const adapter = Module.ubiquittyRichTextAdapters?.get(id);
    adapter?.fontCatalog.refresh();
    return adapter?.fontGeneration || 0;
});
EM_JS(int, webRichTextFontCatalogScope, (int id), {
    return Module.ubiquittyRichTextAdapters?.get(id)?.fontCatalog.scope || 0;
});
EM_JS(int, webRichTextFontCatalog, (int id, unsigned offset, unsigned count, int maxBytes, char* output, int capacity), {
    const catalog = Module.ubiquittyRichTextAdapters?.get(id)?.fontCatalog;
    if (!catalog) return 0;
    const families = [];
    let bytes = 0;
    for (const family of catalog.families.slice(offset, offset + count)) {
        bytes += lengthBytesUTF8(family);
        if (bytes > maxBytes) break;
        families.push(family);
    }
    const json = JSON.stringify({ scope: catalog.scope, total: catalog.families.length, families });
    const length = lengthBytesUTF8(json);
    if (length >= capacity) return 0;
    stringToUTF8(json, output, capacity);
    return length;
});
EM_JS(int, webRichTextMetrics, (int id, const char* family, int style, double* output, int count), {
    const metrics = Module.ubiquittyRichTextAdapters?.get(id)?.metrics(UTF8ToString(family), style);
    if (!metrics || metrics.length !== count) return 0;
    HEAPF64.set(metrics, output >> 3);
    return 1;
});
EM_JS(int, webRichTextShape, (int id, const char* model, std::int32_t* output, int capacity), {
    const result = Module.ubiquittyRichTextAdapters?.get(id)?.shape(JSON.parse(UTF8ToString(model)));
    if (!result || result.length > capacity || !result.every(value => Number.isInteger(value) && value >= 0 && value < 0x7fffffff)) return 0;
    HEAP32.set(result, output >> 2);
    return result.length;
});
// clang-format on
#else
int webRichTextRegister() { return 0; }
void webRichTextUnregister(int) { }
int webRichTextGeneration(int) { return 0; }
int webRichTextFontCatalogScope(int) { return 0; }
int webRichTextFontCatalog(int, unsigned, unsigned, int, char*, int) { return 0; }
int webRichTextMetrics(int, const char*, int, double*, int) { return 0; }
int webRichTextShape(int, const char*, std::int32_t*, int) { return 0; }
#endif

Value numbers(std::initializer_list<double> values)
{
    auto result = Value::array();
    for (const auto value : values)
        result.push(Value::number(value));
    return result;
}

Value familiesJSON(const std::array<std::string, 3>& families)
{
    auto result = Value::array();
    for (const auto& family : families)
        result.push(Value::string(family));
    return result;
}

Value documentJSON(std::span<const std::uint32_t> text, std::span<const RichText::DrawnStyle> styles)
{
    auto result = Value::object();
    auto scalars = Value::array();
    for (const auto scalar : text)
        scalars.push(Value::number(scalar));
    result.set("text", std::move(scalars));
    auto runs = Value::array();
    for (const auto& style : styles) {
        auto run = Value::object();
        run.set("first", Value::number(style.first));
        run.set("end", Value::number(style.end));
        run.set("family", Value::number(std::to_underlying(style.familyClass)));
        run.set("name", Value::string(style.familyName()));
        run.set("size", Value::number(style.halfPoints / 2));
        run.set("bits", Value::number(style.styles));
        if (!style.isAutomaticColor)
            run.set("color", numbers({ static_cast<double>(style.red), static_cast<double>(style.green), static_cast<double>(style.blue) }));
        if (style.hasBackground)
            run.set("background", numbers({ static_cast<double>(style.backgroundRed), static_cast<double>(style.backgroundGreen), static_cast<double>(style.backgroundBlue) }));
        runs.push(std::move(run));
    }
    result.set("styles", std::move(runs));
    return result;
}

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

const RichText::DrawnStyle& styleAt(std::span<const RichText::DrawnStyle> styles, std::uint32_t index)
{
    const auto found = std::ranges::find_if(styles, [index](const auto& style) { return style.first <= index && style.end > index; });
    return found == styles.end() ? styles.front() : *found;
}
}

WebRichText::WebRichText()
{
    std::random_device entropy;
    m_facts.rendererRevision = (std::uint64_t { entropy() } << 32) | entropy();
}

WebRichText::~WebRichText()
{
    if (m_adapterHandle)
        webRichTextUnregister(m_adapterHandle);
}

bool WebRichText::needsConfiguration() const
{
    return m_adapterHandle && static_cast<std::uint32_t>(webRichTextGeneration(m_adapterHandle)) != m_fontGeneration;
}

RichText::TypographyFacts WebRichText::configure(std::string gridFamily, std::string proportionalFamily,
    const Rendering::CellMetrics& metrics, double size, double gridSize, double deviceScale)
{
    // Sync can request a child pane's measurement while the carrier is the
    // selected ABI view. Bind the adapter to this terminal's lifetime rather
    // than reading whichever view's Module properties were selected last.
    if (!m_adapterHandle)
        m_adapterHandle = webRichTextRegister();
    const auto fontGeneration = static_cast<std::uint32_t>(webRichTextGeneration(m_adapterHandle));
    if (!m_adapterHandle || !fontGeneration)
        return {};
    const std::array<std::string, 3> families { proportionalFamily.empty() ? "sans-serif" : std::move(proportionalFamily), "serif", gridFamily.empty() ? "monospace" : std::move(gridFamily) };
    const auto metric = [](double value) { return static_cast<std::uint16_t>(std::clamp(std::lround(value * 64), 1l, static_cast<long>(RichText::maxCellSize))); };
    RichText::TypographyFacts facts;
    facts.cellWidth = metric(metrics.cellWidth / deviceScale);
    facts.cellHeight = metric(metrics.cellHeight / deviceScale);
    facts.baseline = std::min(facts.cellHeight, metric(metrics.baselineFromTop / deviceScale));
    facts.proportionalSize = metric(size);
    facts.monospaceSize = metric(gridSize);
    facts.shaping = 1;
    facts.rendersBlocks = 1;
    facts.fontCatalogScope = static_cast<RichText::FontCatalogScope>(webRichTextFontCatalogScope(m_adapterHandle));
    if (families == m_families && m_facts.cellWidth == facts.cellWidth && m_facts.cellHeight == facts.cellHeight
        && m_facts.baseline == facts.baseline && m_facts.proportionalSize == facts.proportionalSize && m_facts.monospaceSize == facts.monospaceSize
        && fontGeneration == m_fontGeneration)
        return m_facts;
    facts.rendererRevision = m_facts.rendererRevision + 1;
    if (!facts.rendererRevision)
        facts.rendererRevision = 1;
    for (unsigned family = 0; family < families.size(); ++family) {
        for (unsigned style = 0; style < 4; ++style) {
            std::array<double, RichText::tabledCodePointCount + 4> measured {};
            if (!webRichTextMetrics(m_adapterHandle, families[family].c_str(), static_cast<int>(style), measured.data(), static_cast<int>(measured.size())))
                return {};
            const auto em = [](double value) { return static_cast<std::uint16_t>(std::clamp(std::lround(value * RichText::unitsPerEm), 0l, 65535l)); };
            auto& face = facts.faces[facts.faceCount++];
            face.familyClass = static_cast<RichText::FamilyClass>(family);
            face.styles = static_cast<std::uint8_t>(style);
            face.ascent = em(measured[0]);
            face.descent = em(measured[1]);
            face.lineHeight = em(measured[2]);
            face.averageAdvance = em(measured[3]);
            for (std::size_t index = 0; index < face.advances.size(); ++index)
                face.advances[index] = em(measured[index + 4]);
        }
    }
    m_families = families;
    m_facts = facts;
    m_fontGeneration = fontGeneration;
    m_sentKeys.clear();
    return facts;
}

RichText::FontCatalogProvider WebRichText::fontCatalog()
{
    return { [](void* context, const RichText::FontCatalogQuery* query, const RichText::TypographyFacts* facts, RichText::FontCatalogPage* page) {
                auto& owner = *static_cast<WebRichText*>(context);
                page->offset = query->offset;
                page->rendererRevision = owner.m_facts.rendererRevision;
                page->scope = owner.m_facts.fontCatalogScope;
                if (query->rendererRevision != owner.m_facts.rendererRevision || facts->rendererRevision != owner.m_facts.rendererRevision || owner.needsConfiguration()) {
                    page->status = RichText::FontCatalogStatus::Stale;
                    return true;
                }
                if (page->scope == RichText::FontCatalogScope::Unavailable)
                    return true;
                // JSON can expand a UTF-8 name byte into six ASCII escape bytes.
                std::array<char, RichText::maxFontCatalogPageBytes * 6 + RichText::maxFontCatalogPageFamilies * 3 + 128> json {};
                const auto length = webRichTextFontCatalog(owner.m_adapterHandle, query->offset, query->count,
                    static_cast<int>(RichText::maxFontCatalogPageBytes), json.data(), static_cast<int>(json.size()));
                if (length <= 0)
                    return false;
                bool isValid = false;
                const auto decoded = Codec::JSON::parse({ json.data(), static_cast<std::size_t>(length) }, isValid);
                if (!isValid || !decoded.isObject())
                    return false;
                const auto* total = decoded.find("total");
                const auto* scope = decoded.find("scope");
                const auto* families = decoded.find("families");
                if (!total || !total->isNumber() || total->asNumber() < 0 || total->asNumber() > std::numeric_limits<std::uint32_t>::max()
                    || std::floor(total->asNumber()) != total->asNumber()
                    || !scope || !scope->isNumber() || scope->asNumber() != std::to_underlying(page->scope)
                    || !families || !families->isArray())
                    return false;
                page->total = static_cast<std::uint32_t>(total->asNumber());
                if (page->offset > page->total) {
                    page->status = RichText::FontCatalogStatus::Invalid;
                    page->total = 0;
                    return true;
                }
                if (families->items().size() > query->count || families->items().size() > page->total - page->offset)
                    return false;
                for (const auto& family : families->items()) {
                    if (!family.isString() || !page->appendFamily(family.asString()))
                        return false;
                }
                page->status = RichText::FontCatalogStatus::Ready;
                return page->offset == page->total || !page->families.empty();
            },
        this };
}

RichText::Shaper WebRichText::shaper()
{
    return { [](void* context, const RichText::Document* document, const RichText::ShapeRequest* request,
                 const RichText::TypographyFacts* facts, RichText::ShapedText* output) {
                auto& owner = *static_cast<WebRichText*>(context);
                if (facts->rendererRevision != owner.m_facts.rendererRevision || owner.needsConfiguration())
                    return false;
                const auto styles = stylesOf(*document, *request, *facts);
                if (styles.empty() || document->text.empty())
                    return false;
                auto model = documentJSON(document->text, styles);
                model.set("families", familiesJSON(owner.m_families));
                model.set("clip", Value::boolean(request->overflow == RichText::Overflow::Clip));
                model.set("tabWidth", Value::number(facts->cellWidth / 8.0));
                const auto blockWidth = static_cast<std::uint32_t>(std::max(0.0, request->width * facts->cellWidth / 64.0 - request->padding.left - request->padding.right) * 4096);
                auto paragraphs = Value::array();
                for (std::uint32_t first = 0; first < document->text.size();) {
                    auto end = first;
                    while (end < document->text.size() && document->text[end++] != '\n') {
                    }
                    const auto& paragraph = styleAt(styles, first).paragraph;
                    const auto rest = RichText::lineIndent(paragraph, { false, false });
                    const auto start = RichText::lineIndent(paragraph, { true, false });
                    const auto width = RichText::lineWidth(paragraph, { false, false }, blockWidth);
                    // The rest of the paragraph's lines' indent and its first
                    // line's hanging tab stop, which place a line's tabs on the
                    // content box's grid as Core's own layout places them.
                    const auto hanging = RichText::hangingTabStop(paragraph, { true, false });
                    paragraphs.push(numbers({ static_cast<double>(first), static_cast<double>(end), width / 4096.0,
                        (static_cast<double>(start) - rest) / 4096.0, rest / 4096.0, hanging / 4096.0 }));
                    first = end;
                }
                model.set("paragraphs", std::move(paragraphs));
                const auto json = Codec::JSON::serialize(model);
                std::vector<std::int32_t> geometry(2 + RichText::maxCodePoints * 10);
                const int count = webRichTextShape(owner.m_adapterHandle, json.c_str(), geometry.data(), static_cast<int>(geometry.size()));
                if (count < 2 || geometry[0] < 0 || geometry[1] < 0 || geometry[0] > RichText::maxCodePoints || geometry[1] > RichText::maxCodePoints
                    || count != 2 + geometry[0] * 5 + geometry[1] * 5)
                    return false;
                std::uint32_t top = 0;
                for (int index = 0; index < geometry[0]; ++index) {
                    const auto* values = geometry.data() + 2 + index * 5;
                    const auto first = static_cast<std::uint32_t>(values[0]), end = static_cast<std::uint32_t>(values[1]);
                    if (first >= end || end > document->text.size() || values[2] <= 0 || values[3] < 0 || values[4] < 0)
                        return false;
                    const auto& style = styleAt(styles, first);
                    const auto place = RichText::linePlace(document->text, first, end);
                    const auto naturalHeight = request->lineMode == RichText::LineMode::Terminal ? facts->cellHeight * 64u : static_cast<std::uint32_t>(values[2]);
                    const auto naturalBaseline = request->lineMode == RichText::LineMode::Terminal ? facts->baseline * 64u : static_cast<std::uint32_t>(values[3]);
                    const auto box = RichText::lineBox(style.paragraph, naturalHeight, naturalBaseline, place, request->lineMode);
                    const auto width = static_cast<std::uint32_t>(values[4]);
                    const auto available = RichText::lineWidth(style.paragraph, place, blockWidth);
                    const auto alignment = style.alignment == RichText::Alignment::Unspecified ? request->alignment : style.alignment;
                    const auto slack = available > width ? available - width : 0;
                    const auto origin = RichText::lineIndent(style.paragraph, place)
                        + (alignment == RichText::Alignment::Center ? slack / 2 : alignment == RichText::Alignment::Right ? slack
                                                                                                                          : 0);
                    constexpr auto limit = static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max());
                    if (box.height >= limit - top || origin >= limit || width >= limit - origin)
                        return false;
                    output->appendLine({ first, end, top, box.height, box.baseline, origin, width });
                    top += box.height;
                }
                for (int index = 0; index < geometry[1]; ++index) {
                    const auto* values = geometry.data() + 2 + geometry[0] * 5 + index * 5;
                    if (values[2] < 0 || static_cast<std::size_t>(values[2]) >= output->lines.size())
                        return false;
                    const auto origin = static_cast<std::int64_t>(output->lines[static_cast<std::size_t>(values[2])].origin);
                    const auto leading = origin + values[3];
                    const auto trailing = origin + values[4];
                    if (leading < 0 || trailing < 0 || leading >= std::numeric_limits<std::int32_t>::max() || trailing >= std::numeric_limits<std::int32_t>::max())
                        return false;
                    output->appendSpan({ static_cast<std::uint32_t>(values[0]), static_cast<std::uint32_t>(values[1]),
                        static_cast<std::uint32_t>(values[2]), static_cast<std::int32_t>(leading), static_cast<std::int32_t>(trailing) });
                }
                return true;
            },
        this };
}

const char* WebRichText::frameJSON(const Rendering::TerminalFrameInputs& frame, Rendering::ChromeLayers chrome)
{
    auto result = Value::object();
    result.set("families", familiesJSON(m_families));
    auto occlusions = Value::array();
    for (const auto& layer : chrome) {
        if (layer.canvas && layer.canvas->rows > 0 && layer.canvas->columns > 0)
            occlusions.push(numbers({ frame.inputs().originInPixels.x + layer.originColumn * frame.metrics().cellWidth,
                frame.inputs().originInPixels.y + layer.originRow * frame.metrics().cellHeight,
                layer.canvas->columns * frame.metrics().cellWidth, layer.canvas->rows * frame.metrics().cellHeight }));
    }
    result.set("occlusions", std::move(occlusions));
    auto blocks = Value::array();
    const auto quads = frame.richTextQuads();
    std::erase_if(m_sentKeys, [&](const auto& entry) { return std::ranges::none_of(quads, [&](const auto& quad) { return quad.serial == entry.first; }); });
    for (std::size_t index = 0; index < quads.size(); ++index) {
        const auto& quad = quads[index];
        const auto& drawing = frame.richTextDrawing(index);
        auto block = Value::object();
        block.set("id", Value::number(quad.serial));
        block.set("key", Value::string(std::to_string(quad.contentKey)));
        block.set("rect", numbers({ quad.left, quad.top, quad.width, quad.height }));
        block.set("scale", numbers({ quad.pixelsPerUnitX * 4096, quad.pixelsPerUnitY * 4096 }));
        block.set("color", numbers({ static_cast<double>(quad.red), static_cast<double>(quad.green), static_cast<double>(quad.blue) }));
        auto clips = Value::array();
        for (const auto& rect : drawing.visibleRects())
            clips.push(numbers({ rect.x * frame.metrics().cellWidth, rect.y * frame.metrics().cellHeight,
                rect.width * frame.metrics().cellWidth, rect.height * frame.metrics().cellHeight }));
        block.set("clips", std::move(clips));
        if (!m_sentKeys.contains(quad.serial) || m_sentKeys[quad.serial] != quad.contentKey) {
            auto document = documentJSON(drawing.text(), drawing.styles());
            // The tab width the shaper measured with, eight cells in points:
            // a line is presented through the same tab stops it was measured at.
            document.set("tabWidth", Value::number(drawing.cellWidth() * 8 / 4096.0));
            auto lines = Value::array();
            for (const auto& line : drawing.shapedLines()) {
                // Each line's indent and hanging tab stop, from which its tabs
                // are set on the content box's grid as the shaper set them.
                std::uint32_t indent = 0;
                std::uint32_t hanging = 0;
                if (!drawing.styles().empty()) {
                    const auto place = RichText::linePlace(drawing.text(), line.first, line.end);
                    const auto& paragraph = styleAt(drawing.styles(), RichText::paragraphStart(drawing.text(), line.first)).paragraph;
                    indent = RichText::lineIndent(paragraph, place);
                    hanging = RichText::hangingTabStop(paragraph, place);
                }
                lines.push(numbers({ static_cast<double>(line.first), static_cast<double>(line.end),
                    line.origin / 4096.0, (line.top + line.baseline) / 4096.0, indent / 4096.0, hanging / 4096.0 }));
            }
            document.set("lines", std::move(lines));
            auto clusters = Value::array();
            for (const auto& cluster : drawing.clusters())
                clusters.push(numbers({ static_cast<double>(cluster.first), static_cast<double>(cluster.end),
                    cluster.x / 4096.0, cluster.baseline / 4096.0, cluster.advance / 4096.0,
                    cluster.top / 4096.0, cluster.height / 4096.0, static_cast<double>(cluster.style), static_cast<double>(cluster.isEllipsis) }));
            document.set("clusters", std::move(clusters));
            block.set("document", std::move(document));
            m_sentKeys[quad.serial] = quad.contentKey;
        }
        blocks.push(std::move(block));
    }
    result.set("blocks", std::move(blocks));
    auto highlights = Value::array();
    for (const auto& highlight : frame.richTextHighlights())
        highlights.push(numbers({ highlight.left, highlight.top, highlight.width, highlight.height,
            highlight.red, highlight.green, highlight.blue, highlight.alpha }));
    result.set("highlights", std::move(highlights));
    if (frame.hasRichTextCaret()) {
        const auto& in = frame.inputs();
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
        if (Rendering::buildCursorQuad(parameters, caret))
            result.set("caret", numbers({ caret.minX, caret.minY, caret.maxX - caret.minX, caret.maxY - caret.minY, caret.red, caret.green, caret.blue, caret.alpha, caret.strokeWidth }));
    }
    result.set("selectionBehind", Value::boolean(frame.inputs().isSelectionBehindText));
    m_frameJSON = Codec::JSON::serialize(result);
    return m_frameJSON.c_str();
}
} // namespace Ubiquitty::Web
