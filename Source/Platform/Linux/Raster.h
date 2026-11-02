// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// CPU rasterizer for the Linux frontend: renders a passive Terminal's visible
// screen to tightly-packed RGBA8, handed to GTK as a GdkMemoryTexture. The GPU
// grid path replaces this with a glyph atlas. The CPU SoftwareRenderer and GPU
// VulkanRenderer funnel through the same snapshot/build seams here so both
// backends stay byte-identical (the CPU<->GPU oracle).

#include "Core/CellGrid.h"
#include "Core/Rendering/BackgroundImage.h"
#include "Core/Rendering/CellInstanceBuilder.h"
#include "Core/Rendering/PaddingGeometry.h"
#include "Core/Rendering/RenderConfiguration.h"

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace Ubiquitty {
struct Terminal;
} // Ubiquitty::Terminal, the global cell-model POD
namespace Ubiquitty {
struct Cell;
} // Ubiquitty::Cell, one grid cell (Core/Cell.h)
namespace Ubiquitty::Selection {
struct Session;
} // Selection/TerminalSelection.h — one view's selection over one terminal

namespace Ubiquitty {
namespace Rendering {
struct GlyphRasterizer; // Rendering/GlyphRasterizer.h — the raster seam
struct BeamGeometry; // Rendering/BeamLayout.h — the palette's drawn picture
struct HintToastGeometry; // Rendering/HintToastLayout.h — a reserved gesture's hint
}

namespace Linux {

// Frontend-resolved cursor look for a frame. The frontend resolves shape, blink,
// and focus once per tick (Cursor::resolve) and hands it to both render
// paths. A focused block is the cursor tier over its cell (blinkAlpha drives
// the cross-fade); every other case is an overlay quad. nullptr ⇒ a static
// focused block at the live cursor (dump-png / smoke).
struct CursorOverlay {
    bool visible = false; // bool-ok: a cursor-state field, named for the state it holds
                          // DECTCEM on and (live, not scrolled-back)
    Ubiquitty::Cursor::Shape shape = Ubiquitty::Cursor::Shape::Block;
    float blinkAlpha = 1.0f; // 0..1; the focused block's cross-fade
    bool focused = true; // window has key focus (unfocused block → hollow)
    /// A per-pane Core presentation result, shared unchanged by both backends.
    std::optional<Rendering::CursorRenderState> presentation;
};

// The Unifont fallback cell — used when no real-font rasterizer is injected. The
// runtime cell is font-derived once one is; query cellWidth()/cellHeight().
constexpr int fallbackCellWidth = 8; // Attribute::Wide cells span two
constexpr int fallbackCellHeight = 16;

struct PagePadding;

/// Owns one window's CPU cache and the capture settings shared with its GPU.
///
/// Called only on its presentation thread. Every selected face outlives the
/// CPU and Vulkan caches that borrow it; both are reset before a face moves.
/// No context consults another window's scale, configuration or IME state.
class RasterContext {
public:
    /// Creates independent default capture settings without opening a display.
    RasterContext();
    /// Releases the CPU cache before its borrowed face is destroyed.
    ~RasterContext();
    RasterContext(const RasterContext&) = delete;
    RasterContext& operator=(const RasterContext&) = delete;
    RasterContext(RasterContext&&) = delete;
    RasterContext& operator=(RasterContext&&) = delete;

    /// Selects the glyph rasterizer the CPU SoftwareRenderer faults through.
    ///
    /// Set it
    /// before the first rasterizeTerm; the caller owns the face and keeps it
    /// alive while it is selected or cached. Without it the renderer uses its own UnifontRasterizer. The Vulkan
    /// path is injected separately with the same instance. Cell geometry is DERIVED
    /// from the rasterizer's cellMetrics(). To swap at runtime, re-inject then call
    /// resetSoftwareRenderer().
    ///
    /// - Parameter rasterizer: The borrowed face, alive until every cache is released.
    void setGlyphRasterizer(Rendering::GlyphRasterizer& rasterizer);

    /// Drop the lazily-built CPU renderer so the next rasterizeTerm rebuilds it
    /// against the currently-injected rasterizer + re-derived cell geometry. Call
    /// after re-injecting a different rasterizer.
    void resetSoftwareRenderer();

