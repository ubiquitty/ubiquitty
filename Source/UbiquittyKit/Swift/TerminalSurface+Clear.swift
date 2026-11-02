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
    /// Runs a clear command against this surface's terminal.
    ///
    /// - Parameter command: Which clear the user asked for.
    package func runClearCommand(_ command: Ubiquitty.Screen.ClearCommand) {
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
    }
}
