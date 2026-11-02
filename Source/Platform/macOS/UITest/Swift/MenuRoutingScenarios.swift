// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyKit

// MenuRoutingScenarios.swift — every menu action a Swift-shell window is asked
// to answer, it answers.
//
// A menu item with no target sends its action down the key window's responder
// chain. A shell that does not implement one of those actions produces nothing
// when the item is chosen and nothing when its shortcut is pressed — the item
// is grey, or it is enabled and inert. The Objective-C view answers these and the
// Kit-hosted window implements its own set, so the question is not
// whether a particular one is wired but whether any is missing — and that is a
// question about a list, not about an item.
//
// Asked of the chain rather than of `NSApp`, because this app runs as an
// accessory (activation policy 1) while the UI tests drive it: it never becomes
// active, no window ever becomes key, and every `NSApp.target(forAction:)` and
// nil-target `sendAction` therefore answers nil. Those readings say nothing
// about the product. What the harness can read is the chain itself, which is
// what AppKit walks once a window is key, plus each answer's own
// `validateMenuItem` — the two halves that decide whether choosing the item
// does anything.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func surface(under view: NSView) -> TerminalSurface? {
    if let found = view as? TerminalSurface {
        return found
    }
    for subview in view.subviews {
        if let found = surface(under: subview) {
            return found
        }
    }
    return nil
}

/// Who would answer `action` for `window`, walking the chain AppKit walks.
///
/// The window's responder chain first, then the application and its delegate —
/// the order a menu action takes once a window is key. The delegate is asked
/// through `NSApp` because that is what AppKit reports as the target for one of
/// its actions, and because the delegate here is a plain object rather than a
/// responder.
///
/// - Parameters:
///   - action: The selector the menu item sends.
///   - window: The window whose chain to walk.
/// - Returns: The first responder in the chain that answers, or nil.
@MainActor
private func answerer(of action: Selector, from window: NSWindow) -> NSObject? {
    var walker: NSResponder? = window.firstResponder
    while let responder = walker {
        if responder.responds(to: action) {
            return responder
        }
        walker = responder.nextResponder
    }
    if NSApp.responds(to: action) {
        return NSApp
    }
    if let delegate = NSApp.delegate, delegate.responds(to: action) {
        return NSApp
    }
    return nil
}

/// Every action the app's menus send with no explicit target, with its path.
///
/// Items carrying a target of their own are left out: they reach it whatever
/// window is in front, so they say nothing about a shell.
///
/// - Parameter menu: The menu to walk.
/// - Parameter path: The titles above it, for naming a failure.
/// - Returns: The (path, action) pairs.
@MainActor
private func untargetedActions(in menu: NSMenu, path: String = "") -> [(String, Selector)] {
    var found: [(String, Selector)] = []
    for item in menu.items {
        if let submenu = item.submenu {
            found += untargetedActions(in: submenu, path: path.isEmpty ? item.title : "\(path) ▸ \(item.title)")
        } else if let action = item.action, item.target == nil {
            found.append((path.isEmpty ? item.title : "\(path) ▸ \(item.title)", action))
        }
    }
    return found
}

