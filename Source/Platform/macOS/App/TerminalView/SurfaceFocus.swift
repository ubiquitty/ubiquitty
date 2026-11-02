// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SurfaceFocus.swift — the AppKit half of Core's surface-focus rule.
//
// The facts only a windowing system can answer, which window takes keys, which
// view answers them and whether the application owns the keyboard, gathered
// once for both shells. What they mean is Runtime::surfaceFocus in
// Source/Core/Runtime/SurfaceFocus.h.
//
// Two AppKit-shaped rules live here as well, because both shells need them and
// neither is Core's to state: whether an activation may hand a window's first
// responder to its focused pane, and the settled pass. AppKit installs a new
// first responder after becomeFirstResponder returns, so a pass taken inside
// the callback reads the responder the window is leaving; one turn later it
// reads the one it arrived at.
//

import AppKit
import UbiquittyCore

/// Core's verdict about one view, as an Objective-C view can read it.
@objc(UBSurfaceFocusReading)
@MainActor
public final class SurfaceFocusReading: NSObject {
    /// Whether the view answers the keyboard.
    @objc
    public let isFocused: Bool
    /// Whether the caret must be held solid before the next frame draws.
    @objc
    public let wantsActivityNote: Bool

    /// Wraps one verdict.
    ///
    /// - Parameters:
    ///   - isFocused: Whether the view answers the keyboard.
    ///   - wantsActivityNote: Whether the caret latches solid.
    init(isFocused: Bool, wantsActivityNote: Bool) {
        self.isFocused = isFocused
        self.wantsActivityNote = wantsActivityNote
    }
}

/// The window facts behind a terminal surface's focus, for both macOS shells.
@objc(UBSurfaceFocus)
@MainActor
public final class SurfaceFocus: NSObject {
    /// The facts around a view, as Core's rule reads them.
    ///
    /// A view outside a window reports none of them: a host that draws
    /// offscreen knows what focus means without a window and answers for
    /// itself.
    ///
    /// - Parameter view: The view whose focus is in question.
    /// - Returns: The facts, for `Runtime::surfaceFocus`.
    // swift-only: a C++ struct has no printer representation; Objective-C views
    // read the verdict through the reading below
    public static func facts(for view: NSView) -> Ubiquitty.Runtime.SurfaceFocusFacts {
        var facts = Ubiquitty.Runtime.SurfaceFocusFacts()
        facts.isApplicationActive = NSApp.isActive
        guard let window = view.window else { return facts }
        facts.isWindowKey = window.isKeyWindow
        facts.isFirstResponder = window.firstResponder === view
        return facts
    }

    /// Core's verdict for a view, both halves of it.
    ///
    /// An `@objc` entry because an Objective-C view asks in Objective-C, where
    /// the C++ verdict has no representation; the Swift surface reads the
    /// verdict itself through ``facts(for:)``. The activity half rides along
    /// so no caller keeps an arrival-edge rule of its own.
    ///
    /// - Parameters:
    ///   - view: The view whose focus is in question.
    ///   - isPublishedFocused: Whether the view last published itself focused.
    /// - Returns: Whether the view is focused and whether the caret latches.
    @objc(readingForView:isPublishedFocused:)
    public static func reading(for view: NSView, isPublishedFocused: Bool) -> SurfaceFocusReading {
        let verdict = Ubiquitty.Runtime.surfaceFocus(facts(for: view), isPublishedFocused ? .Focused : .Unfocused)
        return SurfaceFocusReading(isFocused: verdict.focus == .Focused, wantsActivityNote: verdict.wantsActivityNote)
    }

    /// Whether an activation must hand this window's first responder to its
    /// focused surface.
    ///
    /// A window can be given key or main status before a responder is
    /// restored, since closing a tab leaves the survivor with none, and a
    /// focus recompute run against that window finds no responder and latches
    /// the caret hollow for a frame, the blink resuming mid-curve instead of at
    /// its solid first frame. The restore is refused whenever anything already
    /// answers keys, so an open find field keeps what the reader is typing
    /// into. AppKit-shaped rather than Core's because its one fact is the
    /// responder chain's identity, which has no Core counterpart.
    ///
    /// - Parameter window: The window that took key or main status.
    /// - Returns: Whether the shell restores the responder.
    @objc(wantsFirstResponderRestoreInWindow:)
    public static func wantsFirstResponderRestore(inWindow window: NSWindow) -> Bool {
        window.firstResponder == nil || window.firstResponder === window
    }

    /// Runs a focus recompute against the state AppKit has, and again against
    /// the state it settles on.
    ///
    /// AppKit installs a first responder after the callback that announced it
    /// returns, so one pass alone reads either the responder being left or the
    /// one being arrived at, depending on which edge ran it. Both passes run
    /// the same idempotent recompute, and the session's own focus edge gate
    /// drops the pass that changes nothing.
    ///
    /// - Parameter recompute: The recompute to run twice.
    @objc(applyAcrossSettling:)
    public static func applyAcrossSettling(_ recompute: @escaping @Sendable () -> Void) {
        recompute()
        DispatchQueue.main.async { recompute() }
    }
}
