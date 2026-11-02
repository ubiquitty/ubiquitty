// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+SpawnRefusal.swift — what a person is told when a
// window or tab they asked for does not open.
//
// A spawn that cannot proceed hands back no window, and the command that asked
// for it has nothing else to show: without a word, File ▸ New Tab reads as a key
// press the app ignored, and the person presses it again. So every refusal is
// written to the diagnostics stream, which reaches the unified log however the
// app was started, and is shown to the person with what to do about it.
//
// One notice at a time. A refusal that arrives while one is on screen is
// written to the stream and not stacked, so a person who presses ⌘T five times
// dismisses one notice.

import AppKit

/// What a person asked to open, which names the notice a refusal shows.
package enum SpawnRequest {
    /// A window of its own: File ▸ New Local Window, a restore, a script.
    case window
    /// A tab of the window the person is working in: File ▸ New Tab.
    case tab

    /// The notice's title.
    var refusalTitle: String {
        switch self {
        case .window: "Couldn’t Open a New Window"
        case .tab: "Couldn’t Open a New Tab"
        }
    }
}

/// Why a window or tab did not open.
package enum SpawnRefusal: Equatable {
    /// The workspace model every local window projects was never built.
    case noWindowModel
    /// No renderer could be built for the configured font.
    case noRenderer(RendererRefusal, family: String, pointSize: Double)
    /// The model opened no surface: the window limit was reached, or the
    /// session's program did not start.
    case noSurface
    /// The model opened a surface whose pane carries no session.
    case noSession

    /// The line the diagnostics stream carries.
    var diagnostic: String {
        switch self {
        case .noWindowModel:
            return "ubiquitty: no window model, so no terminal window opened"
        case .noRenderer(let reason, let family, let pointSize):
            let cause =
                switch reason {
                case .noGraphicsDevice: "no Metal device"
                case .noShaderLibrary: "the shader library did not load from the application bundle"
                case .unusableFont: "the font could not be measured"
                }
            return "ubiquitty: no renderer for family '\(family)' at \(pointSize)pt (\(cause)), so no terminal window opened"
        case .noSurface:
            return "ubiquitty: the model opened no surface, so no terminal window opened"
        case .noSession:
            return "ubiquitty: the opened surface carries no session, so no terminal window opened"
        }
    }

    /// What happened, and what the person can do about it.
    var explanation: String {
        switch self {
        case .noWindowModel:
            return "Ubiquitty didn’t finish starting up. Quit Ubiquitty and open it again."
        case .noRenderer(.noGraphicsDevice, _, _):
            return "This Mac didn’t provide a graphics device for drawing the terminal."
        case .noRenderer(.noShaderLibrary, _, _):
            return
                "Ubiquitty couldn’t load the graphics resources it draws with. The app may have been moved, updated, or replaced while it was open. Quit Ubiquitty and open it again."
        case .noRenderer(.unusableFont, let family, let pointSize):
            let size = pointSize.formatted(.number.precision(.fractionLength(0...1)))
            return "The font “\(family)” can’t be used at \(size) points. Choose another font or size in Settings."
        case .noSurface, .noSession:
            return
                "A new shell couldn’t be started. You may have reached the limit of open windows and tabs, or the system may be out of resources for new processes. Close some windows or tabs and try again."
        }
    }
}

extension TerminalWindowController {
    /// Whether a refusal notice is on screen.
    private static var isShowingSpawnRefusal = false

    /// Says why a window or tab did not open: to the diagnostics stream, and
    /// to the person.
    ///
    /// The notice is shown on the next turn of the run loop, so the command
    /// that asked returns first and a caller answering someone else, such as
    /// a script or the control socket, is not held while the notice is up.
    /// It is a sheet on the window the person is working in, or app-modal
    /// when no terminal window is open.
    ///
    /// - Parameters:
    ///   - refusal: Why the spawn did not proceed.
    ///   - request: What the person asked to open.
    static func report(_ refusal: SpawnRefusal, opening request: SpawnRequest) {
        NSLog("%@", refusal.diagnostic)
        guard !isShowingSpawnRefusal else { return }
        isShowingSpawnRefusal = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.refusalTitle
        alert.informativeText = refusal.explanation
        Task { @MainActor in
            let window =
                NSApp.keyWindow?.windowController is TerminalWindowController
                ? NSApp.keyWindow
                : (NSApp.mainWindow ?? spawnedControllers.lazy.compactMap(\.window).first(where: \.isVisible))
            if let window, window.attachedSheet == nil {
                alert.beginSheetModal(for: window) { _ in
                    MainActor.assumeIsolated { isShowingSpawnRefusal = false }
                }
            } else {
                _ = alert.runModal()
                isShowingSpawnRefusal = false
            }
        }
    }
}
