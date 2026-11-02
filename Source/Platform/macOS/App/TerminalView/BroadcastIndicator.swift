// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// BroadcastIndicator.swift — the pill a window wears while every keystroke
// reaches every pane.
//
// Broadcast input is the one mode where the screen tells the reader nothing:
// the focused pane looks exactly as it does normally, and the difference only
// shows once the other panes have already been typed into. So the mode says so
// out loud, in the title row, in the red the rest of the system uses for "this
// is not the usual state of affairs".
//
// The pill is made on the first enable rather than at window open. Broadcast
// is off in nearly every window in a session's life, and an accessory built
// for each of them is a view hierarchy and a layout pass per window spent on
// something nobody will see.

@preconcurrency import AppKit
import UbiquittyCore

/// The broadcast pill in a window's accessory bar.
@objc(UBBroadcastIndicator)
public final class BroadcastIndicator: NSView {
    /// Left of the presence badge, the clipboard badge and the lock: those
    /// three report what the system or a session is doing, and this reports
    /// what the reader themselves turned on.
    @objc
    public static let priority = 60

    private enum Metrics {
        /// The chrome chip's type, shared with the titlebar tag chips so the
        /// row reads as one family.
        static let pointSize: CGFloat = 9.5
        static let paddingBesideText: CGFloat = 7
        static let paddingAboveText: CGFloat = 2
        /// The capsule sits a little above the row's centre, where the eye
        /// puts the middle of a title next to the traffic lights.
        static let liftAboveCentre: CGFloat = 2
    }

    /// Shows or hides a window's pill, making it the first time it is shown.
    ///
    /// Both shells call this and neither holds the view: the bar already owns
    /// its accessories, so the pill is found there rather than remembered
    /// beside it, and there is no second place for the two to disagree about
    /// whether a window has one.
    ///
    /// - Parameters:
    ///   - isBroadcasting: Whether the window is broadcasting.
    ///   - bar: The window's accessory bar.
    @objc(setBroadcasting:inBar:)
    public static func setBroadcasting(_ isBroadcasting: Bool, in bar: ChromeAccessoryBar) {
        var pill = bar.subviews.compactMap { $0 as? BroadcastIndicator }.first
        if pill == nil {
            guard isBroadcasting else {
                // Nothing to show yet, and no accessory to hide.
                return
            }
            pill = install(in: bar)
        }
        guard let pill else { return }
        bar.setShown(pill, isBroadcasting)
    }

    /// Puts a pill into a bar, hidden until a window says otherwise.
    ///
    /// - Parameter bar: The window's accessory bar.
    /// - Returns: The installed pill.
    @objc
    @discardableResult
    public static func install(in bar: ChromeAccessoryBar) -> BroadcastIndicator {
        let scale = ChromeTypography.scaled(1.0)
        let label = NSTextField(frame: .zero)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.isBezeled = false
        label.drawsBackground = false
        label.attributedStringValue = NSAttributedString(
            string: "BROADCASTING",
            attributes: [
                .font: NSFont.systemFont(ofSize: Metrics.pointSize * CGFloat(scale), weight: .semibold),
                // On the warning fill below, which is dark enough in both
                // appearances that white is the readable ink either way.
                .foregroundColor: NSColor.white,
            ]
        )
        label.sizeToFit()
        let textSize = label.frame.size
        let pillSize = NSSize(
            width: textSize.width + Metrics.paddingBesideText * 2,
            height: textSize.height + Metrics.paddingAboveText * 2
        )
        label.frame = NSRect(
            x: Metrics.paddingBesideText,
            y: Metrics.paddingAboveText,
            width: textSize.width,
            height: textSize.height
        )
        let pill = BroadcastIndicator(
            frame: NSRect(
                x: 0,
                y: (ChromeAccessoryBar.titleRowHeightInPoints - pillSize.height) / 2 + Metrics.liftAboveCentre,
                width: pillSize.width,
                height: pillSize.height
            )
        )
        pill.wantsLayer = true
        pill.layer?.cornerRadius = pillSize.height / 2
        // The system's own warning tint, so the mode reads as "be careful"
        // rather than as decoration.
        pill.layer?.backgroundColor = NSColor.systemRed.cgColor
        pill.addSubview(label)
        pill.isHidden = true
        bar.add(pill, priority: priority)
        return pill
    }
}
