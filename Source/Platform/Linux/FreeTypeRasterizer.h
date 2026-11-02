// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// Real-font glyph raster for the Linux frontend: a GlyphRasterizer backed by
// fontconfig (fc-match) + FreeType (8-bit AA coverage). Coverage is byte-
// identical across the CPU SoftwareRenderer and GPU VulkanGlyphAtlas (both fault
// through the same rasterizer instance).
//
// SINGLE-CODEPOINT only (no shaping yet): one code point → one glyph, positioned
// by FreeType metrics with clamp/center. Code points the face lacks fall back to
// the held UnifontRasterizer, so box-drawing / symbols still draw.
//
// Lives under Platform/Linux (not Rendering/) because it includes FreeType /
// fontconfig — Rendering must stay portable (Scripts/check-boundaries.py).

#include "Core/Preferences/FontRoutePreferences.h"
#include "Core/Rendering/FontFeatureSpecification.h"
#include "Core/Rendering/FontMetrics.h"
#include "Core/Rendering/FontVariationSpecification.h"
#include "Core/Rendering/GlyphRasterizer.h"
#include "Core/Rendering/UnifontRasterizer.h"
#include "Platform/Linux/ColorGlyphPainter.h"

#include <array>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <vector>

// Opaque FreeType handles kept out of the header (no ft2build.h leak).
struct FT_LibraryRec_;
struct FT_FaceRec_;
struct hb_font_t;

namespace Ubiquitty::Linux {
// The resolved feature run, defined where HarfBuzz's headers already are.
struct ShapingFeatures;
}

namespace Ubiquitty::Linux {

/// Whether a rasterizer may apply the face's own ligatures.
///
/// Core's own type rather than a second one with the same two names: the policy
/// is portable and both arms take it, so an alias keeps the frontend spelling
/// short without giving the value a second definition to drift from.
using Ligatures = Rendering::Ligatures;

/// The colour table a kept emoji face draws through.
///
/// Named by what the raster path does with the face rather than by what the
/// face declares: `FT_FACE_FLAG_COLOR` is set for every one of these, and only
/// the first needs a painter of our own. `None` is the answer for a face that
/// failed the draw probe, so a caller reading it cannot mistake a declined
/// face for a working one.
enum class ColorGlyphFormat : std::uint8_t {
    None,
    /// A paint graph drawn by `ColorGlyphPainter`.
    COLRv1,
    /// Layered outlines FreeType composites itself.
    COLRv0,
    /// Embedded bitmap strikes.
    CBDT,
    /// Apple's bitmap strikes.
    Sbix,
};

/// The name of a colour format, for a diagnostic or a test report.
[[nodiscard]] const char* colorGlyphFormatName(ColorGlyphFormat format);

class FreeTypeRasterizer final : public Rendering::GlyphRasterizer {
public:
    // Match a monospace face at `fontPixelSize` px. The CELL is DERIVED from the
    // face's metrics (cellMetrics()): the widest printable-ASCII advance for
    // width, line height for height, FT underline/ascender for decoration
    // positions — so a glyph fills the cell the face itself defines instead of a
    // hardcoded box.
    explicit FreeTypeRasterizer(int fontPixelSize);

    // As above, but fc-match `family` (config [font] family) instead of the
    // generic "monospace" alias. An empty family is treated as "monospace".
    FreeTypeRasterizer(int fontPixelSize, std::string family);

    /// As above, with a glyph-fallback face for code points the primary lacks,
    /// tried before the Unifont last resort, and the metrics the configuration
    /// sets. Every parameter past the fallback has the value a bare default
    /// configuration gives it.
    ///
    /// - Parameters:
    ///   - fallbackFontName: The fallback family. It selects the file this
    ///     project ships when the bundle table carries that family, and is
    ///     fc-matched otherwise; empty or unmatched, `bundledFallbackPath`
    ///     fills the slot.
    ///   - bundledFallbackPath: The bundled Symbols Nerd Font. With both it and
    ///     the name empty there is no fallback face, and the chain is the
    ///     primary then Unifont.
    ///   - bundledPrimaryPath: The shipped file for the primary face, when the
    ///     configuration names a family the project bundles; empty to fc-match
    ///     the family instead.
    ///   - deviceScale: The display scale the pixel size already carries.
    ///   Needed separately because the underline rule's constant term is in
    ///   POINTS and so scales with the display, while the size-relative term
    ///   does not — folding both into the pixel size would put the rule a pixel
    ///   high on every HiDPI screen.
    ///   - lineSpacingInPixels: Extra space between rows, split above and below
    ///     the type by `Rendering::cellLayout`.
    ///   - fontFeatures: The `font.features` specification, in the grammar
    ///     `Core/Rendering/FontFeatureSpecification.h` parses. Requested of the
    ///     shaper on every run.
    ///   - ligatures: Whether the face's own ligatures may apply. `Disabled`
    ///     asks the shaper to suppress `liga`/`clig`/`calt`, which HarfBuzz
    ///     enables by default for horizontal text and no other lever turns off.
    ///   - fontVariations: The `font.variations` specification, in the grammar
    ///     `Rendering::parseFontVariationSpecification` reads. Its axes fold
    ///     on top of the pair `uprightWeight`/`widthPercent` derive, so a tag named
    ///     by both takes the user's value — CSS's precedence, folded in Core so
    ///     this arm and the macOS one cannot answer it differently.
    ///   - fallbackPreferences: The `[font]` fallback families and range maps,
    ///     built by `Preferences::buildFontRoutePreferences`. The system cascade
    ///     tier routes through Core's fallback policy with these, the set the
    ///     route diagnostics answer with, so a cell draws from the face the
    ///     diagnostics name. Empty configures nothing.
    FreeTypeRasterizer(int fontPixelSize, std::string family, std::string fallbackFontName, std::string bundledFallbackPath, std::string bundledPrimaryPath = std::string(), int deviceScale = 1, int lineSpacingInPixels = 0, int trackingInPixels = 0, int uprightWeight = 0, int boldWeight = 0, double widthPercent = 0.0, std::string fontVariations = std::string(), std::string fontFeatures = std::string(), Ligatures ligatures = Ligatures::Enabled, Preferences::FontRoutePreferences fallbackPreferences = {});
    ~FreeTypeRasterizer();

