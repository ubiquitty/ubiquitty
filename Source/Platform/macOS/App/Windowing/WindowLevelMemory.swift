// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// WindowLevelMemory.swift — whether a window floats above other applications.
//
// A frontend-only preference: nothing in Core has an opinion about where a
// window sits in the display server's stacking order, and no other frontend has
// the concept. It is remembered so the answer outlives the window that was
// asked, and read at creation so a window opens the way the last one was left.

import AppKit

@MainActor
@objc(UBWindowLevelMemory)
public final class WindowLevelMemory: NSObject {
    // The one key both shells read and write. A window that floated when the
    // reader last quit floats when they come back.
    private static let defaultsKey = "UBKeepOnTop"

    /// Whether windows were last left floating.
    ///
    /// - Returns: Whether to open floating. False when nothing was ever asked
    ///   for, which is the default this preference has.
    @objc
    public static func isKeptOnTop() -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Applies the remembered level to a window that is opening.
    ///
    /// - Parameter window: The window to place.
    @objc
    public static func apply(to window: NSWindow) {
        setLevel(on: window, isKeptOnTop: isKeptOnTop())
    }

    /// Flips whether windows float, applies it, and remembers the answer.
    ///
    /// The answer is remembered for every window that opens afterwards; which
    /// of the windows already open are re-levelled is the caller's, because
    /// only it knows which ones it speaks for.
    ///
    /// - Parameter windows: The windows to place now.
    /// - Returns: Whether they float now.
    @objc(toggleApplyingTo:)
    @discardableResult
    public static func toggle(applyingTo windows: [NSWindow]) -> Bool {
        let isKeptOnTop = !isKeptOnTop()
        UserDefaults.standard.set(isKeptOnTop, forKey: defaultsKey)
        for window in windows {
            setLevel(on: window, isKeptOnTop: isKeptOnTop)
        }
        return isKeptOnTop
    }

    private static func setLevel(on window: NSWindow, isKeptOnTop: Bool) {
        window.level = isKeptOnTop ? .floating : .normal
    }
}
