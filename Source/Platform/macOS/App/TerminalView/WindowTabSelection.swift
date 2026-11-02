// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// WindowTabSelection.swift — which window of a native tab group is in front.
//
// One derivation both shells read. A pane's cursor paints filled when its
// window is a tab behind the group's front one, and the two arms asking that
// question their own way is how one shell comes to leave a hollow outline on a
// reselected tab while the other does not.
//

import AppKit

/// The tab-group facts a terminal pane's presentation depends on.
@objc(UBWindowTabSelection)
@MainActor
public final class WindowTabSelection: NSObject {
    /// Resolves chrome activation from the tab group's key or main window.
    package static func isGroupActive(_ window: NSWindow) -> Bool {
        guard NSApp.isActive else { return false }
        return (window.tabGroup?.windows ?? [window]).contains { $0.isKeyWindow || $0.isMainWindow }
    }

    /// Whether a window is a native tab behind its group's front one.
    ///
    /// A background tab is occluded by the front tab, so its cursor is never on
    /// screen: the unfocused hollow outline is meaningful only for a terminal
    /// that can be seen, an inactive split pane or a separate unoccluded
    /// window, each its own group's selected window. On a background tab the
    /// outline would surface only as a stale frame the instant the tab is
    /// reselected, which is why the fill is held instead.
    ///
    /// `selectedWindow` moves synchronously with the tab switch, ahead of any
    /// frame, so a tab leaving the front latches filled even on the frame where
    /// occlusion has not caught up.
    ///
    /// The flip changes no cell, so nothing in a drain dirties a row for it;
    /// each shell asks its view for a frame when the answer moves, which is
    /// AppKit mechanics and the one thing left per arm. The answer itself is
    /// only ever read here.
    ///
    /// - Parameter window: The pane's window. Nil, no tab group, or a group
    ///   with no selection is not a background tab: a lone window is behind
    ///   nothing.
    /// - Returns: Whether the window sits behind its group's front tab.
    @objc(isWindowBackgroundedTab:)
    public static func isBackgroundedTab(_ window: NSWindow?) -> Bool {
        guard let window, let group = window.tabGroup, let selected = group.selectedWindow else {
            return false
        }
        return selected !== window
    }
}