/// Registers the menu-routing scenarios with the UI-test runner.
enum MenuRoutingScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_cli_installer_preserves_existing_files") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let menu = NSApp.mainMenu?.items.first?.submenu
                let item = menu?.items.first { $0.title == "Install ubq CLI program…" }
                t.expect(item?.action == #selector(UBAppDelegate.installCLIProgram(_:)), desc: "the app menu offers the CLI installer")
                t.expect(item?.target === NSApp.delegate, desc: "the installer targets the application delegate")
                let files = FileManager.default
                let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("ubq-cli-\(UUID().uuidString)")
                defer { try? files.removeItem(at: root) }
                do {
                    let source = root.appendingPathComponent("A 'quoted' $HOME app.app/Contents/Helpers/ubq")
                    try files.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
                    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
                    let destination = root.appendingPathComponent("bin/ubq")
                    try CLIInstaller.installLink(source: source, destination: destination)
                    try CLIInstaller.installLink(source: source, destination: destination)
                    t.expect(
                        try files.destinationOfSymbolicLink(atPath: destination.path) == source.path,
                        desc: "a repeated install keeps the link to the bundled helper"
                    )

                    for kind in ["file", "directory", "broken-link"] {
                        try files.removeItem(at: destination)
                        if kind == "file" {
                            try Data("keep me".utf8).write(to: destination)
                        } else if kind == "directory" {
                            try files.createDirectory(at: destination, withIntermediateDirectories: false)
                        } else {
                            try files.createSymbolicLink(atPath: destination.path, withDestinationPath: "/missing-ubq-fixture")
                        }
                        var refused = false
                        do { try CLIInstaller.installLink(source: source, destination: destination) } catch { refused = true }
                        t.expect(refused, desc: "an existing \(kind) is not replaced")
                        if kind == "file" {
                            t.expect(
                                try String(contentsOf: destination, encoding: .utf8) == "keep me",
                                desc: "the existing program is unchanged"
                            )
                        }
                        if kind == "directory" {
                            t.expect(
                                try files.contentsOfDirectory(atPath: destination.path).isEmpty,
                                desc: "the installer does not create a nested link"
                            )
                        }
                    }
                    try files.removeItem(at: destination)
                    let command = CLIInstaller.installCommand(source: source, destination: destination)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", command]
                    try process.run()
                    process.waitUntilExit()
                    t.expect(
                        process.terminationStatus == 0,
                        desc: "the authorization command works without elevation in the private fixture"
                    )
                    t.expect(
                        try files.destinationOfSymbolicLink(atPath: destination.path) == source.path,
                        desc: "spaces, quotes and shell syntax remain literal path data"
                    )
                    try files.removeItem(at: source)
                    var missingRefused = false
                    do { try CLIInstaller.installLink(source: source, destination: destination) } catch { missingRefused = true }
                    t.expect(missingRefused, desc: "a bundle without its helper cannot report a successful install")
                } catch {
                    t.expect(false, desc: "CLI installer fixture: \(error)")
                }
            }
        }
        UBUITestRegister("connect_close_menu_closes_only_its_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let directory = ConnectModel.shared.directory
                let wasSuppressed = directory.isDiallingSuppressedForTesting
                directory.isDiallingSuppressedForTesting = true
                defer { directory.isDiallingSuppressedForTesting = wasSuppressed }
                let controller = ConnectWindowController()
                guard let window = controller.window,
                    let file = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
                    let close = file.items.first(where: { $0.keyEquivalent == "w" }), let action = close.action
                else {
                    t.expect(false, desc: "Connect and the standard Close menu action exist")
                    return
                }
                let other = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                defer {
                    window.close()
                    other.close()
                }
                other.orderFront(nil)
                window.orderFront(nil)
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
                window.contentView?.addSubview(field)
                t.expect(window.makeFirstResponder(field), desc: "a native field editor can hold focus in Connect")
                t.expect(
                    field.currentEditor()?.responds(to: #selector(NSText.paste(_:))) == true,
                    desc: "the field editor keeps native Paste"
                )
                t.expect(action == #selector(ConnectWindowController.closePane(_:)), desc: "Command-W uses the existing Close selector")
                t.expect(close.keyEquivalentModifierMask == .command, desc: "Close retains Command-W")
                t.expect(
                    answerer(of: action, from: window) === controller,
                    desc: "Close reaches Connect's controller through the field editor"
                )
                t.expect(controller.validateMenuItem(close), desc: "Close is enabled for Connect")
                controller.closePane(close)
                t.expect(!window.isVisible, desc: "Close dismisses Connect")
                t.expect(other.isVisible, desc: "Close leaves another window open")
            }
        }

        UBUITestRegister("swift_shell_answers_every_menu_action") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let main = NSApp.mainMenu else {
                    t.expect(false, desc: "the app has a main menu")
                    return
                }
                guard let fileMenu = main.items.first(where: { $0.title == "File" })?.submenu,
                    let localWindowItem = fileMenu.items.first(where: { $0.action == #selector(TerminalWindowController.newWindow(_:)) }),
                    let remoteWindowItem = fileMenu.items.first(where: {
                        $0.action == #selector(TerminalWindowController.newRemoteWorkspaceWindow(_:))
                    })
                else {
                    t.expect(false, desc: "File offers separate local and remote window commands")
                    return
                }
                t.expect(localWindowItem.title == "New Local Window", desc: "the local window command names its destination")
                t.expect(
                    localWindowItem.keyEquivalent == "n" && localWindowItem.keyEquivalentModifierMask == .command,
                    desc: "Command-N belongs to New Local Window"
                )
                t.expect(remoteWindowItem.keyEquivalent.isEmpty, desc: "the remote command does not take the local window shortcut")
                t.expect(fileMenu.delegate != nil, desc: "the File menu refreshes its remote connection label on open")
                if WindowContainment.isOffscreen {
                    remoteWindowItem.title = "New Window on stale host"
                    remoteWindowItem.isHidden = false
                    fileMenu.delegate?.menuNeedsUpdate?(fileMenu)
                    t.expect(remoteWindowItem.isHidden, desc: "without a terminal action target the File menu hides the remote command")
                    t.expect(
                        remoteWindowItem.title == "New Window on Remote Host",
                        desc: "without a terminal action target the File menu clears the previous connection name"
                    )
                }
                let actions = untargetedActions(in: main)
                // Said out loud, because a sweep over an empty list passes: the
                // menus are built at launch and a scenario that ran before them
                // would report every shell perfect.
                t.expect(actions.count > 100, desc: "the menus carry their actions (\(actions.count))")

                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                t.pump(0.4)

                let unanswered = actions.compactMap { path, action in
                    answerer(of: action, from: window) == nil ? "\(path) [\(NSStringFromSelector(action))]" : nil
                }
                t.expect(
                    unanswered.isEmpty,
                    desc: "every untargeted menu action reaches a responder"
                        + (unanswered.isEmpty ? "" : " — missing: \(unanswered.joined(separator: ", "))")
                )
            }
        }

        UBUITestRegister("swift_shell_clear_and_copy_are_enabled_where_they_apply") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let terminal = surface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.4)

                // Reaching an answerer is half of it. A menu item whose answerer
                // validates it false is grey, and its shortcut does nothing —
                // which is what "Cmd-K does not work" looks like from the
                // outside, indistinguishable from an action nobody answers.
                @MainActor
                func enabled(_ name: String) -> Bool? {
                    let action = NSSelectorFromString(name)
                    guard let target = answerer(of: action, from: window) else { return nil }
                    let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
                    guard let validating = target as? NSMenuItemValidation else { return true }
                    return validating.validateMenuItem(item)
                }

                for name in ["clearBuffer:", "clearScrollback:", "clearScreen:", "clearToPreviousMark:"] {
                    t.expect(enabled(name) == true, desc: "\(name) is enabled on a Swift window")
                }

                // Copy is the one that must sometimes be disabled, and asserting
                // that is what keeps the four above from passing on a chain that
                // says yes to everything.
                terminal.clearSelection()
                t.pump(0.1)
                t.expect(enabled("copy:") == false, desc: "copy: is disabled with nothing selected")

                terminal.feed(Data("\u{1b}[H\u{1b}[2Jselect me\r\n".utf8))
                t.pump(0.3)
                terminal.selectAll(nil)
                t.pump(0.2)
                t.expect(enabled("copy:") == true, desc: "and enabled once there is a selection")
            }
        }

        UBUITestRegister("swift_shell_window_menu_keeps_one_spaced_title_per_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate,
                    let menu = NSApp.windowsMenu
                else {
                    t.expect(false, desc: "the application owns its Window menu")
                    return
                }
                let originalBase = app.settingsTitleWindowText()
                let marker = "WindowMenu\(UUID().uuidString.prefix(8))"
                app.settingsSetTitleWindowText(marker)
                defer {
                    app.settingsSetTitleWindowText(originalBase)
                    TerminalWindowController.applyTitleCompositionToOpenWindows()
                }
                guard let first = TerminalWindowController.spawn(), let firstWindow = first.window else {
                    t.expect(false, desc: "a first terminal window opens for the native list")
                    return
                }
                defer { firstWindow.close() }
                guard let second = TerminalWindowController.spawn(), let secondWindow = second.window else {
                    t.expect(false, desc: "a second terminal window opens for the native list")
                    return
                }
                defer { secondWindow.close() }
                first.setCustomTitles(window: "Left", tab: "")
                second.setCustomTitles(window: "Right", tab: "")
                t.expect(
                    t.wait(
                        until: {
                            firstWindow.title.hasPrefix(marker) && secondWindow.title.hasPrefix(marker)
                        },
                        timeout: 5
                    ),
                    desc: "both terminal windows carry the configured base title"
                )
                for title in [firstWindow.title, secondWindow.title] {
                    t.expect(title.hasPrefix(marker + " — "), desc: "system title joins parts with spaces (\(title))")
                }
                if let strip = titlebarStrip(of: firstWindow), let field = titleField(in: strip) {
                    t.expect(
                        field.attributedStringValue.string.contains(marker + "—"),
                        desc: "the title row keeps its compact, kerned separator"
                    )
                    t.expect(
                        (field.accessibilityLabel() ?? "").contains(marker + " — "),
                        desc: "the accessible title speaks the spaced system title"
                    )
                } else {
                    t.expect(false, desc: "the first window has a styled native title row")
                }

                let excluded = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                excluded.title = marker + " hidden"
                excluded.isExcludedFromWindowsMenu = true
                excluded.orderFront(nil)
                defer { excluded.close() }

                @MainActor
                func expectNativeList(_ phase: String) {
                    let listed = menu.items.filter { $0.title.contains(marker) }
                    let names = listed.map(\.title)
                    for window in [firstWindow, secondWindow] {
                        let matching = listed.filter { $0.title == window.title }
                        t.expect(
                            matching.count == 1,
                            desc: "\(phase): Window lists \(window.title) once (\(names))"
                        )
                        t.expect(
                            matching.first?.target === window
                                && matching.first?.action == #selector(NSWindow.makeKeyAndOrderFront(_:)),
                            desc: "\(phase): AppKit owns the window's menu item"
                        )
                    }
                    t.expect(
                        !names.contains(excluded.title),
                        desc: "\(phase): an excluded window stays out of the native list (\(names))"
                    )
                }

                t.pump(0.2)
                expectNativeList("initial")
                app.menuNeedsUpdate(menu)
                expectNativeList("delegate update")
                NSApp.updateWindowsItem(firstWindow)
                NSApp.updateWindowsItem(secondWindow)
                menu.update()
                expectNativeList("AppKit update")
            }
        }

        UBUITestRegister("new_tab_and_window_open_while_the_bundle_has_no_shader_library") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The app while an update or a rebuild replaces its bundle:
                // still running, with its compiled shaders gone from Resources.
                // Every window draws with the library the process already
                // loaded, so File ▸ New Tab and File ▸ New Local Window still
                // open.
                guard let library = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
                    t.expect(false, desc: "the application bundle carries its shader library")
                    return
                }
                let fileManager = FileManager.default
                let away = library.deletingLastPathComponent().appendingPathComponent("default.metallib.away")
                // A run that stopped before putting the file back left it here.
                if fileManager.fileExists(atPath: away.path), !fileManager.fileExists(atPath: library.path) {
                    try? fileManager.moveItem(at: away, to: library)
                }
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let delegate = NSApp.delegate as? UBAppDelegate
                else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { t.closeAllWindows() }
                t.pump(0.4)
                do {
                    try fileManager.moveItem(at: library, to: away)
                } catch {
                    t.expect(false, desc: "the shader library moves aside (\(error))")
                    return
                }
                defer { try? fileManager.moveItem(at: away, to: library) }

                let tabsBefore = window.tabbedWindows?.count ?? 1
                shell.newWindowForTab(nil)
                t.pump(1.0)
                t.expect(
                    (window.tabbedWindows?.count ?? 1) == tabsBefore + 1,
                    desc: "File ▸ New Tab opens a tab while the bundle has no shader library"
                )

                let windowsBefore = TerminalWindowController.spawnedControllers.count
                delegate.newWindow(nil)
                t.pump(1.0)
                t.expect(
                    TerminalWindowController.spawnedControllers.count == windowsBefore + 1,
                    desc: "File ▸ New Local Window opens a window while the bundle has no shader library"
                )
            }
        }
    }
}