    /// The runtime cell dims the grid is sized at: the rasterizer's font-derived cell,
    /// or the Unifont fallback (8×16). The window-size + resize math reads these.
    ///
    /// - Returns: The selected face's cell width, or the fallback width.
    int cellWidth() const;
    /// Returns the selected face's cell height, or the fallback height.
    ///
    /// - Returns: The cell height in device pixels.
    int cellHeight() const;

    /// The column under a pixel along a row of the last CPU frame: the letter
    /// there where the primary face laid the row out as proportional runs
    /// (LetterLayout.h), else the column at the pitch.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - xInPixels: The pixel, from the grid's left edge.
    /// - Returns: The column, clamped to the frame.
    [[nodiscard]] int columnAt(int row, double xInPixels) const;

    /// Where a pixel is along such a row, in cells, for ``PointerFact::xInCells``.
    ///
    /// - Parameters:
    ///   - row: The visible row.
    ///   - xInPixels: The pixel, from the grid's left edge.
    /// - Returns: The position, 0 through the column count.
    [[nodiscard]] double xInCellsAt(int row, double xInPixels) const;

    /// Snapshot term's visible grid (at viewOffset) into a row-major flat array of
    /// Cell, sized rows*columns — the single Terminal→grid snapshot used by both
    /// render paths (the oracle). Blank cells default to the terminal default colors,
    /// not ANSI index 0. The selection is not baked in — see selectionRowSpans.
    ///
    /// - Parameters:
    ///   - term: The model to read; null leaves the destination unchanged.
    ///   - viewOffset: Rows above the live tail; nonzero hides the pre-edit.
    ///   - outGrid: Receives rows × columns cells in row-major order.
    void snapshotVisibleGrid(Ubiquitty::Terminal* term, int viewOffset, std::vector<Cell>& outGrid) const;

    /// Set the active input-method pre-edit, shown underlined at the cursor by
    /// snapshotVisibleGrid until cleared (count <= 0). Written into the snapshot COPY
    /// only — never the Terminal. One codepoint per cell.
    ///
    /// - Parameters:
    ///   - codePoints: Text to copy; null clears it.
    ///   - count: Code points to copy; zero or less clears it.
    void setPreedit(const std::uint32_t* codePoints, int count);

    /// Whether snapshotVisibleGrid would composite an overlay over the grid's
    /// cells.
    ///
    /// A retained snapshot must know: the IME pre-edit and the open Beam palette
    /// are composited into the copy and change without touching the grid's damage
    /// stream, so a frame holding either is captured fresh rather than refreshed
    /// in place.
    [[nodiscard]] bool snapshotCompositesOverlay() const;

    /// Returns native palette, hint, and IME rectangles in device pixels.
    ///
    /// A retained rich layer leaves these pixels to the grid's chrome.
    [[nodiscard]] std::vector<IntRect> snapshotOverlayRegions(const Terminal&, int viewOffset) const;

    /// Set the Beam palette's drawn picture for the frames that follow, or clear it
    /// with nullptr. Composited by snapshotVisibleGrid over everything else, so both
    /// render paths draw the palette from the same cells and the CPU<->GPU oracle
    /// covers it. Written into the snapshot COPY only — never the Terminal. Copies:
    /// the caller's geometry is rebuilt every frame and need not outlive the call.
    ///
    /// - Parameter chrome: The palette to copy, or null to clear it.
    void setBeamChrome(const Rendering::BeamGeometry* chrome);

    /// Sets the reserved-gesture hint drawn over the grid, or clears it with null.
    ///
    /// This arm has no window chrome to hang a hint from, so it draws one into
    /// cells. Composited by ``snapshotVisibleGrid`` like the palette, so the CPU
    /// and GPU paths draw it from the same cells and cannot disagree.
    ///
    /// - Parameter chrome: The drawn hint, or null to clear.
    void setHintChrome(const Rendering::HintToastGeometry* chrome);

    /// Sets the configuration both render paths style a frame from.
    ///
    /// Window-owned: both paths read one value, so the CPU and GPU arms see one
    /// configuration and the byte-identical oracle holds, and a per-pane copy would
    /// let two panes of one window disagree about a setting the reader set once.
    ///
    /// - Parameter configuration: Core's fold of the live document.
    void setRenderConfiguration(const Rendering::RenderConfiguration& configuration);

