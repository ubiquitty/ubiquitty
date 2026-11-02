// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// DropDownScenarios.swift — the drop-down terminal follows `[quake]`: there is
// a controller, with its global hotkey registered, only while the feature is on
// and the hotkey names a key; a reload that turns the feature off ends it; and
// the panel is neither made nor shown until it is first toggled.
//
// The panel itself is driven too — toggle, show, hide, the resign-key
// auto-hide and a close — with the controller's activation step replaced by
// nothing and its screen by a frame off every screen, so the run never brings
// the app forward or puts the panel where the operator works. The hotkey spec
// is pinned by Tests/Platform/test_macos_quake_hotkey.swift. The slide itself
// (`animate = true`) is not driven: AppKit runs no frame animation for a window
// off every screen, so an animated show never arrives there.

/// Registers the drop-down terminal scenarios with the UI-test runner.
enum DropDownScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_drop_down_follows_the_quake_configuration") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                // A chord nobody else holds, so the registration is this run's.
                let chord = "hotkey = \"ctrl+opt+shift+cmd+f19\"\n"

                _ = t.configureAppending("[quake]\nenabled = false\n" + chord)
                t.expect(QuakeController.controllerIfEnabled() == nil, desc: "no drop-down controller while [quake] enabled is off")

                t.restoreConfiguration(saved)
                _ = t.configureAppending("[quake]\nenabled = true\nhotkey = \"ctrl+shift\"\n")
                t.expect(QuakeController.controllerIfEnabled() == nil, desc: "no drop-down controller for a hotkey that names no key")

                t.restoreConfiguration(saved)
                _ = t.configureAppending("[quake]\nenabled = true\n" + chord)
                guard let controller = QuakeController.controllerIfEnabled() else {
                    t.expect(false, desc: "a drop-down controller registers its hotkey while [quake] enabled is on")
                    return
                }
                t.expect(
                    !controller.isVisible && controller.windowController == nil,
                    desc: "the panel is neither made nor shown before it is toggled"
                )
                t.expect(controller.reloadFromPreferences(), desc: "a reload that keeps the feature on keeps the controller")

                t.restoreConfiguration(saved)
                _ = t.configureAppending("[quake]\nenabled = false\n")
                t.expect(!controller.reloadFromPreferences(), desc: "a reload that turns the feature off ends the controller")
            }
        }

        UBUITestRegister("swift_drop_down_panel_toggles_hides_and_forgets_its_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer { t.restoreConfiguration(saved) }
                _ = t.configureAppending("[quake]\nenabled = true\nhotkey = \"ctrl+opt+shift+cmd+f18\"\nheight = 0.5\nanimate = false\n")
                guard let controller = QuakeController.controllerIfEnabled() else {
                    t.expect(false, desc: "a drop-down controller registers its hotkey")
                    return
                }
                var activations = 0
                controller.activateApplication = { activations += 1 }
                let screen = NSRect(x: -40000, y: -40000, width: 1000, height: 800)
                controller.dropScreenFrame = { screen }
                let shown = NSRect(x: -40000, y: -40000 + 400, width: 1000, height: 400)
                let parked = NSRect(x: -40000, y: -40000 + 800, width: 1000, height: 400)
                t.expect(
                    controller.shownFrame(in: screen) == shown && controller.parkedFrame(in: screen) == parked,
                    desc: "the panel takes the screen's width and half its height, flush to the top, and parks just above it"
                )

                // Toggled on: the panel is made, restyled, placed and shown.
                controller.toggle()
                guard let window = controller.windowController?.window else {
                    t.expect(false, desc: "the first toggle makes the panel")
                    return
                }
                t.expect(
                    controller.isVisible && window.isVisible && window.frame == shown && activations == 1,
                    desc: "the first toggle shows the panel at its frame, after bringing the app forward (frame \(window.frame))"
                )
                t.expect(
                    window.level == .floating && window.collectionBehavior.contains(.canJoinAllSpaces)
                        && window.collectionBehavior.contains(.fullScreenAuxiliary) && window.isExcludedFromWindowsMenu
                        && window.tabbingMode == .disallowed && window.title == "Quake Terminal" && !window.hidesOnDeactivate,
                    desc: "the panel floats, joins every Space, and stays out of the Window menu and the tab group"
                )

                // Toggled off.
                controller.toggle()
                t.expect(
                    !controller.isVisible && !window.isVisible && controller.windowController?.window === window,
                    desc: "the second toggle hides the panel and keeps it for the next show"
                )

                // Losing key focus hides a showing panel.
                controller.showPanel()
                t.expect(
                    controller.isVisible && window.isVisible && window.frame == shown,
                    desc: "showing again shows the same panel at its frame"
                )
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                t.expect(!controller.isVisible && !window.isVisible, desc: "losing key focus hides the panel")
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                t.expect(!controller.isVisible && !window.isVisible, desc: "a resign while hidden changes nothing")

                // Hiding directly; hiding a hidden panel does nothing.
                controller.showPanel()
                controller.hidePanel()
                controller.hidePanel()
                t.expect(!controller.isVisible && !window.isVisible, desc: "hiding hides the panel, and a second hide does nothing")

                // Closing the panel forgets it; the next toggle makes a new one.
                controller.showPanel()
                window.close()
                t.expect(!controller.isVisible && controller.windowController == nil, desc: "a closed panel is forgotten")
                controller.toggle()
                guard let fresh = controller.windowController?.window else {
                    t.expect(false, desc: "a toggle after a close makes a new panel")
                    return
                }
                t.expect(
                    fresh !== window && controller.isVisible && fresh.isVisible && fresh.frame == shown,
                    desc: "a toggle after a close shows a new panel at the frame"
                )
                controller.hidePanel()
                fresh.close()
                t.expect(activations == 5, desc: "every show brought the app forward through the step, and only those (\(activations))")
            }
        }
    }
}
