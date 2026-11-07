// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// SurfaceSmoke+WindowShell.swift — the surface smoke's legs that drive this
// shell's window controller.
//
// The battery and its entry are the Kit's. These legs construct a window
// controller, which only a build composing the window shell has, so the
// application's entry point hands them to the Kit's entry.

import AppKit
import Metal
internal import UbiquittyCore

extension SurfaceSmokeEntry {
    /// The legs that drive this shell's window controller, which
    /// ``run(windowShellLegs:)`` runs where the battery reaches the window
    /// shell.
    ///
    /// - Parameters:
    ///   - device: The Metal device the battery draws through.
    ///   - library: Its shader library.
    /// - Returns: Whether the legs held.
    @MainActor
    package static func windowShellLegs(device: MTLDevice, library: MTLLibrary) -> Bool {
        SurfaceSmoke.pasteLegs(device: device, library: library)
    }
}

extension SurfaceSmoke {
    /// The paste action, against the window shape a remote attach builds.
    ///
    /// A hosted window holds no pane in the model, so the pane map answers
    /// nothing for it and only the first responder names its surface. Paste
    /// resolves its surface from the first responder, so a remote window —
    /// the one shape an image push exists for — pastes as a local one does.
    ///
    /// - Parameters:
    ///   - device: The Metal device the window's renderer draws through.
    ///   - library: Its shader library.
    /// - Returns: Whether the legs held.
    fileprivate static func pasteLegs(device: MTLDevice, library: MTLLibrary) -> Bool {
        guard let surface = TerminalSurface(rows: 24, columns: 80) else {
            return failed("paste: no surface")
        }
        guard
            let renderer = SurfaceRenderer(device: device, library: library, familyName: "Menlo", pointSize: 12)
        else {
            return failed("paste: no renderer")
        }
        surface.renderer = renderer
        // The hosted shape: no workspace surface, no pane — the window fills
        // with this surface directly, as spawnRemoteWindow builds it.
        let controller = TerminalWindowController(
            workspaceSurface: Ubiquitty.Session.Layout.invalidSurface,
            pane: nil,
            surface: surface,
            renderer: renderer,
            rows: 24,
            columns: 80
        )
        controller.remoteSurface = surface
        controller.window?.makeFirstResponder(surface)

        let recorder = TransmitRecorder()
        surface.observer = recorder

        // A hosted window answers nothing through the pane map. An action
        // keyed on it would find no surface and return having done nothing,
        // which is indistinguishable from an empty clipboard.
        guard controller.focusedSurface == nil else {
            return failed("paste: a hosted window answered the pane map, so this leg proves nothing")
        }
        guard controller.activeSurface === surface else {
            return failed("paste: the hosted surface is not the window's active one")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("echo hosted-paste", forType: .string)
        controller.pasteFromPasteboard(nil)
        guard recorder.text.contains("echo hosted-paste") else {
            return failed("paste: a hosted window transmitted \(recorder.text.debugDescription) for a text paste")
        }

        // Core owns the fence, and a program that asked for bracketed paste
        // must receive one: the bytes are the shell's protection against a
        // multi-line clipboard running as commands.
        recorder.transmitted = []
        feed(surface.drive, "\u{1b}[?2004h")
        _ = surface.drive.takeSyncFrameReady()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("one\ntwo", forType: .string)
        // The confirmation is a different rule with a different owner, and it
        // stands between this leg and the bytes: a clipboard of more than
        // `confirm_multiline_threshold` lines opens a sheet, and a sheet begun
        // on a window nothing is answering never calls back, so the paste
        // returns having transmitted nothing. Set here rather than left to the
        // machine, because the reader's own `[paste]` block would otherwise
        // decide whether this leg tests the fence or tests nothing.
        let standingDocument = String(Ubiquitty.Preferences.liveDocument().pointee)
        _ = Ubiquitty.Preferences.configure(
            std.string(standingDocument + "\n[paste]\nconfirm_multiline = false\n"),
            .Permissive
        )
        controller.pasteFromPasteboard(nil)
        _ = Ubiquitty.Preferences.configure(std.string(standingDocument), .Permissive)
        let fenced = recorder.text
        guard fenced.hasPrefix("\u{1b}[200~"), fenced.hasSuffix("\u{1b}[201~") else {
            return failed("paste: bracketed paste was on and the bytes carried no fence: \(fenced.debugDescription)")
        }
        guard fenced.contains("one\rtwo") else {
            return failed("paste: the newline was not normalised to CR: \(fenced.debugDescription)")
        }

        // An image with no host has nowhere to go, and no bytes can carry it.
        // A shell that typed something here would type the wrong thing.
        recorder.transmitted = []
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        controller.pasteFromPasteboard(nil)
        guard recorder.text.isEmpty else {
            return failed("paste: an image typed \(recorder.text.debugDescription) into a surface with no host")
        }
        guard !surface.isRemoteAttached else {
            return failed("paste: this leg needs a surface with no host, and it has one")
        }

        surface.observer = nil
        return true
    }

    /// Records what a surface transmits.
    private final class TransmitRecorder: NSObject, TerminalSurfaceObserver {
        var transmitted: [CChar] = []

        func terminalSurface(_: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
            transmitted.append(contentsOf: bytes.prefix(count))
        }

        /// What was transmitted, as text.
        var text: String {
            String(decoding: transmitted.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
