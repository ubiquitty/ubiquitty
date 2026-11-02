// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation
internal import UbiquittyCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension TerminalSurface {
    /// Tells an assistive reader the screen changed, at Core's cadence.
    ///
    /// The DECISION is Core's and shared: NotifyThrottle holds a 5 Hz ceiling
    /// with a trailing post, so a flood does not spam a reader and a burst's
    /// final state is not swallowed by the ceiling that tamed it. Both shells
    /// throttle identically because neither of them decides.
    ///
    /// Only the delivery differs, and only in the name of the call.
    internal func noteAccessibilityContentChanged() {
        isAccessibilityTextDirty = true
        let decision = accessibilityNotifyThrottle.noteChange(Date.timeIntervalSinceReferenceDate)
        switch decision.action {
        case .postNow:
            postAccessibilityValueChanged()
        case .scheduleTrailing:
            DispatchQueue.main.asyncAfter(deadline: .now() + decision.delaySeconds) { [weak self] in
                guard let self else { return }
                self.accessibilityNotifyThrottle.noteTrailingFired(Date.timeIntervalSinceReferenceDate)
                self.postAccessibilityValueChanged()
            }
        case .alreadyScheduled:
            break
        default:
            break
        }
    }

    private func postAccessibilityValueChanged() {
        #if canImport(AppKit)
        NSAccessibility.post(element: self, notification: .valueChanged)
        #else
        // UIKit has no per-element value-changed for a custom view whose
        // whole content is the value; a layout change is what tells
        // VoiceOver to re-read it.
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
        #endif
    }

    /// Mirrors the scrollback extent into whatever chrome this shell shows.
    ///
    /// The AppKit shell has a native scroll bar. A phone shows position its own
    /// way and shows nothing here yet — which is a shell's business, not the
    /// terminal's, so the call site says the same thing on both.
    ///
    /// What the bar shows is not this shell's decision and not this call's
    /// argument: `Runtime::scrollerChrome` answers both how far it may scroll
    /// and which way its knob is tinted, off the same published snapshot the
    /// Metal arm reads and the same `Runtime::viewOffsetLimit` the view is
    /// clamped to, so the bar's range and the range the view may reach cannot
    /// be two numbers. It also answers whether the application asks for a bar
    /// at all: rxvt's DEC private mode ?30 rides the same snapshot rather than
    /// a client push this shell does not install, which is why the visibility
    /// is pushed ahead of the extent — the bar takes one answer per drain, not
    /// two.
    ///
    /// - Parameters:
    ///   - viewOffsetLines: Where the view sits, rows above the live tail.
    ///   - reveal: Whether the movement was the user's, so an overlay bar
    ///     flashes rather than refreshing quietly.
    /// Re-syncs the bar's extent from the published snapshot.
    ///
    /// For the surface with no drain of its own: a tmux render-only pane's
    /// rows arrive without one, so the count the bar sizes its knob from moves
    /// with nothing to tell the bar about it.
    package func refreshScrollbackChrome() {
        updateScrollbackChrome(viewOffsetLines: viewOffset, reveal: false)
    }

    internal func updateScrollbackChrome(viewOffsetLines: Int, reveal: Bool) {
        guard frameDelivery == .Draw else { return }
        #if canImport(AppKit)
        let snapshot = drive.readSnapshot()
        let chrome = Ubiquitty.Runtime.scrollerChrome(snapshot)
        terminalScroller.isPrimaryScreen = !snapshot.modes.alternateScreenActive
        terminalScroller.knobStyle = chrome.prefersLightKnob ? .light : .dark
        terminalScroller.setScrollbarVisible(chrome.isBarVisible)
        terminalScroller.update(
            scrollbackLines: Int(chrome.scrollbackLines),
            viewOffsetLines: viewOffsetLines,
            viewportRows: Int(snapshot.rows),
            reveal: reveal
        )
        #else
        if viewOffsetLines == 0 { rowsArrivedWhileScrolledBack = 0 }
        let position = TerminalScrollbackPosition(
            rowsAboveTail: viewOffsetLines,
            reachableRows: viewOffsetLimit,
            visibleRows: Int(drive.readSnapshot().rows),
            rowsArrivedBelow: rowsArrivedWhileScrolledBack
        )
        guard position != reportedScrollbackPosition else { return }
        reportedScrollbackPosition = position
        observer?.terminalSurface(self, didChangeScrollback: position)
        #endif
    }
}