    /// The configuration both render paths style a frame from.
    ///
    /// - Returns: What ``setRenderConfiguration`` last set; the default table's
    ///   fold before any set.
    [[nodiscard]] const Rendering::RenderConfiguration& renderConfiguration() const;

    /// Sets the window's background image, decoded from the configured file.
    ///
    /// Window-owned like the configuration, so both render paths draw the one
    /// image. The mode and opacity are the configuration's.
    ///
    /// - Parameter pixels: The decode; empty clears the image.
    void setBackgroundImage(Rendering::BackgroundImagePixels pixels);

    /// The background image both render paths composite beneath the frame.
    ///
    /// - Returns: The image under the configuration's mode and opacity; not
    ///   visible when no image is set or the configuration names none.
    [[nodiscard]] Rendering::BackgroundImageLayer backgroundImageLayer() const;

    /// How many times ``setBackgroundImage`` has been called.
    ///
    /// - Returns: A count the GPU path compares to know when to re-upload.
    [[nodiscard]] std::uint64_t backgroundImageGeneration() const;

    /// Sets the display scale the glyphs are rasterized at.
    ///
    /// The rule offsets a configuration names are in the same units as the font
    /// size, which the frontend multiplies by this before rasterizing. Left at 1 on
    /// a HiDPI display, a configured offset stays where it was while the type
    /// around it doubles.
    ///
    /// - Parameter scale: Device pixels per logical pixel; zero or less means 1.
    void setDeviceScale(int scale);

    /// Records the GTK caret settings a bar cursor draws as.
    ///
    /// The stem's aspect ratio is a desktop setting (`gtk-cursor-aspect-ratio`)
    /// rather than a configuration key, so the frontend reads it from
    /// GtkSettings and hands it here; both render paths and the rich-text
    /// composite take the caret from ``toolkitCaret()``.
    ///
    /// - Parameter aspectRatio: The stem width per logical pixel of line height.
    void setToolkitCaretAspectRatio(double aspectRatio);

    /// The toolkit caret a bar cursor draws as: the recorded aspect ratio at
    /// the display scale.
    [[nodiscard]] Rendering::ToolkitCaret toolkitCaret() const;

    /// Records the upscale the embedded bitmap face draws at.
    ///
    /// The scale is what tells the frame it is the bitmap tier, the tier whose
    /// partial coverage is held to the levels every arm mixes at; a frame left at
    /// zero on this arm draws the full ramp against a reference that does not.
    ///
    /// - Parameter scale: The face's integer upscale, or zero when the native
    ///   face is the one selected.
    void setEmbeddedBitmapScale(int scale);

    /// Whether the focused search match's pill was mid-bounce on the CPU raster's
    /// last frame, so the window keeps painting until the curve rests.
    [[nodiscard]] bool isFocusedMatchBouncing() const;
    /// The scale set above, or zero when the face is not Core's bitmap: the one
    /// reading the CPU raster and the Vulkan path both take their bitmap-tier
    /// flag from, so the two cannot quantise on different faces.
    [[nodiscard]] int embeddedBitmapScale() const;

    /// The window's background opacity, 0..1, from the configuration.
    ///
    /// - Returns: The configured opacity, clamped.
    float backgroundOpacity() const;

    /// The display scale the glyphs are rasterized at.
    ///
    /// - Returns: Device pixels per logical pixel, never less than 1.
    int deviceScale() const;

    /// Reports whether the CPU renderer's glyph backend gives anything up.
    ///
    /// `Rendering::optionalDefaultsAreLossy` answers it; this exists so a caller
    /// can ask without owning the renderer, which is created lazily on the first
    /// frame. Builds the renderer if it does not exist yet, since the answer is a
    /// property of the configuration rather than of any frame.
    ///
    /// - Returns: Whether a null entry in the backend drops information a cell
    ///   carried — a colour glyph rendered monochrome, or a cluster dropped.
    [[nodiscard]] bool softwareBackendIsLossy();

