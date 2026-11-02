// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+EditMenu.swift — the Edit menu items a Kit-hosted
// window did not answer.
//
// Thirteen of them reached no responder, so AppKit greyed them out and the
// menu quietly described a terminal that could not reset itself, could not
// paste a path with spaces in it, and could not select the output of the last
// command. None of that was a decision; the selectors had nowhere to land on
// this arm.
//
// Every judgement stays Core's: `Selection::hasSelection` decides what is
// scoped to a selection, `Selection::lastCommandOutputRegion` decides whether
// there is a last command to select, and `Input::shellEscapedPath` decides what
// escaping means. What is here is the selectors and the AppKit around them.
//
// Copy and the three Copy Special variants are one Core decision,
// `Selection::copyClipboard`, reached through the surface: which flavour,
// which palette and the walk are Core's, and the pasteboard write is the
// component both shells share. Two items are absent for a reason rather
// than an oversight. Copy on Select and Smart Double-Click write a
// preference, and the writer — SettingsBridge — lives in the executable
// module while this controller lives in the Kit, so reaching it would mean
// opening a seam rather than filling one. Copy Command (Output) Under Mouse
// wants a context menu this arm does not have. Both are recorded rather
// than half-built.

import AppKit
internal import UbiquittyCore

extension TerminalWindowController {
    /// Sends a macro to the focused terminal.
    ///
    /// - Parameter name: The configured macro name.
    @objc
    public func invokeMacroNamed(_ name: String) {
        activeSurface?.invokeMacro(named: name)
    }

    /// Edit > Reset Terminal — a local DECSTR.
    ///
    /// The manual escape hatch for a session a dead peer left wedged: mouse
    /// tracking on, application keys on, nothing left alive to send the
    /// resets. Same reset a host-initiated `CSI ! p` performs.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func resetTerminal(_ sender: Any?) {
        focusedSurface?.softResetTerminal()
    }

    /// File > Rename Tab… (⇧⌘I) — the tab's custom title.
    ///
    /// The same title the title popover's Tab Title field and the inspector
    /// edit, read from and written to the one place it is held, so each opens
    /// on what the others set. Empty clears it, which is the same fact as
    /// never having set one: the tab answers to its window's custom title or
    /// to what the program set again.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func renameTab(_ sender: Any?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = customTabTitle
        field.placeholderString = "Automatic"

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to use the automatic title."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        field.selectText(nil)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            setCustomTitles(tab: field.stringValue)
        case .alertThirdButtonReturn:
            setCustomTitles(tab: "")
        default:
            break
        }
    }

    /// Edit > Paste Escaped Text — the clipboard, shell-quoted.
    ///
    /// For pasting a path with spaces or quotes in it as one argument rather
    /// than as several. The escaping is Core's, shared with the Linux arm.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func pasteEscapedText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        pasteEscaped(text)
    }

    /// Edit > Paste Escaped Selection — the selection, shell-quoted.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func pasteEscapedSelection(_ sender: Any?) {
        guard let surface = activeSurface, let text = surface.selectedText, !text.isEmpty else {
            return
        }
        pasteEscaped(text)
    }

    private func pasteEscaped(_ text: String) {
        let escaped = text.withCString { String(Ubiquitty.Input.shellEscapedPath(std.string_view($0))) }
        pasteText(escaped)
    }

    /// Edit > Copy Special ▸ Copy Without Background Color.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func copySelectionWithoutBackground(_ sender: Any?) {
        focusedPaneSurface?.copySelection(style: .noBackground)
    }

    /// Edit > Copy Special ▸ Copy with Styles Only (No Color).
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func copySelectionStylesOnly(_ sender: Any?) {
        focusedPaneSurface?.copySelection(style: .stylesOnly)
    }

    /// Edit > Copy Special ▸ Copy Plain Text.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func copySelectionPlain(_ sender: Any?) {
        focusedPaneSurface?.copySelection(style: .plainText)
    }

    /// Edit > Select Last Command Output — the region between the last
    /// executed prompt and the next one.
    ///
    /// Needs the shell's OSC 133 marks: without them there is no last command,
    /// which is why the item disables itself rather than selecting a guess.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func selectLastCommandOutput(_ sender: Any?) {
        focusedPaneSurface?.selectLastCommandOutput()
    }

    /// Whether an Edit-menu item applies right now.
    ///
    /// Greying out is not decoration: an item scoped to a selection that stays
    /// enabled without one tells the user it will do something, and then does
    /// nothing when they pick it.
    ///
    /// - Parameter item: The item asking.
    /// - Returns: Whether it is enabled.
    public func validateEditMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }
        switch action {
        // Copy itself is the surface's: the responder chain finds `copy:` on
        // the view before it reaches this controller, so the view validates
        // it (TerminalSurface+SelectionAppKit.swift).
        case #selector(TerminalWindowController.copySelectionWithoutBackground(_:)),
            #selector(TerminalWindowController.copySelectionStylesOnly(_:)),
            #selector(TerminalWindowController.copySelectionPlain(_:)),
            #selector(TerminalWindowController.pasteEscapedSelection(_:)),
            #selector(TerminalWindowController.useSelectionForFind(_:)):
            return focusedPaneSurface?.hasSelection ?? false
        case #selector(TerminalWindowController.pasteEscapedText(_:)):
            let clipboard = NSPasteboard.general.string(forType: .string)
            return !(clipboard?.isEmpty ?? true)
        case #selector(TerminalWindowController.selectLastCommandOutput(_:)):
            return focusedPaneSurface?.hasLastCommandOutput ?? false
        default:
            return true
        }
    }
}
