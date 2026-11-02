// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+Beam.swift — the command palette, as the Kit
// reaches it.
//
// The palette is an overlay only a shell has, so it arrives as closures rather
// than as a dependency the Kit could not satisfy on its own, the call-in the
// paste-push panel already takes. What the Kit supplies is the window and the
// live theme, both read off the pane the user is looking at.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

package struct BeamPaneDestination {
    package let title: String
    package let paneID: Int
    package let isCurrent: Bool

    package init(title: String, paneID: Int, isCurrent: Bool) {
        self.title = title
        self.paneID = paneID
        self.isCurrent = isCurrent
    }
}

/// A shell's command palette, as the Kit reaches it.
///
/// Closures rather than a protocol: the shell that fills these is in another
/// module, and the Kit needs only to call them.
public struct BeamPresenter {
    /// Summons the palette over a window, or dismisses the one already up.
    ///
    /// - Parameters:
    ///   - window: The window the overlay covers.
    ///   - foreground: The live theme's foreground.
    ///   - background: The live theme's background.
    ///   - accent: The live theme's accent.
    ///   - cursor: The live theme's cursor colour.
    public var toggle: (_ window: NSWindow, _ foreground: NSColor, _ background: NSColor, _ accent: NSColor, _ cursor: NSColor) -> Void

    /// Whether the palette is up over a window.
    ///
    /// The key-equivalent pass asks this: while the palette holds the
    /// responder, the surface still claims the chord that dismisses it.
    public var isActive: (_ window: NSWindow) -> Bool

    /// Delivers a pane's search publication to the shell's open palette.
    public var searchDidChange: ((_ surface: TerminalSurface) -> Void)?

    /// Builds a presenter.
    ///
    /// - Parameters:
    ///   - toggle: What summons and dismisses the palette.
    ///   - isActive: What says whether it is up over a window.
    ///   - searchDidChange: What refreshes results from a pane's search publication.
    public init(
        toggle: @escaping (NSWindow, NSColor, NSColor, NSColor, NSColor) -> Void,
        isActive: @escaping (NSWindow) -> Bool,
        searchDidChange: ((TerminalSurface) -> Void)? = nil
    ) {
        self.toggle = toggle
        self.isActive = isActive
        self.searchDidChange = searchDidChange
    }
}

extension TerminalWindowController {
    /// The terminal that owns the palette's command and search context.
    ///
    /// The pane with the keyboard, else the one a hosted window's reader was
    /// last in, else a hosted window's root: a window showing another
    /// session's panes has no local focused pane to fall back on.
    package var beamSurface: TerminalSurface? { activeSurface ?? tmuxIntentSurface ?? remoteSurface }

    /// Lists this window's pane destinations in stable pane order, by the id
    /// ``focusPane(withIdentifier:)`` takes.
    package func beamPaneDestinations() -> [BeamPaneDestination] {
        let panes = panesByIdentifier()
        guard panes.count > 1 else { return [] }
        let current = beamSurface
        return panes.sorted { $0.key < $1.key }
            .map { identifier, surface in
                BeamPaneDestination(
                    // Named as its header names it: a row per pane that
                    // read as the tab would read the same for every pane.
                    title: wovenTitle(for: surface, as: .pane).title,
                    paneID: identifier,
                    isCurrent: surface === current
                )
            }
    }

    /// Reveals a command or search result in the palette's originating terminal.
    package func revealBeamRow(_ absoluteRow: Int, in surface: TerminalSurface) {
        guard surface.window === window else { return }
        let offset = surface.drive.withTerminal { terminal in
            let history = Ubiquitty.Screen.scrollableRowCount(terminal)
            let row = max(0, min(Int32(clamping: absoluteRow), history + terminal.rows - 1))
            return Ubiquitty.Screen.viewOffsetToReveal(history, terminal.rows, row, .CommandBlock)
        }
        if let offset {
            surface.setViewOffset(absolute: Int(offset))
        }
    }

    /// Resolves a search result in the palette's originating terminal.
    package func revealBeamPosition(_ position: Ubiquitty.Screen.LogicalPosition, in surface: TerminalSurface) {
        guard surface.window === window else { return }
        let offset = surface.drive.searchPositionViewOffset(position)
        if offset >= 0 { surface.setViewOffset(absolute: offset) }
    }

    /// Routes a Beam key action to the currently focused terminal pane.
    ///
    /// - Parameter token: The action name from Core's key catalog.
    public func performBeamKeyAction(named token: String) {
        beamSurface?.performKeyAction(named: token)
    }

    /// Restores terminal focus after the palette releases its responder.
    public func restoreFocusAfterBeam() {
        guard let surface = beamSurface else { return }
        window?.makeFirstResponder(surface)
    }

    /// Reconciles title and tab activation after the palette leaves the frame view.
    public func restoreChromeAfterBeam() {
        applyChromeTheme()
        refreshTabGroupForFocusChange()
    }

    /// The shell's palette. A Kit with none summons nothing, which is the
    /// right answer for an embedder that has no palette to show.
    public static var beamPresenter: BeamPresenter?

    /// Summons or dismisses the command palette over this window.
    ///
    /// The colours are the live theme, each of the four Core's own derivation
    /// off the model's palette, OSC overrides included, so the card matches
    /// what is on screen and cannot round the theme differently from the tab
    /// title beside it. The palette wears the system font, so it takes no
    /// terminal font: it is chrome, not content.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func toggleBeam(_ sender: Any?) {
        guard let window, let surface = beamSurface,
            let presenter = Self.beamPresenter
        else {
            return
        }
        presenter.toggle(
            window,
            surface.chromeForegroundColor(),
            surface.chromeBackgroundColor(),
            surface.chromeAccentColor(),
            surface.chromeCursorColor()
        )
    }
}
