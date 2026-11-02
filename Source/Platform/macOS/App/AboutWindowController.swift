// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// AboutWindowController.swift — hosts the SwiftUI About panel in an AppKit
// window, opened from the app menu. A small fixed-size panel with a
// transparent titlebar (traffic lights float over the content, no title text —
// the Safari About look). Single shared window; UBAppDelegate re-shows it.
//

import AppKit
import SwiftUI

private func mtApplicationDisplayName() -> String {
    let bundle = Bundle.main
    for key in ["CFBundleDisplayName", "CFBundleName"] {
        if let value = bundle.object(forInfoDictionaryKey: key) as? String,
            !value.isEmpty
        {
            return value
        }
    }
    return "Ubiquitty"
}

@objc(UBAboutWindowController)
public final class AboutWindowController: NSWindowController {
    // `versionString` is the fully-formatted "Version 0.2.0.3 (1a2b3c4d)" line
    // UBAppDelegate builds from Core's version and build identity.
    @objc
    public init(versionString: String) {
        let appName = mtApplicationDisplayName()
        let hosting = NSHostingController(rootView: AboutView(appName: appName, versionString: versionString))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        // No visible titlebar: the traffic lights float over the clean panel.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "About \(appName)" // window-menu label only
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        // Keep all three traffic lights (close active; minimize/zoom show greyed
        // since the panel isn't .miniaturizable/.resizable) — the Safari look.
        window.setContentSize(NSSize(width: 360, height: 330))
        window.center()
        window.isRestorable = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // ⌘W targets `closePane:` (a terminal action); the About window has no panes,
    // so route it to a standard window close. Mirrors SettingsWindowController.
    @objc
    public func closePane(_ sender: Any?) {
        window?.performClose(sender)
    }
}

extension AboutWindowController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closePane(_:)) {
            return window != nil
        }
        return true
    }
}
