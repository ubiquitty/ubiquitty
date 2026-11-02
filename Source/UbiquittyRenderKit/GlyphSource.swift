// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// GlyphSource.swift — the renderer's side of Core's glyph seam.
//
// Core decides which glyph every cell needs and where it goes; it cannot
// rasterise one, because that is CoreText and CoreText is not portable. The seam
// between those two facts is `Rendering::GlyphBackend`, a table of C function
// pointers over an opaque context, and this is the Swift that fills it.
//
// A table rather than a class hierarchy is what makes this possible at all:
// Swift cannot inherit a C++ pure-virtual interface, so an abstract base would
// oblige the frontend to carry a C++ adapter whose whole job is forwarding. The
// thunks below are that adapter, written once, in the language the glyph work is
// already in.
//
// What may be left out is expressed as conformance rather than as a null check.
// Core treats a null entry as "use my default", so a backend that rasterises no
// colour emoji is legitimate rather than broken. An unadopted protocol states
// that where the type is declared; a nil assignment states it in the middle of a
// table-filling function, next to sixteen that are not nil.

import UbiquittyCore

/// What a renderer must supply before Core can build a frame.
///
/// The four Core names REQUIRED, plus the one it reaches on a cache miss it has
/// already taken a slot for. A source missing any of these cannot draw: Core
/// runs the mono hit path itself, so a slot it assigned and nobody filled shows
/// whatever the atlas last cleared it to, which is indistinguishable from a
/// space in a frame whose every count is correct.
///
/// None of these is per-cell. `bindMonoAtlas` is read once a frame and the walk
/// uses the returned values directly; the rest are per glyph miss.
protocol GlyphSource: AnyObject {
    /// Opens a frame, after which touched slots survive eviction until it ends.
    func beginFrame()

    /// Core's verdict on the primary face's pitch, from the advances its cell
    /// was measured from (``GlyphBackend/primaryFacePitch``).
    var primaryFacePitch: Ubiquitty.Rendering.FontMetrics.FacePitch { get }

    /// Shapes a run of same-pen cells in the primary face at its natural
    /// advances, for a proportional primary face's rows (LetterLayout.h):
    /// the face's advances and kerning with every ligature feature off, one
    /// ``ProportionalShapedGlyph`` per glyph. Empty refuses, and the run
    /// keeps the grid's pitch.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - face: The pen's face.
    ///   - weight: The variable weight the pen carries.
    /// - Returns: The glyphs, in text order.
    func shapePrimaryRun(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph]

    /// Fills in the mono atlas's slot cache and layout for this frame.
    ///
    /// Written through rather than returned: the binding borrows the atlas, so
    /// Swift declines to return it from a declared function without a lifetime
    /// annotation. A closure may return one, which is how the table's thunk
    /// hands it back to Core.
    ///
    /// - Parameter binding: The binding to fill.
    func bindMonoAtlas(into binding: inout Ubiquitty.Rendering.MonoAtlasBinding)

    /// Returns the atlas rect for one code point, rasterising on a miss.
    ///
    /// - Parameters:
    ///   - codePoint: The character to resolve.
    ///   - face: Which face of the family to draw it in.
    ///   - weight: Variable-font weight, or zero for the face's own.
    ///   - phase: Subpixel phase the glyph was positioned at.
    /// - Returns: The glyph's atlas rect, or an absent one.
    func monoGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32
    ) -> Ubiquitty.Rendering.AtlasGlyph

    /// Fills a slot the cache has already assigned.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - face: Which face to draw it in.
    ///   - variant: The raster variant the slot was keyed with — a subpixel
    ///     phase and a smoothing tier packed together, decoded by
    ///     `variantPhase` and `variantTier` rather than used whole.
    ///   - slot: The slot the cache assigned.
    func rasteriseMonoGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        slot: Int32
    ) -> Bool

    /// Stages a coverage plane Core rasterised into a mono slot.
    ///
    /// A DECDLD soft-font glyph is today's only caller: its matrix arrives off
    /// the wire, so there is no code point to shape and only pixels to move.
    /// On the base protocol rather than an optional capability, because a
    /// source that cannot move a plane leaves every soft-font cell
    /// background-only while the other renderers draw the download.
    ///
    /// - Parameters:
    ///   - coverage: The R8 plane, row-major, laid out for this source's slot
    ///     box; refused when its count is not that box's area. Core's own
    ///     span, borrowed for the call — the seam converts nothing.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Whether the plane was staged.
    func stageMonoCoverage(_ coverage: Ubiquitty.Rendering.CoveragePlaneSpan, slot: Int32) -> Bool
}

