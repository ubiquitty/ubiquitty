// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

/// Exercises native inspector geometry and session metadata delivery.
enum InspectorScenarios {
    static func register() {
        UBUITestRegister("swift_inspector_conceals_answerback_until_replaced") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = t.newWindowRunning(["/bin/sh"]),
                    let surface = controller.beamSurface
                else {
                    t.expect(false, desc: "the terminal opens")
                    return
                }
                defer { t.closeAllWindows() }
                controller.toggleNativeInspector(nil)
                guard let model = controller.inspectorModel else {
                    t.expect(false, desc: "the terminal owns its inspector")
                    return
                }
                model.applyAnswerback("inspectable message")
                t.expect(model.answerbackDisplay == "inspectable message", desc: "the replacement is displayed")
                let conceal = Array("\u{1b}[?101h".utf8).map { CChar(bitPattern: $0) }
                conceal.withUnsafeBufferPointer { surface.drive.feed($0) }
                t.expect(
                    t.wait(until: { model.answerbackDisplay == "concealed" }, timeout: 2),
                    desc: "the mode change conceals the inspector without a title or process change"
                )
                let reset = Array("\u{1b}[?101l\u{1b}[!p".utf8).map { CChar(bitPattern: $0) }
                reset.withUnsafeBufferPointer { surface.drive.feed($0) }
                t.pump(0.1)
                t.expect(model.answerbackDisplay == "concealed", desc: "resets preserve concealment")
                model.applyAnswerback("replacement")
                t.expect(model.answerbackDisplay == "replacement", desc: "entering a new message clears concealment")
            }
        }
        UBUITestRegister("swift_inspector_controls_visible_without_moving_tabs") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkNativeGeometry(t) }
        }
        UBUITestRegister("swift_inspector_receives_process_and_directory_events") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let controller = t.newWindowRunning(["/bin/sh"]) else {
                    t.expect(false, desc: "the terminal opens")
                    return
                }
                defer { t.closeAllWindows() }
                controller.window?.makeKeyAndOrderFront(nil)
                t.pump(0.1)
                guard let delegate = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the application owns the inspector")
                    return
                }
                delegate.toggleInspector(t)
                guard let model = controller.inspectorModel else {
                    t.expect(false, desc: "the terminal owns its Swift inspector model")
                    return
                }
                defer { controller.toggleNativeInspector(nil) }
                t.expect(model.columns > 0 && model.rows > 0, desc: "the inspector reads the terminal grid")
                t.expect(t.wait(until: { !model.processes.isEmpty }, timeout: 3), desc: "the cached process sample reaches the inspector")
                controller.setCustomTitles(window: "Inspector event fixture", tab: "Inspector event fixture")
                let directory = "/tmp/ubiquitty-inspector-event"
                t.sendText("printf '\\033]7;file://localhost\(directory)\\007'\r", to: controller)
                t.expect(
                    t.wait(until: { model.directory == directory }, timeout: 1),
                    desc: "directory metadata reaches the inspector without a timer or explicit refresh"
                )
                t.sendText("sleep 2\r", to: controller)
                t.expect(
                    t.wait(until: { model.processes.contains(where: { $0.name == "sleep" }) }, timeout: 1),
                    desc: "the running foreground job appears while title overrides remain unchanged"
                )
                t.expect(
                    t.wait(until: { !model.processes.contains(where: { $0.name == "sleep" }) }, timeout: 4),
                    desc: "the exited job disappears through the process event"
                )
                let records = controller.beamSurface!.drive.inspectorInfo().processes
                if let shell = records.first(where: { String($0.name) == "sh" || String($0.name) == "-sh" }) {
                    let presentation = Ubiquitty.Session.processPresentation(shell)
                    t.expect(
                        presentation.isForeground && !presentation.isSecondary,
                        desc: "an idle foreground shell uses normal ink and the foreground weight"
                    )
                } else {
                    t.expect(false, desc: "the shell remains in the owning session's process sample")
                }
            }
        }
    }
    @MainActor
    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private static func tabStrip(in window: NSWindow) -> NSView? {
        guard let frame = window.contentView?.superview else { return nil }
        return descendants(of: frame)
            .filter {
                String(describing: type(of: $0)).contains("TabBar") && !$0.isHidden && $0.bounds.height > 0
            }
            .max { $0.bounds.width < $1.bounds.width }
    }

    @MainActor
    private static func checkNativeGeometry(_ t: UBUITestContext) {
        guard let app = NSApp.delegate as? UBAppDelegate else {
            t.expect(false, desc: "the application exposes titlebar settings")
            return
        }
        let launch = Ubiquitty.Preferences.Effective.launchSettings()
        let previousStyle = launch.titlebarStyle == .Native ? 1 : 0
        defer {
            app.settingsSetTitlebarStyle(previousStyle)
            app.settingsSetHideTitleBar(launch.shouldHideTitleBar)
        }
        app.settingsSetHideTitleBar(false)
        for style in [0, 1] {
            app.settingsSetTitlebarStyle(style)
            guard
                let controller = TerminalWindowController.spawn(
                    arguments: ["/bin/sh"],
                    localePolicy: .auto,
                    sessionLifetime: .outlivesChild
                ),
                let window = controller.window
            else {
                t.expect(false, desc: "the geometry fixture opens")
                continue
            }
            defer { controller.shellCloseWindow() }
            var sibling: TerminalWindowController?
            defer { sibling?.shellCloseWindow() }
            for count in [1, 2] {
                if count == 2 {
                    sibling = TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild)
                    guard let siblingWindow = sibling?.window else {
                        t.expect(false, desc: "a second native tab opens")
                        continue
                    }
                    window.addTabbedWindow(siblingWindow, ordered: .above)
                    window.tabGroup?.selectedWindow = window
                }
                window.makeKeyAndOrderFront(nil)
                t.pump(0.3)
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                let strip = tabStrip(in: window)
                let before = strip.map { $0.convert($0.bounds, to: nil) }
                if count == 2 { t.expect(before != nil, desc: "the native two-tab strip is measurable") }
                controller.toggleNativeInspector(nil)
                t.pump(0.3)
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                guard let split = window.contentViewController as? NSSplitViewController,
                    let inspector = split.splitViewItems.last,
                    let control = descendants(of: inspector.viewController.view).compactMap({ $0 as? NSSegmentedControl }).first
                else {
                    t.expect(false, desc: "the inspector exposes its native section control")
                    if controller.inspectorWidth > 0 { controller.toggleNativeInspector(nil) }
                    continue
                }
                let frame = control.convert(control.bounds, to: nil)
                var visible = frame
                var ancestor = control.superview
                while let current = ancestor {
                    visible = visible.intersection(current.convert(current.visibleRect, to: nil))
                    ancestor = current.superview
                }
                let label = "style \(style), \(count) tab(s)"
                t.expect(
                    !control.isHiddenOrHasHiddenAncestor && visible.width >= frame.width - 1 && visible.height >= frame.height - 1,
                    desc: "the entire section control is visible (\(label), frame \(frame), visible \(visible))"
                )
                t.expect(
                    frame.maxY <= window.contentLayoutRect.maxY + 1,
                    desc: "the section control stays below title and tab chrome (\(label))"
                )
                if let before, let current = tabStrip(in: window) {
                    let after = current.convert(current.bounds, to: nil)
                    t.expect(
                        abs(before.minX - after.minX) <= 1 && abs(before.minY - after.minY) <= 1
                            && abs(before.width - after.width) <= 1 && abs(before.height - after.height) <= 1,
                        desc: "opening the session inspector leaves the native tab strip unchanged (\(label), \(before) -> \(after))"
                    )
                } else if before != nil {
                    t.expect(false, desc: "opening the inspector retains the tab strip")
                }
                controller.toggleNativeInspector(nil)
                t.pump(0.2)
            }
        }
    }
}