    FreeTypeRasterizer(const FreeTypeRasterizer&) = delete;
    FreeTypeRasterizer& operator=(const FreeTypeRasterizer&) = delete;

    // True once fontconfig matched a face and FreeType loaded it. When false,
    // rasterizeGlyph + cellMetrics delegate wholly to the Unifont fallback, so
    // the frontend can keep this object and still render (just with Unifont).
    [[nodiscard]] bool ready() const { return m_face != nullptr; }

    // The matched family/style (for diagnostics); empty until a face loads.
    [[nodiscard]] const char* faceName() const { return m_faceName; }

    /// The file the glyph-fallback face was opened from.
    ///
    /// A family name cannot answer this: the file this project ships and a copy
    /// a machine has installed carry the same family, and which of the two is
    /// open decides what every symbol cell draws. Empty when no fallback face
    /// loaded, and empty for one fontconfig resolved, whose path is fc's to
    /// report.
    ///
    /// - Returns: The bundled file's path, or an empty string.
    [[nodiscard]] const std::string& bundledFallbackFaceSource() const { return m_bundledFallbackFaceSource; }

    // GlyphRasterizer — the font-derived cell + decoration metrics. When the
    // face failed to load, these are the Unifont fallback's metrics (8×16).
    //
    // Measured once, with the face. The frame clock reads this several times a
    // tick whether or not anything is damaged, and every input it derives from
    // is fixed at construction, so deriving it per call spends a glyph load and
    // a raster on an answer that cannot have moved.
    [[nodiscard]] Rendering::CellMetrics cellMetrics() const override { return m_cellMetrics; }
    [[nodiscard]] Rendering::FontMetrics::FacePitch primaryFacePitch() const override { return m_facePitch; }
    [[nodiscard]] Rendering::FaceMetrics faceMetrics() const override { return m_faceMetrics; }

    /// Draws the master Core selected at its size rather than magnifying the 1x
    /// raster.
    ///
    /// The face is sized to the master's em, its outline stretched across by
    /// the master's horizontal scale, and its pen placed on the master's phase
    /// grid, so a doubled row's stems are the 1x stems scaled by that stretch
    /// alone and a sized glyph is drawn as the face designs it at that size.
    ///
    /// - Parameters:
    ///   - codePoint: The glyph to draw.
    ///   - face: The style to draw it in.
    ///   - weight: The SGR weight the pen asked for.
    ///   - master: The size, stretch and phase grid; the identity defers to the
    ///     unscaled path.
    ///   - slotWidth: The destination's width.
    ///   - slotHeight: The destination's height.
    ///   - coverageOut: Caller-owned `slotWidth * slotHeight` bytes.
    /// - Returns: True when the glyph was drawn.
    bool rasterizeSizedMaster(std::uint32_t codePoint, Rendering::FontFace face, std::uint32_t weight, const Rendering::SizedMaster& master, int slotWidth, int slotHeight, std::uint8_t* coverageOut) override;

    /// The primary face's `wdth` axis, for a face that reaches bold on its
    /// axes; a style drawn from a member file of its own has no room.
    ///
    /// - Parameter face: The style asked about.
    /// - Returns: Where the axis stands and its maximum, or no room.
    [[nodiscard]] Rendering::WidthAxisRoom widthAxisRoom(Rendering::FontFace face) const override;

    /// The primary face's cell advance at a `wdth` coordinate, measured from
    /// the unhinted advance of `0` so the stretch Core derives from two of
    /// them is not quantised to whole pixels.
    ///
    /// - Parameters:
    ///   - face: The style asked about.
    ///   - coordinate: The `wdth` design coordinate.
    /// - Returns: The advance in pixels, or zero without a variable face.
    [[nodiscard]] double cellAdvanceAtWidthAxis(Rendering::FontFace face, double coordinate) override;

    /// True: this face is an outline one, so a scaled raster carries detail the
    /// 1x raster does not.
    [[nodiscard]] bool rasterisesScaledGlyphsSharply() const override { return true; }

    // GlyphRasterizer — the primary + fallback (Nerd Font) face bounding boxes
    // scaled to atlas px, baseline-relative y-up, the core feeds computeGlyphSlot
    // to size the overflow-pass slot. Zero overhang when no real face loaded (the
    // cell-tight Unifont path), so the slot stays the cell box.
    //
    // Measured once alongside the cell, and for the same reason: it reads the
    // face's global bounding boxes and the cell, none of which move.
    [[nodiscard]] Rendering::GlyphOverhangInputs glyphOverhang() const override { return m_glyphOverhang; }

    // GlyphRasterizer — render the code point at the slot's cell size into
    // coverageOut (slotWidth*slotHeight R8). Returns true (real AA coverage)
    // or, for a code point the face lacks, the Unifont fallback's result.
    bool rasterizeGlyph(std::uint32_t codePoint, Rendering::FontFace, std::uint32_t weight, int slotWidth, int slotHeight, std::uint8_t* coverageOut) override;
    /// Draws a grapheme cluster whose base the configured faces lack from the
    /// one face the system cascade routes the whole cluster to, shaped, so its
    /// marks stand where that face positions them over its own base.
    ///
    /// The base lands where ``rasterizeGlyph`` puts it alone, so a marked cell
    /// and its unmarked twin draw the same letter at the same place. A cluster
    /// whose base a configured face carries, or that no single face covers,
    /// keeps the overprint the base class draws.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - count: How many code points.
    ///   - face: The style asked for.
    ///   - weight: The SGR weight lane.
    ///   - slotWidth: The slot's width, pixels.
    ///   - slotHeight: The slot's height, pixels.
    ///   - coverageOut: The R8 slot to fill.
    /// - Returns: Whether any of the cluster was drawn.
    bool rasterizeCluster(const std::uint32_t* codePoints, int count, Rendering::FontFace face, std::uint32_t weight, int slotWidth, int slotHeight, std::uint8_t* coverageOut) override;

