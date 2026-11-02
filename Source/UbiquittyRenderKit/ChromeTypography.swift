// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ChromeTypography.swift — how large the window's own labels are drawn.
//
// The grid's size is the reader's `[font] size` and the View menu's zoom; the
// chrome around it — tab titles, the accessory pills, the hint, the tag
// markers, the pane titles — is a separate axis, so a reader who needs larger
// labels can have them without moving the cell metrics and reflowing every
// session. `[appearance] ui_font_scale` is that axis.
//
// One entry rather than a multiply at each construction: the multiply is easy
// to write and easy to forget, and a strip whose title scaled beside an
// accessory that did not is what forgetting looks like.

import CoreGraphics
import Foundation
import UbiquittyCore

/// The chrome's font sizes.
@MainActor
@objc(UBChromeTypography)
public final class ChromeTypography: NSObject {
    /// Scales a chrome font size by the reader's `[appearance] ui_font_scale`.
    ///
    /// Every label the window draws around the grid goes through this, both
    /// shells included, so a reader who set the scale gets all of them and not
    /// whichever ones a frontend remembered. The multiplier is clamped into the
    /// schema range by `Effective::uiFontScale`, so a configuration naming
    /// something outside it still yields a size worth drawing.
    ///
    /// - Parameter base: The size the label would be drawn at unscaled.
    /// - Returns: The size to draw it at.
    @objc
    public static func scaled(_ base: Double) -> Double {
        base * Ubiquitty.Preferences.Effective.uiFontScale(Ubiquitty.Preferences.values().pointee)
    }

    /// The same scale over a platform point size.
    ///
    /// - Parameter base: The size the label would be drawn at unscaled.
    /// - Returns: The size to draw it at.
    public static func scaled(_ base: CGFloat) -> CGFloat {
        CGFloat(scaled(Double(base)))
    }
}
