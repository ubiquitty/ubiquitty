// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The hand-off from a window's "Rules…" jump to the Settings Tags pane.
///
/// The jump stashes either the rule the window matched or the window's host,
/// and opens the pane; the pane takes the stash — one read clears it — and
/// opens that rule's editor, or its new-rule editor with the host pattern
/// prefilled. Two consumers cover the pane's two states: a freshly
/// built pane takes the stash from its own reload, and a pane already on
/// screen hears `pendingChanged`, posted a turn later so the fresh build has
/// already consumed by then and the nudge finds the stash empty.
///
/// Kept beside the windows rather than beside the pane, because both shells
/// jump and only one of them is above the pane: a window can call down to the
/// stash, and the pane, which is the app's, reads it from there.
@objc(TagRulePrefill)
@MainActor
public final class TagRulePrefill: NSObject {
    /// Reannounces a stash to a Tags pane already on screen, whose reload
    /// will not run again on its own.
    public static let pendingChanged = Notification.Name("UBTagRulePrefillPendingChanged")

    private static var pendingHost: String?

    private static var pendingRuleIndex: Int?

    /// Stashes `host` (nil for a local window) and opens the Tags pane.
    ///
    /// - Parameter host: The machine the jumping window is connected to.
    @objc(openWithHost:)
    public static func open(host: String?) {
        pendingHost = host
        pendingRuleIndex = nil
        showPane()
    }

    /// Stashes the rule a window matched and opens the Tags pane on it.
    ///
    /// - Parameter ruleIndex: The rule's position among the `[[tags]]` blocks.
    public static func open(ruleIndex: Int) {
        pendingHost = nil
        pendingRuleIndex = ruleIndex
        showPane()
    }

    private static func showPane() {
        // Sent rather than called: the Settings window belongs to the app,
        // which is above this, and the responder chain is how everything
        // window-shaped reaches it. The style gate holds the other end —
        // a selector naming no implementation fails it.
        NSApp.sendAction(
            NSSelectorFromString("showSettingsWindowForCategory:"),
            to: nil,
            from: "tags" as NSString
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: pendingChanged, object: nil)
        }
    }

    /// The stashed host, cleared by the read so a later reload cannot reopen
    /// the editor.
    ///
    /// - Returns: The host the jump carried, or nil when nothing is stashed.
    public static func takePendingHost() -> String? {
        let host = pendingHost
        pendingHost = nil
        return host
    }

    /// The stashed rule position, cleared by the read.
    ///
    /// - Returns: The rule the jump carried, or nil when nothing is stashed.
    public static func takePendingRuleIndex() -> Int? {
        let index = pendingRuleIndex
        pendingRuleIndex = nil
        return index
    }
}