    /// Whether a colour face was found on this system.
    ///
    /// The answer is about the SYSTEM rather than about any cluster: a caller
    /// reads it once to decide whether to keep a colour sheet at all, and a
    /// per-cluster decline is `rasterizeColorCluster` returning false. A machine
    /// with no emoji font installed answers false here and never allocates one.
    ///
    /// - Returns: True when an emoji face loaded.
    [[nodiscard]] bool hasColorGlyphs() const override { return m_emojiFace != nullptr; }

    /// Which colour table the kept emoji face draws through; `None` when no
    /// face passed the draw probe, which is exactly when `hasColorGlyphs` is
    /// false.
    [[nodiscard]] ColorGlyphFormat colorGlyphFormat() const { return m_colorGlyphFormat; }

    /// The file the kept emoji face was loaded from; empty when none was.
    [[nodiscard]] const std::string& colorFacePath() const { return m_colorFacePath; }

    /// Every face fontconfig offers for the `emoji` alias, best match first.
    ///
    /// The whole sorted list rather than the one match `fc-match` prints: a
    /// host can carry a colour face this build cannot draw ahead of one it
    /// can, and the first answer alone would decline the host.
    ///
    /// - Returns: Font files, each with its face index, in fontconfig's order.
    [[nodiscard]] std::vector<std::pair<std::string, int>> emojiFaceCandidates() const;
    /// The path of a bundled font file, from the bundled directory the fallback
    /// face was given; empty when no fallback path is known or `file` is empty.
    [[nodiscard]] std::string bundledPath(std::string_view file) const;

    /// The draw probe one candidate is held to, on a face of its own.
    ///
    /// The same test `loadEmojiFace` applies while walking the candidates,
    /// exposed so a caller can re-derive why a candidate was kept or passed
    /// over.
    ///
    /// - Parameters:
    ///   - path: The font file.
    ///   - faceIndex: The face within it.
    ///   - fontPixelSize: The size the probe draws at.
    /// - Returns: The format the face draws colour through, or `None`.
    [[nodiscard]] static ColorGlyphFormat probeColorFace(const std::string& path, int faceIndex, int fontPixelSize);

    /// Draws a cluster from the emoji face as RGBA8.
    ///
    /// A bitmap or COLRv0 face hands back a pre-multiplied BGRA bitmap through
    /// FreeType; a COLRv1 face is painted into one by `ColorGlyphPainter`.
    /// Either way this un-multiplies and swaps to the straight RGBA the seam
    /// is specified in — a consumer that blends pre-multiplied data as if it
    /// were straight darkens every partially transparent edge.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster to draw.
    ///   - count: How many code points; 1 is a lone emoji.
    ///   - slotInPixels: The square slot edge.
    ///   - pixelsOut: The RGBA8 destination.
    /// - Returns: True when the face drew the cluster in colour.
    bool rasterizeColorCluster(const std::uint32_t* codePoints, int count, int slotInPixels, std::uint8_t* pixelsOut) override;

private:
    bool loadMatchedFace();
    // fc-match `pattern` (a family name) to a face file and FT_New_Face it into
    // *outFace (sized by the caller). Shared by loadMatchedFace + the named
    // fallback. Leaves *outFace null and returns false on any failure.
    // Null when fontconfig resolves nothing loadable. The handle is the whole
    // answer — a bool beside it would say the same thing twice, and a caller can
    // only disagree with itself about which of the two to trust.
    [[nodiscard]] FT_FaceRec_* loadFaceByPattern(const char* pattern);
    /// The face a cell of this style rasterises from.
    ///
    /// The bold member only when the family ships one as its own file — a
    /// variable face reaches bold through its axis and must stay on the primary,
    /// or the axis is placed on a face nothing draws.
    ///
    /// - Parameter face: The cell's style.
    /// - Returns: The bold face or the primary; never null when the primary
    ///   loaded.
    [[nodiscard]] FT_FaceRec_* monoFace(Rendering::FontFace face) const;

    // Load the glyph-fallback face (m_fallbackFace): the configured name via
    // fontconfig if it really resolves to that family, else the bundled file.
    // Sized to m_fontPixelSize. Null on failure (the chain skips this tier).
    bool loadFallbackFace();
    /// Loads the first colour-emoji face fontconfig offers that passes the
    /// draw probe, if any is installed.
    ///
    /// - Returns: True when an emoji face loaded.
    bool loadEmojiFace();
    /// Opens `path` and sizes it for colour.
    ///
    /// A bitmap face has fixed strikes and refuses `FT_Set_Pixel_Sizes`, so it
    /// is sized by selecting the strike nearest `fontPixelSize`; the raster is
    /// scaled into the slot when the two differ.
    ///
    /// - Parameters:
    ///   - library: The FreeType library to open the face in.
    ///   - path: The font file.
    ///   - faceIndex: The face within it.
    ///   - fontPixelSize: The size to draw at.
    /// - Returns: The sized face, or null when it cannot be opened or sized.
    static FT_FaceRec_* openSizedColorFace(FT_LibraryRec_* library, const char* path, int faceIndex, int fontPixelSize);
    /// Which colour table a sized face draws through, established by drawing.
    ///
    /// `FT_FACE_FLAG_COLOR` says the face carries colour, not that this build
    /// can draw it, so a probe glyph is drawn through the path the format
    /// would take and the answer is the ink that came back.
    ///
    /// - Parameter face: A sized face with `FT_FACE_FLAG_COLOR`.
    /// - Returns: The format, or `None` for a face that drew nothing.
    static ColorGlyphFormat classifyColorFace(FT_FaceRec_* face);
    /// Paints a COLRv1 glyph, scaled and centred, into the square slot as
    /// straight RGBA.
    ///
    /// - Parameters:
    ///   - glyphIndex: The base glyph in the emoji face.
    ///   - slotInPixels: The square slot edge.
    ///   - pixelsOut: The RGBA8 destination, `slotInPixels²` pixels.
    /// - Returns: False when the graph has a node the painter declines, so the
    ///   caller leaves the cluster to the mono path.
    bool paintColorGlyphIntoSlot(unsigned int glyphIndex, int slotInPixels, std::uint8_t* pixelsOut);

