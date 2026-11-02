// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// BroadcastInputMemory.swift — whether a window opens with every keystroke
// reaching every pane.
//
// A frontend-only preference of the same class as the window level: nothing in
// Core has an opinion about which of a window's panes a key lands in, and no
// other frontend has the concept. It is remembered because the reader who
// turned it on is running a fleet of hosts side by side and expects the next
// window to behave the way the last one did — and because a mode that silently
// resets is one they find out about by typing into it.

import AppKit

@MainActor
@objc(UBBroadcastInputMemory)
public final class BroadcastInputMemory: NSObject {
    // The one key both shells read and write, so a window opened by either
    // arm restores what the other one left.
    private static let defaultsKey = "UBBroadcastInput"

    /// Whether windows were last left broadcasting.
    ///
    /// - Returns: Whether a window opens broadcasting. False when nothing was
    ///   ever asked for, which is the default this preference has: fanning
    ///   keystrokes out is the surprising answer, and an unasked-for surprise
    ///   is the one this mode can least afford.
    @objc
    public static func isBroadcasting() -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Remembers the mode a window was just put into.
    ///
    /// - Parameter isBroadcasting: What the window is now.
    @objc(setBroadcasting:)
    public static func set(_ isBroadcasting: Bool) {
        UserDefaults.standard.set(isBroadcasting, forKey: defaultsKey)
    }
}
