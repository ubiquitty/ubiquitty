// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Clear.swift — the clear commands as a surface performs them.
//
// One call into Core, which holds the model lock, drops the selection, sends
// the redraw byte the shell is owed and republishes the snapshot the scroller
// sizes itself from. What is left here is what Core does not hold: where this
// view's selection lives, where its viewport sits, and the push that carries
// the republished counts into the bar. A clear under a view already at the
// tail moves no offset, and the command that destroys the most history is
// the one that sends the process nothing.
//
// Shared by both shells: a clear means the same thing on a desktop and a
// phone, and only the gesture that asks for one differs.

internal import UbiquittyCore
internal import UbiquittyRenderKit

extension TerminalSurface {
    /// A clear a person asks a terminal for, as the app's Edit menu offers it.
    ///
    /// What each one clears, and what the program is sent, is Core's: the
    /// app's menu items, its key bindings and ``clear(_:)`` run the same
    /// command.
    public enum ClearCommand: Sendable, CaseIterable {
        /// Clear Buffer, Cmd-K in the app: the screen and the scrollback go.
        ///
        /// The cursor's row up to the cursor, which holds the prompt and the
        /// line being typed, rises to the top row and the rest of the screen
        /// is blank.
        /// The program is sent Ctrl-L, because its line editor still believes
        /// the prompt sits where the screen no longer shows it.
        case buffer
        /// Clear Scrollback, Opt-Cmd-K in the app: the history the screen is
        /// not showing goes, and the screen stands. The program is sent
        /// nothing.
        case scrollback
        /// Clear Screen: the current prompt scrolls to the top row, and the
        /// rows above it go into the scrollback, so nothing is destroyed.
        ///
        /// The prompt's first row is the one its shell marked with OSC 133 A;
        /// without shell integration it is the cursor's row. The program is
        /// sent nothing.
        case screen
    }

    /// Runs a clear command against this surface's terminal, as the app's
    /// Edit menu does.
    ///
    /// A command that removes or moves rows drops the selection, telling the
    /// observer through ``TerminalSurfaceObserver/terminalSurfaceSelectionDidChange(_:)``,
    /// and returns the view to the live tail. ``ClearCommand/scrollback`` does
    /// both under every program, whether or not there was history to remove.
    ///
    /// A program that owns the screen's layout, by the alternate screen, a
    /// scroll region or left and right margins, is sent Ctrl-L for
    /// ``ClearCommand/buffer`` and ``ClearCommand/screen`` in place of the
    /// clear: those are the program's rows to redraw, and Ctrl-L is what
    /// shells, editors, pagers and multiplexers read as "redraw". The screen,
    /// the selection and the view stay for those two;
    /// ``ClearCommand/scrollback`` still empties the history. A prompt already
    /// on the top row leaves ``ClearCommand/screen`` nothing to do, and the
    /// selection stays.
    ///
    /// A pane attached to a host asks the host, which runs the same command on
    /// its own copy and sends Ctrl-L to its program itself. The result arrives
    /// with the host's next update; this surface drops its selection and
    /// returns to the live tail when the request is sent. Before the
    /// attachment is established the call does nothing, and a host refuses
    /// it from an attachment that may only watch. On a tmux pane the command
    /// runs on the surface's copy and Ctrl-L reaches the program through tmux.
    ///
    /// - Parameter command: Which clear to run.
    public func clear(_ command: ClearCommand) {
        switch command {
        case .buffer:
            runClearCommand(.Buffer)
        case .scrollback:
            runClearCommand(.Scrollback)
        case .screen:
            runClearCommand(.Screen)
        }
    }

    /// Runs a clear command against this surface's terminal.
    ///
    /// - Parameter command: Which clear the user asked for.
    package func runClearCommand(_ command: Ubiquitty.Screen.ClearCommand) {
        let hadSelection = hasSelection
        let returnsViewToTail = selectionModel.withState { drive.runClearCommand(command, droppingSelection: &$0) }
        if returnsViewToTail {
            setViewOffset(absolute: 0)
        }
        // A view already at the tail does not move, and that move is what
        // would otherwise carry the republished counts to the bar: the common
        // clear is exactly the one that leaves it sized on history that is
        // gone, and Clear Scrollback sends the process nothing, so no drain
        // follows to correct it.
        refreshScrollbackChromeFromModel()
        #if canImport(AppKit)
        terminalScroller.cancelScrollGesture()
        #endif
        needsDisplay = true
        frameClock.noteAnimationActivity()
        // The rows changed under a view that may not have moved, and no
        // delivery follows a clear that sends nothing, so the projection an
        // assistive reader reads is staled here.
        if hadSelection && !hasSelection {
            selectionDidChange()
        } else {
            noteAccessibilityContentChanged()
        }
    }
}