    /// Resolves a cluster to the single glyph the emoji face draws it as.
    ///
    /// A multi-code-point cluster is shaped, because a ZWJ sequence exists only
    /// as a GSUB ligature and has no code point a character map could resolve.
    /// A cluster the face has no ligature for shapes to several glyphs, and this
    /// falls back to the lead code point rather than drawing the pieces.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster.
    ///   - count: How many code points.
    /// - Returns: A glyph index in the emoji face, or 0 when it has none.
    unsigned int shapedGlyphForCluster(const std::uint32_t* codePoints, int count);

public:
    /// One shaped glyph of a text run: what to draw and how far to step after it.
    /// The Core type, not a local one. Two backends drawing the same run have to
    /// agree glyph for glyph, and a type owned here would put the other on a
    /// conversion — which is where two arms start to differ.
    using ShapedGlyph = Rendering::GlyphRasterizer::ShapedGlyph;

    /// Shapes a run of same-shape cells against the primary text face.
    ///
    /// For programming ligatures, which live in the face's GSUB table and are
    /// unreachable through the character map — the same reason
    /// ``shapedGlyphForCluster`` shapes an emoji ZWJ sequence rather than
    /// probing for it.
    ///
    /// The glyph count is not the ligature signal, and a caller must not read it
    /// as one. A monospace programming face keeps one glyph per cell and
    /// ligates by substituting the covered cells for a blank plus one wide
    /// glyph, so `=>` shapes to two glyphs exactly as `ab` does. What separates
    /// them is whether a glyph differs from the character map's own answer.
    ///
    /// - Parameters:
    ///   - codePoints: The run, one per cell.
    ///   - weight: The variable-weight axis value to shape at, so a bold run is
    ///     measured against the weight it will be drawn at.
    ///   - out: Where to write the glyphs. A run shaping to more than this holds
    ///     shapes to none, rather than to a prefix a caller would draw as the
    ///     whole run. Carried as a span rather than a pointer beside a count so
    ///     the bound travels with the buffer.
    /// - Returns: How many glyphs were written, or 0 when the face cannot shape.
    int shapeTextRun(std::span<const std::uint32_t> codePoints, std::uint32_t weight,
        std::span<ShapedGlyph> out) override;

    /// Whether a shaper over the text face exists at all.
    [[nodiscard]] bool canShapeText() const { return m_textShaper != nullptr; }

    /// Shapes a run of same-pen cells in the primary face at its natural
    /// advances, for a proportional primary face's rows (LetterLayout.h).
    ///
    /// HarfBuzz over the pen's face — the bold file where the family ships
    /// one, else the one face at the pen's weight — with kerning on and every
    /// ligature feature off, answering the 26.6 fraction whole.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: The pen's face.
    ///   - weight: The variable-weight axis value to shape at.
    ///   - out: Where to write the glyphs; its size is the bound.
    /// - Returns: How many glyphs were written, or 0 when the face cannot shape.
    int shapePrimaryRun(std::span<const std::uint32_t> codePoints, Rendering::FontFace face, std::uint32_t weight,
        std::span<Ubiquitty::ProportionalShapedGlyph> out) override;

    /// The Core capability, answered by the shaper this face actually has.
    ///
    /// What makes the CPU and GPU arms agree: both fault through this one
    /// instance, so both get ligatures or neither does. Reached through a second
    /// installed handle instead, one arm shaped and the other could not, and the
    /// byte-identical oracle reported the difference as 1083 pixels.
    [[nodiscard]] bool hasLigatureShaping() const override { return canShapeText(); }

    /// Whether fontconfig's `sans-serif` resolved to a face at this pixel size.
    ///
    /// The faces load on the first ask rather than with the grid face, so a
    /// session that never prints a proportional run pays nothing for them.
    ///
    /// - Returns: True when ``shapeProportionalRun`` can shape.
    [[nodiscard]] bool hasProportionalFace() const override;

    /// Shapes a run in the `sans-serif` face, regular or bold, at its own
    /// advances.
    ///
    /// Under the proportional lock: FreeType faces are not thread-safe, and a
    /// measurement on the reader thread can arrive while the render thread
    /// draws a strip from the same face.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: Regular or bold; italic resolves to its upright.
    ///   - out: Caller-owned destination; its size is the bound.
    /// - Returns: How many glyphs were written, or 0 when the face cannot shape.
    int shapeProportionalRun(std::span<const std::uint32_t> codePoints, Rendering::FontFace face,
        std::span<Ubiquitty::ProportionalShapedGlyph> out) override;

    /// Draws glyphs ``shapeProportionalRun`` placed, on the grid face's
    /// baseline so the run sits on the line beside it.
    ///
    /// - Parameters:
    ///   - glyphs: Placed glyphs, offsets already carrying the caller's pen.
    ///   - face: The face the glyphs were shaped in.
    ///   - stripWidthInPixels: The destination's width.
    ///   - stripHeightInPixels: The destination's height.
    ///   - coverageOut: Caller-owned `stripWidth * stripHeight` bytes, row-major.
    /// - Returns: True when the strip was drawn.
    bool rasteriseProportionalRun(std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, Rendering::FontFace face, int stripWidthInPixels,
        int stripHeightInPixels, std::span<std::uint8_t> coverageOut) override;