    /// Fill the builder's Rendering::CursorRenderState from the Terminal + viewOffset (+ optional
    /// CursorOverlay). Shared by both render paths. A scrolled-back view (viewOffset>0)
    /// or hidden cursor returns a row<0 state (no cursor). With a CursorOverlay it
    /// carries the resolved shape/blink/focus; without one, a static focused block.
    ///
    /// - Parameters:
    ///   - term: The model; null suppresses the cursor.
    ///   - viewOffset: Rows above the live tail; nonzero suppresses the cursor.
    ///   - cursor: The resolved frontend look, or null for a static cursor.
    ///   - out: Receives the state shared by both render backends.
    void fillCursorState(const Ubiquitty::Terminal* term, int viewOffset, const CursorOverlay* cursor, Rendering::CursorRenderState& out) const;

    /// CPU-rasterizes a terminal's visible grid to tightly-packed RGBA8.
    ///
    /// - Parameters:
    ///   - term: The terminal to draw; null fails.
    ///   - out: Receives the pixels, widthOut × heightOut × 4 bytes.
    ///   - widthOut: Set to columns × cellWidth(), plus the page margin.
    ///   - heightOut: Set to rows × cellHeight(), plus the page margin.
    ///   - viewOffset: The scrollback window (0 = live tail); when > 0 the
    ///     cursor is suppressed.
    ///   - selection: The pane's selection session driving the overlay; nullable.
    ///   - cursor: The resolved cursor look; null draws a static focused block.
    ///   - blinkTicks: The monotonic SGR 5/6 blink tick, resolved once per frame
    ///     and passed to both paths; 0 holds blink-attributed text fully opaque.
    ///   - page: The margin to draw around the grid; null draws the grid alone.
    /// - Returns: Whether a frame was produced; false on a degenerate size.
    bool rasterizeTerm(Ubiquitty::Terminal* term, std::vector<uint8_t>& out, int& widthOut, int& heightOut, int viewOffset = 0, Ubiquitty::Selection::Session* selection = nullptr, const CursorOverlay* cursor = nullptr, uint32_t blinkTicks = 0, const PagePadding* page = nullptr);

private:
    /// Keeps the mutable resources behind the immovable owner.
    struct State;
    /// Builds this context's CPU cache against its selected face.
    void ensureSoftwareRenderer();
    std::unique_ptr<State> m_state;
};

// Route diagnostics for the CPU path, using the same font-route policy as the
// Vulkan path so route parity is testable without rendering.
std::string diagnoseCPUFontRoutes(std::string_view utf8Text);

/// The active selection's per-row spans in VISIBLE-grid coords, answered by
/// Core's facade (Selection::viewportSpans). Each surviving span becomes one
/// translucent overlay quad, so the highlight is an OVERLAY (glyph reads
/// through), not a cell inversion. Shared by both render paths.
///
/// - Parameters:
///   - term: The terminal the view shows.
///   - viewOffset: Rows the viewport is scrolled back.
///   - selection: The pane's selection session; null leaves the spans empty.
///   - outSpans: Receives at most one span per visible row.
void selectionRowSpans(Ubiquitty::Terminal* term, int viewOffset, Ubiquitty::Selection::Session* selection, std::vector<Rendering::SelectionRowSpan>& outSpans);

// The fixed translucent selection-highlight color (RGBA 0..1) both render paths
// pass as BuildInputs::selectionColor. A ~40%-alpha tint that keeps text readable.
Rendering::Vec4 selectionHighlightColor();

/// The focused search match's baked background colour, RGBA 0..1.
///
/// Read from the one Core constant every frontend passes as
/// `BuildInputs::searchMatchHighlight`, so the colour cannot drift per frontend.
///
/// - Returns: The highlight colour the builder bakes into the match's cells.
Rendering::Vec4 focusedSearchMatchHighlightColor();

// Rasterize term's visible grid into out (RGBA8, row stride width*4), setting
/// Describes the margin a headless page draws around the grid.
///
/// The margin is part of the frame rather than pasted around it afterwards, so
/// an overlay that reaches past the grid, such as a search pill on the first
/// column, is drawn into it while the grid's own layers stay clipped to the
/// grid box.
struct PagePadding {
    /// The margin's edges in device pixels, each rounded to a whole pixel.
    Rendering::EdgeInsets insetsInPixels;
    /// The margin's color as RGBA bytes.
    std::array<uint8_t, 4> color {};
};

} // namespace Linux
} // namespace Ubiquitty