/// A source that draws box-drawing lines from the font.
///
/// Core's policy for the line family is font-first — the font's weight and
/// dashes survive, vertically centred and 9-slice edge-stretched — and the
/// procedural route is the fallback for a face without the glyph. A source
/// without this conformance overrides that policy to procedural-always,
/// which drops what the font carried.
protocol BoxGlyphSource: GlyphSource {
    /// Returns the atlas rect for one box glyph, rasterising on a miss.
    ///
    /// - Parameters:
    ///   - codePoint: The box-drawing character to resolve.
    ///   - face: Which face of the family to draw it in.
    /// - Returns: The glyph's atlas rect, or an absent one — absent keeps the
    ///   cell on the procedural route.
    func boxGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace
    ) -> Ubiquitty.Rendering.AtlasGlyph
}

/// A source that keeps two-cell glyphs on a sheet of their own.
///
/// Without it, a wide lead's glyph stays on its cell and Core stretches the 1x
/// glyph — wide cells render slightly wrong rather than blank.
/// A source that draws a two-cell base carrying combining marks.
///
/// Separate from ``WideGlyphSource`` because Core calls this one per cell rather
/// than probing a bound cache: a cluster's key folds a variable-length run, so
/// the contents have to travel with the probe.
protocol WideClusterGlyphSource: GlyphSource {
    /// The atlas rect for a wide cluster, rasterising on a miss.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - face: Which face to shape it in.
    ///   - weight: The variable weight, where a source applies one.
    ///   - variant: The raster variant, whose tier the raster is weighted by.
    /// - Returns: The glyph, or an absent one when there is no wide sheet.
    func wideClusterGlyph(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32
    ) -> Ubiquitty.Rendering.AtlasGlyph
}

protocol WideGlyphSource: GlyphSource {
    /// Fills in the two-cell sheet's binding for one frame.
    ///
    /// - Parameter binding: The binding to fill.
    func bindWideAtlas(into binding: inout Ubiquitty.Rendering.WideAtlasBinding)

    /// Fills a two-cell slot the cache has already assigned.
    ///
    /// - Parameters:
    ///   - codePoint: The character to draw.
    ///   - face: Which face to draw it in.
    ///   - variant: The raster variant, whose tier the raster is weighted by.
    ///   - slot: The slot the cache assigned.
    func rasteriseWideGlyph(_ codePoint: UInt32, face: Ubiquitty.Rendering.FontFace, variant: UInt32, slot: Int32) -> Bool

    /// The pen grid one two-cell glyph is drawn on, as buckets per pixel.
    ///
    /// - Parameters:
    ///   - codePoint: The glyph, or a cluster's base.
    ///   - face: Which face it is drawn in.
    /// - Returns: The count Core keys and places the glyph at.
    func wideGlyphPhaseCount(_ codePoint: UInt32, face: Ubiquitty.Rendering.FontFace) -> Int32
}

/// A source that keeps colour emoji on an RGBA sheet apart from the coverage one.
///
/// Without it, colour glyphs fall to the mono path and draw as coverage — an
/// emoji in the foreground colour rather than its own.
protocol ColorGlyphSource: GlyphSource {
    /// Fills in the colour sheet's binding for one frame.
    ///
    /// - Parameter binding: The binding to fill.
    func bindColorAtlas(into binding: inout Ubiquitty.Rendering.ColorAtlasBinding)

    /// Fills a colour slot the cache has already assigned.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster to draw; one code point is a lone character.
    ///   - slot: The slot the cache assigned.
    func rasteriseColorGlyph(_ codePoints: Ubiquitty.Rendering.ClusterSpan, slot: Int32) -> Bool
}

