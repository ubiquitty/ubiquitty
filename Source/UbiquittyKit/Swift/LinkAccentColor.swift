// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// LinkAccentColor.swift — the colour a hovered link is emphasised in.
//
// The system's own blue rather than the theme's link colour. A resting link is
// part of the page and takes the palette's legible blue against whatever
// background the theme paints; the Command-hover emphasis is a transient answer
// to "this one would open", and answering it in the colour the reader's system
// uses for every other affordance is what makes it read as one.
//
// One entry because every renderer draws the same hover: a `simd_float4`
// and a `Rendering::Vec4` are two spellings of a number rather than two
// spellings of a rule. Split in two, a system accent that is not blue would
// move one renderer and leave the other on whatever it had been given.
//
// The blue is resolved under the plain light or dark appearance, never a
// vibrant one. A view inside the window's blur backdrop draws under a vibrant
// appearance, and AppKit's vibrant system blue is made to be blended with the
// material behind it, which AppKit does for its own controls. A terminal frame
// is blended with nothing, so that variant drew as itself: a darker blue than
// every control beside it, and a different blue from a frame assembled outside
// the view's display. The hover reads the surface's own appearance for the
// same reason, rather than whichever is current while a frame is assembled.

import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// The Command-hover emphasis colour.
@objc(UBLinkAccentColor)
public final class LinkAccentColor: NSObject {
    /// What to draw with where the system has no accent to ask.
    ///
    /// The blue AppKit itself resolves on a stock installation, so a platform
    /// with no `NSColor` and a conversion that failed both land on the colour
    /// the reader would have seen anyway.
    private static let fallback = (red: 0.15, green: 0.5, blue: 1.0)

    #if canImport(AppKit)
    /// The appearances the accent is resolved under. A vibrant appearance
    /// resolves as the light or dark one it is made from.
    private static let resolvingAppearances: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    /// The accent as AppKit resolves it for the current drawing appearance,
    /// already converted to sRGB.
    ///
    /// Converted here rather than at each reader: `systemBlue` is a dynamic
    /// catalog colour with no components of its own, and a caller that reads
    /// `redComponent` off the unconverted colour raises. Converted once, both
    /// arms read components from it directly.
    @objc
    public static var color: NSColor {
        color(under: NSAppearance.currentDrawing())
    }

    /// The accent as AppKit resolves it for one view's appearance, already
    /// converted to sRGB.
    ///
    /// - Parameter appearance: The appearance of the view drawing it, or nil
    ///   for the light one.
    /// - Returns: The system blue under the light or dark appearance the given
    ///   one matches, so a vibrant appearance answers as the plain one.
    public static func color(under appearance: NSAppearance?) -> NSColor {
        let name = appearance?.bestMatch(from: resolvingAppearances) ?? .aqua
        var resolved: NSColor?
        (NSAppearance(named: name) ?? NSAppearance(named: .aqua))?
            .performAsCurrentDrawingAppearance {
                resolved = NSColor.systemBlue.usingColorSpace(.sRGB)
            }
        return resolved ?? NSColor(srgbRed: fallback.red, green: fallback.green, blue: fallback.blue, alpha: 1.0)
    }

    /// The accent's straight sRGB components for one view's appearance, each
    /// 0 to 1.
    ///
    /// - Parameter appearance: The appearance of the view drawing it.
    /// - Returns: The components of ``color(under:)``.
    public static func components(under appearance: NSAppearance?) -> (red: Double, green: Double, blue: Double) {
        let resolved = color(under: appearance)
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
    }
    #endif

    /// The accent's straight sRGB components for the current drawing
    /// appearance, each 0 to 1.
    public static var components: (red: Double, green: Double, blue: Double) {
        #if canImport(AppKit)
        return components(under: NSAppearance.currentDrawing())
        #else
        return fallback
        #endif
    }
}
