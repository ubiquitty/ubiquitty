// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// TabAccessoryTransitionScenarios.swift — what a tab's accessory slot does on
// the way from an attention mark to what the selected tab shows.
//
// A tab standing behind wears the ellipsis for output nobody read. Selecting
// it answers the mark, so the mark fades and the slot takes what Core ranks
// for a selected tab: the shortcut number when the setting shows it, nothing
// when it does not. Each leg records the slot at every run-loop turn of the
// transition and judges the record: the fade is attached to the mark, the mark
// leaves, and the slot settles on Core's answer drawn whole.

/// Registers the tab-accessory transition scenarios with the UI-test runner.
enum TabAccessoryTransitionScenarios {
    /// What the slot settles on once the mark has gone.
    private enum Settled {
        case hint(String)
        case empty
        case marks
    }

    /// What disturbs the transition while it runs.
    private enum Disturbance {
        case none
        /// The reader moves on and the tab earns the mark again, mid-fade.
        case outputDuringFade
        /// The mark has no layer to animate when the tab is selected.
        case layerlessMark
    }

    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_a_mark_earned_again_mid_fade_keeps_its_place") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                runLeg(
                    t,
                    mode: .Always,
                    isCommandHeld: false,
                    withProgress: false,
                    expected: .marks,
                    disturbance: .outputDuringFade
                )
            }
        }
        UBUITestRegister("swift_shell_a_selected_tab_whose_mark_has_no_layer_still_shows_its_number") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                runLeg(
                    t,
                    mode: .Always,
                    isCommandHeld: false,
                    withProgress: false,
                    expected: .hint("⌘1"),
                    disturbance: .layerlessMark
                )
            }
        }
        UBUITestRegister("swift_shell_a_selected_tab_fades_its_ellipsis_into_its_number") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                runLeg(t, mode: .Always, isCommandHeld: false, withProgress: false, expected: .hint("⌘1"))
            }
        }
        UBUITestRegister("swift_shell_a_selected_reporting_tab_fades_its_ellipsis_into_its_number") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                runLeg(t, mode: .Always, isCommandHeld: false, withProgress: true, expected: .hint("⌘1"))
            }
        }
        UBUITestRegister("swift_shell_a_selected_tab_fades_its_ellipsis_into_its_number_while_command_is_held") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                runLeg(t, mode: .OnCommand, isCommandHeld: true, withProgress: false, expected: .hint("⌘1"))
            }
        }
        UBUITestRegister("swift_shell_a_selected_tab_fades_its_ellipsis_into_nothing_without_command") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                runLeg(t, mode: .OnCommand, isCommandHeld: false, withProgress: false, expected: .empty)
            }
        }
    }

    /// One leg: a background tab earns the ellipsis, is selected, and the slot
    /// is recorded through the transition.
    ///
    /// - Parameters:
    ///   - t: The scenario context.
    ///   - mode: The `[tabs] show_shortcuts` setting the leg runs under.
    ///   - isCommandHeld: Whether the tab-selecting modifier is down.
    ///   - withProgress: Whether the background tab also reports indeterminate
    ///     progress and keeps writing, the way a job under tmux does.
    ///   - expected: What the slot must settle on.
    @MainActor
    private static func runLeg(
        _ t: UBUITestContext,
        mode: Ubiquitty.Preferences.TabShortcutHints,
        isCommandHeld: Bool,
        withProgress: Bool,
        expected: Settled,
        disturbance: Disturbance = .none
    ) {
        guard let shell = TerminalWindowController.spawn(), let first = shell.window else {
            t.expect(false, desc: "a Swift-shell window opens")
            return
        }
        defer { first.tabGroup?.windows.forEach { $0.close() } }
        let restoreMode = hintMode()
        defer { setHintMode(restoreMode) }
        let restoreHeld = TabAccessoryPresenter.isCommandKeyHeld
        defer { TabAccessoryPresenter.isCommandKeyHeld = restoreHeld }
        TabAccessoryPresenter.isCommandKeyHeld = isCommandHeld
        setHintMode(Int(Ubiquitty.Preferences.tabShortcutHintsToInt(mode)))
        first.makeKeyAndOrderFront(nil)
        t.pump(0.4)
        guard let surface = shell.focusedSurfaceForTesting else {
            t.expect(false, desc: "the window has a pane")
            return
        }
        surface.transmitAsUserInputForTesting("k=42; echo \"ready-${k}\"\r")
        // The shell needs a moment to start reading; the background tab's own
        // output below is what proves it is up.
        t.pump(1.5)

        shell.newWindowForTab(nil)
        guard t.wait(until: { (first.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
            let group = first.tabGroup,
            let second = group.windows.first(where: { $0 !== first })
        else {
            t.expect(false, desc: "a second tab opens")
            return
        }
        select(second, over: first, in: group)
        t.pump(0.6)

        // Output the reader has not seen, in the tab standing behind.
        surface.transmitAsUserInputForTesting("echo \"unread-${k}\"\r")
        t.expect(
            t.wait(until: { first.tab.accessoryView is TabAttentionDots }, timeout: 6),
            desc: "the background tab wears the ellipsis (\(describe(first)))"
        )
        if withProgress {
            surface.transmitAsUserInputForTesting(
                "printf '\\033]9;4;3;0\\007'; while :; do echo tick; sleep 0.05; done\r"
            )
            t.expect(
                t.wait(until: { (first.tab.accessoryView as? TabStatusMark)?.isShowingProgress == true }, timeout: 6),
                desc: "the ring outranks the ellipsis behind (\(describe(first)))"
            )
            // The job's report ends while its output carries on, so the slot
            // behind is the ellipsis again when the tab is selected.
            surface.transmitAsUserInputForTesting("\u{3}printf '\\033]9;4;0;0\\007'; while :; do echo tock; sleep 0.05; done\r")
            t.expect(
                t.wait(until: { first.tab.accessoryView is TabAttentionDots }, timeout: 6),
                desc: "the ellipsis is back once the report clears (\(describe(first)))"
            )
        }
        let mark = first.tab.accessoryView
        if disturbance == .layerlessMark {
            mark?.wantsLayer = false
        }

        select(first, over: second, in: group)
        var isDisturbed = false
        var record: [String] = []
        var sawFade = false
        var sawWhole = false
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < 0.6 {
            let line = describe(first)
            if record.last.map({ !$0.hasSuffix(line) }) ?? true {
                let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                record.append("\(ms)ms \(line)")
            }
            if let view = first.tab.accessoryView, view === mark, view.layer?.animation(forKey: "fade") != nil {
                sawFade = true
            }
            if disturbance == .outputDuringFade, !isDisturbed, ProcessInfo.processInfo.systemUptime - start > 0.06 {
                isDisturbed = true
                select(second, over: first, in: group)
                surface.transmitAsUserInputForTesting("echo \"again-${k}\"\r")
            }
            t.pump(0.008)
        }
        if withProgress {
            surface.transmitAsUserInputForTesting("\u{3}")
        }
        let settled = describe(first)
        print("tab-accessory-transition mode=\(mode) held=\(isCommandHeld) progress=\(withProgress)")
        for line in record {
            print("  \(line)")
        }
        if disturbance != .layerlessMark {
            t.expect(sawFade, desc: "selecting the tab attaches the fade to the ellipsis (\(record))")
        }
        if case .marks = expected {
        } else {
            t.expect(!(first.tab.accessoryView is TabAttentionDots), desc: "the ellipsis leaves the selected tab (\(settled))")
        }
        switch expected {
        case .marks:
            t.expect(
                !record.contains { $0.contains(" hint'") },
                desc: "the tab behind never shows a number while Core wants the ellipsis (\(record))"
            )
            t.expect(
                first.tab.accessoryView is TabAttentionDots,
                desc: "the tab behind keeps the ellipsis it earned again (\(settled))"
            )
        case .hint(let text):
            if let label = first.tab.accessoryView as? NSTextField {
                let drawn = label.stringValue.trimmingCharacters(in: .whitespaces)
                sawWhole = drawn == text && isDrawnWhole(label)
            }
            t.expect(sawWhole, desc: "the selected tab settles on \(text), drawn whole (\(settled))")
        case .empty:
            let drawn = (first.tab.accessoryView as? NSTextField)?.stringValue ?? ""
            t.expect(
                first.tab.accessoryView == nil || drawn.isEmpty,
                desc: "the selected tab settles on nothing (\(settled))"
            )
        }
    }

    /// Selects a tab the way the strip does, and tells both windows.
    @MainActor
    private static func select(_ window: NSWindow, over other: NSWindow, in group: NSWindowTabGroup) {
        group.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didResignMainNotification, object: other)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    /// Whether a label has the room its text asks for, so it is not drawn
    /// truncated to an ellipsis of its own.
    @MainActor
    private static func isDrawnWhole(_ label: NSTextField) -> Bool {
        label.superview != nil && label.frame.width + 0.5 >= label.intrinsicContentSize.width && label.alphaValue > 0
    }

    /// One line for what the slot holds at this turn.
    @MainActor
    private static func describe(_ window: NSWindow) -> String {
        guard let view = window.tab.accessoryView else { return "none" }
        let layer = view.layer
        let opacity = layer.map { String(format: "%.2f", $0.presentation()?.opacity ?? $0.opacity) } ?? "nolayer"
        let animations = layer?.animationKeys()?.joined(separator: ",") ?? ""
        let hosted = view.superview == nil ? " unhosted" : ""
        switch view {
        case let dots as TabAttentionDots:
            return "dots(\(dots.dotCount)) opacity=\(opacity) anim=[\(animations)]\(hosted)"
        case let mark as TabStatusMark:
            return (mark.isShowingProgress ? "ring" : "mark(\(mark.symbolName ?? ""))") + hosted
        case let label as NSTextField:
            let text = label.stringValue.trimmingCharacters(in: .whitespaces)
            return String(
                format: "hint'%@' width=%.1f/%.1f alpha=%.2f%@",
                text,
                label.frame.width,
                label.intrinsicContentSize.width,
                label.alphaValue,
                hosted
            )
        default:
            return "\(type(of: view))\(hosted)"
        }
    }

    /// The tab-hint setting in force, in its integer form.
    @MainActor
    private static func hintMode() -> Int {
        Int(
            Ubiquitty.Preferences.tabShortcutHintsToInt(
                Ubiquitty.Preferences.Effective.tabShortcutHints(Ubiquitty.Preferences.values().pointee)
            )
        )
    }

    /// Puts the tab-hint setting where a leg needs it, through the real
    /// settings writer so every open window sees it.
    @MainActor
    private static func setHintMode(_ mode: Int) {
        guard let app = NSApp.delegate as? UBAppDelegate else { return }
        app.settingsSetTabShortcutHintMode(mode)
        TerminalWindowController.refreshTabAccessoriesForOpenWindows()
    }
}
