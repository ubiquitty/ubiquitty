// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
internal import UbiquittyCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Applying a theme to a surface, for either shell, and the colours a host
// paints its own chrome with.
//
// A theme is a write to the terminal's palette, not a call on the renderer:
// the renderer resolves every cell colour through that palette and keys its
// caches on the palette epoch, so a theme applied to the model reaches the
// pixels by itself.
//
// Every colour here is Core's: it adapts a theme under the process's palette
// adaptation, applies a program's OSC overrides, and narrows the palette to the
// 8-bit channels a theme is written in. This file only carries the channels
// across the module wall.

/// One colour of a terminal palette, as the 8-bit channels Core holds.
///
/// Channels rather than a platform colour, because three channels are a colour
/// only once a colour space reads them. A surface reads them as sRGB, or as
/// Display P3 when its ``SurfaceStyle/usesDisplayP3`` is set, and the same three
/// numbers are a different colour under each. A theme read without a surface
/// has no space yet. ``platformColor(usesDisplayP3:)`` makes the colour once
/// the space is known.
public struct TerminalColor: Hashable, Sendable {
    /// The red channel.
    public var red: UInt8
    /// The green channel.
    public var green: UInt8
    /// The blue channel.
    public var blue: UInt8
    /// The opacity the grid draws text in this colour with: 255 except where a
    /// theme dims an ANSI colour.
    public var alpha: UInt8

    /// Creates a colour from its channels.
    ///
    /// - Parameters:
    ///   - red: The red channel.
    ///   - green: The green channel.
    ///   - blue: The blue channel.
    ///   - alpha: The opacity, opaque by default.
    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Carries one of Core's colours across.
    ///
    /// - Parameter color: The colour Core resolved.
    internal init(_ color: Ubiquitty.ColorRGBA) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// The colour, read in the space a surface draws in.
    ///
    /// - Parameter usesDisplayP3: Whether to read the channels as Display P3,
    ///   as a surface whose ``SurfaceStyle/usesDisplayP3`` is set does; sRGB
    ///   otherwise.
    /// - Returns: The platform colour.
    public func platformColor(usesDisplayP3: Bool) -> PlatformColor {
        let unit = { (channel: UInt8) in CGFloat(channel) / 255 }
        return usesDisplayP3
            ? PlatformColor(displayP3Red: unit(red), green: unit(green), blue: unit(blue), alpha: unit(alpha))
            : PlatformColor(srgbRed: unit(red), green: unit(green), blue: unit(blue), alpha: unit(alpha))
    }
}

/// A terminal's palette colours: its default text and background, its cursor,
/// its sixteen ANSI colours, and the selection colours a program set.
///
/// What a theme draws (``TerminalSurface/colors(ofTheme:)``), what a surface
/// draws now (``TerminalSurface/colors``), and what the observer is handed when
/// that moves
/// (``TerminalSurfaceObserver/terminalSurface(_:didChangeColors:)``).
public struct TerminalColors: Hashable, Sendable {
    /// The default text colour, which OSC 10 sets.
    public var foreground: TerminalColor
    /// The default background, which OSC 11 sets.
    public var background: TerminalColor
    /// The cursor colour, which OSC 12 sets.
    public var cursor: TerminalColor
    /// ANSI colours 0 through 15, which OSC 4 sets: black, red, green, yellow,
    /// blue, magenta, cyan and white, then their bright twins in that order.
    public var ansi: [TerminalColor]
    /// The selection background a program set with OSC 17, or nil.
    ///
    /// No theme names one, so a theme's is nil, and a surface's is nil until a
    /// program sets one and again once it resets it (OSC 117). While it is
    /// nil the grid fills a selection in the `[selection]` style: the
    /// platform's selection colour under the text, or a tint over it.
    public var selectionBackground: TerminalColor?
    /// The selected text colour a program set with OSC 19, or nil, when
    /// selected text keeps its own colour. OSC 119 resets it.
    public var selectionForeground: TerminalColor?

    /// Carries Core's colours across.
    ///
    /// - Parameter colors: The colours Core resolved.
    internal init(_ colors: Ubiquitty.Rendering.PaletteColors) {
        foreground = TerminalColor(colors.foreground)
        background = TerminalColor(colors.background)
        cursor = TerminalColor(colors.cursor)
        ansi = (0..<Ubiquitty.Rendering.ansiColorCount).map { TerminalColor(colors.ansi[$0]) }
        selectionBackground = colors.selectionBackground.value.map { TerminalColor($0) }
        selectionForeground = colors.selectionForeground.value.map { TerminalColor($0) }
    }
}

extension TerminalSurface {
    /// The catalog identity of the session's reset palette.
    public var currentThemeName: String? {
        guard let name = Ubiquitty.Themes.themeName(drive.currentThemeIndex()) else { return nil }
        return String(cString: name)
    }

