// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit

// TitleCompositionScenarios.swift — the [title] composition, end to end on a
// Kit-hosted window: the parts a switch adds appear where the reader looks,
// and a pane's header follows its tab's composition until a pane switch of
// its own decouples it.
//
// Which part shows is Core's (`Effective::windowTitleComposition` and its tab
// and pane twins, pinned in Tests/Core/Preferences) and so is the order they
// are woven in (Tests/Core/test_titleformat.cpp). What only a running window
// answers is whether the title row, the tab and the pane header each weave
// from their own composition, and whether a switch that moves while every
// fact stands still reaches them.
//
// Each switch is configured as a document and the document the scenario
// found is configured again after, rather than written through the settings
// writer, which also persists it: the settings sandbox is one per run, and a
// stated pane switch left in its file decouples every pane of every scenario
// that reloads it.

/// The header label of the pane that frames `surface`.
///
/// - Parameters:
///   - surface: The pane's surface.
///   - root: The view to search under.
/// - Returns: The label, or nil when no header frames the surface.
@MainActor
private func paneTitleField(framing surface: TerminalSurface, under root: NSView) -> NSTextField? {
    if let chrome = root as? PaneChrome, let content = chrome.contentView, surface.isDescendant(of: content) {
        return labelIdentified("pane.title", under: chrome)
    }
    for subview in root.subviews {
        if let found = paneTitleField(framing: surface, under: subview) {
            return found
        }
    }
    return nil
}

/// The text field carrying an accessibility identifier.
///
/// - Parameters:
///   - identifier: The identifier to match.
///   - root: The view to search under.
/// - Returns: The field, or nil when none carries it.
@MainActor
private func labelIdentified(_ identifier: String, under root: NSView) -> NSTextField? {
    if let field = root as? NSTextField, field.accessibilityIdentifier() == identifier {
        return field
    }
    for subview in root.subviews {
        if let found = labelIdentified(identifier, under: subview) {
            return found
        }
    }
    return nil
}

