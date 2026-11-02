// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+Paste.swift — the paste action for a Kit-hosted window.
//
// The bytes are Core's: `Input::wrapPaste` decides CR/LF, the bracketed-paste
// fence, and what a raw paste may carry, and `Input::pasteLineCount` decides
// whether a paste is held for confirmation. Nothing here re-spells any of
// that — a second spelling would be a second answer to "is this dangerous".
//
// The progress panel is the shell's, not the Kit's: an embedder that hosts a
// surface without the app's window furniture still pastes. It arrives as
// ``TerminalWindowController/pastePushPresenter``, and a Kit with none sends
// no image push at all, rather than starting a transfer it cannot report on.

import AppKit
internal import UbiquittyCore
internal import UbiquittyPasteboard

/// How a shell shows a paste crossing to a host.
///
/// Closures rather than a protocol: the shell that fills these is in another
/// module, and the Kit needs only to call them.
public struct PastePushPresenter {
    /// The general pasteboard's image as PNG, or nil when it holds none.
    public var imageFromPasteboard: () -> Data?
    /// A push started; the closure reports how much has left, or negative
    /// when the sender cannot say.
    public var began: (String, String, NSWindow?, @escaping () -> Double) -> Void
    /// The host answered: the status, and the path when it landed.
    public var settled: (UInt8, String) -> Void
    /// The push is over with no answer coming, so the panel goes now.
    ///
    /// The session the push was crossing to has ended: no status will arrive,
    /// and a panel left up would name a destination that is gone.
    public var dismissed: () -> Void

    /// - Parameters:
    ///   - imageFromPasteboard: Reads the pasteboard's image.
    ///   - began: Shows the panel for a starting push.
    ///   - settled: Reports the host's answer.
    ///   - dismissed: Takes the panel down when no answer is coming.
    public init(
        imageFromPasteboard: @escaping () -> Data?,
        began: @escaping (String, String, NSWindow?, @escaping () -> Double) -> Void,
        settled: @escaping (UInt8, String) -> Void,
        dismissed: @escaping () -> Void
    ) {
        self.imageFromPasteboard = imageFromPasteboard
        self.began = began
        self.settled = settled
        self.dismissed = dismissed
    }
}

extension TerminalWindowController {
    /// The shell's paste-progress panel, installed once at startup.
    public static var pastePushPresenter: PastePushPresenter?

    /// Persists the reader's choice to stop confirming multiline pastes.
    public static var disableMultilinePasteConfirmation: (() -> Void)?

    /// Pastes the general pasteboard into the focused surface.
    ///
    /// Text takes Core's paste path. A pasteboard carrying no text is a
    /// screenshot-shaped one: only a remote surface has somewhere to send it,
    /// because the host lands it as a file and types the path — which is what
    /// a path-taking program wants and what input bytes cannot carry. A local
    /// surface already shares a machine with the program.
    ///
    /// - Parameter sender: Unused; the menu item's target.
    @objc(paste:)
    public func pasteFromPasteboard(_ sender: Any?) {
        _ = sender
        // activeSurface, not focusedSurface: a hosted window — the shape a
        // remote attach builds — has no pane in the model, so the pane map
        // answers nothing for it. Its surface is the window's first responder,
        // and a hosted window is exactly what an image push exists for.
        guard let surface = activeSurface else {
            return
        }
        if surface.sendPasteNotification(TypedPasteboard.typeNames("").joined(separator: " ")) {
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            pastePushFromPasteboard(on: surface)
            return
        }
        pasteText(text)
    }

