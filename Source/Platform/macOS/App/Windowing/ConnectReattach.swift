// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// ConnectReattach.swift — File ▸ Reattach (⌃⌘K): Core's plan for the last
// host, carried out without the Connect window when the plan can act alone.
//

import AppKit

/// The target of File ▸ Reattach, which titles and enables the item from the
/// last host a connect opened on.
@MainActor
@objc(UBConnectReattach)
final class ConnectReattach: NSObject, NSMenuItemValidation {
    /// The menu item's one target.
    @objc
    static let shared = ConnectReattach()

    /// Returns to the last host by Core's plan.
    ///
    /// - Parameter sender: The menu item.
    @objc
    func reattach(_ sender: Any?) {
        ConnectModel.shared.reattach()
    }

    /// Titles the item with the session and host it returns to, and disables
    /// it when there is no host to return to.
    ///
    /// - Parameter menuItem: The item.
    /// - Returns: Whether it is enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let model = ConnectModel.shared
        menuItem.title = model.reattachTitle
        return model.reattachTarget != nil
    }
}