    /// Draws placed proportional glyphs from the proportional face at a sized
    /// master: sized to the master's em for the draw, its outline stretched
    /// across by the master's horizontal scale, on the 1x strip's baseline
    /// taken `scale` times.
    ///
    /// - Parameters:
    ///   - glyphs: Placed glyphs, offsets in master pixels.
    ///   - face: Regular or bold.
    ///   - master: The size and stretch Core selected.
    ///   - stripWidthInPixels: The destination's width.
    ///   - stripHeightInPixels: The destination's height.
    ///   - coverageOut: Caller-owned `stripWidth * stripHeight` bytes.
    /// - Returns: True when the strip was drawn.
    bool rasteriseSizedProportionalRun(std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, Rendering::FontFace face, const Rendering::SizedMaster& master,
        int stripWidthInPixels, int stripHeightInPixels, std::span<std::uint8_t> coverageOut) override;

    /// Draws already-shaped glyphs into one strip, advancing a pen between them.
    ///
    /// The other half of ``shapeTextRun``, kept separate from it so the two can
    /// be compared: feeding this the character map's glyphs instead of the
    /// shaper's draws the same run unligated, through the same code, and the
    /// difference between the two images is the ligature and nothing else.
    ///
    /// Unlike ``rasterizeGlyph``, which centres one glyph in its cell, this
    /// places each glyph at the pen and steps by the shaped advance — a run's
    /// glyphs are positioned relative to each other, and a wide ligature glyph
    /// reaches back across the cells its blanks left empty.
    ///
    /// - Parameters:
    ///   - glyphs: The shaped run, in draw order.
    ///   - stripWidthInPixels: The strip's width; ink past it is clipped rather
    ///     than wrapped into the next row.
    ///   - stripHeightInPixels: The strip's height, sharing the primary
    ///     baseline so a strip lines up with the mono cells around it.
    ///   - coverageOut: R8 coverage, row-major, top-left origin. Cleared first,
    ///     so a run that draws nothing leaves a blank strip rather than stale
    ///     pixels.
    /// - Returns: False when the strip geometry does not match `coverageOut`, or
    ///   when there is no face to draw from.
    bool rasteriseShapedRun(std::span<const ShapedGlyph> glyphs, int stripWidthInPixels,
        int stripHeightInPixels, std::span<std::uint8_t> coverageOut) override;

    /// Draws already-shaped glyphs and reports each one's horizontal ink.
    ///
    /// The measured spelling of ``rasteriseShapedRun``: the same pen walk and
    /// the same pixels, plus one extent per glyph taken from the bitmap this
    /// pass is holding anyway — its bearing and width at the placed pen,
    /// clipped to the strip like the pixels are. The extents exist for the
    /// consumer's ownership cut; measuring here costs no extra load.
    ///
    /// - Parameters:
    ///   - glyphs: The shaped run, in draw order.
    ///   - stripWidthInPixels: The strip's width; ink past it is clipped.
    ///   - stripHeightInPixels: The strip's height, sharing the primary
    ///     baseline so a strip lines up with the mono cells around it.
    ///   - coverageOut: R8 coverage, row-major, top-left origin. Cleared
    ///     first, so a run that draws nothing leaves a blank strip.
    ///   - inkOut: One extent per entry of `glyphs`; a glyph that drew
    ///     nothing reports an empty extent.
    /// - Returns: False when the strip geometry does not match `coverageOut`,
    ///   when `inkOut` is not one entry per glyph, or when there is no face.
    bool rasteriseShapedRunMeasured(std::span<const ShapedGlyph> glyphs, int stripWidthInPixels,
        int stripHeightInPixels, std::span<std::uint8_t> coverageOut,
        std::span<GlyphInkExtent> inkOut) override;

    /// Whether the primary face carries a variable 'wght' axis.
    ///
    /// Reported so a caller can say which case it measured rather than implying
    /// the other. Shaping at a weight only moves anything on a face that has the
    /// axis; on a static face ``shapeTextRun`` takes the same path for every
    /// weight, and a test that shaped bold there has not exercised the axis.
    [[nodiscard]] bool hasWeightAxis() const { return m_wghtAxisIndex >= 0; }
    // Whether the face carries a 'wdth' variation axis, which is what decides
    // whether a width setting can be honoured at all on this face.
    [[nodiscard]] bool hasWidthAxis() const { return m_wdthAxisIndex >= 0; }

