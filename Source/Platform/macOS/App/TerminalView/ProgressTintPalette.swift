// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// ProgressTintPalette.swift — the colours macOS has of its own for a status mark.
//
// Core decides what a mark is drawn in (`App.statusMarkInk`): the colour the
// pane's theme names for it, or, where the theme names none, the platform's.
// What is here is the platform's half and nothing else: that macOS has an
// accent, a dimmed grey, an alert red and a system blue, and which is which.
// It is one table because the content bar, the per-pane bars, the tab-button
// bar and the inactive tab's ring are the same indicator in four slots — a
// second table is how one of them comes to dim to a different grey.

import AppKit
import UbiquittyCore

/// The macOS colours for Core's progress tint roles.
@MainActor
@objc(UBProgressTintPalette)
public final class ProgressTintPalette: NSObject {
    /// That macOS has a colour of its own for every one of these marks.
    private static var platformColors: Ubiquitty.App.PlatformStatusColors {
        var platform = Ubiquitty.App.PlatformStatusColors()
        platform.hasProgress = true
        platform.hasProgressInactive = true
        platform.hasProgressError = true
        platform.hasNotification = true
        return platform
    }

    /// The colour a status mark is drawn in.
    ///
    /// - Parameters:
    ///   - mark: The mark.
    ///   - colors: The pane's theme's status colours.
    /// - Returns: The theme's colour where it names one, else the system's.
    package static func color(for mark: Ubiquitty.App.StatusMark, colors: Ubiquitty.Themes.StatusColors) -> NSColor {
        let ink = Ubiquitty.App.statusMarkInk(mark, colors, platformColors)
        guard ink.isPlatformColor else {
            return NSColor(
                srgbRed: CGFloat(ink.color.red) / 255.0,
                green: CGFloat(ink.color.green) / 255.0,
                blue: CGFloat(ink.color.blue) / 255.0,
                alpha: 1.0
            )
        }
        switch mark {
        case .ProgressError:
            // Never dimmed: an error is an alert, and an alert a backgrounded
            // window greys out is one nobody reads.
            return .systemRed
        case .ProgressInactive:
            // AppKit dims its own controls off the accent in an inactive
            // window; a bar that kept the accent would read as the one live
            // thing on a window that is not.
            return .systemGray
        case .Notification:
            // The system's blue, not the reader's accent: this one says the
            // system has something for them rather than that the terminal does.
            return .systemBlue
        default:
            return .controlAccentColor
        }
    }

    /// The colour one tint role is drawn in.
    ///
    /// - Parameters:
    ///   - role: The role `Ubiquitty::OSC::progressTint` ranked.
    ///   - colors: The pane's theme's status colours.
    /// - Returns: The colour.
    package static func color(forTintRole role: Ubiquitty.OSC.ProgressTint, colors: Ubiquitty.Themes.StatusColors) -> NSColor {
        color(for: Ubiquitty.App.progressStatusMark(role), colors: colors)
    }

    /// The role Core ranks for a slot that stands for a whole window.
    ///
    /// The content-top bar and the tab-button bar are the degenerate
    /// single-pane case — one focused pane — so they track window activity
    /// alone, which is what Core's parameters say when they are passed that
    /// way. Spelled once here rather than at each call, because a transposed
    /// pair reads as a legitimate call and dims the wrong bar.
    ///
    /// - Parameters:
    ///   - state: A `Ubiquitty::OSC::ProgressState`, as stored on the wire.
    ///   - isWindowActive: Whether the window is the active one on screen.
    ///   - colors: The titled pane's theme's status colours.
    /// - Returns: The colour the slot is drawn in.
    package static func colorForWindowSlot(state: UInt8, isWindowActive: Bool, colors: Ubiquitty.Themes.StatusColors) -> NSColor {
        let role = Ubiquitty.OSC.progressTint(
            state,
            .Focused,
            .SinglePane,
            isWindowActive ? .Active : .Background
        )
        return color(forTintRole: role, colors: colors)
    }
}
