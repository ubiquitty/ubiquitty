// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SizedWindowRaster.swift — CoreText's half of one window of a sized block.
//
// Core owns what a sized window is (SizedMaster.h): which master it is cut from,
// where the glyph stands in that master, which texel the window begins at and
// the sub-texel shift the master is drawn with. Every arm that draws a sized
// block asks Core for those and keeps only the drawing, so a window is the same
// picture on Apple, Linux, the browser and the portable renderer.
//
// What is left here is what only CoreText can do: draw the glyph into a plane
// of the size Core names, at the pen Core placed it at, under the scale the
// master selects. The window is then lifted out by Core's cut and handed to the
// sheet to upload.

import CoreGraphics
import CoreText
import Foundation
import UbiquittyCore

/// How a sized window's glyph is placed in its master.
enum SizedWindowPen {
    /// The face's own glyph: Core centres its advance in the master, as it does
    /// for every arm, and moves it by the shift.
    case advanceCentred
    /// A glyph the sheet places itself — a fallback face's ink-centred pen, or the
    /// wide sheet's — at this pen in the unscaled slot, bottom-left origin. The
    /// master draws it where the box's own pen is magnified to, moved by the shift.
    case placed(CGPoint)
}

/// Everything CoreText needs to draw one sized window's master.
struct SizedWindowFace {
    /// The glyph the character maps to, in `font`.
    let glyph: CGGlyph
    /// The face that carries it.
    let font: CTFont
    /// The same face widened on its `wdth` axis, for a block on a doubled row;
    /// `nil` where the family has no room to widen. Core decides whether the
    /// widened face is drawn, from the two advances.
    let widened: (glyph: CGGlyph, font: CTFont)?
    /// Where the face's `wdth` axis stands and how far it reaches.
    let room: Ubiquitty.Rendering.WidthAxisRoom
    /// How the glyph is placed in the master.
    let pen: SizedWindowPen
}

/// Draws the masters sized windows are cut from and lifts the windows out of them.
///
/// Not thread-safe: the planes and the window buffer are reused across calls, as
/// the rasteriser's are. The frame build is the only caller.
final class SizedWindowRaster {
    /// One plane's size, which the planes are kept by.
    private struct PlaneSize: Hashable {
        let width: Int
        let height: Int
    }

    /// How many plane sizes are kept at once. A block at one scale asks one size
    /// of each sheet; this holds a few scales of both without growing with use.
    private static let planeCapacity = 8

    private var planes: [PlaneSize: GlyphRasterizer] = [:]
    private var planeOrder: [PlaneSize] = []
    private var window: [UInt8] = []

    /// Draws one window of a sized block.
    ///
    /// - Parameters:
    ///   - face: The glyph, its face and how it is placed.
    ///   - tile: Which window of which block.
    ///   - phase: The anchor's raster variant; its phase bits are the pen's fraction.
    ///   - canvas: The slot canvas the window fills.
    ///   - baselinePenInPixels: The pen's height above the slot's bottom.
    ///   - boostCap: The wide sheet's growth multiplier, zero for a sheet that draws natural.
    ///   - style: The raster style.
    /// - Returns: `canvas.width * canvas.height` bytes of coverage, top row first,
    ///   or `nil` when Core sized no master.
    func rasterise(
        _ face: SizedWindowFace,
        tile: Ubiquitty.Rendering.SizedTile,
        phase: UInt32,
        canvas: Ubiquitty.Rendering.SizedWindowCanvas,
        baselinePenInPixels: CGFloat,
        boostCap: CGFloat,
        style: GlyphRasterizer.Style
    ) -> [UInt8]? {
        var glyph = face.glyph
        let advance = CTFontGetAdvancesForGlyphs(face.font, .horizontal, &glyph, nil, 1)
        var widenedAdvance: Double = 0
        if let widened = face.widened, tile.widthScale == 2 {
            var widenedGlyph = widened.glyph
            widenedAdvance = CTFontGetAdvancesForGlyphs(widened.font, .horizontal, &widenedGlyph, nil, 1)
        }
        let master = Ubiquitty.Rendering.selectSizedMaster(tile, face.room, advance, widenedAdvance)
        let cut = Ubiquitty.Rendering.planSizedWindow(master, tile, phase, canvas)
        let width = Int(cut.masterWidth)
        let height = Int(cut.masterHeight)
        guard width > 0, height > 0, canvas.width > 0, canvas.height > 0 else {
            return nil
        }

        // The master Core selected decides the face: a widening it found on the
        // axis is drawn from the widened face, and the stretch it left over is
        // the outline's horizontal scale; where it found none, the base face is
        // stretched by the whole doubling.
        var drawnGlyph = face.glyph
        var drawnFont = face.font
        if master.widthAxisCoordinate > 0, let widened = face.widened {
            drawnGlyph = widened.glyph
            drawnFont = widened.font
        }
        let down = master.scale.value()
        let across = master.horizontalMagnification().value()
        let scaleX = down * master.horizontalScale
        let pen = Self.penInMaster(
            face.pen,
            cut: cut,
            canvas: canvas,
            drawnAdvance: across * advance,
            baselinePenInPixels: baselinePenInPixels,
            masterHeight: height
        )

        let plane = self.plane(width: width, height: height)
        guard let plane else {
            return nil
        }
        plane.rasterise(
            master: drawnGlyph,
            in: drawnFont,
            at: pen,
            scaleX: scaleX,
            scaleY: down,
            boostCappedTo: boostCap,
            within: CGSize(width: CGFloat(canvas.width), height: CGFloat(canvas.height)),
            style: style
        )

        let windowBytes = Int(canvas.width) * Int(canvas.height)
        if window.count != windowBytes {
            window = [UInt8](repeating: 0, count: windowBytes)
        }
        plane.coverage.withUnsafeBufferPointer { masterBytes in
            window.withUnsafeMutableBufferPointer { windowBuffer in
                Ubiquitty.Rendering.cutSizedWindow(
                    Ubiquitty.Rendering.SizedMasterBytes(masterBytes),
                    cut,
                    canvas,
                    Ubiquitty.Rendering.SizedWindowBytes(windowBuffer)
                )
            }
        }
        return window
    }

