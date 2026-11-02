// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// WindowFrameMemory.swift — where a terminal window opens, and why there.
//
// A window that forgets is a window the user re-places every launch. The
// arithmetic that decides where it lands is Session::WindowPlacement, shared
// with the Metal arm so two shells of one application cannot disagree about
// where a second window goes; what is here is the platform's half — reading a
// frame back out of user defaults, finding the screen the user is working on,
// and knowing which of those a window may be told about.
//
// The defaults key is the Metal arm's, shared on purpose: a user switching renderers
// keeps their window where they left it, and two keys would make the switch
// look like the app forgetting.

import AppKit
internal import UbiquittyCore

/// The last window frame the app was left with, and where the next one goes.
@MainActor
enum WindowFrameMemory {
    /// Shared with the Metal arm — see the file comment.
    private static let defaultsKey = "UbiquittyWindowFrame"

    /// The frame a previous session left behind, if any.
    ///
    /// - Returns: The frame, or nil when nothing was saved or what was saved
    ///   no longer describes a window.
    static func savedFrame() -> NSRect? {
        guard let text = UserDefaults.standard.string(forKey: defaultsKey) else {
            return nil
        }
        let frame = NSRectFromString(text)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    /// Remembers a window's frame as where the next one opens.
    ///
    /// Which frames are worth remembering is Core's — a full-screen,
    /// minimised or empty frame describes no place a user chose — so the rule
    /// cannot drift between the two shells.
    ///
    /// - Parameter window: The window to remember.
    static func remember(_ window: NSWindow, doesSessionEndWithChild: Bool) {
        let frame = window.frame
        guard
            Ubiquitty.Session.WindowPlacement.isWorthPersisting(
                coreRect(frame),
                window.styleMask.contains(.fullScreen),
                window.isMiniaturized,
                doesSessionEndWithChild
            )
        else {
            return
        }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: defaultsKey)
    }

    /// The screen a freshly-opened window should land on.
    ///
    /// The one under the pointer, because that is where the user is working;
    /// else the key window's, else the main one. Without this a saved frame
    /// anchors to whichever display it was saved from, and a new window opens
    /// on the primary monitor while the user is on the second.
    ///
    /// - Returns: The screen, or nil when the app can see none.
    static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let under = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) {
            return under
        }
        return NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Places a window where the last one was, cascading and re-homing.
    ///
    /// - Parameters:
    ///   - window: The window to place.
    ///   - shouldCascade: Whether another terminal window is already on screen,
    ///     in which case this one steps off it rather than landing on it.
    static func place(_ window: NSWindow, cascadingFrom shouldCascade: Bool) {
        var frame = savedFrame() ?? window.frame
        if savedFrame() == nil {
            window.center()
            frame = window.frame
        }
        let savedScreen = screenContaining(frame)
        if shouldCascade {
            frame = appKitRect(
                Ubiquitty.Session.WindowPlacement.cascaded(
                    coreRect(frame),
                    coreRect(savedScreen?.visibleFrame ?? frame)
                )
            )
        }
        if let active = activeScreen(), active !== savedScreen {
            frame = appKitRect(
                Ubiquitty.Session.WindowPlacement.movedToScreen(
                    coreRect(frame),
                    coreRect(savedScreen?.visibleFrame ?? frame),
                    coreRect(active.visibleFrame)
                )
            )
        }
        window.setFrame(frame, display: false)
    }

    /// How many terminal windows are already on screen.
    ///
    /// The window being created is not among them — it has not been ordered in
    /// — which is what makes a non-zero count mean "cascade".
    ///
    /// - Returns: The count.
    static func visibleTerminalWindowCount() -> Int {
        NSApp.windows.filter { $0.isVisible && $0.windowController is TerminalWindowController }.count
    }

    /// The screen a frame sits on, by its origin.
    ///
    /// - Parameter frame: The frame to locate.
    /// - Returns: The screen, or the main one when nothing contains it.
    private static func screenContaining(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { NSPointInRect(frame.origin, $0.frame) } ?? NSScreen.main
    }

    /// A rect as Core spells one.
    static func coreRect(_ r: NSRect) -> Ubiquitty.FloatRect {
        Ubiquitty.FloatRect(
            origin: Ubiquitty.FloatPoint(x: Float(r.origin.x), y: Float(r.origin.y)),
            size: Ubiquitty.FloatSize(width: Float(r.size.width), height: Float(r.size.height))
        )
    }

    /// A rect as AppKit spells one.
    static func appKitRect(_ r: Ubiquitty.FloatRect) -> NSRect {
        NSRect(
            x: CGFloat(r.origin.x),
            y: CGFloat(r.origin.y),
            width: CGFloat(r.size.width),
            height: CGFloat(r.size.height)
        )
    }
}
