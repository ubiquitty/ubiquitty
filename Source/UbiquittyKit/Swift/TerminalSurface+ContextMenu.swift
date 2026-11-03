// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+ContextMenu.swift — what a right-click on the grid offers.
//
// The two items that need more than a selector are the OSC 133 ones, and what
// they copy is Core's: `Selection::selectCommandLineUnderRow` and
// `Selection::selectCommandOutputUnderRow` resolve the command from the clicked
// row, anchor the output search on that command's own executed row, and hand
// back a selection. The menu carries the row and nothing else.
//
// A program that is reading the mouse gets no menu at all, the way it gets no
// selection: the right button belongs to it while it is asking for it.

internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit

extension TerminalSurface {
    /// The menu a right-click opens.
    ///
    /// The order is the app's one context-menu order, so a user meeting two
    /// windows must not have to look twice for the same item.
    /// The link items appear only over a link and the command items only when
    /// a cell was clicked, so an empty region offers what applies to it and
    /// nothing else.
    ///
    /// - Parameter event: The click.
    /// - Returns: The menu, or nil while the program is reading the mouse.
    override public func menu(for event: NSEvent) -> NSMenu? {
        let reporting = pointerReportingState(modifiers: event.modifierFlags)
        if event.type != .rightMouseDown, reporting.isMouseReporting,
            reporting.isSelectionOverrideModifierArmed || reporting.isBlockSelectionOverrideModifierArmed
        {
            return nil
        }
        guard !drive.readSnapshot().mouseReportsActive else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu(title: "")
        addItem(to: menu, title: "Copy", action: #selector(copy(_:)), target: self)
        addItem(
            to: menu,
            title: "Paste",
            action: #selector(TerminalWindowController.pasteFromPasteboard(_:)),
            target: nil
        )
        menu.addItem(.separator())
        addItem(to: menu, title: "Select All", action: #selector(selectAll(_:)), target: self)

        if let found = link(atViewPoint: point, isCommandHeld: true), !found.uri.isEmpty {
            // A file link copies the path a shell would take, not the URL
            // spelling of it — pasting `file:///Users/…` into a prompt is
            // never what the reader wanted.
            let isFileLink = found.uri.hasPrefix("file://")
            let payload = isFileLink ? (URL(string: found.uri)?.path ?? found.uri) : found.uri
            menu.addItem(.separator())
            let item = addItem(
                to: menu,
                title: isFileLink ? "Copy Path" : "Copy Link",
                action: #selector(copyLinkUnderMouse(_:)),
                target: self
            )
            item.representedObject = payload
        }

        if let cell = reportCell(atViewPoint: point) {
            // The clamped cell here, not the strict one: the command items
            // answer for a row, and a click in the padding beside the grid is
            // still on that row.
            let absoluteRow = drive.absoluteRow(forVisibleRow: Int(cell.row), viewOffset: viewOffset)
            menu.addItem(.separator())
            addItem(
                to: menu,
                title: "Copy Command Output",
                action: #selector(copyCommandOutputUnderMouse(_:)),
                target: self
            )
            .tag = absoluteRow
            addItem(
                to: menu,
                title: "Copy Command",
                action: #selector(copyCommandUnderMouse(_:)),
                target: self
            )
            .tag = absoluteRow
        }

        // These two act on the pane the menu opened over, focused or not, and
        // this surface answers them: a host's responder chain holds no window
        // controller of the app's to answer the Edit menu's selectors.
        menu.addItem(.separator())
        addItem(
            to: menu,
            title: "Clear Scrollback",
            action: #selector(clearScrollbackUnderMouse(_:)),
            target: self
        )
        addItem(
            to: menu,
            title: "Reset Terminal",
            action: #selector(resetTerminalUnderMouse(_:)),
            target: self
        )
        return menu
    }

    /// Clears the scrollback of this surface, the one the menu opened over.
    ///
    /// - Parameter sender: The item.
    @objc
    package func clearScrollbackUnderMouse(_ sender: NSMenuItem) {
        runClearCommand(.Scrollback)
    }

    /// Soft-resets the terminal of this surface, the one the menu opened over.
    ///
    /// - Parameter sender: The item.
    @objc
    package func resetTerminalUnderMouse(_ sender: NSMenuItem) {
        softResetTerminal()
    }

    /// Copies the resolved link target captured when the menu was built.
    ///
    /// The target is read at build time rather than now because the grid moves:
    /// output arriving between the right-click and the pick would scroll a
    /// different link under the same point.
    ///
    /// - Parameter sender: The item, carrying the target as its represented
    ///   object.
    @objc
    package func copyLinkUnderMouse(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String, !payload.isEmpty else { return }
        payload.withCString { Ubiquitty.PAL.clipboardSetText(std.string_view($0)) }
    }

    /// Copies the command line of the command under the clicked row.
    ///
    /// - Parameter sender: The item, carrying the absolute row as its tag.
    @objc
    package func copyCommandUnderMouse(_ sender: NSMenuItem) {
        copyCommandSpan(atAbsoluteRow: sender.tag) { drive.selectCommandLine(underAbsoluteRow: sender.tag, into: &$0) }
    }

    /// Copies the output of the command under the clicked row.
    ///
    /// - Parameter sender: The item, carrying the absolute row as its tag.
    @objc
    package func copyCommandOutputUnderMouse(_ sender: NSMenuItem) {
        copyCommandSpan(atAbsoluteRow: sender.tag) { drive.selectCommandOutput(underAbsoluteRow: sender.tag, into: &$0) }
    }

    /// Whether a context-menu item this view answers applies right now.
    ///
    /// - Parameter item: The item asking.
    /// - Returns: Whether it is enabled.
    internal func contextMenuItemApplies(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copyLinkUnderMouse(_:)):
            return (item.representedObject as? String)?.isEmpty == false
        case #selector(copyCommandUnderMouse(_:)), #selector(copyCommandOutputUnderMouse(_:)):
            // A shell with no integration marks nothing, which is the common
            // case, so these grey out rather than beeping at every pick.
            return drive.hasCommand(underAbsoluteRow: item.tag)
        case #selector(resetTerminalUnderMouse(_:)):
            // A pane attached to a host shows the host's terminal, which Core's
            // reset leaves as it is.
            return !drive.isRemoteAttached
        default:
            return true
        }
    }

    /// Selects a command's span and copies it, or beeps when there is none.
    ///
    /// The selection is left standing:
    /// what was copied stays visible, so a reader can see they took the right
    /// rows.
    ///
    /// - Parameters:
    ///   - absoluteRow: The clicked row, for the beep's sake.
    ///   - select: The Core call that writes the span.
    private func copyCommandSpan(atAbsoluteRow absoluteRow: Int, select: (inout Ubiquitty.SelectionState) -> Bool) {
        guard absoluteRow >= 0, selectionModel.withState({ select(&$0) }) else {
            NSSound.beep()
            return
        }
        copySelection()
        needsDisplay = true
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        return item
    }
}

#endif
