// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SettingsWindowController.swift — hosts the SwiftUI Settings UI in an
// AppKit window via NSHostingView, opened from Ubiquitty ▸ Settings… (⌘,).
// Single shared window; UBAppDelegate keeps one instance and re-shows it.
//

import AppKit
import Combine
import SwiftUI
import UbiquittyCore

@objc(UBSettingsWindowController)
public final class SettingsWindowController: NSWindowController {
    static let editCurrentThemeNotification = Notification.Name("UbiquittyEditCurrentTheme")

    private static var pendingThemeEdit: Int?

    @objc
    public static func editCurrentTheme() {
        pendingThemeEdit = TerminalWindows.keyTerminalThemeIndex()?.intValue
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: editCurrentThemeNotification, object: nil)
        }
    }

    static func takePendingThemeEdit() -> Int? {
        defer { pendingThemeEdit = nil }
        return pendingThemeEdit
    }

    private let catalogModel = SettingsCatalogModel()
    private var titleSubscription: AnyCancellable?

    /// Publishes a completed preference edit after its caller finishes updating live state.
    @objc
    public static func preferencesDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SettingsBridge.valuesChanged, object: nil)
        }
    }

    /// Publishes a load of the preferences file, and has every own write the
    /// app makes to it from here on publish itself.
    ///
    /// A menu toggle or a settings row moves a value a pane shows, and the
    /// reload that would otherwise have told the pane is the one Core's
    /// self-write guard skips, so Core tells the pane instead. Installed on the
    /// load because that is the first thing the app does with the file, ahead
    /// of any write. Own writes run on the main thread, as Core's live values
    /// require, so the listener runs on the main actor.
    @objc
    public static func preferencesDidLoad() {
        Ubiquitty.Preferences.setOwnWriteListener {
            MainActor.assumeIsolated { SettingsWindowController.preferencesDidChange() }
        }
        preferencesDidChange()
    }

    @objc
    public init() {
        let hosting = NSHostingController(rootView: SettingsView(catalogModel: catalogModel))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.backgroundColor = .controlBackgroundColor
        window.setContentSize(NSSize(width: 760, height: 640))
        window.contentMinSize = NSSize(width: 720, height: 460)
        window.center()
        window.setFrameAutosaveName("UBSettingsWindow")
        super.init(window: window)
        titleSubscription = catalogModel.$shownTitle.sink { [weak self] title in
            self?.window?.title = title
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func showWindow(_ sender: Any?) {
        catalogModel.refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Select a sidebar category (e.g. Beam opening a custom pane like Themes).
    // Call after showWindow so the refresh has rebuilt the catalog.
    @objc(selectCategory:)
    public func select(category: String) {
        catalogModel.selectCategory = category
    }

    /// Reveals a setting by its stable address, including across catalogue refreshes.
    @objc(revealRow:inCategory:)
    public func reveal(rowID: String, inCategory category: String) {
        catalogModel.revealRowID = rowID
        catalogModel.selectCategory = category
    }

    // The app's ⌘W (and ⇧⌘W) menu items target `closePane:`, a terminal action.
    // The Settings window has no panes; route it to a standard window close so
    // ⌘W closes Settings. As the key window's controller we're early in the
    // responder chain, so AppKit dispatches + enables the item here.
    @objc
    public func closePane(_ sender: Any?) {
        window?.performClose(sender)
    }

    /// Focuses Settings search through the app's Edit > Find command.
    @objc
    public func performFindAction(_ sender: Any?) {
        guard let content = window?.contentView,
            let field = searchField(in: content)
        else { return }
        window?.makeFirstResponder(field)
        field.selectText(sender)
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField, field.identifier?.rawValue == "settings-search" {
            return field
        }
        for child in view.subviews {
            if let field = searchField(in: child) { return field }
        }
        return nil
    }
}

extension SettingsWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closePane(_:)) {
            return window != nil
        }
        return true
    }
}
