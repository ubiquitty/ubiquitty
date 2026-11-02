// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalWindowController+Clear.swift — the Edit menu's four clear items,
// against a Kit-hosted window.
//
// Selectors only. Which gesture destroys what is Core's — see
// `Screen::ClearCommand` — and the command itself runs there too, so each of
// these is the name of a menu item bound to the name of a command. A shell
// that spelled the policy again is a shell that could spell it differently.
//
// They target the active surface, the one every pane verb addresses: a split
// window's user means the pane they are looking at, and a hosted or tmux
// window's panes are not in the local model the focused-pane lookup reads, so
// that lookup finds nothing there and the gesture would be dropped.

import AppKit
internal import UbiquittyCore

extension TerminalWindowController {
    /// Edit > Clear Buffer — screen and scrollback both, keeping the line
    /// being typed. Cmd-K.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func clearBuffer(_ sender: Any?) {
        activeSurface?.runClearCommand(.Buffer)
    }

    /// Edit > Clear Scrollback — the history the screen is not showing.
    /// Opt-Cmd-K.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func clearScrollback(_ sender: Any?) {
        activeSurface?.runClearCommand(.Scrollback)
    }

    /// Edit > Clear Screen — the current prompt scrolls to the top and
    /// nothing is destroyed.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func clearScreen(_ sender: Any?) {
        activeSurface?.runClearCommand(.Screen)
    }

    /// Edit > Clear to Previous Mark — everything above the most recent
    /// executed prompt. Cmd-L.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func clearToPreviousMark(_ sender: Any?) {
        activeSurface?.runClearCommand(.ToPreviousMark)
    }

    /// View > Jump to Previous Prompt — the viewport walks back through the
    /// shell's OSC 133 marks.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func scrollToPreviousPrompt(_ sender: Any?) {
        activeSurface?.stepToPrompt(direction: -1)
    }

    /// View > Jump to Next Prompt — the same walk forward, snapping to the
    /// live tail when nothing is left below.
    ///
    /// - Parameter sender: Ignored.
    @objc
    public func scrollToNextPrompt(_ sender: Any?) {
        activeSurface?.stepToPrompt(direction: 1)
    }
}
