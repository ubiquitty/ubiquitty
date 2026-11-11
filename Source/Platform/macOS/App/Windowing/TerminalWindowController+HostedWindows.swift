// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+HostedWindows.swift — a pane's session hosting
// windows of its own.
//
// A program in one of this window's panes can speak for windows and panes of
// its own: a typed `tmux -CC` is one. Core's session notices, becomes the
// source of those windows, and tells this window what to show — a window
// appeared, its panes were laid out, it was renamed or closed. This side opens
// a window for each, binds a surface to each pane over the model Core hands
// out, and releases each pane back when its view goes. Which program is behind
// them is the session's business; nothing here asks.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalWindowController {
    /// Shows every change a pane's session has queued about the windows it
    /// hosts, then repaints the hosted panes whose models changed.
    ///
    /// - Parameter surface: The pane whose session hosts the windows.
    func hostedWindowsDidChange(on surface: TerminalSurface) {
        while let event = surface.drive.takeHostedWindowEvent() {
            switch event.kind {
            case .windowOpened:
                openHostedWindow(event, from: surface)
            case .layoutChanged:
                hostedWindows[event.windowID]?.applyHostedLayout(event, from: surface)
            case .windowRenamed:
                hostedWindows[event.windowID]?.tmuxWindowName = event.name
            case .sessionRenamed:
                for hosted in hostedWindows.values {
                    hosted.tmuxSessionName = event.sessionName
                }
            case .windowClosed:
                closeHostedWindow(event.windowID, from: surface)
            case .ended:
                endHostedWindows(from: surface)
            }
        }
        let sessionAddress = surface.drive.hostedWindowSourceAddress
        for pane in surface.drive.takeRepaintedHostedPanes() {
            Self.repaintTmuxPane(pane, sessionAddress: sessionAddress)
        }
    }

    /// Opens the window a hosted-window event announced, in the tab group of
    /// the session that hosts it.
    private func openHostedWindow(_ event: RuntimeDrive.HostedWindowEvent, from surface: TerminalSurface) {
        if let standing = hostedWindows[event.windowID], !standing.isWindowClosed {
            return
        }
        // One tab group per hosting session, so two attached sessions never
        // merge their tabs.
        let identity = "ubiquitty-hosted-\(surface.drive.hostedWindowSourceAddress)"
        guard let hosted = Self.spawnTmuxHostingWindow(tabbingIdentity: identity) else {
            return
        }
        hosted.hostingSurface = surface
        hosted.hostedWindowID = event.windowID
        hosted.tmuxSessionName = event.sessionName
        hosted.tmuxWindowName = event.name
        hostedWindows[event.windowID] = hosted
    }

    /// Binds a surface to each pane of a hosted window's new layout, unbinds
    /// the panes it dropped, and mirrors the layout's splits.
    ///
    /// - Parameters:
    ///   - event: The layout change.
    ///   - surface: The pane whose session hosts this window.
    fileprivate func applyHostedLayout(_ event: RuntimeDrive.HostedWindowEvent, from surface: TerminalSurface) {
        // A window the reader closed binds nothing: its panes were released
        // as it closed.
        guard !isWindowClosed else {
            return
        }
        let sourceAddress = surface.drive.hostedWindowSourceAddress
        var live = Set<Int32>()
        for pane in event.paneIDs {
            live.insert(pane)
            guard let facts = surface.drive.hostedPaneFacts(pane) else {
                continue
            }
            bindTmuxPane(
                pane,
                terminal: facts.terminal,
                lockAddress: facts.lockAddress,
                rows: facts.rows,
                columns: facts.columns,
                clientAddress: facts.inputClientAddress,
                streamAddress: facts.inputStreamAddress,
                sessionAddress: sourceAddress
            )
        }
        for pane in boundTmuxPaneIDs() where !live.contains(pane) {
            unbindTmuxPane(pane)
        }
        applyTmuxLayoutMirror(event.layout, activePaneID: event.activePaneID)
    }

    /// Unbinds and closes the hosted window the session closed, then tells the
    /// session its panes' views are gone.
    private func closeHostedWindow(_ windowID: Int32, from surface: TerminalSurface) {
        if let hosted = hostedWindows.removeValue(forKey: windowID) {
            hosted.releaseTmuxPanes()
            hosted.window?.close()
        }
        surface.drive.releaseHostedWindow(windowID)
    }

    /// Closes every window a pane's session hosts and stops the hosting.
    ///
    /// For the program's own end, and for this window closing under it: the
    /// session owns the models every hosted pane's view reads, so each view
    /// unbinds before the session lets them go.
    ///
    /// - Parameter surface: The pane whose session hosts the windows.
    func endHostedWindows(from surface: TerminalSurface) {
        let hosted = hostedWindows
        hostedWindows.removeAll()
        for window in hosted.values {
            window.releaseTmuxPanes()
            window.window?.close()
        }
        surface.drive.endHostedWindows()
    }

    /// The windows this window's panes host, for a scenario that watches them
    /// open and close.
    package var hostedWindowsForTesting: [TerminalWindowController] { liveHostedWindows }

    /// Lists hosted windows whose controllers are still open.
    package var liveHostedWindows: [TerminalWindowController] {
        hostedWindows.values.filter { !$0.isWindowClosed }
    }

    /// Releases a hidden restore connection after its last visible window closes.
    func releaseUnusedArrangementConnection() {
        guard let owner = hostingSurface?.window?.windowController as? TerminalWindowController,
            owner.isArrangementControlClient
        else { return }
        DispatchQueue.main.async { [weak owner] in
            guard let owner, !owner.isWindowClosed, owner.liveHostedWindows.isEmpty else { return }
            owner.window?.close()
        }
    }
}
