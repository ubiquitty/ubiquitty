// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// StreamDebugWindowController — hosts the ⌃⌘S "Stream Debug" window (StreamDebugView).
// window.level = .floating keeps it above the terminal so you can watch live
// stream traffic while typing; it never takes key focus away from the terminal
// for long, so TerminalWindowController.frontmostStreamDebugRecorder keeps
// reporting on the session you're driving.
//

import AppKit
import SwiftUI

@objc(UBStreamDebugWindowController)
public final class StreamDebugWindowController: NSWindowController {
    @objc
    public init() {
        let hosting = NSHostingController(rootView: StreamDebugView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Stream Debug"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 800, height: 600))
        window.setFrameAutosaveName("UBStreamDebugWindow")
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
