// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
internal import UbiquittyCore

// Applying a theme to a surface, for either shell.
//
// A theme is a write to the terminal's palette, not a call on the renderer:
// the renderer resolves every cell colour through that palette and keys its
// caches on the palette epoch, so a theme applied to the model reaches the
// pixels by itself.

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

    /// Applies a theme to this surface.
    ///
    /// Core applies accessibility adaptation, updates the reset baseline, and
    /// notifies programs that subscribe to color-scheme changes. Remote sessions
    /// send the request to their host and receive the palette in its snapshots.
    ///
    /// - Parameter index: The theme's index in ``themeNames``.
    /// - Returns: Whether Core had a theme at that index and it applied.
    @discardableResult
    public func applyTheme(at index: Int) -> Bool {
        guard let themeIndex = Int32(exactly: index) else { return false }
        return drive.applyTheme(themeIndex)
    }
}