/// A source that shapes a row's ligature runs into strips.
///
/// Without it, text renders unligatured rather than wrongly — the fair
/// default the Linux and software backends take today.
protocol LigatureGlyphSource: GlyphSource {
    var canPrepareLigatures: Bool { get }
    func prepareLigatureRow(_ row: Ubiquitty.Rendering.LigatureRowSpan, cellWidthInPixels: Float)
    func finishLigaturePreparation()

    /// Shapes one row's ligature runs into the seam's per-column form.
    ///
    /// - Parameters:
    ///   - row: The distilled row, one entry per column.
    ///   - rowOriginXInPixels: The row's left edge, for the run pen's phase.
    ///   - cellWidthInPixels: One cell's width in device pixels.
    ///   - pass: Whether the row draws subpixel-snapped or cell-baked.
    ///   - runs: One entry per column to fill; untouched entries stay empty.
    func shapeLigatureRuns(
        _ row: Ubiquitty.Rendering.LigatureRowSpan,
        rowOriginXInPixels: Float,
        cellWidthInPixels: Float,
        pass: Ubiquitty.Rendering.GlyphPass,
        into runs: Ubiquitty.Rendering.LigatureRunStream
    )
}

/// A source that shapes a proportional run into one strip
/// (Docs/proportional-text.md).
///
/// Without it, Core sets the run's text in the grid's face, one code point
/// per cell — legible, and not the look the run asked for, which is why a
/// source with a proportional face says so.
protocol ProportionalStripSource: GlyphSource {
    /// Returns the strip for one proportional run — its text shaped in the
    /// proportional face at natural advances, aligned inside the run's cells
    /// and clipped to them — with where its quad goes from the pen's whole
    /// pixel.
    ///
    /// - Parameters:
    ///   - codePoints: The run's text.
    ///   - widthCells: The cells the run occupies.
    ///   - horizontalAlign: Left, right or centred inside them.
    ///   - penResidualInPixels: The pen's fraction past its whole pixel.
    ///   - face: Which face — the proportional family's regular or bold.
    ///   - weight: Variable-font weight, or zero for the face's own.
    ///   - variant: The raster variant the run's foreground selects.
    ///   - tileIndex: The zero-based horizontal tile of the complete run.
    ///   - size: The run's scale, the band asked for and its doubling across,
    ///     as `GlyphBackend::proportionalStrip` names them.
    /// - Returns: The placement; its strip is absent when the sheet refuses.
    func proportionalStrip(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        widthCells: Int32,
        horizontalAlign: UInt8,
        penResidualInPixels: Float,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32,
        tileIndex: Int32,
        size: Ubiquitty.Rendering.SizedTile
    ) -> Ubiquitty.Rendering.ProportionalStripPlacement
}

/// A source that rasterises a 2x master for DECDWL/DECDHL rows.
///
/// Without it, Core halves the 1x glyph's V range instead, so double rows never
/// blank — softer than a real master, which is why a source that has one says so.
protocol DoubleGlyphSource: GlyphSource {
    /// Returns the atlas rect for a double-size glyph, applying the region.
    ///
    /// - Parameters:
    ///   - codePoint: The character to resolve.
    ///   - face: Which face to draw it in.
    ///   - variant: The raster variant, whose tier the raster is weighted by.
    ///   - region: Which half of the master the row needs.
    /// - Returns: The finished rect, or an absent one.
    func doubleGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        region: Ubiquitty.Rendering.DoubleRegion
    ) -> Ubiquitty.Rendering.AtlasGlyph
}

