// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// COLRv1 paint-graph rasteriser for the Linux frontend.
//
// FreeType exposes a COLRv1 glyph as a directed acyclic graph of paint nodes
// (`FT_Get_Color_Glyph_Paint`) and draws none of it: `FT_Render_Glyph` on such
// a glyph yields an empty bitmap. This walks the graph and composites it into a
// caller-owned premultiplied BGRA canvas, source-over, honouring the face's
// first CPAL palette and the caller's foreground colour for palette index
// 0xFFFF.
//
// Drawn: `PaintColrLayers`, `PaintGlyph` (the child paint clipped to the glyph
// outline's coverage), `PaintSolid`, `PaintLinearGradient`,
// `PaintRadialGradient` (colour lines with pad / repeat / reflect extension),
// `PaintTransform`, `PaintTranslate`, `PaintScale`, `PaintColrGlyph`,
// `PaintComposite` in every mode the table names — the Porter-Duff operators,
// the separable blends and the HSL ones (a waving flag is a stripe glyph
// clipped into a wave with SRC_IN and shaded with SOFT_LIGHT). Any other node
// — sweep gradient, rotate, skew — fails the whole glyph with
// `UnsupportedPaint`, so the caller can hand the glyph to the monochrome path
// rather than draw part of it.
//
// Coordinates: the graph is walked in font units; the root transform FreeType
// supplies maps those to pixels at the face's active size, y up. The canvas is
// row-major with row 0 at the top; the placement origin is the glyph's baseline
// point measured from the canvas's bottom-left corner, y up, so a caller that
// centres a glyph reasons in one orientation.
//
// Lives under Platform/Linux because it includes FreeType — Rendering must stay
// portable (Scripts/check-boundaries.py).

#include <cstdint>
#include <expected>
#include <span>
#include <vector>

struct FT_FaceRec_;

namespace Ubiquitty::Linux {

/// Why a glyph could not be drawn, each a reason the caller acts on
/// differently: a glyph with no graph or an unsupported node goes to the mono
/// path, a malformed one is a font defect, a canvas mismatch is the caller's.
enum class ColorGlyphPaintError : std::uint8_t {
    /// The face has no COLRv1 paint graph for this glyph.
    NotAColorGlyph,
    /// A node this painter does not draw (sweep gradient, rotate, skew, or
    /// one FreeType does not know).
    UnsupportedPaint,
    /// Nesting past the bound, which a well-formed graph never reaches.
    GraphTooDeep,
    /// A colour line with no stops or too many, or a palette index the face's
    /// palette does not have.
    MalformedColorLine,
    /// A `PaintGlyph` whose outline could not be loaded or rasterised.
    OutlineUnavailable,
    /// The canvas span is not `width * height * 4` bytes.
    CanvasMismatch,
};

/// How a colour line continues past its first and last stop.
enum class ColorLineExtend : std::uint8_t {
    Pad,
    Repeat,
    Reflect,
};

/// Folds a colour-line parameter into the stop range `[first, last]`.
///
/// Pad clamps; repeat wraps with period `last - first`; reflect wraps with
/// twice that period and mirrors the second half. A range of zero width
/// answers `first` for every parameter. Public so the extension arithmetic can
/// be tested apart from a font.
///
/// - Parameters:
///   - parameter: The gradient's own parameter, unbounded.
///   - first: The first stop's offset.
///   - last: The last stop's offset, at or after `first`.
///   - extend: The colour line's extend mode.
/// - Returns: A parameter within `[first, last]`.
[[nodiscard]] double extendedColorLineParameter(double parameter, double first, double last, ColorLineExtend extend);

/// A straight (not premultiplied) colour with 8-bit channels.
struct ColorRGBA8 {
    std::uint8_t red = 0;
    std::uint8_t green = 0;
    std::uint8_t blue = 0;
    std::uint8_t alpha = 0;
};

/// The destination: premultiplied BGRA, row-major, row 0 at the top.
struct ColorGlyphCanvas {
    std::span<std::uint8_t> premultipliedBGRA;
    int widthInPixels = 0;
    int heightInPixels = 0;
};

/// Where the glyph lands on the canvas.
struct ColorGlyphPlacement {
    /// The baseline origin's x, in pixels from the canvas's left edge.
    double originX = 0.0;
    /// The baseline origin's y, in pixels *up* from the canvas's bottom edge.
    double originY = 0.0;
    /// Multiplies the face's active size; 1 draws at that size.
    double scale = 1.0;
};

/// Composites a COLRv1 paint graph into a premultiplied BGRA canvas.
///
/// One instance per rasterizer: it pools the coverage masks the graph's
/// `PaintGlyph` nesting needs, so the pool is sized by the deepest glyph seen
/// and every later glyph paints without allocating.
class ColorGlyphPainter {
public:
    ColorGlyphPainter() = default;

    ColorGlyphPainter(const ColorGlyphPainter&) = delete;
    ColorGlyphPainter& operator=(const ColorGlyphPainter&) = delete;

    /// Whether the face has a COLRv1 paint graph for the glyph.
    ///
    /// - Parameters:
    ///   - face: The face; null answers false.
    ///   - glyphIndex: The glyph.
    /// - Returns: True when `paint` can proceed past the graph lookup.
    [[nodiscard]] static bool hasPaintGraph(FT_FaceRec_* face, unsigned int glyphIndex);

    /// Composites the glyph's paint graph onto the canvas.
    ///
    /// The canvas is not cleared: a caller that wants the glyph alone clears
    /// first, and one layering several glyphs does not. The face's glyph slot
    /// is used for outlines and holds an arbitrary glyph on return. The
    /// face must be sized, because the root transform is derived from its
    /// active size.
    ///
    /// On an error nothing is guaranteed about the canvas: a graph can fail on
    /// its last node after its first drew, so a caller treats an error as
    /// "discard the canvas", never as "draw what landed".
    ///
    /// - Parameters:
    ///   - face: A sized face with a COLRv1 table.
    ///   - glyphIndex: The base glyph.
    ///   - foreground: The colour palette index 0xFFFF stands for.
    ///   - canvas: The destination.
    ///   - placement: Where the glyph's baseline origin lands, and its scale.
    /// - Returns: Nothing on success, else why the glyph could not be drawn.
    [[nodiscard]] std::expected<void, ColorGlyphPaintError> paint(FT_FaceRec_* face, unsigned int glyphIndex, ColorRGBA8 foreground, ColorGlyphCanvas canvas, ColorGlyphPlacement placement);

    /// A coverage mask the size of the canvas for one `PaintGlyph` nesting
    /// level, reused across glyphs so a paint allocates only when the graph
    /// nests deeper than any before it.
    ///
    /// - Parameters:
    ///   - depth: The nesting level, from zero.
    ///   - pixelCount: The canvas's pixel count.
    /// - Returns: A mask of at least `pixelCount` bytes, contents unspecified.
    [[nodiscard]] std::span<std::uint8_t> maskForDepth(std::size_t depth, std::size_t pixelCount);

private:
    std::vector<std::vector<std::uint8_t>> m_masks;
};

} // namespace Ubiquitty::Linux