/// Registers the title-composition scenarios with the UI-test runner.
enum TitleCompositionScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // The static base text leads the window title, and the profile part
        // shows a profile's name only once one is applied: its switch alone
        // has nothing to name.
        UBUITestRegister("swift_shell_title_weaves_the_base_text_and_the_applied_profile") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate else {
                    t.expect(false, desc: "the title settings are reachable")
                    return
                }
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a pane")
                    return
                }
                let baseText = app.settingsTitleWindowText()
                let profileName = "title-weave-profile-" + UUID().uuidString
                // Saved ahead of every switch below: saving a profile reloads
                // the configuration from its file, which drops a switch set
                // in memory before it.
                app.settingsSaveProfile(["name": profileName])
                // The document from before the switch is configured again
                // first: the settings writers below splice the live document,
                // and the switch must not reach the file through them.
                var beforeSwitch: String?
                defer {
                    if let beforeSwitch {
                        t.restoreConfiguration(beforeSwitch)
                    }
                    app.settingsDeleteProfileNamed(profileName)
                    app.settingsSetTitleWindowText(baseText)
                    window.close()
                }

                surface.send("echo weave-probe\n")
                t.expect(
                    t.wait(until: { !surface.drive.processChain.isEmpty && !window.title.isEmpty }, timeout: 10.0),
                    desc: "the session sampled its chain and named the window (\(window.title))"
                )
                t.expect(!window.title.contains("UTBASE"), desc: "the title carries no base text before one is set (\(window.title))")

                // Through the setter the Settings field calls, which persists
                // the text; it is put back the same way.
                app.settingsSetTitleWindowText("UTBASE")
                TerminalWindowController.applyTitleCompositionToOpenWindows()
                t.expect(window.title.hasPrefix("UTBASE"), desc: "the base text leads the weave (\(window.title))")

                beforeSwitch = t.configureAppending("[title]\nwindow_profile_name = true\n")
                TerminalWindowController.applyTitleCompositionToOpenWindows()
                t.expect(
                    !window.title.contains("title-weave-profile-"),
                    desc: "the profile switch alone, with no profile applied, adds no segment (\(window.title))"
                )
                shell.applyProfile(named: profileName)
                t.expect(window.title.contains(profileName), desc: "the applied profile's name weaves in (\(window.title))")
            }
        }

        // A pane's header follows its tab's composition until the pane states
        // a value of its own: the tab's process part switched off empties the
        // pane's chain as well, and the pane's own switch brings it back while
        // the tab stays without.
        UBUITestRegister("swift_shell_pane_title_follows_the_tab_until_the_pane_says_otherwise") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyTitleCompositionToOpenWindows()
                }
                // The directory out of both, so the chain is the only thing a
                // search for the program can find: a checkout whose path
                // contained the program's name would answer every search.
                // The tab's process part stated on and the pane's left unset,
                // so the pane inherits a value this scenario chose.
                let paneInherits =
                    documentDroppingKeys(["pane_process"], inSection: "title", of: saved)
                    + "\n[title]\ntab_directory = false\npane_directory = false\n"
                t.restoreConfiguration(paneInherits + "tab_process = true\n")
                TerminalWindowController.applyTitleCompositionToOpenWindows()

                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                shell.splitRight(nil)
                t.pump(0.3)
                guard let surface = shell.focusedSurfaceForTesting,
                    let header = paneTitleField(framing: surface, under: shell.paneHost)
                else {
                    t.expect(false, desc: "the split pane carries a header")
                    return
                }
                let paneLabel = { header.stringValue }
                let tabLabel = { window.tab.attributedTitle?.string ?? window.tab.title ?? "" }

                // A program that takes the foreground and holds it without
                // writing again, so the chain stands still while it is read.
                surface.send("perl -e 'print \"held\\n\"; sleep 8'\n")
                t.expect(
                    t.wait(until: { paneLabel().contains("perl") && tabLabel().contains("perl") }, timeout: 10.0),
                    desc: "the tab and the pane inheriting from it both name the program"
                        + " (pane \(paneLabel()), tab \(tabLabel()))"
                )

                t.restoreConfiguration(paneInherits + "tab_process = false\n")
                TerminalWindowController.applyTitleCompositionToOpenWindows()
                t.expect(!tabLabel().contains("perl"), desc: "the tab's process part off takes the chain off the tab (\(tabLabel()))")
                t.expect(
                    !paneLabel().contains("perl"),
                    desc: "and off the pane that inherits it (\(paneLabel()))"
                )

                t.restoreConfiguration(paneInherits + "tab_process = false\npane_process = true\n")
                TerminalWindowController.applyTitleCompositionToOpenWindows()
                t.expect(paneLabel().contains("perl"), desc: "the pane's own process part brings its chain back (\(paneLabel()))")
                t.expect(
                    !tabLabel().contains("perl"),
                    desc: "while the tab stays without it: the pane decoupled alone (\(tabLabel()))"
                )
            }
        }

        // A program that names itself at length has its tab's label fitted to
        // the tab's pill: the strip measures the pill and hands the room to
        // the tab, whose label gives up the middle of the title to fit.
        UBUITestRegister("swift_shell_a_long_tab_title_fits_its_pill") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a pane")
                    return
                }
                defer { Array(TerminalWindowController.spawnedControllers).forEach { $0.window?.close() } }
                window.setContentSize(NSSize(width: 720, height: 420))
                // A second tab shows the strip, and halves the first tab's pill.
                shell.newWindowForTab(nil)
                _ = t.wait(until: { window.tabGroup?.windows.count == 2 }, timeout: 8)
                let long = "Fitting probe with a title far longer than half a strip has room for"
                surface.send("printf '\\033]2;\(long)\\007'; sleep 8\r")
                let label = { window.tab.attributedTitle }
                let fittedWidth = { () -> CGFloat? in
                    guard let label = label(), label.length > 0 else { return nil }
                    return label.attribute(TabStripStyling.fittedWidthKey, at: 0, effectiveRange: nil) as? CGFloat
                }
                t.expect(
                    t.wait(until: { window.tab.title.contains(long) && (fittedWidth() ?? 0) > 0 }, timeout: 10),
                    desc: "the strip measured the tab's pill and the title was fitted to it (\(String(describing: fittedWidth())))"
                )
                let shown = label()?.string ?? ""
                // Fitting includes the tightening the field allows before it
                // truncates, so the label is judged as the field draws it.
                t.expect(
                    shown.contains("Fitting") && !shown.contains(long)
                        && label().map { TabTitleStyling.drawsWhole($0, width: fittedWidth() ?? 0) } == true,
                    desc: "the label gives up the middle of the title to fit its pill and keeps its start ('\(shown)')"
                )
            }
        }

        // A name put on the tab or the window names the tab or the window,
        // not the panes in it: under a tab called "build" each pane's header
        // still says what runs in that pane, and the tab still says "build".
        UBUITestRegister("swift_shell_pane_headers_keep_their_own_titles_under_a_named_tab") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyTitleCompositionToOpenWindows()
                }
                // The program's own title is the header's only part, so what
                // the header says is exactly which name it answered to.
                let programTitleOnly =
                    documentDroppingKeys(
                        ["pane_app_title", "pane_directory", "pane_process", "pane_dimensions"],
                        inSection: "title",
                        of: saved
                    )
                    + "\n[title]\npane_app_title = true\npane_directory = false\npane_process = false\npane_dimensions = false\n"
                t.restoreConfiguration(programTitleOnly)
                TerminalWindowController.applyTitleCompositionToOpenWindows()

                guard let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let left = shell.focusedSurfaceForTesting
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a pane")
                    return
                }
                defer { window.close() }
                shell.splitRight(nil)
                t.pump(0.3)
                guard let right = shell.focusedSurfaceForTesting, right !== left,
                    let leftHeader = paneTitleField(framing: left, under: shell.paneHost),
                    let rightHeader = paneTitleField(framing: right, under: shell.paneHost)
                else {
                    t.expect(false, desc: "both split panes carry a header")
                    return
                }
                // Both names the window carries, its tab's and its own, set
                // before the panes title themselves.
                shell.setCustomTitles(window: "named-window", tab: "build")

                // Each title is set by the program that then holds the
                // foreground, so no prompt redraw retitles it while the headers
                // are read, and no other program is found holding the terminal
                // after the bytes that set it.
                left.send("perl -e '$|=1; print \"\\e]2;left-pane-probe\\a\"; sleep 8'\n")
                right.send("perl -e '$|=1; print \"\\e]2;right-pane-probe\\a\"; sleep 8'\n")
                let leftLabel = { leftHeader.stringValue }
                let rightLabel = { rightHeader.stringValue }
                let tabLabel = { window.tab.attributedTitle?.string ?? window.tab.title ?? "" }
                t.expect(
                    t.wait(
                        until: { leftLabel().contains("left-pane-probe") && rightLabel().contains("right-pane-probe") },
                        timeout: 10.0
                    ),
                    desc: "each pane's header shows its own program's title (left \(leftLabel()), right \(rightLabel()))"
                )
                for (side, label) in [("left", leftLabel()), ("right", rightLabel())] {
                    t.expect(
                        !label.contains("build") && !label.contains("named-"),
                        desc: "the \(side) header answers to no name given to its tab or window (\(label))"
                    )
                }
                t.expect(tabLabel().contains("build"), desc: "the tab keeps the name it was given (\(tabLabel()))")
                let destinations = shell.beamPaneDestinations().map(\.title)
                t.expect(
                    destinations.count == 2 && destinations.allSatisfy { !$0.contains("build") && !$0.contains("named-") },
                    desc: "go-to names each pane by its own title (\(destinations))"
                )
            }
        }

        // A title the shell sets the moment a command exits is the shell's,
        // and stands while the shell holds the terminal. Its bytes are parsed
        // while the last probe still names the command; a title stamped with
        // that probe's group is retired by the next one, and the header falls
        // back to the folder and the shell's name.
        UBUITestRegister("swift_shell_a_title_set_as_a_command_exits_stays_at_the_prompt") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
                defer {
                    t.restoreConfiguration(saved)
                    TerminalWindowController.applyTitleCompositionToOpenWindows()
                }
                let programTitleOnly =
                    documentDroppingKeys(
                        ["pane_app_title", "pane_directory", "pane_process", "pane_dimensions"],
                        inSection: "title",
                        of: saved
                    )
                    + "\n[title]\npane_app_title = true\npane_directory = false\npane_process = false\npane_dimensions = false\n"
                t.restoreConfiguration(programTitleOnly)
                TerminalWindowController.applyTitleCompositionToOpenWindows()

                guard let shell = TerminalWindowController.spawn(), let window = shell.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { window.close() }
                shell.splitRight(nil)
                t.pump(0.3)
                guard let surface = shell.focusedSurfaceForTesting,
                    let header = paneTitleField(framing: surface, under: shell.paneHost)
                else {
                    t.expect(false, desc: "the split pane carries a header")
                    return
                }
                let paneLabel = { header.stringValue }

                // The command writes while it runs, so a probe reads it as the
                // foreground, and exits just before the shell titles the pane.
                surface.send(
                    "perl -e '$|=1; print \"one\\n\"; select(undef, undef, undef, 0.4); print \"two\\n\"';"
                        + " printf '\\033]2;set-as-a-command-exits\\007'\n"
                )
                t.expect(
                    t.wait(until: { paneLabel().contains("set-as-a-command-exits") }, timeout: 10.0),
                    desc: "the header shows the title the shell set (\(paneLabel()))"
                )
                // An empty line redraws the prompt without starting anything,
                // so the probes it brings find the shell that set the title.
                t.pump(1.0)
                surface.send("\n")
                t.pump(1.0)
                t.expect(
                    paneLabel().contains("set-as-a-command-exits"),
                    desc: "the title stands while the shell that set it holds the terminal (\(paneLabel()))"
                )
            }
        }
    }
}