/// A source that rasterises OSC 66 sized glyphs at the block's size.
///
/// Without it, Core magnifies the cell-sized master — the band crop — so sized
/// text stays soft rather than wrong. A fair default, which is why Core's
/// `optionalDefaultsAreLossy` does not count these; the conformance is the
/// sharpness win the crop site reserves.
///
/// Each call names one slot-shaped window of the scaled glyph
/// (``Ubiquitty/Rendering/SizedTile``), and the answer lands on the sheet the
/// stream already samples, in an ordinary slot — no new texture, stream or
/// pass. Windows step by the destination the slot kind fills: a cell for the
/// mono entry, two cells for the wide one, the colour square for the colour
/// one.
protocol SizedGlyphSource: GlyphSource {
    /// The atlas rect for one cell-shaped window of a sized mono glyph.
    ///
    /// - Parameters:
    ///   - codePoint: The character to resolve.
    ///   - face: Which face to draw it in.
    ///   - weight: Variable-font weight, or zero for the face's own.
    ///   - phase: Subpixel phase the anchor was positioned at.
    ///   - pass: Which rect flavour the consumer maps — the subpixel quad
    ///     re-expands a margin-contracted rect, the cell-baked quad maps the
    ///     glyph box; the raster is one and the same.
    ///   - tile: Which window of the scaled glyph.
    /// - Returns: The window's rect, or an absent one.
    func sizedGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        phase: UInt32,
        pass: Ubiquitty.Rendering.GlyphPass,
        tile: Ubiquitty.Rendering.SizedTile
    ) -> Ubiquitty.Rendering.AtlasGlyph

    /// The atlas rect for one two-cell window of a sized wide glyph.
    ///
    /// - Parameters:
    ///   - codePoint: The character to resolve.
    ///   - face: Which face to draw it in.
    ///   - variant: The raster variant, whose tier the raster is weighted by.
    ///   - tile: Which window of the scaled glyph.
    /// - Returns: The window's rect, or an absent one.
    func sizedWideGlyph(
        _ codePoint: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        tile: Ubiquitty.Rendering.SizedTile
    ) -> Ubiquitty.Rendering.AtlasGlyph

    /// The atlas rect for one square window of a sized colour cluster.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - tile: Which window of the scaled cluster — the SOURCE square's
    ///     grid, whose rows need not align with the block's cell rows.
    /// - Returns: The window's rect, or an absent one.
    func sizedColorGlyph(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        tile: Ubiquitty.Rendering.SizedTile
    ) -> Ubiquitty.Rendering.AtlasGlyph
}

/// A source that draws a glyph the shaper already chose, by its identity.
///
/// Without it Core keeps every healed letterform on the strip that produced
/// it, keyed by the run's text — a key space that grows with the corpus where
/// this one saturates at the face's repertoire.
protocol ShapedGlyphSource: GlyphSource {
    /// Rasterises a shaped glyph into a mono slot Core's cache assigned.
    ///
    /// Core runs the hit path — the key, the probe, the rect — so this is
    /// reached once per glyph per miss, and owes the slot's ink-table entry as
    /// ``rasteriseMonoGlyph(_:face:variant:slot:)`` does.
    ///
    /// - Parameters:
    ///   - glyphID: The glyph the shaper chose, in `face`'s own numbering.
    ///   - face: The style it was shaped in.
    ///   - variant: The raster variant, carrying the phase and the tier.
    ///   - slot: The slot the cache assigned.
    /// - Returns: Whether the slot now holds the glyph; false keeps the caller
    ///   on the strip it already has.
    func rasteriseShapedGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        variant: UInt32,
        slot: Int32
    ) -> Bool
}

/// A source that shapes a whole grapheme cluster into one slot.
///
/// Without it, Core renders the base code point ALONE — `e` where the text said
/// `é`. That default is lossy, which is why the conformance is worth stating.
protocol ClusterGlyphSource: GlyphSource {
    /// Returns the atlas rect for a cluster, rasterising on a miss.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - face: Which face to shape it in.
    ///   - weight: Variable-font weight, or zero for the face's own.
    ///   - phase: Subpixel phase the cluster was positioned at.
    /// - Returns: The cluster's atlas rect, or an absent one.
    func clusterGlyph(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        phase: UInt32
    ) -> Ubiquitty.Rendering.AtlasGlyph

    /// Fills a cluster slot the cache has already assigned.
    ///
    /// - Parameters:
    ///   - codePoints: The cluster, base first.
    ///   - face: Which face to shape it in.
    ///   - variant: The raster variant the slot was keyed with — a subpixel
    ///     phase and a smoothing tier packed together, decoded by
    ///     `variantPhase` and `variantTier` rather than used whole.
    ///   - slot: The slot the cache assigned.
    func rasteriseClusterGlyph(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        phase: UInt32,
        slot: Int32
    ) -> Bool
}

