// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// TabButtonProgressBar.swift — the selected tab's own progress band, inside
// its pill.
//
// A tabbed window's content-top band steps aside: the strip is where a reader
// looks to see which tab is doing what, so the selected tab carries its report
// on its own pill and the others carry theirs in the ring accessory. Which of
// the three slots owns the display is `OSC::tabButtonBarVisible` and its
// siblings, so the slots partition the cases instead of two of them lighting
// up for one download.
//
// The bar is homed in a view AppKit publishes nothing about, so the home can go
// stale: rebuilding the strip detaches the bar without telling anyone. That is
// why the fast path below asks whether the bar still has a window rather than
// remembering that it was placed — a remembered placement is a promise about a
// view hierarchy this code does not own.

import AppKit
internal import UbiquittyRenderKit

/// The progress band inside a tab's pill, for whichever window is selected.
@MainActor
@objc(UBTabButtonProgressBar)
public final class TabButtonProgressBar: NSObject {
    /// Puts, restyles or takes away the selected tab's band.
    ///
    /// Both shells call this and neither holds the view: the pill owns it while
    /// it is placed, and a band that is not wanted is taken out of the strip
    /// entirely rather than hidden, because the pill it was in may be gone.
    ///
    /// - Parameters:
    ///   - window: Any window of the group; the strip is shared.
    ///   - state: A `Ubiquitty::OSC::ProgressState`, as stored on the wire.
    ///   - value: The percent, 0 to 100, for the determinate states.
    ///   - tint: The colour the role resolves to.
    ///   - isWanted: Whether this slot owns the display, as Core ranked it.
    @objc(reconcileInWindow:state:value:tint:isWanted:)
    public static func reconcile(in window: NSWindow, state: UInt8, value: UInt8, tint: NSColor, isWanted: Bool) {
        let strip = TabStripStyling.tabStripView(inGroupOf: window)
        let placed = strip.flatMap { firstBand(under: $0) }
        guard isWanted else {
            placed?.removeFromSuperview()
            return
        }
        // Still homed in the selected tab's live pill: a progress tick only
        // restyles it, and the walk below is a descent through the whole title
        // row. A live pill alone is not enough. Where AppKit keeps the pills
        // across a selection change instead of rebuilding them, the band stays
        // on the tab that is no longer selected.
        if let placed, placed.window != nil, let strip, TabStripStyling.isInSelectedPill(placed, under: strip) {
            placed.tintColor = tint
            placed.setState(state, value: value)
            return
        }
        guard let target = TabStripStyling.activePillContent(inGroupOf: window) else {
            // No pill to pin into — an older system, or a strip mid-rebuild.
            // The ring accessory is what carries the report there.
            placed?.removeFromSuperview()
            return
        }
        let band = placed ?? makeBand()
        if band.superview !== target {
            // In one transaction with actions disabled, for the same reason the
            // strip's own repaint takes one. `target` is the pill's content
            // view, whose flat theme fill the strip paints; adding a subview to
            // it is a content change the glass animates, and what crossfades is
            // that fill — the theme-coloured rectangle that appears behind a
            // tab on a window switch and dies away. Only the tab hosting the
            // band re-parents, which is why only a tab with a spinner shows it.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            band.removeFromSuperview()
            target.addSubview(band)
            NSLayoutConstraint.activate([
                band.leadingAnchor.constraint(equalTo: target.leadingAnchor),
                band.trailingAnchor.constraint(equalTo: target.trailingAnchor),
                band.bottomAnchor.constraint(equalTo: target.bottomAnchor),
            ])
            CATransaction.commit()
        }
        band.tintColor = tint
        band.setState(state, value: value)
    }

    /// A band dressed the way every progress slot in this app is.
    ///
    /// - Returns: The band, unplaced.
    private static func makeBand() -> ProgressBar {
        let band = ProgressBar(frame: .zero)
        band.capRadius = 0
        band.borderWidth = 0
        band.trackColor = .clear
        band.translatesAutoresizingMaskIntoConstraints = false
        return band
    }

    /// The band already standing somewhere in a strip.
    ///
    /// - Parameter root: The strip to search.
    /// - Returns: The band, or nil when none is placed.
    private static func firstBand(under root: NSView) -> ProgressBar? {
        if let band = root as? ProgressBar {
            return band
        }
        for subview in root.subviews {
            if let found = firstBand(under: subview) {
                return found
            }
        }
        return nil
    }
}
