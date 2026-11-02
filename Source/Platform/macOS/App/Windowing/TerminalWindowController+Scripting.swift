// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+Scripting.swift — what AppleScript reads from and
// types into a Kit-hosted window.
//
// The application's scripting bridge (ScriptingBridge.swift) wraps the windows
// of both shells behind one dictionary; these are this shell's answers to the
// two questions only a window can answer: what its focused pane shows, and
// where a scripted command line goes.

import AppKit
internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalWindowController {
    /// The focused pane's visible screen as text: one UTF-8 row per line,
    /// trailing blanks trimmed.
    ///
    /// Core's projection, the one every screen-read in the product uses, taken
    /// under the model lock because the ingest thread writes the grid it walks.
    /// The live screen rather than wherever the view is scrolled back to: a
    /// script reads what the program is showing.
    ///
    /// - Returns: The text, or empty when the window has no pane.
    package func scriptScreenText() -> String {
        guard let surface = focusedPaneSurface else { return "" }
        return surface.drive.withTerminal { String(Ubiquitty.Accessibility.visibleScreenText($0, 0)) } ?? ""
    }

    /// Writes text to the focused pane's session, character for character.
    ///
    /// The session the script addressed and no other. The dictionary names a
    /// window and a tab and has no word for a pane, so a script cannot say
    /// which sessions of a split it means; a line sent the way a keystroke is
    /// would be fanned out by Broadcast Input to sessions the caller has no
    /// way to name, some of them on other machines. The text is sent as it
    /// stands: no escape notation in it is interpreted.
    ///
    /// - Parameter text: The characters to send.
    package func sendScriptText(_ text: String) {
        guard !text.isEmpty, let surface = focusedPaneSurface else { return }
        surface.send(text)
    }
}
