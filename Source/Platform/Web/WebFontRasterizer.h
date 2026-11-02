// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

//
// Source/Platform/Web/WebFontRasterizer.h — a real font behind the raster seam,
// drawn by the host's own text engine.
//
// The browser's third implementation of `GlyphRasterizer`, beside Core Text and
// FreeType. It rasterizes through a canvas the embedder owns, which makes the
// host's font stack — its hinting, its fallback chain, its subpixel positioning
// — the thing that produces coverage, exactly as the other two do for theirs.
//
// The seam is synchronous and so is the drawing: filling a glyph and reading the
// pixels back are both immediate on a 2D context, so no part of this needs the
// staging that the clipboard and the socket do.
//
// The browser is also this arm's shaper. A canvas names no glyph, so a run of
// grid text is shaped by drawing it: the face's substitutions are the cells
// whose ink differs between the run drawn whole and its characters drawn one
// at a time.
//

#include "Core/Rendering/Font/FontFallbackCache.h"
#include "Core/Rendering/Font/FontFallbackPolicy.h"
#include "Core/Rendering/FontFeatureSpecification.h"
#include "Core/Rendering/FontMetrics.h"
#include "Core/Rendering/FontVariationSpecification.h"
#include "Core/Rendering/GlyphRasterizer.h"
#include "Platform/Web/WebFontInventory.h"

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace Ubiquitty::Web {

/// Rasterizes glyphs through the embedder's text engine.
///
/// Falls back to the caller's supplied rasterizer for any code point the host
/// declines to draw, so a face with gaps still renders the box-drawing and
/// symbol coverage the terminal needs.
class WebFontRasterizer final : public Rendering::GlyphRasterizer {
public:
    /// Whether a run of grid text can draw differently from its characters.
    ///
    /// The face the page registers carries the resolved feature list as its
    /// descriptor and the browser applies it, as HarfBuzz and Core Text apply
    /// the same list on the other arms. One verdict about that list is known
    /// before anything is drawn: with every default ligature suppressed and
    /// nothing named back on, no run can fuse. Held here, it keeps such a
    /// configuration unfused even on a page drawing with a face registered
    /// without the descriptor, and it costs no canvas work to answer.
    enum class RunSubstitution : std::uint8_t {
        /// The face's default features apply, or the reader named one on.
        Possible,
        /// `font.ligatures` is off and `font.features` names nothing on.
        Suppressed,
    };

    /// Decides ``RunSubstitution`` from the two settings the descriptor is
    /// composed from.
    ///
    /// - Parameters:
    ///   - ligatures: `font.ligatures`.
    ///   - featureSpecification: `font.features`, in Core's grammar.
    /// - Returns: `Suppressed` when the resolved list turns no feature on.
    [[nodiscard]] static RunSubstitution runSubstitutionFor(Rendering::Ligatures ligatures, const std::string& featureSpecification);

    /// Set in ``ShapedGlyph::glyph`` on a cell whose ink the run's context
    /// changed.
    ///
    /// A canvas has no glyph indices, so a shaped glyph names its code point —
    /// the index space ``shapeProportionalRun`` already uses here — and this
    /// bit says the face drew another form of it. Above every Unicode scalar
    /// value, so the two never collide.
    static constexpr unsigned int contextualFormBit = 1u << 31;

    /// Creates a rasterizer over the font the embedder has installed.
    ///
    /// The metrics are measured once, here: a cell is as wide as the widest
    /// advance in the face's printable-ASCII range and as tall as its ascent
    /// plus descent plus the requested line spacing, so a proportional face —
    /// which a terminal cannot use — is detectable by the caller rather than
    /// silently laid out as if it were monospaced.
    ///
    /// - Parameters:
    ///   - fallback: Rasterizes the code points the host has no glyph for. The
    ///     caller owns it and it must outlive this.
    ///   - pixelSize: The em size to draw at, in device pixels.
    ///   - lineSpacingInPixels: Added to the face's own line height.
    ///   - trackingInPixels: `font.character_spacing` in device pixels, added
    ///     to the cell pitch and not to the glyph.
    ///   - preferences: The route preferences to hand `FontFallbackPolicy` on
    ///     every draw — a view; the caller owns the backing storage and it
    ///     must outlive this.
    ///   - deviceScale: The display scale `pixelSize` already carries. Needed
    ///     separately because the underline rule's constant term is in POINTS
    ///     and so scales with the display, while the size-relative term is
    ///     already in device pixels.
    ///   - fontVariations: The `font.variations` specification. Its `wght`, if it
    ///     names one, overrides the upright weight and sets the floor for an
    ///     unset bold weight through Core's shared fold. Every other tag is the
    ///     page's to bake into a registered face: a canvas font shorthand carries no
    ///     font-variation-settings, so this seam can express weight and slant
    ///     and nothing else.
    ///   - weights: `font.weight` and `font.bold_weight`, 0 for unset, which
    ///     Core's ``weightForFace`` turns into each cell's weight.
    ///   - runSubstitution: Whether the face's features leave a run of grid
    ///     text anything to substitute, from ``runSubstitutionFor``.
    WebFontRasterizer(GlyphRasterizer& fallback, int pixelSize, int lineSpacingInPixels, int trackingInPixels, const Rendering::Font::FontFallbackPreferences& preferences, int deviceScale = 1, std::string fontVariations = std::string(), Rendering::Font::WeightSettings weights = {}, RunSubstitution runSubstitution = RunSubstitution::Possible);

    /// Whether the embedder installed a usable monospaced face.
    ///
    /// False when no font was set, when the measured advance is zero, or when
    /// the sampled advances are too uneven for one cell to carry — a caller then
    /// uses the fallback alone rather than laying text out against a cell of no
    /// width, or against a grid its own glyphs do not fit.
    [[nodiscard]] bool isAvailable() const { return m_isAvailable; }

    /// Reports the validated primary family, or the embedded fallback in use.
    /// - Returns: The font family used for ordinary text.
    [[nodiscard]] std::string_view familyName() const { return m_isAvailable ? std::string_view(m_primaryFamily) : "Unifont"; }

    [[nodiscard]] Rendering::CellMetrics cellMetrics() const override { return m_metrics; }
    [[nodiscard]] Rendering::FontMetrics::FacePitch primaryFacePitch() const override { return m_facePitch; }
    [[nodiscard]] Rendering::FaceMetrics faceMetrics() const override { return m_face; }

    [[nodiscard]] Rendering::GlyphOverhangInputs glyphOverhang() const override { return m_overhang; }

    bool rasterizeGlyph(std::uint32_t codePoint, Rendering::FontFace, std::uint32_t weight, int slotWidth, int slotHeight, std::uint8_t* coverageOut) override;

    /// True whenever the host's text engine is usable.
    ///
    /// A browser's emoji face is the system's rather than the page's, so the
    /// question is whether there is a canvas to draw on and not whether the
    /// configured family carries emoji — a terminal font never does, and asking
    /// about it would answer no on every platform that renders them fine.
    ///
    /// - Returns: True when the embedder installed a usable face.
    [[nodiscard]] bool hasColorGlyphs() const override { return m_isAvailable; }

    /// Draws the cluster through the host's emoji face.
    ///
    /// Declines when the result came back monochrome, which is what a face with
    /// no colour for the cluster produces — that belongs on the mono path rather
    /// than taking a colour slot to draw the same grey glyph.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster to draw.
    ///   - count: How many code points; 1 is a lone one.
    ///   - slotInPixels: The square slot edge.
    ///   - pixelsOut: The RGBA8 destination.
    /// - Returns: True when the host drew the cluster in colour.
    bool rasterizeColorCluster(const std::uint32_t* codePoints, int count, int slotInPixels, std::uint8_t* pixelsOut) override;

    /// Re-rasterizes at the scaled point size rather than upscaling the 1x raster.
    ///
    /// A double-height row gains real resolution instead of doubled pixels,
    /// and an OSC 66 fraction is drawn at its own fractional pixel size. The
    /// base implementation's nearest-neighbour is right for a bitmap face and a
    /// waste of a vector one.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - weight: Variable-font weight, or zero for the face's own.
    ///   - master: The size and stretch Core selected.
    ///   - slotWidth: The slot's width, the cell slot's scaled.
    ///   - slotHeight: The slot's height, the cell slot's scaled.
    ///   - coverageOut: `slotWidth * slotHeight` coverage bytes.
    /// - Returns: False when nothing could draw the glyph.
    bool rasterizeSizedMaster(std::uint32_t codePoint, Rendering::FontFace, std::uint32_t weight, const Rendering::SizedMaster& master, int slotWidth, int slotHeight, std::uint8_t* coverageOut) override;

    /// True: this face is an outline one, so a scaled raster carries detail the
    /// 1x raster does not.
    [[nodiscard]] bool rasterisesScaledGlyphsSharply() const override { return true; }

    /// Whether the page's face is in use and its features leave a run of grid
    /// text something to substitute.
    ///
    /// - Returns: True when ``shapeTextRun`` can report a substitution.
    [[nodiscard]] bool hasLigatureShaping() const override { return m_isAvailable && m_runSubstitution == RunSubstitution::Possible; }

    /// Shapes a run of grid text in the primary family by having the browser
    /// draw it.
    ///
    /// The run is drawn as one string, which the browser shapes with the
    /// face's features, and its characters are drawn one at a time at the same
    /// pens, which is the per-cell mono path's picture. A cell whose ink
    /// differs between the two took a form its context gave it. The answer is
    /// one glyph per code point with clusters in order; each glyph names its
    /// code point, with ``contextualFormBit`` set on the cells that differ, so
    /// the sheet's comparison against the isolated mapping finds exactly the
    /// cells the face rewrote. A run of one code point is its own isolated
    /// mapping and is measured without being drawn.
    ///
    /// - Parameters:
    ///   - codePoints: The run in visual order, context included.
    ///   - weight: The SGR weight, which Core's rule turns into the CSS
    ///     weight the run is shaped and drawn at.
    ///   - glyphsOut: Caller-owned; a span shorter than the run is refused.
    /// - Returns: The run's length, or 0 when the run is refused.
    int shapeTextRun(std::span<const std::uint32_t> codePoints, std::uint32_t weight, std::span<ShapedGlyph> glyphsOut) override;

    /// Draws the run ``shapeTextRun`` last shaped into a coverage strip, each
    /// glyph at the pen the caller placed it on.
    ///
    /// The browser draws the whole run once per glyph, so the face sees the
    /// context it was shaped with every time, moved so that glyph lands on its
    /// pen and clipped to the span between its pen and the next one. A fused
    /// run then fills its cells on the grid's pitch rather than on the face's
    /// own advance, which differs from the cell by the rounding the cell took
    /// and would otherwise drift a long run off its cells.
    ///
    /// - Parameters:
    ///   - glyphs: The glyphs ``shapeTextRun`` answered, offsets carrying the
    ///     caller's pen.
    ///   - stripWidthInPixels: The strip's width.
    ///   - stripHeightInPixels: The strip's height, sharing the mono slot's
    ///     baseline.
    ///   - coverageOut: Exactly `stripWidth * stripHeight` bytes.
    /// - Returns: False for any run but the last one shaped, whose weight and
    ///   natural pens the draw uses, and for a strip `coverageOut` does not
    ///   match.
    bool rasteriseShapedRun(std::span<const ShapedGlyph> glyphs, int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut) override;

    /// Whether a proportional face stands beside the grid face.
    ///
    /// The CSS generic `sans-serif`, which every browser resolves and which is
    /// the same request the Linux arm makes of fontconfig — so the two arms ask
    /// their platforms the same question rather than each naming a family.
    ///
    /// - Returns: True when there is a canvas to measure and draw on.
    [[nodiscard]] bool hasProportionalFace() const override { return m_isAvailable; }

    /// Uses the configured proportional family and point size for OSC 66.
    /// - Parameters:
    ///   - family: CSS font cascade; empty selects sans-serif.
    ///   - pixelSize: Font size in device pixels.
    void setProportionalFont(std::string family, int pixelSize)
    {
        m_proportionalFamily = family.empty() ? "sans-serif" : std::move(family);
        m_proportionalPixelSize = pixelSize;
    }

    /// Measures a proportional run at the face's natural advances.
    ///
    /// Canvas exposes no shaping API, so this substitutes nothing and returns
    /// one entry per code point. ``Rendering::GlyphRasterizer::ShapedGlyph::glyph``
    /// carries the code point rather than a face-local index, which is what the
    /// seam's own wording licenses: an index is meaningless outside the face
    /// that shaped it, and for a canvas the face's index space is Unicode.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: Regular or bold; italic resolves to its upright.
    ///   - glyphsOut: Caller-owned destination; its size is the bound.
    /// - Returns: How many entries were written; 0 refuses.
    int shapeProportionalRun(std::span<const std::uint32_t> codePoints, Rendering::FontFace face, std::span<Ubiquitty::ProportionalShapedGlyph> glyphsOut) override;

    /// Shapes a run in the primary family at its natural advances, for a
    /// proportional primary face's rows (LetterLayout.h).
    ///
    /// A canvas has no shaping API, so each code point is measured on its
    /// own and the glyph stands in for the face's index; kerning pairs are
    /// what the page's engine cannot answer, and the run is laid out at the
    /// letters' own advances without them.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: Regular, bold, italic or both.
    ///   - weight: The variable weight the pen carries.
    ///   - glyphsOut: Caller-owned destination; its size is the bound.
    /// - Returns: How many entries were written; 0 refuses.
    int shapePrimaryRun(std::span<const std::uint32_t> codePoints, Rendering::FontFace face, std::uint32_t weight, std::span<Ubiquitty::ProportionalShapedGlyph> glyphsOut) override;

    /// Draws the glyphs ``shapeProportionalRun`` placed into a coverage strip.
    ///
    /// - Parameters:
    ///   - glyphs: Placed glyphs, offsets already carrying the caller's pen.
    ///   - face: The face the glyphs were shaped in.
    ///   - stripWidthInPixels: The destination's width.
    ///   - stripHeightInPixels: The destination's height.
    ///   - coverageOut: Caller-owned `stripWidth * stripHeight` bytes.
    /// - Returns: True when the strip was drawn.
    bool rasteriseProportionalRun(std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, Rendering::FontFace face, int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut) override;
    /// Draws placed glyphs at a sized master: the proportional face at the
    /// master's whole size and stretched across by the master's doubling, on
    /// the strip's baseline taken `scale` times. A fraction declines.
    ///
    /// - Parameters:
    ///   - glyphs: Placed glyphs, offsets in master pixels.
    ///   - face: The face the glyphs were shaped in.
    ///   - master: The scale and the doubling across.
    ///   - stripWidthInPixels: The destination's width.
    ///   - stripHeightInPixels: The destination's height, `scale` times the strip's.
    ///   - coverageOut: Caller-owned `stripWidth * stripHeight` bytes.
    /// - Returns: True when the master was drawn.
    bool rasteriseSizedProportionalRun(std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, Rendering::FontFace face, const Rendering::SizedMaster& master,
        int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut) override;

private:
    /// The seven caches `Rendering::Font::FontFallbackPolicy` binds to.
    struct RouteCaches {
        Rendering::Font::HanFallbackCache han { 64 };
        Rendering::Font::ScriptFallbackCache script { 64 };
        Rendering::Font::GenericFallbackCache generic { 16 };
        Rendering::Font::EmojiFallbackCache emoji { 64 };
        Rendering::Font::SymbolFallbackCache symbol { 64 };
        Rendering::Font::RangeMapCache rangeMap { 64 };
        Rendering::Font::NegativeRouteCache negative { 128 };
    };

    /// Asks Core which family should draw a cluster.
    ///
    /// The route is resolved here rather than at the seam because
    /// `GlyphRasterizer` passes a code point and no font — the same arrangement
    /// macOS uses, where its rasterise methods call `copyFontForCodePoint` and
    /// the handle never crosses a seam.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster; one code point for a lone glyph.
    ///   - count: How many code points.
    ///   - face: The style the pen asked for.
    ///   - weight: The variable weight the pen asked for.
    /// - Returns: A CSS font-family list to draw with, empty when the policy
    ///   found no family and the caller should take its fallback.
    std::string familyForCluster(const std::uint32_t* codePoints, int count, Rendering::FontFace face, std::uint32_t weight);

    /// Maps the seam's style to Core's.
    ///
    /// - Parameter face: The style the pen asked for.
    /// - Returns: The matching `Rendering::Font::FontStyle`.
    [[nodiscard]] static Rendering::Font::FontStyle styleForFace(Rendering::FontFace face);

    /// Places and joins an assembly piece using Core's shared tiling rules.
    /// - Parameters:
    ///   - codePoint: The requested assembly piece.
    ///   - face: The requested text style.
    ///   - weight: SGR weight selection.
    ///   - master: Cell and horizontal magnification.
    ///   - slotWidth: Atlas slot width in device pixels.
    ///   - slotHeight: Atlas slot height in device pixels.
    ///   - coverageOut: Caller-owned slot coverage.
    /// - Returns: True when the browser drew a usable assembly piece.
    bool rasterizeTilingGlyph(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight,
        const Rendering::SizedMaster& master, int slotWidth, int slotHeight, std::uint8_t* coverageOut);

    GlyphRasterizer& m_fallback;
    WebFontInventory m_inventory;
    RouteCaches m_caches;
    // A view over the constructor's `preferences` argument: the spans and
    // string_views it carries point into storage the caller owns, not into
    // anything this class holds.
    Rendering::Font::FontFallbackPreferences m_preferences;
    Rendering::CellMetrics m_metrics {};
    Rendering::FaceMetrics m_face {};
    Rendering::GlyphOverhangInputs m_overhang {};
    int m_pixelSize = 0;
    int m_deviceScale = 1;
    // The user's axes, parsed once. Only a `wght` among them reaches this seam;
    // the rest are baked into the face the page registers, because a canvas font
    // shorthand has no way to name an axis.
    Rendering::FontVariationSettings m_userAxes;
    // `font.weight` and `font.bold_weight`, which Core folds into the number
    // each cell is drawn at.
    Rendering::Font::WeightSettings m_weights;
    bool m_isAvailable = false;
    // The primary family and its pitch: a proportional one's rows are laid
    // out as proportional runs by the builder, through `shapePrimaryRun`.
    std::string m_primaryFamily;
    std::string m_proportionalFamily = "sans-serif";
    int m_proportionalPixelSize = 0;
    Rendering::FontMetrics::FacePitch m_facePitch = Rendering::FontMetrics::FacePitch::Fixed;
    // Scratch for the proportional seam, held rather than allocated per strip:
    // a run is shaped and rasterised on the frame path, once per candidate.
    std::vector<double> m_proportionalAdvances;
    std::vector<std::uint32_t> m_proportionalCodePoints;
    std::vector<double> m_proportionalOffsetsX;
    std::vector<double> m_proportionalOffsetsY;
    RunSubstitution m_runSubstitution = RunSubstitution::Possible;
    // The last run of more than one code point `shapeTextRun` answered, with
    // the weight and the natural advances it was measured at. A strip is drawn
    // from this and from nothing else: the seam's draw carries no weight, and
    // the sheet shapes a run's isolated characters between shaping it and
    // drawing it, so a single code point leaves this alone. Reused run to run,
    // so a steady frame allocates nothing here.
    std::vector<std::uint32_t> m_shapedRun;
    std::vector<double> m_shapedRunAdvances;
    std::vector<std::uint8_t> m_shapedRunContextualForms;
    int m_shapedRunCSSWeight = 0;
    // The draw's per-glyph pens, natural and placed, held for the same reason.
    std::vector<double> m_shapedRunNaturalPensX;
    std::vector<double> m_shapedRunPlacedPensX;
};

#if UBIQUITTY_ENABLE_TEST_HOOKS
/// Test seam over the browser text engine's entry points.
///
/// Natively those are stubs that answer "absent", so the available arm — the
/// metric mapping, the family routing, the draw-then-fallback ladder — never
/// runs where a test can hold it. A test installs a stand-in engine here; what
/// it exercises is this file's mapping of the engine's answers, which is the
/// half that belongs to this seam rather than to a browser.
namespace ForTest {
struct WebFontHost {
    int (*primaryFamily)(char* familyOut, int capacity) = nullptr;
    int (*measure)(int pixelSize, int firstCharacter, int characterCount, double* advances, int* ascent, int* descent, int* xHeight) = nullptr;
    int (*drawGlyph)(const char* family, int codePoint, double pixelSize, double horizontalScale, double verticalScale, int cssWeight, int isItalic, double penX, double baseline, int slotWidth, int slotHeight, std::uint8_t* coverageOut) = nullptr;
    int (*drawColorCluster)(const char* family, const std::uint32_t* codePoints, int count, int slotInPixels, std::uint8_t* pixelsOut) = nullptr;
    int (*measureProportional)(const char* family, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, double* advancesOut) = nullptr;
    int (*drawProportional)(const char* family, const std::uint32_t* codePoints, const double* offsetsX, const double* offsetsY, int count, int pixelSize, double horizontalScale, int cssWeight, int baseline, int stripWidth, int stripHeight, std::uint8_t* coverageOut) = nullptr;
    int (*shapeRun)(const char* family, const std::uint32_t* codePoints, int count, int pixelSize, int cssWeight, int bandHeight, int baseline, double* advancesOut, std::uint8_t* contextualFormsOut) = nullptr;
    int (*drawShapedRun)(const char* family, const std::uint32_t* codePoints, const double* naturalPensX, const double* placedPensX, int count, int pixelSize, int cssWeight, int baseline, int stripWidth, int stripHeight, std::uint8_t* coverageOut) = nullptr;
};
void installWebFontHost(const WebFontHost& host);
} // namespace ForTest
#endif

} // namespace Ubiquitty::Web
