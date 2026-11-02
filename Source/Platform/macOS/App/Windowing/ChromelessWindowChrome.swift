// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// ChromelessWindowChrome.swift — the composite a window without a title bar is.
//
// "Hide the title bar" is not one switch. The `titled` style mask STAYS —
// clearing it makes a borderless window, which loses the rounded corners and
// the drop shadow a reader expects of a window — and what happens instead is
// that the content grows up under a title row emptied piece by piece: the
// title text, the hairline that would otherwise rule a line across the grid,
// the three standard buttons, and every titlebar accessory. An accessory is
// two objects and both have to go: hiding the controller alone leaves its view
// drawing its labels over the terminal.
//
// Every piece is reversible and the whole thing is idempotent, because a
// config reload and a theme change both re-run it on a window that is already
// in the state it asks for.
//
// The body stands in for the missing drag handle; which modifiers arm that is
// `Input::windowDragArmed`, and both shells read this window's own chrome
// rather than the configured default, so a reader who hid one window's bar can
// still move it by its body while the window beside it keeps a bar to grab.

import AppKit
internal import UbiquittyCore

/// The window-level pieces of a chromeless window, applied together.
@MainActor
@objc(UBChromelessWindowChrome)
public final class ChromelessWindowChrome: NSObject {
    /// Puts a window into, or takes it out of, the chromeless composite.
    ///
    /// - Parameters:
    ///   - isChromeless: Whether the window carries no title bar.
    ///   - window: The window to dress.
    @objc(applyChromeless:toWindow:)
    public static func apply(_ isChromeless: Bool, to window: NSWindow) {
        if isChromeless {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.titleVisibility = isChromeless ? .hidden : .visible
        // Nothing should rule a line across the body at the title row's
        // underside.
        window.titlebarSeparatorStyle = isChromeless ? .none : .automatic
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = isChromeless
        }
        syncAccessories(in: window, isChromeless: isChromeless)
    }

    /// Makes a window's titlebar accessories agree with its chrome.
    ///
    /// Called again whenever one is added, because an accessory raised after
    /// the composite was applied — a session's pill, a build's badge — has a
    /// title row to live in only while the window has one, and otherwise
    /// draws over the first rows of the grid.
    ///
    /// Both objects, not one: hiding the controller leaves its view drawing.
    ///
    /// - Parameters:
    ///   - window: The window whose title row to reconcile.
    ///   - isChromeless: Whether the window carries no title bar.
    @objc(syncAccessoriesInWindow:isChromeless:)
    public static func syncAccessories(in window: NSWindow, isChromeless: Bool) {
        for accessory in window.titlebarAccessoryViewControllers {
            accessory.isHidden = isChromeless
            accessory.view.isHidden = isChromeless
        }
    }

    /// The content's top inset for a window's chrome, in points.
    ///
    /// A chromeless window's grid meets the frame's top edge directly, so it
    /// borrows `titleless_padding_top` — whose own default is the bottom
    /// padding, because what a reader sees above the first row is then the
    /// same gap they see below the last, rather than the one that was sized to
    /// stand clear of a title row.
    ///
    /// - Parameters:
    ///   - isChromeless: Whether the window carries no title bar.
    ///   - configuration: The window's renderer configuration.
    /// - Returns: The inset in points.
    static func contentTopPadding(
        isChromeless: Bool,
        configuration: borrowing Ubiquitty.Rendering.RenderConfiguration
    ) -> Double {
        isChromeless ? configuration.titlelessPaddingTopPoints : configuration.paddingTopPoints
    }
}
