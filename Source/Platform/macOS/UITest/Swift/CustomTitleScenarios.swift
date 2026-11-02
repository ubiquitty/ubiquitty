// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// CustomTitleScenarios.swift — the one custom-title state a window and its
// tab carry, through every door the shell gives it: the title popover, the
// Rename Tab sheet, the inspector and the controller's own writer.
//
// What a custom title does to a composed title is Core's
// (`Session::resolveTitleNames`, pinned in Tests/Core/test_title_compose.cpp):
// it fills the app-title segment and takes the process segments' place, and
// the directory, the columns×rows readout and the status stay. What only a
// running window answers is whether each door reads and writes the same
// state, so that a name set in one is what the next opens on, whether a
// program's later title moves it, and whether a cleared field restores the
// automatic title at once.

/// Registers the custom-title scenarios with the UI-test runner.
enum CustomTitleScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_popover_names_the_window_and_the_tab_follows_until_named_apart") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyPopover(t) }
        }
        UBUITestRegister("swift_shell_inspector_opens_on_the_popovers_names_and_its_name_keeps_the_readout") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyInspector(t) }
        }
        UBUITestRegister("swift_shell_a_programs_title_does_not_move_a_custom_title") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyProgramTitle(t) }
        }
    }

    /// The popover's Title field names the window and its tab follows; the
    /// Tab Title field names the tab alone; both erased is automatic again.
    @MainActor
    private static func verifyPopover(_ t: UBUITestContext) {
        guard let shell = spawnShell(t), let window = shell.window else { return }
        defer { window.close() }
        guard let strip = titlebarStrip(of: window), openIdentityPopover(in: strip, t),
            let windowField = popoverView("titlebarDocumentActions.windowTitle") as? NSTextField,
            let tabField = popoverView("titlebarDocumentActions.tabTitle") as? NSTextField
        else {
            t.expect(false, desc: "the title row opens the popover with both name fields")
            return
        }
        defer { closeIdentityPopover(in: strip, t) }
        let titleNow = { window.title }
        let tabNow = { window.tab.title ?? "" }

        // The Title field names the window; its tab, which has no name of its
        // own, follows.
        windowField.stringValue = "ops"
        windowField.sendAction(windowField.action, to: windowField.target)
        t.pump(0.3)
        t.expect(
            shell.customWindowTitle == "ops" && shell.customTabTitle.isEmpty,
            desc: "the popover wrote the window's name and nothing to the tab's (\(shell.customWindowTitle), \(shell.customTabTitle))"
        )
        t.expect(titleNow().contains("ops"), desc: "the window wears the name (\(titleNow()))")
        t.expect(tabNow().contains("ops"), desc: "and its tab follows it (\(tabNow()))")

        // The Tab Title field names the tab alone: the window keeps its name
        // and the tab stops following it.
        tabField.stringValue = "deploy"
        tabField.sendAction(tabField.action, to: tabField.target)
        t.pump(0.3)
        t.expect(shell.customTabTitle == "deploy", desc: "the popover wrote the tab's name (\(shell.customTabTitle))")
        t.expect(tabNow().contains("deploy") && !tabNow().contains("ops"), desc: "the tab answers to its own name (\(tabNow()))")
        t.expect(titleNow().contains("ops") && !titleNow().contains("deploy"), desc: "the window keeps its own (\(titleNow()))")

        // Both fields erased: both titles are automatic again, at once, with
        // no copy left behind to answer for them.
        windowField.stringValue = ""
        windowField.sendAction(windowField.action, to: windowField.target)
        tabField.stringValue = ""
        tabField.sendAction(tabField.action, to: tabField.target)
        t.pump(0.3)
        t.expect(
            shell.customWindowTitle.isEmpty && shell.customTabTitle.isEmpty,
            desc: "erasing both fields leaves no custom title (\(shell.customWindowTitle), \(shell.customTabTitle))"
        )
        t.expect(
            !titleNow().contains("ops") && !tabNow().contains("deploy") && !tabNow().contains("ops"),
            desc: "the window and the tab are named by the composition again (\(titleNow()) / \(tabNow()))"
        )
    }

    /// The inspector and the Rename Tab sheet open on what the popover set; a
    /// name typed in the inspector keeps the window's readout; the popover,
    /// opened after, shows the inspector's name.
    @MainActor
    private static func verifyInspector(_ t: UBUITestContext) {
        guard let shell = spawnShell(t), let window = shell.window else { return }
        defer { window.close() }
        // Through the writer the popover's fields call.
        shell.setCustomTitles(window: "ops", tab: "deploy")

        // The Rename Tab sheet (⇧⌘I) opens on the tab's title. The sheet is
        // modal and would hold this runner, so it is read where the sheet
        // reads it.
        t.expect(shell.customTabTitle == "deploy", desc: "Rename Tab opens on the tab's name the popover set (\(shell.customTabTitle))")

        shell.toggleNativeInspector(nil)
        defer { shell.toggleNativeInspector(nil) }
        guard let model = shell.inspectorModel else {
            t.expect(false, desc: "the window owns its inspector model")
            return
        }
        t.pump(0.3)
        t.expect(
            model.title == "ops" && model.tabTitle == "deploy",
            desc: "the inspector shows the names the popover set (\(model.title) / \(model.tabTitle))"
        )

        // The inspector names the window: the readout its title row draws
        // beside the text survives, and the tab keeps its own name.
        let readoutBefore = shell.windowTitleReadoutForTesting
        t.expect(
            !readoutBefore.isEmpty && readoutBefore == "\(model.columns)×\(model.rows)",
            desc: "the window's readout names its grid to begin with (\(readoutBefore))"
        )
        model.title = "release"
        model.applyTitles()
        t.pump(0.3)
        t.expect(
            shell.customWindowTitle == "release" && window.title.contains("release") && !window.title.contains("ops"),
            desc: "a name typed in the inspector reaches the window (\(window.title))"
        )
        t.expect(
            shell.windowTitleReadoutForTesting == readoutBefore,
            desc: "the readout survives the name (\(shell.windowTitleReadoutForTesting))"
        )
        t.expect(
            shell.customTabTitle == "deploy" && (window.tab.title ?? "").contains("deploy"),
            desc: "the tab keeps its own name (\(window.tab.title ?? ""))"
        )

        // The popover reads the state when it opens, so it shows the
        // inspector's name rather than a copy of what it last wrote.
        guard let strip = titlebarStrip(of: window), openIdentityPopover(in: strip, t),
            let windowField = popoverView("titlebarDocumentActions.windowTitle") as? NSTextField,
            let tabField = popoverView("titlebarDocumentActions.tabTitle") as? NSTextField
        else {
            t.expect(false, desc: "the title row opens the popover with both name fields")
            return
        }
        defer { closeIdentityPopover(in: strip, t) }
        t.expect(
            windowField.stringValue == "release" && tabField.stringValue == "deploy",
            desc: "the popover opens on the inspector's names (\(windowField.stringValue) / \(tabField.stringValue))"
        )
    }

    /// A program's later title lands in the pane's facts and moves nothing a
    /// person named; cleared, the window shows the program's current title.
    @MainActor
    private static func verifyProgramTitle(_ t: UBUITestContext) {
        guard let shell = spawnShell(t), let window = shell.window, let surface = shell.focusedSurfaceForTesting else { return }
        defer { window.close() }
        let titleNow = { window.title }
        let tabNow = { window.tab.title ?? "" }

        surface.send("printf '\\033]2;program-before\\007'\n")
        t.expect(
            t.wait(until: { titleNow().contains("program-before") }, timeout: 10),
            desc: "the program's title reaches the window (\(titleNow()))"
        )
        shell.setCustomTitles(window: "ops")
        t.expect(
            titleNow().contains("ops") && !titleNow().contains("program-before"),
            desc: "the custom title takes the program's place (\(titleNow()))"
        )

        surface.send("printf '\\033]2;program-after\\007'\n")
        t.expect(
            t.wait(until: { surface.title == "program-after" }, timeout: 10),
            desc: "the program's later title is recorded (\(surface.title))"
        )
        t.pump(0.3)
        t.expect(
            titleNow().contains("ops") && !titleNow().contains("program-after"),
            desc: "the window keeps the name it was given (\(titleNow()))"
        )
        t.expect(
            tabNow().contains("ops") && !tabNow().contains("program-after"),
            desc: "and so does the tab that follows it (\(tabNow()))"
        )

        shell.setCustomTitles(window: "")
        t.expect(
            titleNow().contains("program-after") && !titleNow().contains("ops"),
            desc: "cleared, the window shows the program's current title (\(titleNow()))"
        )
    }

    /// A Swift-shell window running `/bin/sh`, ordered on screen, with the
    /// shell named: a window whose title is still empty would make every
    /// later read ambiguous.
    @MainActor
    private static func spawnShell(_ t: UBUITestContext) -> TerminalWindowController? {
        guard let shell = TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .endsWithChild),
            let window = shell.window, let surface = shell.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "a Swift-shell window opens with a pane")
            return nil
        }
        window.orderFront(nil)
        surface.send("echo title-probe\n")
        t.expect(
            t.wait(until: { !window.title.isEmpty && !(window.tab.title ?? "").isEmpty }, timeout: 10),
            desc: "the shell names the window and its tab to begin with (\(window.title))"
        )
        return shell
    }
}
