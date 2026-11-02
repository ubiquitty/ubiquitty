// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// FrameGeometry.swift — where a frame's grid sits inside its drawable, and how
// large one cell is, resolved once per frame.
//
// The first piece of the Swift renderer to run on the shipping frame path. It is
// the piece every pixel depends on: a cell size wrong in the last bit moves every
// glyph, so an arm that agrees here byte for byte is an arm whose remaining
// differences are its own.
//
// This type computes nothing. Every float comes back from `Ubiquitty::Rendering`
// (PaddingGeometry.h) and this type marshals. That is not deference for its own
// sake: clang contracts `a*b+c` into an FMA under -ffp-contract=on, which is the
// tree's default, and Swift does not contract. A layout scalar recomputed here
// would differ from the C++ arm in the last bit, and the two would disagree about
// a pixel with no way to attribute it. Scaling a padding by the backing scale is
// a lone multiply and is exact in both, which is why the two products below are
// allowed to be here at all.
//
// Nothing in this file is per-cell. It runs once per frame, so the crossing cost
// is a rounding error against the frame — which matters because Swift here gets
// neither PGO nor ThinLTO (Scripts/build-macos.sh applies both only to the
// C-family flags), so code that left the .mm for this module left its profile
// behind. Anything reached per row or per cell belongs in Core.

import UbiquittyCore

/// A width and a height in device pixels.
///
/// Plain scalars rather than `SIMD2`: a SIMD parameter makes the whole function
/// `Unavailable in C++` in the generated header, so a Swift declaration written
/// with one cannot be reached from C++. The
/// vector type buys nothing here — this is marshalling, and every arithmetic
/// operation on it happens in Core.
@frozen
public struct PixelExtent {
    public var width: Float
    public var height: Float

    @inlinable
    @inline(__always)
    public init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }
}

/// Where a frame's grid sits, and how large one of its cells is.
///
/// A value type with no reference members, so it crosses back to the caller in
/// registers rather than through a retain.
@frozen
public struct ResolvedFrameGeometry {
    /// The grid's top-left corner inside the drawable, in device pixels.
    public var originInPixels: PixelExtent
    /// One cell's extent in device pixels, after column-mode compression and any
    /// device-pixel snap.
    public var cellSizeInPixels: PixelExtent

    @inlinable
    @inline(__always)
    init(origin: PixelExtent, cell: PixelExtent) {
        self.originInPixels = origin
        self.cellSizeInPixels = cell
    }
}

/// Whether the frame paints edge to edge, with no padding and no extra inset.
///
/// DECSET 7402 with a `Color` letterbox suppresses the window padding, so the
/// insets are not scaled down — they are absent.
@frozen
public enum FrameEdgeMode {
    case padded
    case edgeToEdge
}

/// Resolves a frame's grid rect and cell size through the portable geometry.
///
/// - Parameters:
///   - drawableSize: The drawable's extent in device pixels.
///   - gridColumns: Columns the terminal is showing.
///   - gridRows: Rows the terminal is showing.
///   - naturalAdvance: The font's cell in points, before the backing scale.
///   - paddingLeftPoints: Left window padding in points.
///   - paddingRightPoints: Right window padding in points.
///   - paddingTopPoints: Top window padding in points.
///   - paddingBottomPoints: Bottom window padding in points.
///   - extraTopInsetPoints: Chrome reserved above the grid, in points.
///   - backingScale: Device pixels per point.
///   - edgeMode: Whether padding applies at all.
///   - isColumns132: DECCOLM, which compresses the advance to fit rather than
///     clipping the extra columns.
///   - snapsLineHeight: Whether a row boundary lands on a whole device pixel.
/// - Returns: The grid origin and the resolved cell, both in device pixels.
@inlinable
public func resolveFrameGeometry(
    drawableSize: PixelExtent,
    gridColumns: Int32,
    gridRows: Int32,
    naturalAdvance: PixelExtent,
    paddingLeftPoints: Float,
    paddingRightPoints: Float,
    paddingTopPoints: Float,
    paddingBottomPoints: Float,
    extraTopInsetPoints: Float,
    backingScale: Float,
    edgeMode: FrameEdgeMode,
    isColumns132: Bool,
    snapsLineHeight: Bool
) -> ResolvedFrameGeometry {
    // A lone multiply, exact in both languages. Anything shaped `a*b+c` would
    // not be, and none is written here.
    let insets: Ubiquitty.Rendering.EdgeInsets =
        switch edgeMode {
        case .edgeToEdge:
            Ubiquitty.Rendering.EdgeInsets()
        case .padded:
            Ubiquitty.Rendering.EdgeInsets(
                left: paddingLeftPoints * backingScale,
                right: paddingRightPoints * backingScale,
                top: paddingTopPoints * backingScale,
                bottom: paddingBottomPoints * backingScale
            )
        }
    let extraTop: Float =
        switch edgeMode {
        case .edgeToEdge: 0
        case .padded: extraTopInsetPoints * backingScale
        }

    let content = Ubiquitty.Rendering.resolveGridContentRect(
        Ubiquitty.FloatSize(width: drawableSize.width, height: drawableSize.height),
        insets,
        extraTop
    )

    let cell = Ubiquitty.Rendering.resolveCellSize(
        content,
        Ubiquitty.GridSize(columns: gridColumns, rows: gridRows),
        Ubiquitty.FloatSize(
            width: naturalAdvance.width * backingScale,
            height: naturalAdvance.height * backingScale
        ),
        isColumns132 ? .Columns132 : .Standard,
        snapsLineHeight ? .Snapped : .Unsnapped,
        backingScale
    )

    return ResolvedFrameGeometry(
        origin: PixelExtent(width: content.origin.x, height: content.origin.y),
        cell: PixelExtent(width: cell.width, height: cell.height)
    )
}