    /// The themes a picker can offer, in the order Core holds them.
    public static var themeNames: [String] {
        (0..<Int(Ubiquitty.Themes.themeCount()))
            .compactMap { index in
                guard let name = Ubiquitty.Themes.themeName(Int32(index)) else { return nil }
                return String(cString: name)
            }
    }

    /// Whether the theme at `index` is a dark one.
    ///
    /// Core's own answer rather than a second reading of the colours: a picker
    /// that grouped them differently would disagree with the scheme the program
    /// is told about.
    ///
    /// - Parameter index: The theme's index in ``themeNames``.
    /// - Returns: Whether it is dark.
    public static func isThemeDark(at index: Int) -> Bool {
        Ubiquitty.Themes.isThemeDark(Int32(index))
    }

    /// The colours a theme draws, read without a surface.
    ///
    /// The colours applying the theme draws: Core resolves them under the
    /// palette adaptation an apply reads, so chrome painted from a theme before
    /// it is applied matches the terminal after. That adaptation is the
    /// process's. The Ubiquitty app sets it from its colour-vision setting and
    /// the system's Increase Contrast; the Kit sets none, so in another host a
    /// theme's colours are the ones the theme names.
    ///
    /// - Parameter name: The theme's name, as ``themeNames`` lists it. A name
    ///   that differs only in ASCII case matches when no name matches exactly.
    /// - Returns: The colours, or nil when Core has no theme by that name.
    public static func colors(ofTheme name: String) -> TerminalColors? {
        guard let index = themeIndex(named: name), let colors = Ubiquitty.Themes.themeColors(index).value else {
            return nil
        }
        return TerminalColors(colors)
    }

    /// The colours the surface's grid draws.
    ///
    /// Its theme's, with each colour a program has set through OSC 4, 10, 11,
    /// 12, 17 or 19 in place until the program resets it. A remote surface's
    /// are its host's. While a program holds a synchronized update (DEC 2026)
    /// open the grid keeps the frame from before it, and these stay that
    /// frame's until the update ends or the terminal gives up waiting on it: a
    /// colour the program sets inside the update is not here before then, and
    /// one it puts back inside the update never is. They are what
    /// ``TerminalSurfaceObserver/terminalSurface(_:didChangeColors:)`` carries
    /// when they move. The whole-screen swap DECSCNM makes is drawn over
    /// these, not written into them, so a visual bell does not move them.
    public var colors: TerminalColors {
        TerminalColors(drive.readCoherentColors().colors)
    }

    /// Applies a theme to this surface.
    ///
    /// Core applies the process's palette adaptation (see
    /// ``colors(ofTheme:)``), updates the reset baseline, and notifies programs
    /// that subscribe to color-scheme changes. Remote sessions send the request
    /// to their host and receive the palette in its snapshots. The observer
    /// hears the new colours through
    /// ``TerminalSurfaceObserver/terminalSurface(_:didChangeColors:)``: from
    /// this call for a local session, unless a program holds a synchronized
    /// update open, and when the host's palette arrives for a remote one.
    ///
    /// - Parameter index: The theme's index in ``themeNames``.
    /// - Returns: Whether Core had a theme at that index and it applied.
    @discardableResult
    public func applyTheme(at index: Int) -> Bool {
        guard let themeIndex = Int32(exactly: index), drive.applyTheme(themeIndex) else { return false }
        publishModelWrite()
        return true
    }

    /// Applies the theme with the given name to this surface.
    ///
    /// ``applyTheme(at:)`` by name, which is what a host keeps: an index moves
    /// when the catalog gains a theme, and a name does not. The observer hears
    /// the new colours as ``applyTheme(at:)`` describes.
    ///
    /// - Parameter name: The theme's name, as ``themeNames`` lists it. A name
    ///   that differs only in ASCII case matches when no name matches exactly.
    /// - Returns: False when Core has no theme by that name, which leaves the
    ///   surface's colours as they were, or when the session took no palette.
    public func applyTheme(named name: String) -> Bool {
        guard let index = Self.themeIndex(named: name) else { return false }
        return applyTheme(at: Int(index))
    }

    /// Core's index for a theme name.
    ///
    /// Core takes the name as a C string, which ends at its first NUL, so a
    /// name holding one is refused here rather than read as its prefix.
    ///
    /// - Parameter name: The name, matched exactly and then ignoring ASCII case.
    /// - Returns: The index, or nil when no theme bears the name.
    private static func themeIndex(named name: String) -> Int32? {
        guard !name.utf8.contains(0) else { return nil }
        let index = name.withCString { Ubiquitty.Themes.indexForName($0) }
        return index >= 0 ? index : nil
    }
}
