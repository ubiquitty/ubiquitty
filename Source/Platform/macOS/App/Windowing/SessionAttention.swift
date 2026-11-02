// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// SessionAttention.swift — a session asking to be noticed while the app is not
// the one the reader is in.
//
// A bell or a notification in a backgrounded application has nowhere to land:
// the window is behind something, the tab is behind another tab, and whatever
// the pane drew is not on screen. The Dock is the one surface that is, so a
// session that wants attention takes it there — a bounce, a badge, or both,
// per `[dock]`.
//
// No-op while the app is active, because the reader is already looking at it
// and a Dock icon jumping at somebody who is watching the window is noise. The
// badge count is the process's, since the Dock tile is: it counts asks since
// the last time the reader came back, and coming back clears it.

import AppKit
internal import UbiquittyCore

/// The Dock's share of a session asking to be noticed.
@MainActor
@objc(UBSessionAttention)
public final class SessionAttention: NSObject {
    /// Asks for attention on behalf of a session, if the app is not active.
    ///
    /// Both shells call this, so a bell in a backgrounded window bounces the
    /// same Dock icon whichever one drew it.
    @objc
    public static func note() {
        note(isAppActive: NSApp.isActive)
    }

    /// Asks for attention, given whether the app is the one the reader is in.
    ///
    /// The fact is taken rather than read so the gate can be put to both
    /// answers: an ask made while the reader is watching the window is noise,
    /// and a Dock icon that jumped anyway is the defect this guards.
    ///
    /// - Parameter isAppActive: Whether this app is frontmost.
    @objc(noteWhenAppActive:)
    public static func note(isAppActive: Bool) {
        guard !isAppActive else { return }
        let configuration = Ubiquitty.Preferences.values().pointee
        if Ubiquitty.Preferences.Effective.dockBadge(configuration) {
            pendingAskCount += 1
            NSApp.dockTile.badgeLabel = String(pendingAskCount)
        }
        if Ubiquitty.Preferences.Effective.dockBounce(configuration) {
            // Critical rather than informational: the icon keeps jumping until
            // the reader activates the app, which is the point of an ask made
            // while they are somewhere else.
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    /// Clears the badge, because the reader has come back.
    @objc
    public static func clear() {
        pendingAskCount = 0
        NSApp.dockTile.badgeLabel = nil
    }

    /// Whether a badge is standing, for a caller checking what the reader sees.
    @objc
    public static var isBadgeShowing: Bool { pendingAskCount > 0 }

    /// Asks made since the reader was last here. The Dock tile is the
    /// process's, so this is too — two windows asking twice is two.
    private static var pendingAskCount = 0
}
