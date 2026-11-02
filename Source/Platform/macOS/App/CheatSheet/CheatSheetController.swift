// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// CheatSheetController.swift — the keyboard cheat sheet: a display-only overlay
// listing every menu keyEquivalent and every user [keys] binding. Opened from
// Help ▸ Keyboard Shortcuts… (⌘/); dismissed by Esc, a click, or re-invoking.
// Reuses Beam's overlay hosting, minus the responder handoff — it never takes
// first responder, so the terminal keeps focus the whole time.
//

import AppKit
import SwiftUI
import UbiquittyKit

@MainActor
@objc(UBCheatSheetController)
public final class CheatSheetController: NSObject {
    private static let shared = CheatSheetController()

    private var hostView: NSView?
    private weak var window: NSWindow?
    private var dismissMonitor: Any?

    // Toggle the cheat sheet over the key window (Help ▸ Keyboard Shortcuts… /
    // ⌘/). Presenting again while shown — or over a different window — dismisses.
    @objc
    public static func toggle() {
        shared.toggle()
    }

    private func toggle() {
        if hostView != nil {
            dismiss()
        } else {
            present()
        }
    }

    private func present() {
        guard hostView == nil, let window = NSApp.keyWindow,
            let frameView = window.contentView?.superview ?? window.contentView
        else { return }
        let menu = CheatSheetSources.menuShortcuts()
        let keys = CheatSheetSources.userBindings()
        guard !menu.isEmpty || !keys.isEmpty else { return }

        let host = NSView(frame: frameView.bounds)
        host.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(
            rootView: CheatSheetView(menu: menu, keys: keys) { [weak self] in
                self?.dismiss()
            }
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        frameView.addSubview(host)
        self.hostView = host
        self.window = window

        // Display-only: no first responder to Esc into, so a local monitor
        // dismisses on Esc or a click anywhere (the scrim's tap does the same,
        // but a click on the card's own controls shouldn't leak through).
        dismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                if event.type == .keyDown && event.keyCode != 53 { return event } // 53 = Esc
                self?.dismiss()
                return event.type == .keyDown ? nil : event // swallow the Esc
            }

        if !SystemDisplayOptions.shouldReduceMotion {
            host.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                host.animator().alphaValue = 1
            }
        }
    }

    private func dismiss() {
        guard let host = hostView else { return }
        hostView = nil
        window = nil
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
        if SystemDisplayOptions.shouldReduceMotion {
            host.removeFromSuperview()
        } else {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.08
                    host.animator().alphaValue = 0
                },
                // AppKit invokes NSAnimationContext completion handlers on the main
                // thread; assumeIsolated asserts that contract for the type checker.
                completionHandler: { MainActor.assumeIsolated { host.removeFromSuperview() } }
            )
        }
    }

    // UI-test seam: "shortcut␟label␟group" for both inventories.
    @MainActor
    public static func uiTestEntries() -> [String] {
        (CheatSheetSources.menuShortcuts() + CheatSheetSources.userBindings())
            .map { "\($0.shortcut)\u{1f}\($0.label)\u{1f}\($0.group)" }
    }
}
