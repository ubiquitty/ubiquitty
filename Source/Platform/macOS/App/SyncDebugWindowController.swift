// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// SyncDebugWindowController — hosts the ⌃⌘Y "Sync Debug" window (SyncDebugView).
// window.level = .floating keeps it above the terminal so you can watch live
// Sync traffic while typing over an SSH session; it never takes key focus away
// from the terminal for long, so SyncTraceSource keeps reporting on the
// session you're driving.
//

import AppKit
import SwiftUI

@objc(UBSyncDebugWindowController)
public final class SyncDebugWindowController: NSWindowController {
    @objc
    public init() {
        let hosting = NSHostingController(rootView: SyncDebugView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sync Debug"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 600, height: 660))
        window.setFrameAutosaveName("UBSyncDebugWindow")
        // Float above terminal windows so it stays visible during a live session.
        window.level = .floating
        window.hidesOnDeactivate = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