/// Holds the source for as long as Core is calling back into it.
///
/// The table Core receives carries a raw pointer, so something has to own the
/// object it points at. This box is that owner, and its lifetime is the contract
/// the seam's `UBIQUITTY_NONESCAPABLE` tag states: a table whose box has been
/// released is a dangling context, and Core has no way to notice.
///
/// It also spares every thunk a dynamic cast. The opaque pointer is this
/// concrete class rather than an existential, so a callback is one dereference
/// and a stored property read.
/// A source that shapes a proportional run and draws its glyphs by identity
/// (Docs/proportional-text.md); Core places what it answers.
protocol ProportionalGlyphSource: GlyphSource {
    /// Fills the dedicated proportional sheet's cache and geometry.
    func bindProportionalAtlas(into binding: inout Ubiquitty.Rendering.ProportionalAtlasBinding)

    func shapeProportionalRun(
        _ codePoints: Ubiquitty.Rendering.ClusterSpan,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32
    ) -> [Ubiquitty.ProportionalShapedGlyph]
    /// Rasterises one shaped glyph into the slot Core assigned.
    func rasteriseProportionalGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32,
        slot: Int32
    ) -> Bool
    /// Rasterises one slot-sized window of a glyph drawn larger than its slot,
    /// for a DECDWL row, a DECDHL pair or an OSC 66 scale.
    func rasteriseSizedProportionalGlyph(
        _ glyphID: UInt32,
        face: Ubiquitty.Rendering.FontFace,
        weight: UInt32,
        variant: UInt32,
        tile: Ubiquitty.Rendering.SizedTile,
        slot: Int32
    ) -> Bool
}

final class GlyphBackendContext {
    /// The source every entry in the table forwards to.
    let source: GlyphSource
    /// Each capability, downcast once here so no thunk pays the conformance
    /// scan per call. A nil marks a source without that capability, and the
    /// fill below installs no entry for it — so a thunk that fires may
    /// unwrap: its installation was the proof.
    let boxSource: BoxGlyphSource?
    let wideSource: WideGlyphSource?
    let colorSource: ColorGlyphSource?
    let ligatureSource: LigatureGlyphSource?
    let doubleSource: DoubleGlyphSource?
    let clusterSource: ClusterGlyphSource?
    let shapedSource: ShapedGlyphSource?
    let wideClusterSource: WideClusterGlyphSource?
    let sizedSource: SizedGlyphSource?
    let proportionalSource: ProportionalStripSource?
    let proportionalGlyphSource: ProportionalGlyphSource?

    /// Boxes a source so a Core table can point at it.
    ///
    /// - Parameter source: The glyph source to forward to.
    init(source: GlyphSource) {
        self.source = source
        boxSource = source as? BoxGlyphSource
        wideSource = source as? WideGlyphSource
        colorSource = source as? ColorGlyphSource
        ligatureSource = source as? LigatureGlyphSource
        doubleSource = source as? DoubleGlyphSource
        clusterSource = source as? ClusterGlyphSource
        shapedSource = source as? ShapedGlyphSource
        wideClusterSource = source as? WideClusterGlyphSource
        sizedSource = source as? SizedGlyphSource
        proportionalSource = source as? ProportionalStripSource
        proportionalGlyphSource = source as? ProportionalGlyphSource
    }

    /// The context pointer Core hands back to every entry.
    var opaque: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// Resolves the box from the pointer Core passes an entry.
    ///
    /// - Parameter context: The opaque pointer the table was built with.
    /// - Returns: The box that pointer belongs to.
    static func resolve(_ context: UnsafeMutableRawPointer?) -> GlyphBackendContext {
        Unmanaged<GlyphBackendContext>.fromOpaque(context!).takeUnretainedValue()
    }

    /// The source, for entries every ``GlyphSource`` answers.
    ///
    /// - Parameter context: The opaque pointer the table was built with.
    /// - Returns: The source that pointer belongs to.
    static func source(_ context: UnsafeMutableRawPointer?) -> GlyphSource {
        resolve(context).source
    }

