// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+Beam.swift — the command palette, as this window
// summons it.
//
// The palette is an overlay only a shell has, so it arrives as the Kit's
// ``TerminalSurface/beamPresenter`` closures rather than as a dependency the
// Kit could not satisfy on its own, the call-in the paste-push panel already
// takes. What the window supplies is itself and the live theme, both read off
// the pane the user is looking at.

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
            let presenter = TerminalSurface.beamPresenter
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
