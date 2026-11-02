// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+SessionLog.swift — File ▸ Log Session to File…,
// against a Kit-hosted window.
//
// Core appends every byte a session ingests to the open log, on the ingest
// thread and inside its locked parse. So the file is opened and closed under
// that same lock (`RuntimeDrive.setSessionLogPath`); an fclose on this thread
// outside it could land in the middle of a write. The log follows the pane
// that was focused when it started: a focus change moves what the reader is
// typing into, not what the file is recording.

import AppKit
internal import UbiquittyRenderKit

extension TerminalWindowController {
    /// File ▸ Log Session to File… — asks where to log the focused pane's
    /// session and starts appending to it, or stops the log this window keeps.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func toggleSessionLog(_ sender: Any?) {
        if isLoggingSession {
            stopSessionLog()
            return
        }
        guard let window else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Log Session to File"
        panel.prompt = "Start Logging"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "session.log"
        panel.beginSheetModal(for: window) { [weak self, weak panel, weak window] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self, let path = panel?.url?.path, !path.isEmpty else { return }
                guard !self.startSessionLog(atPath: path), let window else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn’t Open the Log File"
                alert.informativeText = "Ubiquitty couldn’t write to \(path). Choose another location, then try again."
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// Whether this window is appending a pane's session to a file.
    package var isLoggingSession: Bool {
        sessionLogPath != nil && sessionLogSurface != nil
    }

    /// Names File ▸ Log Session to File… by what choosing it does: a window
    /// keeping a log offers to stop it, and one keeping none offers to start
    /// one. The application labels the item the same way for a window of
    /// either shell.
    ///
    /// - Parameters:
    ///   - item: The menu item.
    ///   - state: `.on` for a window keeping a log, `.off` for one keeping none.
    package static func labelSessionLogItem(_ item: NSMenuItem, for state: NSControl.StateValue) {
        item.state = state
        item.title = state == .on ? "Stop Logging Session" : "Log Session to File…"
    }

    /// Starts appending every byte the focused pane's session receives to a
    /// file, closing any log this window already keeps.
    ///
    /// - Parameter path: The file to append to.
    /// - Returns: Whether the file opened.
    @discardableResult
    package func startSessionLog(atPath path: String) -> Bool {
        stopSessionLog()
        guard let surface = focusedSurface, surface.drive.setSessionLogPath(path) else {
            return false
        }
        sessionLogSurface = surface
        sessionLogPath = path
        return true
    }

    /// Closes the log this window keeps, flushing what it holds to the file.
    package func stopSessionLog() {
        sessionLogSurface?.drive.setSessionLogPath(nil)
        sessionLogSurface = nil
        sessionLogPath = nil
    }
}
