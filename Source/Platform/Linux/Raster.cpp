// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// See Raster.h. A thin wrapper over Rendering::SoftwareRenderer: snapshots
// the passive Terminal's visible grid into a flat array and hands it to the
// shared renderer. Cell/glyph/cursor/decoration logic lives in the shared core;
// this file only bridges the Terminal to it.

#include "Platform/Linux/Raster.h"
#include "Core/CellPen.h"
#include "Core/Cursor/RenderState.h"
#include "Core/Rendering/OverlaySpanGather.h"
#include "Core/Screen/Addressing.h"
#include "Core/Selection/TerminalSelection.h"
#include <span>

#include "Core/Attributes/LinkRun.h"
#include "Core/Preferences/RenderStyle.h"
#include "Core/Rendering/BeamLayout.h"
#include "Core/Rendering/BoxStrokeProfile.h"
#include "Core/Rendering/CellCanvas.h"
#include "Core/Rendering/GlyphRasterizer.h"
#include "Core/Rendering/HintToastLayout.h"
#include "Core/Rendering/OverlayAssembly.h"
#include "Core/Rendering/OverlayGeometry.h"
#include "Core/Rendering/SoftwareRenderer.h"
#include "Core/Rendering/StatusRow.h"
#include "Core/Rendering/TerminalFrameInputs.h"
#include "Core/Rendering/TerminalSnapshot.h"
#include "Core/Screen/ScrollSearch.h"
#include "Core/Selection/Selection.h"
#include "Core/TermPalette.h"
#include "Core/TerminalOperations.h"
#include "Core/Triggers/Triggers.h"
#include "Core/Unicode/Width.h"

#include <algorithm>
#include <cmath>
#include <optional>

namespace Ubiquitty::Linux {

struct RasterContext::State {
    // Set before the first rasterizeTerm; selects the SoftwareRenderer's glyph
    // raster (FreeType when injected, else its own Unifont).
    Rendering::GlyphRasterizer* injectedRasterizer = nullptr;

    // The CPU renderer, built lazily on the first rasterizeTerm against the
    // injected rasterizer (it owns the cross-frame glyph LRU, so it persists).
    // resetSoftwareRenderer() drops it so a runtime rasterizer swap rebuilds it.
    std::optional<Rendering::SoftwareRenderer> softwareRenderer;

    // The active IME pre-edit (composition) codepoints, drawn underlined at
    // the cursor by snapshotVisibleGrid. Empty = no composition in progress.
    std::vector<std::uint32_t> preeditText;

