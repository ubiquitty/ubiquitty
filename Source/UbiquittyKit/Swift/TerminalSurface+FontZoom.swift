// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+FontZoom.swift — the window's font size, as an offset over
// the configured one.
//
// A zoom is an offset rather than a size. The reader configures a size; a
// window moves away from it and back, and "back" has to land exactly where it
// started — which it cannot if each step rewrites the size it was computed
// from, because the clamp at either end quietly eats the difference.
//
// The range, the step and the clamp are Core's (Preferences::Zoom), shared with
// the macOS window controller's Cmd-+/-/0. A frontend that spelled its own
// bounds would let one arm zoom to a size another refuses to draw.

import CoreGraphics
import QuartzCore
internal import UbiquittyCore

extension TerminalSurface {
    /// Applies a configured font and clears this surface's temporary zoom.
    ///
    /// - Parameters:
    ///   - familyName: The family or PostScript face name.
    ///   - pointSize: The configured em size, clamped to the supported range.
    /// - Returns: Whether the renderer could adopt the font.
    @discardableResult
    public func applyFont(familyName: String, pointSize: Double) -> Bool {
        guard pointSize.isFinite, let renderer = renderer as? SurfaceRenderer else { return false }
        let size = Ubiquitty.Preferences.Zoom.clampFontZoom(pointSize)
        var didAdopt = false
        let change = {
            didAdopt = renderer.adopt(pointSize: size, familyName: familyName, typography: renderer.typography)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let host = cellMetricChangeHost {
            host(change)
        } else {
            change()
            if didAdopt { resizeGridToBounds() }
        }
        CATransaction.commit()
        guard didAdopt else { return false }
        configuredPointSize = size
        fontZoomOffset = 0
        drive.publishActualFont(family: renderer.familyName, sizePoints: renderer.pointSize)
        needsDisplay = true
        return true
    }

    /// The family this surface's regular text is drawn in.
    ///
    /// The configured family, spelled as configured, when that family is
    /// drawn: a family the framework ships, GNU Unifont, which the framework
    /// draws itself, or a family CoreText finds under any of its family, full
    /// or PostScript names. A family that is not found is drawn in a
    /// substitute, and this is CoreText's name for the substitute's family. A
    /// typography whose `unifontScale` puts another family on the framework's
    /// bitmap face draws GNU Unifont, and this is GNU Unifont. It therefore
    /// differs from the configured family exactly when a substitute is drawn.
    ///
    /// - Returns: The family, or nil for a surface with no renderer or with a
    ///   renderer the framework did not build.
    public var resolvedFontFamily: String? {
        (renderer as? SurfaceRenderer)?.resolvedFontFamily
    }

    /// The em size this surface draws at right now.
    ///
    /// - Returns: The configured size with the window's offset applied.
    public var zoomedPointSize: Double {
        Ubiquitty.Preferences.Zoom.zoomedFontSize(configuredPointSize, fontZoomOffset)
    }

    /// Sets the window's offset over the configured font size.
    ///
    /// Clamped by Core, so an offset past either end of the range settles at
    /// the end rather than being refused — a pinch runs past the limit
    /// constantly and a gesture that stopped answering there would read as the
    /// terminal having stopped responding.
    ///
    /// - Parameter offset: Points over the configured size; zero restores it.
    public func applyFontZoom(offset: Double) {
        guard configuredPointSize > 0, let renderer else { return }
        let wanted = Ubiquitty.Preferences.Zoom.zoomedFontSize(configuredPointSize, offset)
        // Re-derived from the clamped size, so the stored offset can never name
        // a size the renderer is not drawing.
        let settled = Ubiquitty.Preferences.Zoom.fontZoomOffsetForSize(configuredPointSize, wanted)
        guard settled != fontZoomOffset else { return }
        fontZoomOffset = settled
        // The cell size moves, so the grid no longer fits the view: re-fit
        // before drawing, or the next frame draws the old row count at the new
        // scale and the program is told nothing about it. A host that owns
        // the window answers instead — the window follows the font, or holds
        // and reflows.
        // No implicit animation: the layer's bounds and the grid's letterbox
        // must move together, or a frame draws the old grid in the new viewport
        // and shows a black letterbox strip.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let host = cellMetricChangeHost {
            host { renderer.adopt(pointSize: wanted) }
        } else {
            renderer.adopt(pointSize: wanted)
            resizeGridToBounds()
        }
        CATransaction.commit()
        if let actualRenderer = renderer as? SurfaceRenderer {
            drive.publishActualFont(family: actualRenderer.familyName, sizePoints: actualRenderer.pointSize)
        }
        needsDisplay = true
    }

    /// Steps the zoom by Core's zoom step, a whole point per step.
    ///
    /// - Parameter steps: How many steps, negative to zoom out.
    public func stepFontZoom(by steps: Int) {
        guard steps != 0 else { return }
        let step = Ubiquitty.Preferences.Zoom.fontZoomStep
        applyFontZoom(offset: fontZoomOffset + Double(steps) * step)
    }

    /// Restores the configured size.
    public func resetFontZoom() {
        applyFontZoom(offset: 0)
    }
}
