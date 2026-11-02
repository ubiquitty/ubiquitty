// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0
//
// PasswordPromptRegistry.swift — which terminal views believe a password
// prompt is on screen, process-wide.
//
// Secure Keyboard Entry is a process-wide, counted resource held by one
// policy (the app delegate's), and that policy needs one fact: whether any
// pane, in either shell, is at a password prompt. Both shells report here;
// the delegate reads here and reconciles on every change. Views are held
// weakly, so one closed mid-prompt falls out of the count by itself.
//
import AppKit

/// The set of terminal views at a password prompt.
@MainActor
@objc(UBPasswordPromptRegistry)
public final class PasswordPromptRegistry: NSObject {
    /// The one registry.
    @objc
    public static let shared = PasswordPromptRegistry()

    /// Posted on the main thread when ``hasActivePrompt`` may have changed.
    @objc
    public static let didChangeNotification = Notification.Name("UBPasswordPromptRegistryDidChange")

    private let active = NSHashTable<AnyObject>.weakObjects()

    /// Whether any view is at a password prompt now.
    @objc
    public var hasActivePrompt: Bool {
        active.allObjects.isEmpty == false
    }

    /// Records a view's prompt state and announces a change.
    ///
    /// - Parameters:
    ///   - view: The terminal view reporting.
    ///   - isActive: Whether a password prompt is on its screen.
    @objc
    public func note(_ view: AnyObject, isActive: Bool) {
        let wasActive = hasActivePrompt
        if isActive {
            active.add(view)
        } else {
            active.remove(view)
        }
        if wasActive != hasActivePrompt {
            NotificationCenter.default.post(name: PasswordPromptRegistry.didChangeNotification, object: nil)
        }
    }

    /// Drops a view that is going away, announcing the change its absence
    /// makes; a weak table would drop it too, but without telling anyone.
    ///
    /// - Parameter view: The view being torn down.
    @objc
    public func forget(_ view: AnyObject) {
        note(view, isActive: false)
    }
}