    // The Beam palette's drawn picture for this frame, or an empty canvas when it is
    // closed. Composited by snapshotVisibleGrid, so both render paths draw it from
    // the same cells and the CPU<->GPU oracle covers the palette for free. Handing it
    // to renderGrid and rasterizeTerm separately would let the two disagree, and a
    // palette that appears under one backend and not the other reads as a rendering
    // fault rather than a missing argument.
    Rendering::BeamGeometry beamChrome;
    // The reserved-gesture hint, drawn into cells because this arm has no window
    // chrome to hang one from. Composited beside the palette, below it when both
    // are up: the palette is what the user is looking at.
    Rendering::HintToastGeometry hintChrome;
    // The render settings that belong to the window rather than to a pane. One
    // object because one function sets them and one capture reads them: a setting
    // added beside these has nowhere to be forgotten, so the headless snapshot
    // cannot honour the opacity and drop the link styling.
    struct WindowRenderSettings {
        // Core's fold of the configuration, the one input both render paths style
        // a frame from.
        Rendering::RenderConfiguration configuration = Preferences::Effective::renderConfiguration(Preferences::Values {});
        // The window's GTK scale factor. The glyphs are rasterized at the device
        // size, so the rule offsets the configuration names in the same units have
        // to travel the same multiplier or they shrink relative to the type on
        // every HiDPI display.
        int deviceScale = 1;
        // The embedded bitmap face's upscale while it is the selected face, else 0.
        int embeddedBitmapScale = 0;
        // The decoded `[appearance] background_image`, which the frontend
        // loads when the path changes, and how many times it has changed: the
        // GPU path re-uploads its texture when the count moves.
        Rendering::BackgroundImagePixels backgroundImage;
        std::uint64_t backgroundImageGeneration = 0;
        // GTK's gtk-cursor-aspect-ratio, which sizes the bar as GTK's caret.
        // GTK's own default until the frontend reads the setting.
        double toolkitCaretAspectRatio = 0.04;
    };
    WindowRenderSettings windowRenderSettings;
    float lastFocusedMatchAgeSeconds = -1.0f;
};

RasterContext::RasterContext()
    : m_state(std::make_unique<State>())
{
}

RasterContext::~RasterContext() = default;

std::vector<IntRect> RasterContext::snapshotOverlayRegions(const Terminal& terminal, int viewOffset) const
{
    std::vector<IntRect> regions;
    const auto append = [&](int column, int row, int columns, int rows) {
        if (columns > 0 && rows > 0)
            regions.push_back({ { column * cellWidth(), row * cellHeight() }, { columns * cellWidth(), rows * cellHeight() } });
    };
    append(m_state->beamChrome.originColumn, m_state->beamChrome.originRow, m_state->beamChrome.canvas.columns, m_state->beamChrome.canvas.rows);
    append(m_state->hintChrome.originColumn, m_state->hintChrome.originRow, m_state->hintChrome.canvas.columns, m_state->hintChrome.canvas.rows);
    if (!m_state->preeditText.empty() && viewOffset == 0 && terminal.screens.active) {
        int width = 0;
        for (const auto scalar : m_state->preeditText)
            width += std::max(Unicode::Width::forCodePoint(scalar, terminal.ambiguousWidth), 0);
        append(terminal.screens.active->cursorX, terminal.screens.active->cursorY, width, 1);
    }
    return regions;
}

bool RasterContext::snapshotCompositesOverlay() const
{
    return !m_state->preeditText.empty() || m_state->beamChrome.canvas.rows > 0 || m_state->hintChrome.canvas.rows > 0;
}

void RasterContext::setPreedit(const std::uint32_t* codePoints, int count)
{
    if (!codePoints || count <= 0)
        m_state->preeditText.clear();
    else
        m_state->preeditText.assign(codePoints, codePoints + count);
}

void RasterContext::setBeamChrome(const Rendering::BeamGeometry* chrome)
{
    m_state->beamChrome = chrome != nullptr ? *chrome : Rendering::BeamGeometry {};
}

void RasterContext::setHintChrome(const Rendering::HintToastGeometry* chrome)
{
    m_state->hintChrome = chrome != nullptr ? *chrome : Rendering::HintToastGeometry {};
}

void RasterContext::setRenderConfiguration(const Rendering::RenderConfiguration& configuration) { m_state->windowRenderSettings.configuration = configuration; }

void RasterContext::setBackgroundImage(Rendering::BackgroundImagePixels pixels)
{
    m_state->windowRenderSettings.backgroundImage = std::move(pixels);
    ++m_state->windowRenderSettings.backgroundImageGeneration;
}

Rendering::BackgroundImageLayer RasterContext::backgroundImageLayer() const
{
    Rendering::TerminalSnapshotOptions options;
    Preferences::Effective::applyBackgroundImageSettings(options, m_state->windowRenderSettings.configuration,
        &m_state->windowRenderSettings.backgroundImage);
    return options.backgroundImage;
}

std::uint64_t RasterContext::backgroundImageGeneration() const { return m_state->windowRenderSettings.backgroundImageGeneration; }
const Rendering::RenderConfiguration& RasterContext::renderConfiguration() const { return m_state->windowRenderSettings.configuration; }

void RasterContext::setDeviceScale(int scale) { m_state->windowRenderSettings.deviceScale = scale > 0 ? scale : 1; }
void RasterContext::setToolkitCaretAspectRatio(double aspectRatio) { m_state->windowRenderSettings.toolkitCaretAspectRatio = aspectRatio; }
Rendering::ToolkitCaret RasterContext::toolkitCaret() const
{
    return { .aspectRatio = m_state->windowRenderSettings.toolkitCaretAspectRatio, .logicalScale = m_state->windowRenderSettings.deviceScale };
}
void RasterContext::setEmbeddedBitmapScale(int scale) { m_state->windowRenderSettings.embeddedBitmapScale = scale > 0 ? scale : 0; }
int RasterContext::embeddedBitmapScale() const { return m_state->windowRenderSettings.embeddedBitmapScale; }
bool RasterContext::isFocusedMatchBouncing() const { return m_state->lastFocusedMatchAgeSeconds >= 0.0f && m_state->lastFocusedMatchAgeSeconds < Rendering::focusedPillBounceSeconds; }

float RasterContext::backgroundOpacity() const { return std::clamp(static_cast<float>(m_state->windowRenderSettings.configuration.backgroundOpacity), 0.0f, 1.0f); }

int RasterContext::deviceScale() const { return m_state->windowRenderSettings.deviceScale; }

void RasterContext::setGlyphRasterizer(Rendering::GlyphRasterizer& rasterizer) { m_state->injectedRasterizer = &rasterizer; }

void RasterContext::resetSoftwareRenderer() { m_state->softwareRenderer.reset(); }

int RasterContext::columnAt(int row, double xInPixels) const
{
    if (m_state->softwareRenderer)
        return m_state->softwareRenderer->columnAt(row, xInPixels);
    const int pitch = cellWidth();
    return pitch > 0 ? std::max(0, static_cast<int>(std::floor(xInPixels / pitch))) : 0;
}

double RasterContext::xInCellsAt(int row, double xInPixels) const
{
    if (m_state->softwareRenderer)
        return m_state->softwareRenderer->xInCellsAt(row, xInPixels);
    const int pitch = cellWidth();
    return pitch > 0 ? std::max(0.0, xInPixels / pitch) : 0.0;
}

// The atlas persists across frames on the single GTK thread that renders, and is
// built lazily so an injected rasterizer set before the first call is wired in.
void RasterContext::ensureSoftwareRenderer()
{
    auto& softwareRenderer = m_state->softwareRenderer;
    auto* injectedRasterizer = m_state->injectedRasterizer;
    if (softwareRenderer)
        return;
    if (injectedRasterizer)
        softwareRenderer.emplace(*injectedRasterizer); // font-derived cell
    else
        softwareRenderer.emplace(fallbackCellWidth, fallbackCellHeight);
}

bool RasterContext::softwareBackendIsLossy()
{
    ensureSoftwareRenderer();
    return Rendering::optionalDefaultsAreLossy(m_state->softwareRenderer->glyphBackend());
}

int RasterContext::cellWidth() const
{
    const auto* injectedRasterizer = m_state->injectedRasterizer;
    if (injectedRasterizer)
        return Rendering::cellDimension(injectedRasterizer->cellMetrics().cellWidth);
    return fallbackCellWidth;
}

int RasterContext::cellHeight() const
{
    const auto* injectedRasterizer = m_state->injectedRasterizer;
    if (injectedRasterizer)
        return Rendering::cellDimension(injectedRasterizer->cellMetrics().cellHeight);
    return fallbackCellHeight;
}

void RasterContext::snapshotVisibleGrid(Ubiquitty::Terminal* term, int viewOffset, std::vector<Cell>& outGrid) const
{
    const auto& preeditText = m_state->preeditText;
    const auto& beamChrome = m_state->beamChrome;
    const auto& hintChrome = m_state->hintChrome;
    if (!term)
        return;
    const int columns = term->columns;
    const int rows = term->rows;
    if (columns <= 0 || rows <= 0)
        return;

    // Snapshot the visible grid into a contiguous row-major array (the builder
    // reads a flat Cell*; the Terminal stores rows in a ring). Blank cells default
    // to the terminal default colors, not ANSI index 0. The selection is not baked
    // in — it is an overlay quad (see selectionRowSpans).
    Cell blank {};
    {
        Pen blankPen;
        penReset(&blankPen);
        Ubiquitty::cellSetPen(blank, blankPen);
    }
    outGrid.assign(static_cast<size_t>(rows) * columns, blank);
    for (int row = 0; row < rows; ++row) {
        for (int column = 0; column < columns; ++column) {
            const Cell* cell = Ubiquitty::Screen::visibleCell(term, viewOffset, row, column);
            if (cell)
                outGrid[static_cast<size_t>(row) * columns + column] = *cell;
        }
    }

    // Overlay the IME pre-edit at the cursor, underlined. Only at viewOffset 0
    // (the cursor lives at the live tail); overwrites the snapshot copy, never the
    // Terminal. A wide codepoint takes its two cells — the pre-edit is CJK more
    // often than not, and a wide glyph stamped into one cell draws over the
    // neighbour or collapses, depending on the renderer.
    if (!preeditText.empty() && viewOffset == 0 && term->screens.active) {
        const int cursorRow = term->screens.active->cursorY;
        int column = term->screens.active->cursorX;
        if (cursorRow >= 0 && cursorRow < rows) {
            for (const std::uint32_t codePoint : preeditText) {
                const int width = Ubiquitty::Unicode::Width::forCodePoint(codePoint, term->ambiguousWidth);
                if (width <= 0)
                    continue; // combining or zero-width: no cell of its own here
                if (column < 0) {
                    column += width;
                    continue;
                }
                if (column + width > columns)
                    break; // a wide glyph does not split across the edge
                Cell& cell = outGrid[static_cast<size_t>(cursorRow) * columns + column];
                cell = blank;
                cell.codePoint = codePoint;
                Pen preeditPen = Ubiquitty::cellPen(cell);
                preeditPen.attributes.add(Ubiquitty::VT::Attribute::Underline);
                if (width == 2)
                    preeditPen.attributes.add(Ubiquitty::VT::Attribute::Wide);
                Ubiquitty::cellSetPen(cell, preeditPen);
                if (width == 2) {
                    Cell& continuation = outGrid[static_cast<size_t>(cursorRow) * columns + column + 1];
                    continuation = blank;
                    Pen continuationPen = Ubiquitty::cellPen(continuation);
                    continuationPen.attributes.add(Ubiquitty::VT::Attribute::Underline);
                    continuationPen.attributes.add(Ubiquitty::VT::Attribute::WideContinuation);
                    Ubiquitty::cellSetPen(continuation, continuationPen);
                }
                column += width;
            }
        }
    }

    // Stamp the Beam palette over everything else. Last, because it is a popover:
    // it sits above the terminal's own content including a pre-edit, and Core's
    // composite clips to the destination, so an oversized or badly-placed canvas
    // cannot write outside the grid. Closed, the canvas has no rows and this is
    // one branch.
    //
    // Not gated on viewOffset: the palette is chrome, not screen content, and
    // hiding it while the user is scrolled back would make Beam unusable exactly
    // when someone is looking for something they scrolled past.
    if (hintChrome.canvas.rows > 0)
        Rendering::composite(outGrid.data(), rows, columns, hintChrome.canvas, hintChrome.originRow, hintChrome.originColumn);
    // The palette last, so it covers the hint rather than the other way round:
    // an open palette is what the user is looking at.
    if (beamChrome.canvas.rows > 0)
        Rendering::composite(outGrid.data(), rows, columns, beamChrome.canvas, beamChrome.originRow, beamChrome.originColumn);
}

void selectionRowSpans(Ubiquitty::Terminal* term, int viewOffset, Ubiquitty::Selection::Session* selection, std::vector<Rendering::SelectionRowSpan>& outSpans)
{
    outSpans.clear();
    if (!term || !selection || term->rows <= 0)
        return;
    // Core's facade resolves the wide-aware bounds and the per-row void rule;
    // this side only sizes the scratch, to the room Core says holds every span
    // and piece of the grid.
    outSpans.resize(static_cast<std::size_t>(Ubiquitty::Selection::viewportSpanCapacity(term->rows, term->columns)));
    const int count = Ubiquitty::Selection::viewportSpans(*selection, *term, viewOffset,
        Ubiquitty::Selection::ViewportSpans { outSpans.data(), outSpans.size() });
    outSpans.resize(static_cast<std::size_t>(count > 0 ? count : 0));
}

Rendering::Vec4 focusedSearchMatchHighlightColor()
{
    const Rendering::OverlayColor color = Rendering::focusedSearchMatchColor();
    return { color.red, color.green, color.blue, color.alpha };
}

Rendering::Vec4 selectionHighlightColor()
{
    // The translucent selection tint is shared with the macOS frontend + the
    // agent rasterizer (Rendering::OverlayGeometry::selectionHighlightColor) so
    // every backend's selection overlay composites the same color.
    const Rendering::OverlayColor c = Rendering::selectionHighlightColor();
    return { c.red, c.green, c.blue, c.alpha };
}

void RasterContext::fillCursorState(const Ubiquitty::Terminal* term, int viewOffset, const CursorOverlay* cursor, Rendering::CursorRenderState& out) const
{
    out = Rendering::CursorRenderState {};
    // The cursor lives at the live cursorY; suppress it in a scrolled-back view
    // (viewOffset > 0). A null override ⇒ a static focused block; an override that
    // isn't visible suppresses the cursor.
    if (!term || !term->screens.active || viewOffset != 0)
        return;
    if (cursor && cursor->presentation) {
        out = *cursor->presentation;
        return;
    }
    if (cursor) {
        if (!cursor->visible)
            return;
    } else if (term->modes.isCursorVisible == 0) {
        return;
    }
    const Ubiquitty::PaletteRGB color = term->palette.cursor;
    out.row = term->screens.active->cursorY;
    out.column = term->screens.active->cursorX;
    if (out.row >= 0 && out.row < term->rows) {
        out.lineAttribute = Ubiquitty::Screen::rowLineAttribute(term, Ubiquitty::Screen::scrollbackCount(term) + out.row);
    }
    // The configuration's, not constants: the glyph under the block inverts
    // as `[cursor] invert_text` says, and the cursor's colour carries
    // `[cursor] alpha`, which the palette's three channels cannot.
    const Rendering::RenderConfiguration& configuration = m_state->windowRenderSettings.configuration;
    out.shouldInvertText = configuration.shouldCursorInvertText;
    Rendering::setCursorTextColor(out, Rendering::cursorTextColor(*term));
    out.rgb = { Ubiquitty::channel16To8(color.red) / 255.0f, Ubiquitty::channel16To8(color.green) / 255.0f, Ubiquitty::channel16To8(color.blue) / 255.0f,
        static_cast<float>(configuration.cursorAlpha) };
    if (cursor) {
        out.shape = cursor->shape;
        out.focused = cursor->focused;
        // mixA cross-fades the focused block's tier; for the bar/underline/
        // hollow overlay it is the quad's blink alpha. Core's resolve already
        // freezes an unfocused cursor solid, so the weight is taken as given.
        out.mixA = cursor->blinkAlpha;
    } else {
        // No overlay: the shape still comes from the same Core policy the live
        // path reads, because DECSCUSR is the program's request and a caller
        // with no frame clock has no reason to overrule it. Hard coding a block
        // here renders a bar-requesting program as a block in every headless
        // dump, with nothing in the image to say the request was dropped.
        // Tick 0 is a static cursor: the blink phase is what this caller lacks,
        // not the shape.
        out.shape = Ubiquitty::Cursor::resolve(term, 0).shape;
        out.focused = true;
        out.mixA = 1.0f; // static (non-blinking) and focused
    }
}

bool RasterContext::rasterizeTerm(Ubiquitty::Terminal* term, std::vector<uint8_t>& out, int& widthOut, int& heightOut, int viewOffset, Ubiquitty::Selection::Session* selection, const CursorOverlay* cursor, uint32_t blinkTicks, const PagePadding* page)
{
    auto& softwareRenderer = m_state->softwareRenderer;
    auto* injectedRasterizer = m_state->injectedRasterizer;
    const auto& windowRenderSettings = m_state->windowRenderSettings;
    if (!term)
        return false;
    const int columns = term->columns;
    const int rows = term->rows;
    if (columns <= 0 || rows <= 0)
        return false;

    std::vector<Cell> grid;
    snapshotVisibleGrid(term, viewOffset, grid);

    std::vector<Rendering::SelectionRowSpan> selectionSpans;
    selectionRowSpans(term, viewOffset, selection, selectionSpans);
    std::vector<Rendering::SelectionRowSpan> searchMatchSpans;
    Rendering::collectSearchMatchRowSpans(*term, viewOffset, searchMatchSpans);
    std::vector<Rendering::SelectionRowSpan> otherSearchMatchSpans;
    Rendering::collectOtherSearchMatchRowSpans(*term, viewOffset, otherSearchMatchSpans);
    std::vector<Rendering::SelectionRowSpan> triggerHighlightSpans;
    Rendering::collectTriggerHighlightRowSpans(*term, viewOffset, triggerHighlightSpans);
    std::vector<Rendering::SelectionRowSpan> hiliteSpans;
    Rendering::collectHiliteRegionRowSpans(*term, viewOffset, hiliteSpans);

    // Row-scoped facts the builder reads per row rather than per cell. The grid
    // snapshot above carries the IME pre-edit composited into it, which is why
    // this fills a FrameSource by hand instead of calling the Terminal overload
    // of capture(): that one reads the rows straight from the model and would
    // draw a pre-edit that is not in it.
    std::vector<std::uint8_t> lineAttributes(static_cast<std::size_t>(rows), Ubiquitty::lineAttributeNormal);
    std::vector<std::uint8_t> rowMarks(static_cast<std::size_t>(rows), 0u);
    const int history = Ubiquitty::Screen::scrollbackCount(term);
    const int firstAbsoluteRow = history - std::clamp(viewOffset, 0, history);
    for (int row = 0; row < rows; ++row) {
        lineAttributes[static_cast<std::size_t>(row)] = Ubiquitty::Screen::rowLineAttribute(term, firstAbsoluteRow + row);
        rowMarks[static_cast<std::size_t>(row)] = Ubiquitty::Screen::rowMark(term, firstAbsoluteRow + row);
    }

    Rendering::FrameSource source;
    source.cells = grid.data();
    source.lineAttributes = lineAttributes.data();
    // Marks live on the primary, so the alternate screen has none to pass.
    source.rowMarks = term->screens.isUsingAlternateScreen ? nullptr : rowMarks.data();
    source.rows = rows;
    source.columns = columns;
    source.scrollbackCount = history;
    source.palette = &term->palette;
    source.paletteGeneration = term->paletteEpoch;
    source.hasPaletteGeneration = true;
    source.textSizeTable = &term->textSizeTable;
    source.ambiguousWidth = term->ambiguousWidth;
    source.cursorColor = term->palette.cursor;
    source.hasSelectionBackground = term->selectionBackgroundSet;
    source.selectionBackgroundRed = term->selectionBackgroundRed;
    source.selectionBackgroundGreen = term->selectionBackgroundGreen;
    source.selectionBackgroundBlue = term->selectionBackgroundBlue;
    source.hasCursorTextColor = term->hasCursorTextColor;
    source.cursorTextColor = { term->cursorTextRed, term->cursorTextGreen, term->cursorTextBlue };
    source.isScreenReverse = Ubiquitty::isReverseVideo(term);
    source.isColumns132 = term->modes.columns132;
    // The edge-to-edge letterbox, as Core's own capture reads it: the mode and
    // the colour letterbox together, and the fill the OSC named. Left out, a
    // frame under DECSET 7402 draws the grid this arm was told to occlude.
    source.isEdgeToEdge = term->modes.fullscreenContent
        && term->fullscreenContentDisplay.letterbox == Ubiquitty::FullscreenContentLetterbox::Color;
    source.letterboxColor = term->fullscreenContentDisplay.letterboxColor;
    source.isCursorVisible = term->modes.isCursorVisible != 0;
    // Paired with the options.shouldDrawPasswordLock set below: the option is this
    // frontend saying it has no view layer to stand a badge in, and this is the
    // terminal saying there is a password prompt to stand one for. A
    // caller-built FrameSource carries whatever this function sets and zero for
    // everything else, so a field left out here reads as "no prompt" and the
    // badge silently never draws.
    source.isPasswordPromptActive = Ubiquitty::passwordPromptActive(term);
    source.activeMatchEpoch = Screen::ScrollSearch::activeMatchEpoch(*term);
    source.cursorRow = term->screens.active != nullptr ? term->screens.active->cursorY : 0;
    source.cursorColumn = term->screens.active != nullptr ? term->screens.active->cursorX : 0;
    source.cursorShape = Ubiquitty::Cursor::resolveAppearance(term, 0).shape;
    const bool hasStoredImages = std::ranges::any_of(term->images.stored, [](const Image::TerminalImage& image) {
        return image.used;
    });
    source.images = hasStoredImages ? term->images.stored.data() : nullptr;
    source.placements = term->images.livePlacementCount != 0 ? term->images.placements.data() : nullptr;
    // The resolver's context is the terminal the cells came from, so a cell's
    // cluster is read back from the same model that holds its base code point.
    source.clusterResolverContext = term;
    source.clusterResolver = [](const Cell* cell, std::span<std::uint32_t> codePoints, void* terminal) -> int {
        const auto* owner = static_cast<const Ubiquitty::Terminal*>(terminal);
        return Ubiquitty::cellClusterCodePoints(owner, cell, codePoints.data(), static_cast<int>(codePoints.size()));
    };
    source.softFont = Ubiquitty::softFontOrNull(*term);

    Rendering::TerminalSnapshotOptions options;
    options.viewOffset = viewOffset;
    // No view layer here: the badge that says the terminal is taking a
    // password has to be part of the frame or it does not exist.
    options.shouldDrawPasswordLock = true;
    options.selectionSpans = selectionSpans.data();
    options.selectionSpanCount = static_cast<int>(selectionSpans.size());
    options.searchMatchSpans = searchMatchSpans.data();
    options.searchMatchSpanCount = static_cast<int>(searchMatchSpans.size());
    options.searchMatchHighlight = focusedSearchMatchHighlightColor();
    options.otherSearchMatchSpans = otherSearchMatchSpans.data();
    options.otherSearchMatchSpanCount = static_cast<int>(otherSearchMatchSpans.size());
    options.triggerHighlightSpans = triggerHighlightSpans.data();
    options.triggerHighlightSpanCount = static_cast<int>(triggerHighlightSpans.size());
    options.hiliteRegionSpans = hiliteSpans.data();
    options.hiliteRegionSpanCount = static_cast<int>(hiliteSpans.size());
    const Rendering::RenderConfiguration& configuration = windowRenderSettings.configuration;
    options.style.backgroundOpacity = backgroundOpacity();
    options.style.shouldEnhanceTextContrast = configuration.shouldEnhanceTextContrast;
    options.style.unifontScale = windowRenderSettings.embeddedBitmapScale;
    Preferences::Effective::applyRuleSettings(options.style, configuration, windowRenderSettings.deviceScale);
    Preferences::Effective::applyCursorSettings(options, configuration);
    options.toolkitCaret = toolkitCaret();
    Preferences::Effective::applyTekSettings(options, configuration);
    options.tekDeviceScale = static_cast<float>(windowRenderSettings.deviceScale);
    options.backgroundImage = backgroundImageLayer();
    Rendering::applyPointSpace(options, static_cast<float>(cellHeight()), windowRenderSettings.deviceScale,
        configuration.lineSpacingPoints);
    // SGR 5/6 text blink: the shared cell builder fades blink-attributed cells
    // through the common Core curve (Cursor::Blink, honoring [appearance]
    // blink_animation). Gated on hasBlinkHint so a screen with no blink cells is
    // unaffected; blinkTicks==0 holds them fully opaque (the oracle / dump path).
    options.shouldResolveBlink = term->grid != nullptr && term->grid->hasBlinkHint();
    options.blinkTicks = blinkTicks;
    // OSC 8 link styling is Core's fold: whether links underline, which rule,
    // and the per-kind lookup against the ring the terminal owns. The link
    // colour is left to the capture, which takes the palette's own.
    Preferences::Effective::applyLinkSettings(options, configuration, term);
    // The DECSSDT status row. It is not part of the grid the snapshot above
    // read — it is a one-row buffer beside it — so this arm has to ask for it
    // by hand. Core's whole-terminal entry derives the row itself; the
    // FrameSource path cannot, because a FrameSource carries cells and no
    // terminal to fill them from. Left out, the last row draws whatever the
    // grid holds there, which downstream is indistinguishable from a terminal
    // with no status line configured. The scratch outlives the capture below,
    // which only borrows it.
    Rendering::StatusRowStorage statusRowScratch;
    if (Rendering::fillStatusRow(term, rows, columns, viewOffset,
            Rendering::StatusRowCells { statusRowScratch.cells.data(), statusRowScratch.cells.size() })) {
        options.statusRowCells = statusRowScratch.cells.data();
        options.statusRowColumns = columns;
    }

    Rendering::TerminalFrameInputs frame;
    // The same rasterizer the atlas below is built from, so the capture's metrics
    // and the glyphs it addresses come from one face.
    const Rendering::CellMetrics metrics = injectedRasterizer != nullptr
        ? injectedRasterizer->cellMetrics()
        : Rendering::CellMetrics { .cellWidth = static_cast<float>(fallbackCellWidth), .cellHeight = static_cast<float>(fallbackCellHeight) };
    // Built before the capture and handed to it. Writing these onto the
    // BuildInputs afterwards reaches four of the eleven fields the geometry
    // carries, and the seven a hand-written subset leaves at zero are what keeps
    // a wide glyph off the wide pass on this arm.
    //
    // Zero overhang (Unifont, or no real face) yields zero margins and leaves the
    // cell-baked path, which is what the injected-rasterizer test relies on.
    Rendering::GlyphSlotGeometry slot {};
    if (injectedRasterizer) {
        const Rendering::GlyphOverhangInputs overhang = injectedRasterizer->glyphOverhang();
        const Rendering::GlyphSlot glyphSlot = Rendering::computeGlyphSlot(overhang);
        // The slot is cut to the face's own advance rather than to the cell
        // pitch, because it holds INK: character spacing moves the column and
        // leaves the glyph the size the face drew it. A slot sized from the
        // pitch would stretch a glyph under positive tracking and clip one
        // under negative. Zero overhang (Unifont, or no real face) reports no
        // advance, and the pitch is then the only measurement there is.
        const float inkAdvance = overhang.advanceWidth > 0.0 ? static_cast<float>(overhang.advanceWidth)
                                                             : injectedRasterizer->cellMetrics().cellWidth;
        slot.glyphMarginInPixels = glyphSlot.marginInPixels;
        slot.slotWidthInPixels = Rendering::cellDimension(inkAdvance) + 2 * glyphSlot.marginInPixels.width;
        slot.slotHeightInPixels = Rendering::cellDimension(injectedRasterizer->cellMetrics().cellHeight) + 2 * glyphSlot.marginInPixels.height;
        slot.glyphWidthInPixels = Rendering::cellDimension(inkAdvance);
        // The face's own box strokes, so procedural geometry — diagonals,
        // arcs, the thin separators — carries the weight the face draws its
        // rules at. Left unmeasured, every one of them falls back to the
        // em-derived rule and draws heavier than the lines beside it.
        slot.boxStrokeProfile = Rendering::BoxDrawing::measureBoxStrokeProfile(*injectedRasterizer,
            Rendering::cellDimension(injectedRasterizer->cellMetrics().cellWidth),
            Rendering::cellDimension(injectedRasterizer->cellMetrics().cellHeight));
    }
    // The atlas persists across frames (cross-frame glyph LRU) on the single
    // GTK thread that calls this. Built lazily so an injected rasterizer set
    // before the first call is wired in; otherwise it uses its own Unifont.
    ensureSoftwareRenderer();
    // A page draws its margin inside the frame: the viewport is the grid plus
    // the margin and the grid sits at the margin's corner, which is what lets
    // the overlay pass reach into the margin the renderer paints.
    if (page) {
        const int left = std::max(static_cast<int>(std::lround(page->insetsInPixels.left)), 0);
        const int right = std::max(static_cast<int>(std::lround(page->insetsInPixels.right)), 0);
        const int top = std::max(static_cast<int>(std::lround(page->insetsInPixels.top)), 0);
        const int bottom = std::max(static_cast<int>(std::lround(page->insetsInPixels.bottom)), 0);
        options.viewportSizeInPixels = { static_cast<float>(columns * softwareRenderer->cellWidth() + left + right),
            static_cast<float>(rows * softwareRenderer->cellHeight() + top + bottom) };
        options.originInPixels = { static_cast<float>(left), static_cast<float>(top) };
    }
    if (!frame.capture(source, options, metrics, slot))
        return false;
    Rendering::BuildInputs in = frame.inputs();
    m_state->lastFocusedMatchAgeSeconds = in.focusedMatchAgeSeconds;

    fillCursorState(term, viewOffset, cursor, in.cursor);

    // Inline images (kitty / sixel / iTerm): hand the renderer the Terminal's
    // image + placement tables to composite over the grid, resolved via the shared
    // resolveImagePlacements and scrolled with viewOffset.
    in.images = term->images.stored.data();
    in.imageCount = Image::maxTerminalImageCount;
    in.placements = term->images.placements.data();
    in.placementCount = Image::maxTerminalImagePlacementCount;
    in.viewOffset = viewOffset;

    if (!softwareRenderer->render(in, out, widthOut, heightOut, page ? page->color : std::array<uint8_t, 4> {}))
        return false;
    // A Tektronix frame is the tube, drawn over the whole surface by Core's
    // own beam raster — the pass the portable reference runs — rather than the
    // grid the terminal left behind when it entered Tek mode.
    Rendering::compositeTektronixFrame(*term, options, out, widthOut, heightOut);
    return true;
}

} // namespace Ubiquitty::Linux
