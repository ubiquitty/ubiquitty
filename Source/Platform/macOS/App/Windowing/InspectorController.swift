// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UbiquittyCore
import UbiquittyKit

/// Hosts the application's shared inspector panel, which follows the terminal
/// window the reader is working in, whichever shell drew it. A window that has
/// no inspector of its own opens it; a window that keeps its own inspector
/// beside the grid does not.
@objc(UBInspectorController)
@MainActor
final class InspectorController: NSObject {
    private let model = TerminalInspectorModel()
    private var panel: NSPanel?

    #if UBIQUITTY_UI_TESTS
    /// Exposes the actual shared model to the in-process inspector scenario.
    var inspectedModelForTesting: TerminalInspectorModel { model }

    /// Whether the panel stands on screen, for the scenario that closes the
    /// window it was following.
    var isPanelShownForTesting: Bool { panel?.isVisible == true }
    #endif

    override init() {
        super.init()
        for name in [
            NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification, NSWindow.willCloseNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
        // A window that hosts a surface reports its own title, directory and
        // process changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inspectedTerminalChanged(_:)),
            name: .terminalInspectedFactsChanged,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Shows or hides the inspector without changing the inspected session.
    @objc
    func toggle() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            model.isObservationActive = false
            return
        }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 390, height: 650),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "Inspector"
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.contentViewController = NSHostingController(rootView: TerminalInspectorView(model: model))
            panel.setFrameAutosaveName("UbiquittyInspector")
            panel.center()
            self.panel = panel
        }
        panel?.orderFront(nil)
        model.isObservationActive = true
        refresh()
    }

    /// Refreshes from the same metadata event that updates terminal titles.
    @objc
    func refresh() {
        refresh(besides: nil)
    }

    /// Points the panel at the terminal window the reader is working in, or
    /// hides it when there is none left.
    ///
    /// - Parameter closingWindow: A window that is going, which the panel
    ///   never follows: it is still key while it posts `willClose`, and a
    ///   panel left on it shows a window that is gone and acts on nothing.
    private func refresh(besides closingWindow: NSWindow?) {
        guard panel?.isVisible == true else { return }
        guard let terminal = TerminalWindows.keyTerminal(besides: closingWindow) else {
            panel?.orderOut(nil)
            model.isObservationActive = false
            model.target = nil
            return
        }
        terminal.inspect(in: model)
    }

    @objc
    private func windowChanged(_ notification: Notification) {
        let window = notification.object as? NSWindow
        guard window !== panel else {
            if notification.name == NSWindow.willCloseNotification {
                model.isObservationActive = false
            }
            return
        }
        refresh(besides: notification.name == NSWindow.willCloseNotification ? window : nil)
    }

    @objc
    private func inspectedTerminalChanged(_ notification: Notification) {
        guard panel?.isVisible == true, notification.object as AnyObject? === TerminalWindows.keyTerminal() else { return }
        refresh()
    }
}