    /// What the primary face's character map alone gives for one code point.
    ///
    /// The other half of reading ``shapeTextRun``: shaping is what moved a glyph
    /// off this answer, and on a face that keeps one glyph per cell that
    /// difference is the only thing separating a ligated run from an unligated
    /// one. Zero when the face lacks the code point, which is the same answer
    /// FreeType gives.
    [[nodiscard]] unsigned int glyphIndexForCodePoint(std::uint32_t codePoint) const;

private:
    // The primary face's baseline (rounded ascender, clamped into the slot) —
    // fallback glyphs share it so they sit on the text baseline. m_face != null.
    [[nodiscard]] int primaryBaselineY(int slotHeight) const;
    // The one pen walk both shaped-run spellings share; a null inkOut draws
    // without recording, a non-null one is one entry per glyph, caller-checked.
    bool drawShapedRun(std::span<const ShapedGlyph> glyphs, int stripWidthInPixels,
        int stripHeightInPixels, std::span<std::uint8_t> coverageOut, GlyphInkExtent* inkOut);
    /// The same walk over any face.
    ///
    /// The strip draws `face`'s glyph indices on the PRIMARY face's baseline,
    /// which is what keeps a proportional run on the line beside it.
    ///
    /// - Parameters:
    ///   - face: The face the glyph indices belong to.
    ///   - glyphs: Placed glyphs, offsets already carrying the caller's pen.
    ///   - stripWidthInPixels: The destination's width.
    ///   - stripHeightInPixels: The destination's height.
    ///   - coverageOut: Caller-owned `stripWidth * stripHeight` bytes, row-major.
    ///   - inkOut: One extent per glyph, or null to draw without recording.
    /// - Returns: True when the strip was drawn.
    /// Draws a proportional run in `face`, each glyph at its fractional pen:
    /// the outline is translated by the fraction before it is rasterised, so
    /// the ink lands where the shaper put it rather than on the nearest
    /// whole pixel.
    /// A sized master stretches each outline across by its horizontal scale
    /// and sits it on `baselineY`; the face must already carry the master's size.
    bool drawProportionalRunWithFace(FT_FaceRec_* face, std::span<const Ubiquitty::ProportionalShapedGlyph> glyphs, int stripWidthInPixels,
        int stripHeightInPixels, std::span<std::uint8_t> coverageOut, const Rendering::SizedMaster& master = {}, std::optional<int> baselineY = std::nullopt);
    bool drawShapedRunWithFace(FT_FaceRec_* face, std::span<const ShapedGlyph> glyphs, int stripWidthInPixels,
        int stripHeightInPixels, std::span<std::uint8_t> coverageOut, GlyphInkExtent* inkOut);
    /// Loads the `sans-serif` pair on the first ask, under the proportional
    /// lock; a pattern fontconfig cannot resolve leaves both null for good.
    void ensureProportionalFaces();
    /// The face a proportional run draws in: regular or bold.
    ///
    /// - Parameter face: Regular or bold; italic resolves to its upright.
    /// - Returns: The face, or null when none loaded.
    [[nodiscard]] FT_FaceRec_* proportionalFace(Rendering::FontFace face) const;
    /// The shaper over ``proportionalFace``: the regular shaper when the bold
    /// face is the regular one.
    ///
    /// - Parameter face: Regular or bold.
    /// - Returns: The shaper, or null when no face loaded.
    [[nodiscard]] hb_font_t* proportionalShaper(Rendering::FontFace face) const;
    // Load + render + center-blit `codePoint` from `face` into coverageOut at the
    // given (primary-derived) baseline. False when the face is null, lacks the
    // glyph, or FreeType fails — so the caller falls through to the next tier.
    // A sized master stretches the outline across by its horizontal scale and
    // places the pen on its phase grid; the face must already carry its size.
    bool renderGlyphFromFace(FT_FaceRec_* face, std::uint32_t codePoint, int baselineY, int slotWidth, int slotHeight, std::uint8_t* coverageOut, const Rendering::SizedMaster& master = {});
    /// ``renderGlyphFromFace`` at whatever coordinates the face carries.
    ///
    /// - Parameters:
    ///   - face: The face to draw from.
    ///   - codePoint: The cell's code point.
    ///   - baselineY: The primary baseline, in slot rows from the top.
    ///   - slotWidth: The slot's width in pixels.
    ///   - slotHeight: The slot's height in pixels.
    ///   - coverageOut: The slot's coverage.
    ///   - master: The sized master, or the identity for the cell's own glyph.
    /// - Returns: False when the face lacks the glyph or FreeType fails.
    bool renderGlyphAtCurrentCoordinates(FT_FaceRec_* face, std::uint32_t codePoint, int baselineY, int slotWidth, int slotHeight, std::uint8_t* coverageOut, const Rendering::SizedMaster& master);
    // Query the face's variation axes (once, at load) — caches the 'wght' and
    // 'wdth' axis indices + ranges so the setters can place a coordinate per
    // glyph without re-walking fvar.
    void queryVariationAxes();
    /// Places the face's variation coordinates for one drawing request.
    ///
    /// Writes both axes: every coordinate is restated from the fvar defaults on
    /// each call, so setting one alone would reset the other. A no-op on a face
    /// with no variation axes, where the request is ignored as it is on macOS.
    ///
    /// - Parameters:
    ///   - face: Which member is being drawn, which selects the upright or the
    ///     bold configured weight.
    ///   - weight: The SGR 1:n weight, or zero to take the configured default.
    ///   - widthAxisOverride: A `wdth` coordinate that replaces the configured
    ///     and user ones, for a sized master Core widened; zero for none.
    void applyWeightAxis(Rendering::FontFace face, std::uint32_t weight, double widthAxisOverride = 0.0);
    /// The `wdth` coordinate the primary face stands at: the user's `wdth`
    /// variation where one is set, else the configured width.
    ///
    /// - Returns: The coordinate, clamped to the axis.
    [[nodiscard]] double effectiveWidthAxis() const;
    /// The `wght` coordinate a face and an SGR weight resolve to.
    ///
    /// - Parameters:
    ///   - face: Which member is being drawn; selects the upright or the bold
    ///     configured weight when no SGR weight overrides them.
    ///   - sgrWeight: The per-run weight, 1 through 7, or zero for none.
    /// - Returns: The axis coordinate, clamped to what the face offers.
    [[nodiscard]] double resolvedWeightAxis(Rendering::FontFace face, std::uint32_t sgrWeight) const;
    /// The `wdth` coordinate the configured width resolves to.
    ///
    /// - Returns: The axis coordinate, clamped to what the face offers, or the
    ///   face's own when no width is configured.
    [[nodiscard]] double configuredWidthAxis() const;
    /// Derives the cell and decoration metrics from the loaded face.
    ///
    /// Reads the face's line height, ascender, and the ink height of 'x', and
    /// folds them through Core's shared cell layout and rule geometry. Called
    /// once, at construction: `cellMetrics()` hands back what this returned.
    [[nodiscard]] Rendering::CellMetrics computeCellMetrics() const;

    /// Derives the face's own vertical metrics from the loaded face.
    ///
    /// Reads the sized face's ascender and descender, and the ink box of `[`
    /// for the prompt mark to centre on. Separate from ``computeCellMetrics``
    /// because the cell has the line spacing folded into its baseline and the
    /// face does not, and a consumer substituting one for the other is right
    /// only while that spacing is zero.
    [[nodiscard]] Rendering::FaceMetrics computeFaceMetrics() const;

