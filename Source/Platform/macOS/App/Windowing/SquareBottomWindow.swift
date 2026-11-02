// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SquareBottomWindow.swift — the window shape: continuous top corners, square
// bottom ones.
//
// macOS exposes no public API for per-corner window radii, so the frame's clip
// is taken over through the private `-_cornerMask` the window server reads: a
// 9-part stretchable alpha mask whose caps carry the corner shapes. The drop
// shadow follows the mask, so squaring the bottom caps squares the shadow with
// them.
//
// Being private, the hook can stop being called. Nothing here chains to
// AppKit's own implementation and nothing calls it directly, so a macOS that
// drops it leaves the window with the system shape — the shape goes dormant
// rather than the window losing its clip.
//

import AppKit
internal import UbiquittyCore

/// A window clipped to continuous top corners and square bottom ones.
@objc(UBSwiftSquareBottomWindow)
public final class SquareBottomWindow: ZoomTrackingWindow {
    private var squareBottomCornersOverride: Bool? // bool-ok: nil inherits the configured shape; false explicitly requests rounded corners.

    /// Allows a host to override the configured window shape.
    @objc
    public var hasSquareBottomCorners: Bool {
        get { squareBottomCornersOverride ?? Self.squaresBottomCorners }
        set { squareBottomCornersOverride = newValue }
    }

    /// The system window radius, which the top corners match.
    ///
    /// Exposed to Objective-C because a window that shapes its own mask and
    /// lifts its own bar uses the same radius; one spelling keeps corners and
    /// clearances from drifting apart.
    @objc
    public static let cornerRadiusInPoints: CGFloat = 16

    /// Whether the shape squares the bottom corners, from
    /// `[appearance] square_bottom_corners`.
    ///
    /// Read per sample rather than held per window: AppKit samples the mask
    /// from inside its own initialiser, before an instance has any state of
    /// its own to have been assigned. Static for the same reason: the shape
    /// is the configuration's, and no window carries one of its own.
    private static var squaresBottomCorners: Bool {
        Ubiquitty.Preferences.Effective.squareBottomCorners(Ubiquitty.Preferences.values().pointee)
    }

    /// The lift a view standing on the window's bottom edge needs to clear
    /// the shape's bottom corner, in points.
    ///
    /// Zero where the corners are square, since the frame reaches the edge
    /// and nothing curves away from what stands on it, and the corner radius
    /// where they are round, which is the lift a scroll bar's knob needs to
    /// clear the curve. The pair is spelled here alone: a window opening
    /// reads it, and so does a corner setting that moves.
    ///
    /// Fullscreen is not folded in. The mask stands aside there, and nothing
    /// re-places a bar across that transition, so an answer naming fullscreen
    /// would be one no reader maintains.
    @objc
    public static var bottomCornerClearanceInPoints: CGFloat {
        squaresBottomCorners ? 0 : cornerRadiusInPoints
    }

    /// The mask the window server clips this window's frame to.
    ///
    /// A nil answer is AppKit's own shape, which is what both opt-outs want:
    /// fullscreen fills the display edge to edge, where a rounded top would
    /// clip the content against the screen and read wrong under the menu bar,
    /// and the setting turned off asks for the system's four rounded corners.
    ///
    /// - Returns: The mask image, or nil to take AppKit's shape.
    @objc(_cornerMask)
    public func cornerMask() -> NSImage? {
        guard !styleMask.contains(.fullScreen), hasSquareBottomCorners else {
            return nil
        }
        return WindowCornerMask.topRoundedSquareBottom(radius: SquareBottomWindow.cornerRadiusInPoints)
    }
}
