// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// TabAccessorySelectionScenarios.swift — the selected tab's accessory slot on
// the paths that reach the selection without a key or main edge of their own.
//
// `TabAccessoryTransitionScenarios` selects a background tab and posts the key
// and main notifications a click delivers. These legs reach a selected tab the
// other ways a session does: a lone window whose group forms around it while it
// stays selected, a ⌘1 that moves only the group's selection, a background job
// reporting progress across the switch back, a tmux -CC session whose windows
// open as tabs, and an arrangement restored with its first tab selected. Each
// records the slot every 8 ms and judges what it settles on: a selected tab
// never wears an attention mark, and under `show_shortcuts = "always"` it shows
// its number.

/// Registers the selected-tab accessory scenarios with the UI-test runner.
enum TabAccessorySelectionScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_a_first_tab_that_gains_a_background_sibling_shows_its_number") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { firstTabGainsBackgroundSibling(t) }
        }
        UBUITestRegister("swift_shell_a_tab_selected_by_number_alone_shows_its_number") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { selectedByNumberAlone(t, withProgress: false) }
        }
        UBUITestRegister("swift_shell_a_reporting_tab_selected_by_number_alone_shows_its_number") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { selectedByNumberAlone(t, withProgress: true) }
        }
        UBUITestRegister("swift_shell_a_restored_first_tab_shows_its_number") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { restoredFirstTab(t) }
        }
        UBUITestRegister("swift_tmux_a_hosted_tab_selected_as_its_group_forms_shows_its_number") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { tmuxSelectedHostedTab(t) }
        }
    }

    // MARK: - Legs

    /// A lone window earns the ellipsis, then a sibling joins its group behind
    /// it, the way a restored or tmux-opened tab arrives: the first tab stays
    /// selected throughout and sees no key or main edge.
    @MainActor
    private static func firstTabGainsBackgroundSibling(_ t: UBUITestContext) {
        guard case (let shell, let first, let surface)? = openShell(t) else { return }
        defer { closeGroup(of: first) }
        let restore = useAlwaysHints()
        defer { restore() }
        surface.transmitAsUserInputForTesting("echo \"lone-${k}\"\r")
        // The harness has no key window, so the lone window's output is
        // unread; a lone window has no strip, so Core reads it as unselected.
        _ = t.wait(until: { shell.hasUnseenActivity }, timeout: 6)
        t.pump(0.3)
        let before = describe(first)

        guard let sibling = TerminalWindowController.spawn(), let second = sibling.window else {
            t.expect(false, desc: "a second Swift-shell window opens")
            return
        }
        second.setFrame(first.frame, display: false)
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = first
        let record = recordSlot(of: first, for: 1.0, t: t)
        report("first-tab-gains-sibling", before: before, record: record)
        judgeSelected(first, wants: "⌘1", record: record, t: t)
    }

    /// A background tab earns the ellipsis, and the reader comes back to it
    /// with ⌘1, which moves the group's selection and nothing else
    /// (`-[UBAppDelegate selectTab:]`).
    ///
    /// - Parameter withProgress: Whether the tab behind is also running a job
    ///   that keeps reporting indeterminate progress across the switch.
    @MainActor
    private static func selectedByNumberAlone(_ t: UBUITestContext, withProgress: Bool) {
        guard case (let shell, let first, let surface)? = openShell(t) else { return }
        defer { closeGroup(of: first) }
        let restore = useAlwaysHints()
        defer { restore() }
        shell.newWindowForTab(nil)
        guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
            let group = first.tabGroup,
            let second = group.windows.first(where: { $0 !== first })
        else {
            t.expect(false, desc: "a second tab opens")
            return
        }
        group.selectedWindow = second
        t.pump(0.6)
        if withProgress {
            // A job that re-reports as it goes, the way one under tmux does:
            // every report is a progress edge that refreshes the group.
            surface.transmitAsUserInputForTesting(
                "while :; do printf '\\033]9;4;3;0\\007'; echo tick; sleep 0.03; printf '\\033]9;4;1;50\\007'; sleep 0.03; done\r"
            )
            _ = t.wait(until: { (first.tab.accessoryView as? TabStatusMark)?.isShowingProgress == true }, timeout: 6)
        } else {
            surface.transmitAsUserInputForTesting("echo \"unread-${k}\"\r")
            _ = t.wait(until: { first.tab.accessoryView is TabAttentionDots }, timeout: 6)
        }
        let before = describe(first)
        group.selectedWindow = first
        let record = recordSlot(of: first, for: 1.0, t: t)
        if withProgress {
            surface.transmitAsUserInputForTesting("\u{3}printf '\\033]9;4;0;0\\007'\r")
            t.pump(0.3)
        }
        report("selected-by-number progress=\(withProgress)", before: before, record: record)
        judgeSelected(first, wants: "⌘1", record: record, t: t)
    }

    /// Two windows that each produced output before they were grouped are
    /// grouped as a restore groups them (`settleRestoredGroup`): the second is
    /// tabbed onto the first and the first is selected, with no key edge.
    @MainActor
    private static func restoredFirstTab(_ t: UBUITestContext) {
        guard case (let shell, let first, let surface)? = openShell(t) else { return }
        defer { closeGroup(of: first) }
        let restore = useAlwaysHints()
        defer { restore() }
        guard let sibling = TerminalWindowController.spawn(), let second = sibling.window else {
            t.expect(false, desc: "a second Swift-shell window opens")
            return
        }
        t.pump(0.6)
        surface.transmitAsUserInputForTesting("echo \"restored-${k}\"\r")
        _ = t.wait(until: { shell.hasUnseenActivity }, timeout: 6)
        _ = t.wait(until: { sibling.hasUnseenActivity }, timeout: 6)
        let before = describe(first)
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = first
        let record = recordSlot(of: first, for: 1.0, t: t)
        report("restored-first-tab", before: before, record: record)
        judgeSelected(first, wants: "⌘1", record: record, t: t)
        t.expect(
            (second.tab.accessoryView as? TabStatusMark)?.isShowingProgress != true,
            desc: "the restored tab behind shows no ring it was never sent (\(describe(second)))"
        )
    }

    /// A tmux -CC session's two windows are grouped as tabs after both have
    /// opened, with the first selected; the first then runs a job writing
    /// output (and an OSC 9;4 report tmux may or may not forward) through
    /// control mode.
    ///
    /// Both windows existed before the group did, so no window is spawned
    /// into it and none takes key: the group forming is the only edge.
    @MainActor
    private static func tmuxSelectedHostedTab(_ t: UBUITestContext) {
        let socket = "ubiquitty-uitest-tab-accessory"
        t.killTmuxServer(onSocket: socket)
        defer { t.killTmuxServer(onSocket: socket) }
        let restore = useAlwaysHints()
        defer { restore() }
        guard
            let control = TerminalWindowController.spawn(
                arguments: ["/bin/sh"],
                localePolicy: .auto,
                sessionLifetime: .endsWithChild
            ),
            let controlSurface = control.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "a Swift-shell window opens with a surface")
            return
        }
        defer { control.window?.close() }
        t.pump(0.3)
        controlSurface.send("\(tmuxPath()) -L \(socket) -f /dev/null -CC new-session -s accessory\n")
        guard
            t.wait(until: { control.hostedWindowsForTesting.first?.boundTmuxPaneIDs().isEmpty == false }, timeout: 15),
            let firstHost = control.hostedWindowsForTesting.first,
            let first = firstHost.window
        else {
            t.expect(false, desc: "a tmux -CC session surfaces a Swift-shell window")
            return
        }
        defer { closeGroup(of: first) }
        _ = askTmux(socket: socket, ["new-window", "-d", "-t", "accessory"])
        var secondHost: NSWindow?
        guard
            t.wait(
                until: {
                    secondHost = control.hostedWindowsForTesting.lazy.compactMap(\.window).first { $0 !== first }
                    return secondHost != nil
                },
                timeout: 15
            ),
            let second = secondHost
        else {
            t.expect(false, desc: "the session's second window surfaces (\(control.hostedWindowsForTesting.count) hosted)")
            return
        }
        // AppKit tabs windows that share a tabbing identifier as they are
        // ordered front, which an accessory application never does; the
        // group is formed here the way that ordering forms it.
        if (first.tabbedWindows?.count ?? 0) < 2 {
            second.setFrame(first.frame, display: false)
            first.addTabbedWindow(second, ordered: .above)
        }
        guard (first.tabGroup?.windows.count ?? 0) >= 2, let group = first.tabGroup else {
            t.expect(false, desc: "the session's two windows share a tab group")
            return
        }
        group.selectedWindow = first
        t.pump(0.6)
        _ = askTmux(
            socket: socket,
            [
                "send-keys", "-t", "accessory:0", "-l",
                "while :; do printf '\\033]9;4;3;0\\007'; echo tick; sleep 0.05; done\r",
            ]
        )
        let record = recordSlot(of: first, for: 2.0, t: t)
        _ = askTmux(socket: socket, ["send-keys", "-t", "accessory:0", "C-c"])
        report("tmux-selected-hosted-tab tabs=\(group.windows.count)", before: describe(first), record: record)
        let position = (group.windows.firstIndex(of: first) ?? 0) + 1
        judgeSelected(first, wants: "⌘\(position)", record: record, t: t)
    }

    // MARK: - Support

    /// Opens a Swift-shell window, small and never in front, with a shell
    /// that has answered once.
    @MainActor
    private static func openShell(_ t: UBUITestContext) -> (TerminalWindowController, NSWindow, TerminalSurface)? {
        guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
            t.expect(false, desc: "a Swift-shell window opens")
            return nil
        }
        t.pump(0.4)
        guard let surface = shell.focusedSurfaceForTesting else {
            t.expect(false, desc: "the window has a pane")
            window.close()
            return nil
        }
        surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
        t.pump(1.5)
        return (shell, window, surface)
    }

    /// Closes every tab of a window's group.
    @MainActor
    private static func closeGroup(of window: NSWindow) {
        (window.tabGroup?.windows ?? [window]).forEach { $0.close() }
    }

    /// Puts `show_shortcuts` at `"always"` through the real settings writer.
    ///
    /// - Returns: What puts the previous setting back.
    @MainActor
    private static func useAlwaysHints() -> () -> Void {
        let previous = Int(
            Ubiquitty.Preferences.tabShortcutHintsToInt(
                Ubiquitty.Preferences.Effective.tabShortcutHints(Ubiquitty.Preferences.values().pointee)
            )
        )
        let previousHeld = TabAccessoryPresenter.isCommandKeyHeld
        TabAccessoryPresenter.isCommandKeyHeld = false
        setHintMode(Int(Ubiquitty.Preferences.tabShortcutHintsToInt(.Always)))
        return {
            TabAccessoryPresenter.isCommandKeyHeld = previousHeld
            setHintMode(previous)
        }
    }

    /// Writes the tab-hint setting and re-dresses every open window.
    @MainActor
    private static func setHintMode(_ mode: Int) {
        guard let app = NSApp.delegate as? UBAppDelegate else { return }
        app.settingsSetTabShortcutHintMode(mode)
        TerminalWindowController.refreshTabAccessoriesForOpenWindows()
    }

    /// Records the slot at every 8 ms turn, one line per change.
    @MainActor
    private static func recordSlot(of window: NSWindow, for seconds: Double, t: UBUITestContext) -> [String] {
        var record: [String] = []
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            let line = describe(window)
            if record.last.map({ !$0.hasSuffix(" " + line) }) ?? true {
                let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                record.append("\(ms)ms \(line)")
            }
            t.pump(0.008)
        }
        return record
    }

    /// Prints a leg's record for the run's log.
    private static func report(_ leg: String, before: String, record: [String]) {
        print("tab-accessory-selection \(leg) before=\(before)")
        for line in record {
            print("  \(line)")
        }
    }

    /// Judges a selected tab's slot: no attention mark once settled, and the
    /// number drawn.
    @MainActor
    private static func judgeSelected(_ window: NSWindow, wants hint: String, record: [String], t: UBUITestContext) {
        let isSelected = window.tabGroup?.selectedWindow === window
        t.expect(isSelected, desc: "the tab under test is its group's selected tab")
        let settled = describe(window)
        t.expect(
            !(window.tab.accessoryView is TabAttentionDots) && !(window.tab.accessoryView is TabStatusMark),
            desc: "the selected tab settles without an attention mark (\(settled); \(record))"
        )
        let drawn = (window.tab.accessoryView as? NSTextField)?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        t.expect(drawn == hint, desc: "the selected tab settles on \(hint) (\(settled); \(record))")
    }

    /// One line for what the slot holds.
    @MainActor
    private static func describe(_ window: NSWindow) -> String {
        guard let view = window.tab.accessoryView else { return "none" }
        let opacity = view.layer.map { String(format: "%.2f", $0.presentation()?.opacity ?? $0.opacity) } ?? "nolayer"
        let hosted = view.superview == nil ? " unhosted" : ""
        switch view {
        case let dots as TabAttentionDots:
            return "dots(\(dots.dotCount)) opacity=\(opacity)\(hosted)"
        case let mark as TabStatusMark:
            return (mark.isShowingProgress ? "ring" : "mark(\(mark.symbolName ?? ""))") + hosted
        case let label as NSTextField:
            return "hint'\(label.stringValue.trimmingCharacters(in: .whitespaces))'\(hosted)"
        default:
            return "\(type(of: view))\(hosted)"
        }
    }
}

/// The tmux the scenarios drive, wherever this machine keeps it.
private func tmuxPath() -> String {
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tmux"
}

/// Runs one command against the scenario's own tmux server.
///
/// - Parameters:
///   - socket: The private server's socket name.
///   - arguments: The tmux command and its arguments.
/// - Returns: The exit status and the trimmed output.
@discardableResult
private func askTmux(socket: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let task = Process()
    let path = tmuxPath()
    if path.hasPrefix("/") {
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-L", socket] + arguments
    } else {
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tmux", "-L", socket] + arguments
    }
    let output = Pipe()
    task.standardOutput = output
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return (-1, "")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
