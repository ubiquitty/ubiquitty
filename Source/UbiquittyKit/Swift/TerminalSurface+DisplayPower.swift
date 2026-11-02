// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+DisplayPower.swift — the Linux-console display blank.
//
// console_codes' CSI 9/13/14 ] reach Core, which holds whether the program has
// the display blanked and wakes it on CSI 13 ]. A Metal view has no monitor
// sync to cut, so a blanked display is a black layer over the whole view —
// above the Metal layer and every piece of chrome drawn beside it — and a lit
// one is that layer gone. The cover is what the program asked for and stays
// until the display is woken, so hiding the drawable under it is the requested
// effect rather than a paper-over of something transient.
//
// The state is read off the snapshot each drain publishes, as the password
// badge's is: this shell installs no `WindowClient` for Core to tell.

import QuartzCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension TerminalSurface {
    /// Covers the view while the program has the display blanked, and takes
    /// the cover away once the display is lit again.
    ///
    /// - Parameter isBlanked: The DPMS state the drain published.
    internal func updateDisplayBlank(isBlanked: Bool) {
        guard isBlanked else {
            displayBlankCover?.removeFromSuperlayer()
            return
        }
        #if canImport(AppKit)
        guard let host = layer else { return }
        #else
        let host = layer
        #endif
        let cover = displayBlankCover ?? Self.makeDisplayBlankCover()
        displayBlankCover = cover
        if cover.superlayer !== host {
            host.addSublayer(cover)
        }
        layoutDisplayBlankCover()
    }

    /// Sizes the cover to the view, which a sublayer is not by itself.
    internal func layoutDisplayBlankCover() {
        guard let cover = displayBlankCover, cover.superlayer != nil else { return }
        cover.frame = bounds
    }

    /// Whether the black cover stands over the view.
    package var isDisplayBlankCoverShown: Bool {
        displayBlankCover?.superlayer != nil
    }

    /// The cover itself, for a reader asking what it covers.
    package var displayBlankCoverForTesting: CALayer? {
        displayBlankCover
    }

    /// Makes the cover: opaque black, ordered above every sibling layer, and
    /// moved without the implicit animation a sublayer's geometry otherwise
    /// gets, so it never trails a resize.
    private static func makeDisplayBlankCover() -> CALayer {
        let cover = CALayer()
        cover.backgroundColor = CGColor(gray: 0, alpha: 1)
        cover.isOpaque = true
        cover.zPosition = .greatestFiniteMagnitude
        cover.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        return cover
    }
}