    /// Where CoreText draws the glyph, in the plane's pixels from its bottom-left.
    ///
    /// Core's placement gives the pen in whole pixels and a fraction, or the
    /// box's corner for a glyph the sheet places and the shift that carries it to
    /// the window, and the baseline with the shift down
    /// (``sizedMasterBaselineFromTop``). The pen is returned exact on both axes:
    /// every band of a block is cut from its own master, the part of a texel
    /// each band's place leaves differs from band to band, and only a pen drawn
    /// where Core put it lines the bands up. The master's draw positions it
    /// unquantised (``GlyphRasterizer/rasterise(master:in:at:scaleX:scaleY:boostCappedTo:within:style:)``).
    ///
    /// - Parameters:
    ///   - placement: How the glyph is placed.
    ///   - cut: Core's placement of the window in its master.
    ///   - canvas: The slot canvas the window fills.
    ///   - drawnAdvance: The glyph's advance in the master, stretch included.
    ///   - baselinePenInPixels: The pen's height above the slot's bottom.
    ///   - masterHeight: The plane's height.
    /// - Returns: The pen.
    private static func penInMaster(
        _ placement: SizedWindowPen,
        cut: Ubiquitty.Rendering.SizedWindowCut,
        canvas: Ubiquitty.Rendering.SizedWindowCanvas,
        drawnAdvance: Double,
        baselinePenInPixels: CGFloat,
        masterHeight: Int
    ) -> CGPoint {
        let across = cut.master.horizontalMagnification().value()
        let penX: Double
        var baseline = Double(baselinePenInPixels)
        switch placement {
        case .advanceCentred:
            let centred = Ubiquitty.Rendering.sizedMasterPen(Int32(cut.masterWidth), drawnAdvance, cut.master)
            penX = Double(centred.snappedPenX) + Double(centred.phase) / Double(Ubiquitty.Rendering.sizedMasterPenGrid)
        case .placed(let slotPen):
            penX = cut.boxLeft + across * (Double(slotPen.x) - Double(canvas.marginX)) + cut.blockShiftX
            baseline = Double(slotPen.y)
        }
        // The plane is bottom-up, so the pen's height is what is left of the
        // plane below the baseline.
        let penFromTop = Ubiquitty.Rendering.sizedMasterBaselineFromTop(Double(canvas.height) - baseline, cut.master)
        return CGPoint(x: penX, y: Double(masterHeight) - penFromTop)
    }

    /// The plane a master of this size is drawn into, made on first use.
    ///
    /// - Parameters:
    ///   - width: The master's width.
    ///   - height: The master's height.
    /// - Returns: The plane, or `nil` when one of that size cannot be made.
    private func plane(width: Int, height: Int) -> GlyphRasterizer? {
        let size = PlaneSize(width: width, height: height)
        if let kept = planes[size] {
            return kept
        }
        guard let made = GlyphRasterizer(width: width, height: height) else {
            return nil
        }
        if planeOrder.count >= Self.planeCapacity {
            planes[planeOrder.removeFirst()] = nil
        }
        planes[size] = made
        planeOrder.append(size)
        return made
    }
}
