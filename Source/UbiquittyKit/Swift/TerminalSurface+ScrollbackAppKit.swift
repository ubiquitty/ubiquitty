// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)

import AppKit
internal import UbiquittyRenderKit
internal import UbiquittyCore

// The gestures that move the scrollback view, on this platform.
//
// A wheel with momentum phases and an NSScroller drag have no counterpart on
// a touch screen. What they do — the clamp, the follow-or-hold decision, the
// reveal — is shared and lives in TerminalSurface+Scrollback.swift; only
// their arrival is here.

extension TerminalSurface {
    /// Routes one scroll event through Core's wheel ladder.
    ///
    /// AppKit's part is the deltas and whether they are continuous; which of
    /// the three routes answers, and how far the view moves, is the session's.
    ///
    /// - Parameter event: The scroll event.
    internal func routeWheel(_ event: NSEvent) {
        guard terminalScroller.acceptsScrollWheel(event) else { return }
        var fact = Ubiquitty.Runtime.TerminalSession.ScrollFact()
        fact.deltaX = Double(event.scrollingDeltaX)
        fact.deltaY = Double(event.scrollingDeltaY)
        fact.isPrecise = event.hasPreciseScrollingDeltas
        if let cell = reportCell(for: event) {
            fact.row = Int(cell.row)
            fact.column = Int(cell.column)
        }
        let backing = convertToBacking(convert(event.locationInWindow, from: nil))
        fact.pixelX = Int(backing.x) + 1
        fact.pixelY = Int(backing.y) + 1
        fact.hasShift = event.modifierFlags.contains(.shift)
        fact.hasAlternate = event.modifierFlags.contains(.option)
        fact.hasControl = event.modifierFlags.contains(.control)

        let outcome = drive.scrollFact(fact, tuning: wheelTuning)
        let endingPhases: NSEvent.Phase = [.ended, .cancelled]
        if outcome.isViewportScroll || !event.phase.intersection(endingPhases).isEmpty
            || !event.momentumPhase.intersection(endingPhases).isEmpty
        {
            terminalScroller.updateForScrollWheel(event) {
                if outcome.linesToOffsetView != 0 {
                    offsetView(byLines: Int(outcome.linesToOffsetView))
                }
            }
        }
    }

    /// Handles the scrollback navigation chrome, before the input method.
    ///
    /// Cmd-PageUp / Cmd-PageDown page by visible rows; Cmd-Home and
    /// Shift-Cmd-Up jump to the oldest retained line; Cmd-End and
    /// Shift-Cmd-Down return to the live tail — the Metal arm's exact set.
    ///
    /// - Parameter event: The key event.
    /// - Returns: Whether the key was consumed as navigation.
    internal func handleScrollbackNavigationKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let action = Ubiquitty.Keys.scrollNavigationAction(
            Ubiquitty.macOS.portableKeyForCode(event.keyCode),
            flags.contains(.command),
            flags.contains(.shift)
        )
        guard action != .none else { return false }
        let snap = drive.readSnapshot()
        // Core's one page rule — a row of overlap, so the line anchoring the
        // reader's place survives the jump — shared with every arm.
        let page = Ubiquitty.Keys.pageLinesForRows(Int(snap.rows))
        switch action {
        case .pageUp:
            offsetView(byLines: page)
        case .pageDown:
            offsetView(byLines: -page)
        case .top:
            setViewOffset(absolute: Int(Int32.max))
        case .bottom:
            setViewOffset(absolute: 0)
        case .none:
            return false
        @unknown default:
            return false
        }
        return true
    }
}

/// The scroller's delegate, a separate object for the reason the clock's is:
/// the surface is public and the scroller's protocol is package-scoped, so the
/// surface conforming directly would force every UbiquittyKit consumer to
/// import RenderKit.
@MainActor
final class SurfaceScrollerBridge: NSObject, TerminalScrollerDelegate {
    unowned let surface: TerminalSurface

    init(surface: TerminalSurface) {
        self.surface = surface
    }

    /// A scroller drag drove the offset directly.
    func terminalScroller(_ scroller: TerminalScroller, didScrollToOffsetLines lines: Int) {
        surface.setViewOffset(absolute: lines)
    }
}

#endif