    /// Pastes text into the active pane, applying confirmation and terminal paste policy.
    ///
    /// - Parameter text: The complete text to paste.
    @objc
    public func pasteText(_ text: String) {
        guard !text.isEmpty, let surface = activeSurface else { return }
        let configuration = Ubiquitty.Preferences.values().pointee
        if Ubiquitty.Preferences.Effective.confirmMultilinePaste(configuration) {
            let lines = text.withCString { Int(Ubiquitty.Input.pasteLineCount(std.string_view($0))) }
            let threshold = Int(Ubiquitty.Preferences.Effective.confirmMultilinePasteThreshold(configuration))
            if lines > threshold {
                confirmMultilinePaste(text, lineCount: lines, on: surface)
                return
            }
        }
        forwardPaste(text, to: surface)
    }

    /// Sends text through Core's paste path.
    ///
    /// - Parameters:
    ///   - text: The clipboard text.
    ///   - surface: Where it goes.
    func forwardPaste(_ text: String, to surface: TerminalSurface) {
        surface.pasteAsUserInput(text)
    }

    /// Asks before a paste that would type more lines than the threshold.
    ///
    /// A clipboard spanning many lines types a string of commands into the
    /// shell. The fence is applied after confirmation, so a confirmed paste is
    /// byte-identical to one that was never held.
    ///
    /// - Parameters:
    ///   - text: The clipboard text.
    ///   - lineCount: What ``Ubiquitty/Input/pasteLineCount`` answered.
    ///   - surface: Where it goes once confirmed.
    func confirmMultilinePaste(_ text: String, lineCount: Int, on surface: TerminalSurface) {
        let alert = NSAlert()
        alert.messageText = "Paste \(lineCount) lines?"
        alert.informativeText = "Pasting multiple lines may run several shell commands."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.showsSuppressionButton = Self.disableMultilinePasteConfirmation != nil
        alert.suppressionButton?.title = "Don’t ask again"

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let preview = NSTextView(frame: scroll.bounds)
        preview.isEditable = false
        preview.isRichText = false
        preview.isVerticallyResizable = true
        preview.autoresizingMask = .width
        preview.textContainer?.widthTracksTextView = true
        preview.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // Bound layout work independently of the complete payload sent on approval.
        let previewUnits = Array(text.utf16.prefix(16_385))
        preview.string =
            String(decoding: previewUnits.prefix(16_384), as: UTF16.self)
            + (previewUnits.count > 16_384 ? "\n… (preview truncated)" : "")
        scroll.documentView = preview
        alert.accessoryView = scroll

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if alert.suppressionButton?.state == .on {
                Self.disableMultilinePasteConfirmation?()
            }
            if response == .alertFirstButtonReturn {
                self?.forwardPaste(text, to: surface)
            }
        }
        guard let window else {
            handle(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: handle)
    }

    /// Pushes a screenshot-shaped pasteboard to the host, with the panel.
    ///
    /// - Parameter surface: The surface the paste is for.
    func pastePushFromPasteboard(on surface: TerminalSurface) {
        guard surface.isRemoteAttached, let presenter = Self.pastePushPresenter else {
            return
        }
        guard let png = presenter.imageFromPasteboard(), !png.isEmpty else {
            return
        }
        guard surface.pushPaste(mime: "image/png", bytes: [UInt8](png)) != 0 else {
            let alert = NSAlert()
            alert.messageText = "The Image Couldn’t Be Sent"
            alert.informativeText =
                "The host may not support image transfers, the connection may be busy, or the image may be too large. Try again when the connection is ready."
            alert.addButton(withTitle: "OK")
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        presenter.began(window?.title ?? "", "image/png", window) { [weak surface] in
            surface?.pastePushProgress ?? -1
        }
    }

    /// Reports a settled push to the panel.
    ///
    /// The event's payload is the status alone; the path is read from the
    /// surface, because a path is not a scalar.
    ///
    /// - Parameters:
    ///   - status: The host's answer.
    ///   - surface: The surface the push crossed on.
    public func pastePushSettled(status: UInt32, on surface: TerminalSurface) {
        Self.pastePushPresenter?.settled(UInt8(truncatingIfNeeded: status), surface.lastPastePushPath)
    }
}
