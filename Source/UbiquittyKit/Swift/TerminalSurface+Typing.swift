// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Typing.swift — what happens around a keystroke besides the
// bytes.
//
// Two effects that are not about the text at all: the caret stops blinking so
// it does not flicker under what is being typed, and the pointer gets out of
// the way until the next mouse move. Both are what every terminal on the
// platform does and neither is visible in a diff of the input path, which is
// why they are here under a name that says when they apply rather than
// scattered through the handlers that trigger them.
//
// The hold itself is Core's — `Cursor::noteUserActivity` and the duration
// beside it — so this is the fact that input happened, not a policy about it.

import QuartzCore
internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit
#endif

extension TerminalSurface {
    /// The user typed or pointed: hold the caret solid and repaint.
    ///
    /// Called from focus arrival as well as input, because a caret that
    /// resumes blinking the instant a window is clicked into reads as a
    /// flicker rather than as focus.
    package func noteUserActivity() {
        drive.noteUserActivity()
        cursorPresentationBypassUntil = CACurrentMediaTime() + 0.1
        userActivityNotesForTesting += 1
        needsDisplay = true
        frameClock.noteAnimationActivity()
    }

    /// The user typed: get the pointer out of the way until they move it.
    ///
    /// With no visible pointer there is nothing for a hover to anchor on, so
    /// this is also where a link affordance would be dropped once the Swift
    /// arm draws one.
    package func hidePointerForTyping() {
        #if canImport(AppKit)
        NSCursor.setHiddenUntilMouseMoves(true)
        pointerIsHiddenForTyping = true
        // With no visible pointer there is nothing for a hover to anchor on,
        // so the accent goes with it rather than being left underlining text
        // beneath a pointer the user can no longer see.
        clearLinkAffordance()
        #endif
    }
}
