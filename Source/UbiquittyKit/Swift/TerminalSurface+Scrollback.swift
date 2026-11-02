// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+Scrollback.swift — the surface's view over history: the
// offset it maintains, the follow-tail policy when the tail grows under a
// scrolled-back view, and the reveal arithmetic. Every policy here is Core's —
// ScrollTuning folds the deltas, viewOffsetLimit says how far and
// clampViewOffset bounds the offset,
// shouldSnapToTail arbitrates output against reading — so this file dispatches
// and owns no tuning of its own.
//
// Shared by both shells, because every answer above is the same on a desktop
// and a phone. Only the gestures that move the view differ, and they live in
// TerminalSurface+ScrollbackAppKit.swift beside this.

internal import UbiquittyCore
internal import UbiquittyRenderKit

#if canImport(AppKit)
import AppKit
#endif

extension TerminalSurface {
    /// The wheel and trackpad tuning this surface folds deltas through.
    ///
    /// Built from config by `Preferences::Effective::wheelPolicy` — the one
    /// builder every frontend shares, so two views over one config cannot
    /// scroll at two speeds — unless an embedder supplied its own.
    ///
    /// Derived per read rather than cached because the two inputs both move
    /// under it: a config edit changes the speeds, and a font-size change
    /// changes the points-per-line the precise-delta path divides by. A cached
    /// copy would need invalidating from both, and the read is a struct fill.
    ///
    /// Package-visible rather than public: the policy is a C++-imported type,
    /// and the framework's resilient interface cannot name one — an
    /// out-of-package embedder configures scrolling through config once a
    /// scalar facade exists.
    package var wheelPolicy: Ubiquitty.Screen.ScrollTuning.Policy {
        get { wheelTuning }
        set { injectedWheelPolicy = newValue }
    }

    /// The tuning a scroll event folds through: the embedder's when one was
    /// injected, else the config's.
    internal var wheelTuning: Ubiquitty.Screen.ScrollTuning.Policy {
        if let injected = injectedWheelPolicy {
            return injected
        }
        return Ubiquitty.Preferences.Effective.wheelPolicy(
            Ubiquitty.Preferences.values().pointee,
            Double(scrollbackCellHeightPoints)
        )
    }

    /// How far this surface's view may scroll back, as Core reads it off the
    /// published snapshot.
    ///
    /// Read per use rather than cached: the limit moves with every drain and
    /// again on every screen switch, so a cached copy would need invalidating
    /// from both, and the read is a field off a lock-free snapshot.
    internal var viewOffsetLimit: Int {
        Int(Ubiquitty.Runtime.viewOffsetLimit(drive.readSnapshot()))
    }

    /// Moves the view by whole lines, clamped to what Core says is reachable.
    ///
    /// - Parameter delta: Lines toward history when positive.
    package func offsetView(byLines delta: Int) {
        setViewOffset(absolute: viewOffset + delta)
    }

    /// Places the view at an absolute offset, clamped to what Core says is
    /// reachable.
    ///
    /// - Parameter requested: Rows above the tail; clamped into range.
    internal func setViewOffset(absolute requested: Int) {
        setViewOffset(absolute: requested, limit: viewOffsetLimit)
    }

    /// The one clamp, taking the limit rather than reading it.
    ///
    /// The drain path holds history facts it read under the model lock, newer
    /// than the snapshot the computed limit reads, and passes them here so an
    /// offset is not clamped against a count the drain has already moved past.
    /// Every other caller goes through the entry points above. The label is
    /// `limit` and never a count: the retained storage count stays true on the
    /// alternate screen, where no offset into it is reachable.
    ///
    /// - Parameters:
    ///   - requested: Rows above the tail; clamped into range.
    ///   - limit: The greatest reachable offset: `Runtime::viewOffsetLimit`,
    ///     or `HistoryFacts.retainedRows` for a caller holding the facts.
    internal func setViewOffset(absolute requested: Int, limit: Int) {
        let clamped = Int(Ubiquitty.Screen.clampViewOffset(Int32(requested), Int32(limit)))
        guard clamped != viewOffset else { return }
        viewOffset = clamped
        noteScrollMovement()
    }