    /// Derives the slot-overhang inputs from the face bounding boxes.
    ///
    /// - Parameter cell: The metrics `computeCellMetrics` produced, whose cell
    ///   width and height the overhang fold is measured against. Passed rather
    ///   than read back from the member so the two cannot be computed in the
    ///   wrong order.
    [[nodiscard]] Rendering::GlyphOverhangInputs computeGlyphOverhang(const Rendering::CellMetrics& cell) const;

    /// Measures the cell width from the face's printable-ASCII advances.
    ///
    /// Samples the range Core names and hands it to `FontMetrics::cellAdvance`,
    /// which decides which advance the cell is; the result lands in
    /// `m_cellAdvanceInPixels`. Called once per sized face rather than per
    /// `cellMetrics()`, because the answer is a property of (face, pixel size)
    /// and the metrics are read on the frame path.
    void measureCellAdvance();

    static constexpr int maxVariationAxes = 8;

    int m_fontPixelSize;
    // The tracking folded into the column pitch, device pixels, possibly
    // negative. The cell grows or shrinks around a glyph the face still draws
    // at its own size, which is what separates tracking from a scale.
    int m_trackingInPixels = 0;
    // The `wght` axis upright and bold text are drawn at, or zero for the
    // face's own. Held as the configured usWeightClass rather than an axis
    // coordinate: `Font::variationWeightForSetting` owns that mapping, and a
    // second copy of it here is the drift the shared seam exists to stop.
    int m_uprightWeight = 0;
    int m_boldWeight = 0;
    // The `wdth` axis text is drawn at, as a percent of normal, or zero for the
    // face's own. The axis is percent-of-normal by specification, so a variable
    // face takes this value directly; a static family has no axis to take it,
    // and fontconfig's width class is the only lever there.
    double m_widthPercent = 0.0;
    // The feature run every `hb_shape` here is given, resolved once at
    // construction rather than per call: the inputs are fixed by the
    // constructor and rebuilding it per shaped run would allocate on the hot
    // path to reach the same answer.
    //
    // HarfBuzz applies `liga`, `clig` and `calt` by default for horizontal
    // text, so an empty run is not "no features" — it is the face's defaults.
    // Suppression has to be requested explicitly, which is why a disabled
    // toggle produces a non-empty run.
    //
    // Held behind a pointer because `hb_feature_t` is a value type and this
    // header names every other HarfBuzz type by forward declaration. Including
    // `hb.h` to hold it directly would put the shaper's headers into
    // VulkanRenderer.h and everything downstream of it, which is the transitive
    // set the forward declarations exist to keep closed.
    std::unique_ptr<ShapingFeatures> m_shapingFeatures;
    // The cell and slot geometry the face implies, measured once at
    // construction. Every input is fixed there — the face, its pixel size, the
    // device scale and the line spacing are all set in the constructor and
    // nothing reopens them — so a later read cannot be stale.
    Rendering::CellMetrics m_cellMetrics {};
    // The face's own vertical metrics, without the line spacing the cell folds
    // into its baseline. Measured once beside the cell metrics, from the same
    // fixed inputs, so a later read cannot be stale.
    Rendering::FaceMetrics m_faceMetrics {};
    Rendering::GlyphOverhangInputs m_glyphOverhang {};
    // The cell width Core derived from the face's printable-ASCII advances,
    // measured once per sized face. Zero until a face loads, which is the
    // condition the cell metrics fall back to the font pixel size on.
    int m_cellAdvanceInPixels = 0;
    /// The primary face's pitch, from the unhinted advances the cell is read
    /// from: a proportional face's rows are laid out as proportional runs by
    /// the builder, and its cell is the digit's advance.
    Rendering::FontMetrics::FacePitch m_facePitch = Rendering::FontMetrics::FacePitch::Fixed;
    // The display scale already folded into m_fontPixelSize, kept because the
    // underline rule's constant term is in points and scales with it.
    int m_deviceScale = 1;
    int m_lineSpacingInPixels = 0;
    std::string m_family; // fc-match pattern; empty → "monospace"
    std::string m_fallbackFontName; // config [font] fallback; empty → bundled
    std::string m_bundledFallbackPath; // bundled Symbols Nerd Font (next to binary)
    std::string m_bundledPrimaryPath; // the shipped file for the primary face, when the configuration names a bundled family
    /* owned via FT_Done_Library */ FT_LibraryRec_* m_library = nullptr;
    /* owned via FT_Done_Face */ FT_FaceRec_* m_face = nullptr;
    // Glyph-fallback face for code points the primary lacks. Glyph-only: never
    // influences cellMetrics() and never gets the wght variation axis.
    /* owned via FT_Done_Face */ FT_FaceRec_* m_fallbackFace = nullptr;
    // The primary family's bold member, when the bundle table names one as a
    // separate file. A variable face expresses bold on its `wght` axis and has
    // no such file; a static one has no axis to place, so without this a bold
    // run draws at the body weight and the two are the same colour on screen.
    /* owned via FT_Done_Face */ FT_FaceRec_* m_boldFace = nullptr;
    // The primary family's italic and bold italic members, when the bundle
    // table names them, so an italic cell draws the family's own italic
    // letterforms as the CoreText arm does rather than the upright. A variable
    // italic carries its weights on the same axes as the upright and is placed
    // with it; a static family names each file.
    /* owned via FT_Done_Face */ FT_FaceRec_* m_italicFace = nullptr;
    /* owned via FT_Done_Face */ FT_FaceRec_* m_boldItalicFace = nullptr;
    // Whether the italic face's variation axes are the upright's, tag for tag,
    // so the coordinates placed on the upright place it too.
    bool m_doesItalicShareAxes = false;
    // The bundled file the fallback face was opened from, empty when fontconfig
    // answered instead. Read by the test that holds the two machines to one
    // file, since the family name is the same either way.
    std::string m_bundledFallbackFaceSource;
    // The configured fallback families the system cascade routes with. Owns
    // the storage the policy's preference views borrow.
    Preferences::FontRoutePreferences m_fallbackPreferences;
    // Everything the system cascade tier owns: an inventory over fontconfig
    // and the route caches Core's fallback policy reads and fills. Null until
    // a code point misses both faces above, so a session whose text the
    // primary covers pays nothing for it.
    struct CascadeRouting;
    std::unique_ptr<CascadeRouting> m_cascade;
    /// Returns the face Core's fallback policy routes a code point to once the
    /// primary and glyph-fallback faces have missed it.
    ///
    /// Asked for text presentation: this is the mono path, and an
    /// emoji-presentation cluster reaches the colour path instead. An assembly
    /// extension routes as the piece it borrows its stem from, so the face
    /// carries the glyph the extension is drawn from and the stroke runs on
    /// through the join at the hook's column and weight.
    ///
    /// - Parameter codePoint: The character the earlier tiers lacked.
    /// - Returns: A sized face carrying it, owned by the cascade inventory, or
    ///   null when no scalable system face does.
    [[nodiscard]] FT_FaceRec_* cascadeFace(std::uint32_t codePoint);
    /// Returns the face Core's fallback policy routes a whole cluster to.
    ///
    /// - Parameter codePoints: The cluster, base first.
    /// - Returns: A sized face carrying every code point of it, or null.
    [[nodiscard]] FT_FaceRec_* cascadeFace(std::span<const std::uint32_t> codePoints);
    // The system colour-emoji face. Null when none is installed, which is the
    // question hasColorGlyphs answers.
    /* owned via FT_Done_Face */ FT_FaceRec_* m_emojiFace = nullptr;
    ColorGlyphFormat m_colorGlyphFormat = ColorGlyphFormat::None;
    std::string m_colorFacePath;
    // The COLRv1 painter and its canvas, kept so a glyph paints without
    // allocating once the first has sized them.
    ColorGlyphPainter m_colorGlyphPainter;
    std::vector<std::uint8_t> m_colorCanvas;
    // The shaper over that face, built once. A ZWJ sequence is a ligature in the
    // font's GSUB table and no amount of character-map lookup will find it, so
    // composing one needs a shaping pass rather than a wider probe.
    /* owned via hb_font_destroy */ hb_font_t* m_emojiShaper = nullptr;
    // The shaper over the primary text face, built once beside it. Separate from
    // m_emojiShaper because it is a different face: one answers ZWJ sequences,
    // the other programming ligatures, and neither face carries the other's
    // tables.
    /* owned via hb_font_destroy */ hb_font_t* m_textShaper = nullptr;
    // The shapers over the shipped styled faces, where the family has them,
    // for the letter layout of a bold or italic run; each built on first use
    // beside its face.
    /* owned via hb_font_destroy */ hb_font_t* m_boldTextShaper = nullptr;
    /* owned via hb_font_destroy */ hb_font_t* m_italicTextShaper = nullptr;
    /* owned via hb_font_destroy */ hb_font_t* m_boldItalicTextShaper = nullptr;
    // The proportional faces (Docs/proportional-text.md): fontconfig's
    // `sans-serif` at the grid's pixel size, regular and bold, with a shaper
    // each. Loaded on first use; guarded because the reader thread measures
    // while the render thread draws, and a FreeType face serves one at a time.
    mutable std::mutex m_proportionalLock;
    bool m_didLoadProportionalFaces = false;
    /* owned via FT_Done_Face */ FT_FaceRec_* m_proportionalRegularFace = nullptr;
    /* owned via FT_Done_Face */ FT_FaceRec_* m_proportionalBoldFace = nullptr;
    /* owned via hb_font_destroy */ hb_font_t* m_proportionalRegularShaper = nullptr;
    /* owned via hb_font_destroy */ hb_font_t* m_proportionalBoldShaper = nullptr;
    char m_faceName[256] = { 0 };

