// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)

import AppKit
internal import UbiquittyRenderKit
internal import UbiquittyCore

// Selecting by dragging, and copying to the AppKit pasteboard.
//
// A mouse drag and NSPasteboard have no counterpart on a touch screen;
// what a selection is, and the text it yields, are shared.

extension TerminalSurface {
    /// Copies the selection to a pasteboard, in the flavour the reader's
    /// `[selection] copy_style` names.
    ///
    /// - Parameter pasteboard: The destination; the general pasteboard by
    ///   default.
    /// - Returns: Whether there was a selection to copy.
    @discardableResult
    public func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        copySelection(style: .configured, to: pasteboard)
    }

    /// Copies the selection to a pasteboard, in one flavour.
    ///
    /// The flavour, the palette and the walk are Core's
    /// (`Selection::copyClipboard`, reached through the session under its
    /// lock); the write is the component both shells share. Package rather
    /// than public: the flavour is a Core type, and the module's public
    /// interface carries none.
    ///
    /// - Parameters:
    ///   - style: The flavour the picked menu item names; `.configured` for
    ///     ⌘C, which takes the file's answer.
    ///   - pasteboard: The destination; the general pasteboard by default.
    /// - Returns: Whether there was a selection to copy.
    @discardableResult
    package func copySelection(style: Ubiquitty.Selection.CopyStyle, to pasteboard: NSPasteboard = .general) -> Bool {
        let pointSize = renderer?.pointSize ?? zoomedPointSize
        let built = drive.selectionClipboard(of: &selectionModel.session.pointee, style: style, pointSize: pointSize)
        return SelectionPasteboard.write(plain: built.plain, rtf: built.rtf, html: built.html, to: pasteboard)
    }

    /// The standard Copy action, which the shared Edit menu's Copy item names.
    ///
    /// Reached by selector from the responder chain, so it carries `@objc`:
    /// without it the Edit menu's Copy finds nothing here.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func copy(_ sender: Any?) {
        copySelection()
    }

    private func selectionCell(for event: NSEvent) -> (row: Int32, column: Int32)? {
        // The report path's mapping, not a second one: a gesture and a mouse
        // report quantising through different inset math select one cell and
        // report its neighbour.
        reportCell(for: event)
    }
}

extension TerminalSurface: NSMenuItemValidation {
    /// Whether a menu item this view answers applies right now.
    ///
    /// Copy is answered here rather than by the window controller because the
    /// responder chain stops at the first object implementing the action, and
    /// that is this view: an item validated further up the chain would stay
    /// enabled without a selection whatever the controller decided. The
    /// answer is Core's `Selection::hasSelection`, through ``hasSelection``.
    ///
    /// - Parameter item: The item asking.
    /// - Returns: Whether it is enabled.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(copy(_:)) else {
            return contextMenuItemApplies(item)
        }
        return hasSelection
    }
}

#endif