    /// Steps the viewport to the neighbouring OSC 133 prompt.
    ///
    /// The step is Core's — `Screen::stepToPrompt`, reached through the
    /// session so the mark scan runs under the model lock — and what is here
    /// is the anchor this surface remembers between steps and the three ways
    /// the result is applied. Without the anchor a walk up through several
    /// prompts re-derives from the viewport each time and sticks on the one
    /// nearest the top edge.
    ///
    /// - Parameter direction: Negative to step back through history, positive
    ///   to step forward toward the live tail.
    package func stepToPrompt(direction: Int) {
        let step = drive.stepToPrompt(
            viewOffset: viewOffset,
            anchorRow: promptNavigationAnchorRow,
            direction: direction
        )
        switch step.action {
        case .Bell:
            #if canImport(AppKit)
            NSSound.beep()
            #endif
        case .Scroll, .SnapToTail:
            promptNavigationAnchorRow = Int(step.newAnchor)
            setViewOffset(absolute: Int(step.newViewOffset))
            // Unconditionally, not only when the offset moved: a step that
            // lands on a prompt already at the top edge moves the anchor and
            // nothing else, and `setViewOffset` returns early on an unchanged
            // offset.
            needsDisplay = true
        @unknown default:
            break
        }
    }

    /// Publishes a viewport move: the schedule's conservative blink arm, the
    /// scroll bar, and a repaint all follow the new offset.
    internal func noteScrollMovement() {
        selectionModel.withSession {
            drive.observeSelectionViewport(&$0, viewOffset: viewOffset)
        }
        drive.setPresentedViewOffset(viewOffset)
        // The projection reads the viewed rows, so a viewport move stales it.
        noteAccessibilityContentChanged()
        updateScrollbackChrome(viewOffsetLines: viewOffset, reveal: true)
        #if canImport(AppKit)
        // The text moved, the pointer did not: whatever it was over has
        // scrolled away, and whatever took its place is what it is over now.
        // No move event is coming to say so.
        updateLinkAffordanceAtLivePointer()
        #endif
        needsDisplay = true
        frameClock.noteAnimationActivity()
    }

    /// Publishes the model's scrollback extent to the chrome without moving
    /// the view.
    ///
    /// The other two refreshes cover a viewport that moved
    /// (``noteScrollMovement()``) and a drain that delivered output
    /// (``followTailOrHoldViewport(history:)``). Neither covers a main-thread
    /// edit of the model under a view that stays where it is: the offset
    /// does not change, so nothing publishes, and an edit that sends the
    /// process no bytes is followed by no drain either, so the bar would go
    /// on sizing itself on history the model no longer holds.
    ///
    /// Quiet by construction: an extent that changed is not a scroll, so the
    /// overlay bar is not flashed for one.
    internal func refreshScrollbackChromeFromModel() {
        // The drain's reveal comparator differences against the extent as of
        // this surface's last look at the model, and this is one.
        lastScrollbackCount = viewOffsetLimit
        updateScrollbackChrome(viewOffsetLines: viewOffset, reveal: false)
    }

    /// Captures the top logical position before a local grid change.
    internal func noteViewportBeforeResize() {
        selectionModel.withSession { drive.noteViewportBeforeResize(&$0, viewOffset: viewOffset) }
    }

    /// Resolves the top logical position after the grid changes and refreshes chrome.
    internal func carryViewOffsetAcrossResize() {
        if viewOffset > 0 {
            viewOffset = selectionModel.withSession {
                drive.selectionViewportAfterResize(&$0, viewOffset: viewOffset)
            }
            drive.setPresentedViewOffset(viewOffset)
            needsDisplay = true
        }
        // Quiet, and re-baselined in one call: the bar is sized by the
        // viewport's share of the content and the resize just moved the
        // viewport, while a resize is not growth and must not flash an overlay
        // bar the reader did not touch.
        refreshScrollbackChromeFromModel()
    }