    // Variable-font 'wght' axis (SGR 1:n). m_wghtAxisIndex < 0 ⇒ the face has
    // no wght axis (or isn't variable) and weight is ignored. m_axisDefault
    // holds every axis's default so a per-glyph set keeps the others put.
    int m_wghtAxisIndex = -1;
    // The 'wdth' axis, found beside 'wght' in the same fvar walk. Negative when
    // the face has no such axis, which is what makes a width setting inert
    // rather than wrong on a static family.
    int m_wdthAxisIndex = -1;
    double m_minWdth = 0.0;
    double m_wdthDefault = 0.0;
    double m_maxWdth = 0.0;
    unsigned m_axisCount = 0;
    double m_minWght = 0.0;
    double m_wghtDefault = 0.0;
    double m_maxWght = 0.0;
    double m_axisDefault[maxVariationAxes] = { 0.0 };
    // Every axis by tag and range, not only the two a named setting derives:
    // `font.variations` can name any tag the face carries, and an axis placed
    // without its own range would be clamped against another axis's.
    std::array<std::uint32_t, maxVariationAxes> m_axisTag {};
    std::array<double, maxVariationAxes> m_minCoordinate {};
    std::array<double, maxVariationAxes> m_maxCoordinate {};
    // The user's `font.variations` axes, parsed once. Fixed for the life of the
    // rasterizer: the specification is configuration, not per-run state.
    Rendering::FontVariationSettings m_userAxes;
    // The coordinate set currently on the face, to skip redundant FT sets.
    // The whole set rather than the weight alone: an axis list can move a
    // coordinate the weight did not, and a key that watches one axis reports
    // "unchanged" for a write that changed the others.
    std::array<double, maxVariationAxes> m_lastAppliedCoords {};
    bool m_didApplyAxes = false; // bool-ok: first apply must reach the face
    // Bumped only when a set actually reaches the face, so a caller can tell
    // whether the coordinates moved without re-deriving them. hb_ft caches the
    // face's metrics and has to be told.
    std::uint64_t m_axisGeneration = 0;

    // Fallback for code points the mono face lacks (box drawing, rare symbols).
    Rendering::UnifontRasterizer m_unifontFallback;
};

} // namespace Ubiquitty::Linux