    /// Builds the table Core calls, filling only what the source supplies.
    ///
    /// An entry the source cannot answer is left null, which is Core's signal to
    /// use its own default rather than an error. The result borrows this box and
    /// is valid only while it lives.
    ///
    /// `colorGlyph` is left null and no emoji loses its colour for it. Core
    /// reaches colour two ways, both in `buildCellInstances` — a bound colour
    /// cache with `rasteriseColorGlyph` before the per-cell entry — and this
    /// source supplies the first pair, so the builder never
    /// asks for the second. `optionalDefaultsAreLossy` reads the entry rather
    /// than the route and reports a loss that does not happen here.
    ///
    /// - Parameter backend: The table to fill.
    func fillBackend(into backend: inout Ubiquitty.Rendering.GlyphBackend) {
        backend.context = opaque
        backend.beginFrame = { context in
            GlyphBackendContext.source(context).beginFrame()
        }
        backend.bindMonoAtlas = { context in
            var binding = Ubiquitty.Rendering.MonoAtlasBinding()
            GlyphBackendContext.source(context).bindMonoAtlas(into: &binding)
            return binding
        }
        backend.monoGlyph = { context, codePoint, face, weight, phase in
            GlyphBackendContext.source(context).monoGlyph(codePoint, face: face, weight: weight, variant: phase)
        }
        backend.primaryFacePitch = source.primaryFacePitch
        backend.shapePrimaryRun = { context, codePoints, face, weight, out, capacity in
            let shaped = GlyphBackendContext.source(context).shapePrimaryRun(codePoints, face: face, weight: weight)
            guard let out, capacity > 0, !shaped.isEmpty, shaped.count <= Int(capacity) else {
                return 0
            }
            for index in 0..<shaped.count {
                out[index] = shaped[index]
            }
            return Int32(shaped.count)
        }
        backend.rasteriseMonoGlyph = { context, codePoint, face, variant, slot in
            GlyphBackendContext.source(context).rasteriseMonoGlyph(codePoint, face: face, variant: variant, slot: slot)
        }
        backend.stageMonoCoverage = { context, slot, coverage in
            GlyphBackendContext.source(context).stageMonoCoverage(coverage, slot: slot)
        }
        if boxSource != nil {
            backend.boxGlyph = { context, codePoint, face in
                GlyphBackendContext.resolve(context).boxSource!.boxGlyph(codePoint, face: face)
            }
        }
        if wideSource != nil {
            backend.bindWideAtlas = { context in
                var binding = Ubiquitty.Rendering.WideAtlasBinding()
                GlyphBackendContext.resolve(context).wideSource!.bindWideAtlas(into: &binding)
                return binding
            }
            backend.rasteriseWideGlyph = { context, codePoint, face, variant, slot in
                GlyphBackendContext.resolve(context).wideSource!
                    .rasteriseWideGlyph(codePoint, face: face, variant: variant, slot: slot)
            }
            backend.wideGlyphPhaseCount = { context, codePoint, face in
                GlyphBackendContext.resolve(context).wideSource!.wideGlyphPhaseCount(codePoint, face: face)
            }
        }
        if colorSource != nil {
            backend.bindColorAtlas = { context in
                var binding = Ubiquitty.Rendering.ColorAtlasBinding()
                GlyphBackendContext.resolve(context).colorSource!.bindColorAtlas(into: &binding)
                return binding
            }
            backend.rasteriseColorGlyph = { context, codePoints, slot in
                GlyphBackendContext.resolve(context).colorSource!
                    .rasteriseColorGlyph(codePoints, slot: slot)
            }
        }
        backend.prepareLigatureRow = nil
        backend.finishLigaturePreparation = nil
        if ligatureSource?.canPrepareLigatures == true {
            backend.prepareLigatureRow = { context, row, pitch in
                GlyphBackendContext.resolve(context).ligatureSource!.prepareLigatureRow(row, cellWidthInPixels: pitch)
            }
            backend.finishLigaturePreparation = { context in
                GlyphBackendContext.resolve(context).ligatureSource!.finishLigaturePreparation()
            }
        }
        if ligatureSource != nil {
            backend.shapeLigatureRuns = { context, row, rowOriginXInPixels, cellWidthInPixels, pass, runs in
                GlyphBackendContext.resolve(context).ligatureSource!
                    .shapeLigatureRuns(
                        row,
                        rowOriginXInPixels: rowOriginXInPixels,
                        cellWidthInPixels: cellWidthInPixels,
                        pass: pass,
                        into: runs
                    )
            }
        }
        if doubleSource != nil {
            backend.doubleGlyph = { context, codePoint, face, variant, region in
                GlyphBackendContext.resolve(context).doubleSource!
                    .doubleGlyph(codePoint, face: face, variant: variant, region: region)
            }
        }
        if sizedSource != nil {
            backend.sizedGlyph = { context, codePoint, face, weight, phase, pass, tile in
                GlyphBackendContext.resolve(context).sizedSource!
                    .sizedGlyph(codePoint, face: face, weight: weight, phase: phase, pass: pass, tile: tile)
            }
            backend.sizedWideGlyph = { context, codePoint, face, variant, tile in
                GlyphBackendContext.resolve(context).sizedSource!
                    .sizedWideGlyph(codePoint, face: face, variant: variant, tile: tile)
            }
            backend.sizedColorGlyph = { context, codePoints, tile in
                GlyphBackendContext.resolve(context).sizedSource!
                    .sizedColorGlyph(codePoints, tile: tile)
            }
        }
        if proportionalSource != nil {
            backend.proportionalStrip = {
                context,
                codePoints,
                widthCells,
                horizontalAlign,
                penResidualInPixels,
                face,
                weight,
                variant,
                tileIndex,
                size in
                GlyphBackendContext.resolve(context).proportionalSource!
                    .proportionalStrip(
                        codePoints,
                        widthCells: widthCells,
                        horizontalAlign: horizontalAlign,
                        penResidualInPixels: penResidualInPixels,
                        face: face,
                        weight: weight,
                        variant: variant,
                        tileIndex: tileIndex,
                        size: size
                    )
            }
        }
        if proportionalGlyphSource != nil {
            backend.bindProportionalAtlas = { context in
                var binding = Ubiquitty.Rendering.ProportionalAtlasBinding()
                GlyphBackendContext.resolve(context).proportionalGlyphSource!
                    .bindProportionalAtlas(into: &binding)
                return binding
            }
            backend.shapeProportionalRun = { context, codePoints, face, weight, out, capacity in
                let shaped = GlyphBackendContext.resolve(context).proportionalGlyphSource!
                    .shapeProportionalRun(codePoints, face: face, weight: weight)
                guard let out, capacity > 0, !shaped.isEmpty, shaped.count <= Int(capacity) else {
                    return 0
                }
                for index in 0..<shaped.count {
                    out[index] = shaped[index]
                }
                return Int32(shaped.count)
            }
            backend.rasteriseProportionalGlyph = { context, glyphID, face, weight, variant, slot in
                GlyphBackendContext.resolve(context).proportionalGlyphSource!
                    .rasteriseProportionalGlyph(glyphID, face: face, weight: weight, variant: variant, slot: slot)
            }
            backend.rasteriseSizedProportionalGlyph = { context, glyphID, face, weight, variant, tile, slot in
                GlyphBackendContext.resolve(context).proportionalGlyphSource!
                    .rasteriseSizedProportionalGlyph(
                        glyphID,
                        face: face,
                        weight: weight,
                        variant: variant,
                        tile: tile,
                        slot: slot
                    )
            }
        }
        if wideClusterSource != nil {
            backend.wideClusterGlyph = { context, codePoints, face, weight, variant in
                GlyphBackendContext.resolve(context).wideClusterSource!
                    .wideClusterGlyph(
                        codePoints,
                        face: face,
                        weight: weight,
                        variant: variant
                    )
            }
        }
        if shapedSource != nil {
            backend.rasteriseShapedGlyph = { context, glyphID, face, variant, slot in
                GlyphBackendContext.resolve(context).shapedSource!
                    .rasteriseShapedGlyph(
                        glyphID,
                        face: face,
                        variant: variant,
                        slot: slot
                    )
            }
        }
        if clusterSource != nil {
            backend.clusterGlyph = { context, codePoints, face, weight, phase in
                GlyphBackendContext.resolve(context).clusterSource!
                    .clusterGlyph(
                        codePoints,
                        face: face,
                        weight: weight,
                        phase: phase
                    )
            }
            backend.rasteriseClusterGlyph = { context, codePoints, face, phase, slot in
                GlyphBackendContext.resolve(context).clusterSource!
                    .rasteriseClusterGlyph(
                        codePoints,
                        face: face,
                        phase: phase,
                        slot: slot
                    )
            }
        }
    }
}