    /// Returns the view to the live tail, the way a reader's Jump to Bottom
    /// does.
    public func scrollToTail() {
        setViewOffset(absolute: 0)
    }

    /// Returns the view to the live tail after a key press, when the mode
    /// says to.
    ///
    /// DEC 1011, default on: typing means the user is acting on the live
    /// screen, so the view leaves history to show it. Core owns the policy —
    /// this realizes the offset reset, the same split the Metal arm records on
    /// its snapToTailOnKeypress. Without it, one wheel touch pins the view in
    /// history and every full repaint an application draws lands out of
    /// sight, which reads as a screen that stopped refreshing.
    package func snapToTailOnKeypress() {
        let shouldSnap =
            drive.withTerminal { Ubiquitty.Modes.shouldSnapToTail($0, .Keypress) } ?? false
        guard shouldSnap else { return }
        setViewOffset(absolute: 0)
        #if canImport(AppKit)
        terminalScroller.cancelScrollGesture()
        #endif
    }

    /// Holds the viewed rows or snaps to the tail after output landed.
    ///
    /// A tail view follows output, including during an open selection gesture.
    /// A selection already back in history holds; otherwise the scroll-on-output
    /// policy decides. Remote logical anchors resolve under the model lock.
    internal func followTailOrHoldViewport() {
        followTailOrHoldViewport(history: drive.readSnapshot().history)
    }

    /// The policy core of ``followTailOrHoldViewport()``, taking the history
    /// facts instead of reading the published snapshot — the snapshot
    /// republishes on the drain path, so a caller that fed the model directly
    /// passes the facts it read under the lock.
    ///
    /// - Parameter history: The retained history as the output left it.
    internal func followTailOrHoldViewport(history: Ubiquitty.Screen.HistoryFacts) {
        let scrollback = Int(history.retainedRows)
        defer { lastScrollbackCount = scrollback }
        // Core reads the mode, keeps the baseline and decides; this surface
        // supplies where its view sits and applies the verdict.
        #if canImport(UIKit)
        var appendedRows = 0
        #endif
        let output = selectionModel.withSession {
            #if canImport(UIKit)
            if $0.hasViewportObservation, $0.viewportObservedHistory.absoluteRowEpoch == history.absoluteRowEpoch {
                appendedRows = Int(max(0, history.appendedRows - $0.viewportObservedHistory.appendedRows))
            }
            #endif
            return drive.updateSelectionAfterOutput(&$0, viewOffset: viewOffset, history: history)
        }
        let viewport = output.viewport
        if output.didChangeSelection {
            needsDisplay = true
        }
        guard viewport.hold == .hold else {
            guard viewOffset > 0 else {
                // Already at the tail and staying: the offset does not move, so
                // only the scroller's extent is refreshed.
                updateScrollbackChrome(viewOffsetLines: 0, reveal: false)
                return
            }
            setViewOffset(absolute: Int(viewport.viewOffset), limit: scrollback)
            return
        }
        let next = Int(viewport.viewOffset)
        #if canImport(UIKit)
        if next > 0 {
            // Retained rows stop growing at the history limit; Core's appended
            // count still records new output as older rows are evicted.
            rowsArrivedWhileScrolledBack += min(appendedRows, Int.max - rowsArrivedWhileScrolledBack)
        }
        #endif
        if next != viewOffset {
            viewOffset = next
            drive.setPresentedViewOffset(next)
            needsDisplay = true
        }
        updateScrollbackChrome(viewOffsetLines: viewOffset, reveal: scrollback != lastScrollbackCount)
    }
}

/// Where a view stands in its terminal's scrollback.
public struct TerminalScrollbackPosition: Equatable, Sendable {
    /// Rows the view is scrolled back from the live tail; zero at the tail.
    public let rowsAboveTail: Int
    /// The furthest the view can scroll back.
    public let reachableRows: Int
    /// Rows the view shows.
    public let visibleRows: Int
    /// Rows of output that arrived below the view while it was held back.
    public let rowsArrivedBelow: Int

    /// Whether the view is away from the live tail.
    public var isScrolledBack: Bool { rowsAboveTail > 0 }
}
