// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Retains a bounded set of local windows for recovery with their live processes.
@MainActor
final class ClosedWindowRecovery: NSObject, NSMenuItemValidation {
    static let shared = ClosedWindowRecovery()

    private struct Entry {
        let identifier: UUID
        let controller: TerminalWindowController
        let expiration: Task<Void, Never>
        let tabbingMode: NSWindow.TabbingMode
        let wasExcludedFromWindowsMenu: Bool
    }

    private var entries: [Entry] = []

    /// Installs recovery in the File menu once the application has built it.
    func installMenuItem() {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
            !menu.items.contains(where: { $0.identifier?.rawValue == "reopenClosedWindow" })
        else { return }
        let item = NSMenuItem(title: "Reopen Closed Window", action: #selector(reopen(_:)), keyEquivalent: "t")
        item.identifier = NSUserInterfaceItemIdentifier("reopenClosedWindow")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        menu.insertItem(item, at: min(2, menu.items.count))
    }

    /// Hides an eligible window while keeping its actual process and terminal.
    ///
    /// - Parameter controller: The window whose close did not require confirmation.
    /// - Returns: Whether the window is retained instead of being destroyed.
    func retainForRecovery(_ controller: TerminalWindowController) -> Bool {
        guard !controller.isWindowClosed, controller.isWindowShareable, controller.isSafeToClose,
            let window = controller.window, (window.tabGroup?.windows.count ?? 1) == 1,
            !entries.contains(where: { $0.controller === controller })
        else { return false }
        while entries.count >= 8 {
            let expired = entries.removeFirst()
            expired.expiration.cancel()
            expired.controller.window?.close()
        }
        let identifier = UUID()
        let expiration = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.expire(identifier)
        }
        entries.append(
            Entry(
                identifier: identifier,
                controller: controller,
                expiration: expiration,
                tabbingMode: window.tabbingMode,
                wasExcludedFromWindowsMenu: window.isExcludedFromWindowsMenu
            )
        )
        TerminalWindowController.spawnedControllers.removeAll { $0 === controller }
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.orderOut(nil)
        return true
    }

    /// Removes a window that another close path has destroyed.
    ///
    /// - Parameter controller: The window being destroyed.
    func forget(_ controller: TerminalWindowController) {
        for entry in entries where entry.controller === controller { entry.expiration.cancel() }
        entries.removeAll { $0.controller === controller }
    }

    private func expire(_ identifier: UUID) {
        guard let index = entries.firstIndex(where: { $0.identifier == identifier }) else { return }
        let expired = entries.remove(at: index)
        expired.controller.window?.close()
    }

    /// Reopens the most recently closed window with its original live terminal.
    ///
    /// - Parameter sender: The menu item, unused.
    @objc
    func reopen(_ sender: Any?) {
        guard let entry = entries.popLast() else { return }
        entry.expiration.cancel()
        guard !entry.controller.isWindowClosed, let window = entry.controller.window else { return }
        TerminalWindowController.spawnedControllers.append(entry.controller)
        window.isExcludedFromWindowsMenu = entry.wasExcludedFromWindowsMenu
        window.tabbingMode = entry.tabbingMode
        entry.controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(entry.controller.focusedSurface)
    }

    /// Enables recovery while a retained window remains available.
    ///
    /// - Parameter menuItem: The recovery item.
    /// - Returns: Whether a window can be reopened.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !entries.isEmpty
    }
}
