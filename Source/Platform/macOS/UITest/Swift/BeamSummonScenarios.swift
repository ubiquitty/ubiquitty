// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UbiquittyCore
import UbiquittyKit

/// Supplies the focus state of a presented palette without activating the app.
@MainActor
private final class BeamSearchTestWindow: NSWindow {
    var hasKeyFocus = true
    override var isKeyWindow: Bool { hasKeyFocus }
}

// BeamSummonScenarios.swift — the command palette's summon on a Kit-hosted
// window.
//
// The chord is a Core default binding and the yield to a user's rebind is
// Core's rule; what a scenario can see is whether the surface claims the chord
// on the key-equivalent pass and whether the card is in the view hierarchy
// afterwards. The card is the witness, not the controller's bookkeeping, which
// a half-failed present would also set.
//
// Every witness is read before the run loop turns. The palette arms its
// focus-loss dismissal one turn after presenting and dismisses at once when
// its window is not key, and the harness's windows never are, the app being an
// accessory; a pump between the chord and the witness would read a palette
// the harness closed, not one the chord failed to open. Presenting is
// synchronous, so a summon is read the same turn it is asked; a dismissal
// drops the controller's entry the same turn and takes the card off with its
// animation, so the entry is the synchronous witness and the card is waited
// for.

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    for subview in view.subviews {
        if let found = terminalSurface(under: subview) {
            return found
        }
    }
    return nil
}

/// Beam's host view in a window, when the palette is up.
///
/// - Parameter window: The window to search.
/// - Returns: The host, or nil when no palette is presented.
@MainActor
private func beamHost(in window: NSWindow) -> NSView? {
    func find(_ view: NSView) -> NSView? {
        if view is BeamHostView {
            return view
        }
        for subview in view.subviews {
            if let found = find(subview) {
                return found
            }
        }
        return nil
    }
    return window.contentView?.superview.flatMap(find) ?? window.contentView.flatMap(find)
}

/// Records what a surface transmits.
@MainActor
private final class TransmitRecorder: TerminalSurfaceObserver {
    private(set) var transmitted: [UInt8] = []

    nonisolated func terminalSurface(_ surface: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
        let taken = bytes.prefix(count).map { UInt8(bitPattern: $0) }
        MainActor.assumeIsolated { transmitted.append(contentsOf: taken) }
    }
}

/// One key press, synthesised the way AppKit would deliver it.
///
/// - Parameters:
///   - characters: The characters the key produces.
///   - keyCode: The hardware key code.
///   - modifiers: The modifier flags held.
/// - Returns: The event, or nil when AppKit refuses the combination.
@MainActor
private func keyPress(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )
}

/// Registers the Beam summon scenarios with the UI-test runner.
enum BeamSummonScenarios {
    /// Registers every scenario in this file.
    static func register() {
        // The palette's state transitions on a real BeamModel, the one the
        // summon drives, with no window: drilling in from an empty query shows
        // the value list, leaving the drill restores the command list with the
        // selection reset, Enter applies the selected option, and a scope
        // switch never inherits the previous list's selection. The model
        // reports each broken expectation by name.
        UBUITestRegister("beam_drill_state") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let failures = BeamController.uiTestStateMachineFailures()
                for failure in failures {
                    t.expect(false, desc: "beam: \(failure)")
                }
                t.expect(failures.isEmpty, desc: "the drill and scope state machine holds")
            }
        }

        UBUITestRegister("beam_summon_leaves_font_menu_lazy_until_a_family_query") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? UBAppDelegate,
                    let shell = TerminalWindowController.spawn(), let window = shell.window,
                    let viewMenu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu,
                    let fontMenu = viewMenu.items.first(where: { $0.title == "Font" })?.submenu
                else {
                    t.expect(false, desc: "a Swift shell and View ▸ Font menu open")
                    return
                }
                defer { window.close() }
                let originalItems = fontMenu.items
                let catalogWasUnbuilt = app.fontFamilySnapshot == nil
                fontMenu.removeAllItems()
                defer {
                    fontMenu.removeAllItems()
                    for item in originalItems { fontMenu.addItem(item) }
                }

                BeamController.toggle(in: window, foreground: .white, background: .black, accent: .blue, cursor: .white)
                defer {
                    if BeamController.isActive(in: window) {
                        BeamController.toggle(in: window, foreground: .white, background: .black, accent: .blue, cursor: .white)
                    }
                }
                guard let model = BeamController.modelForTesting(in: window) else {
                    t.expect(false, desc: "summoning Beam creates its model")
                    return
                }
                t.expect(fontMenu.items.isEmpty, desc: "summoning Beam leaves View ▸ Font unfilled")
                if catalogWasUnbuilt {
                    t.expect(app.fontFamilySnapshot == nil, desc: "summoning Beam does not classify installed fonts")
                }
                model.handleFieldInput("Menlo")
                t.expect(model.results.contains(where: { $0.title == "Menlo" }), desc: "a family query finds Menlo")
            }
        }

        // The keyboard-only [keys] actions have no menu item, so this provider
        // is the only way Beam reaches them; the menu-covered ones stay out,
        // since the menu walk already lists them and a second copy would
        // duplicate the command under another identity.
        UBUITestRegister("swift_shell_beam_lists_keyboard_only_actions") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn() else {
                    t.expect(false, desc: "a Swift-shell window opens for the keys-action provider")
                    return
                }
                defer { shell.window?.close() }
                let titles = KeysActionCommandProvider(windowController: shell).commands().map(\.title)
                t.expect(titles.contains("Scroll to Top"), desc: "Scroll to Top is a Beam command (\(titles))")
                t.expect(!titles.contains("Copy"), desc: "a menu-covered action stays out")
                // Clear Scrollback has its own Edit-menu item, so the menu
                // walk lists it and this provider does not.
                t.expect(!titles.contains("Clear Scrollback"), desc: "Clear Scrollback is menu-covered, so it stays out")
                t.expect(!titles.contains("Toggle Beam"), desc: "summoning Beam from Beam stays out")
            }
        }

        // The hold-⌘ cheat sheet lists the menus' key equivalents beside the
        // [keys] bindings; the menu column is read off the menu bar the launch
        // built.
        UBUITestRegister("cheatsheet_lists_menu_shortcuts") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                t.expect(NSApp.mainMenu != nil, desc: "the launch built the menu bar the cheat sheet walks")
                let viewMenu = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
                let fontMenu = viewMenu?.items.first { $0.title == "Font" }?.submenu
                let fontMenuItemCount = fontMenu?.items.count
                let entries = CheatSheetController.uiTestEntries()
                t.expect(fontMenu?.items.count == fontMenuItemCount, desc: "the shortcut walk leaves the shortcut-free Font menu untouched")
                t.expect(!entries.isEmpty, desc: "the cheat sheet lists at least the menu shortcuts")
                let listsNewTab = entries.contains { entry in
                    let parts = entry.components(separatedBy: "\u{1f}")
                    return parts.count == 3 && parts[1] == "New Tab" && parts[0].contains("⌘")
                }
                t.expect(listsNewTab, desc: "⌘T New Tab appears in the cheat sheet's menu column")
            }
        }

        UBUITestRegister("swift_shell_beam_find_fills_from_search_publications") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let originalWindow = shell.window,
                    let surface = shell.focusedSurfaceForTesting
                else { return }
                t.pump(0.3)
                let window = BeamSearchTestWindow(
                    contentRect: originalWindow.contentLayoutRect,
                    styleMask: [.titled, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.contentView = originalWindow.contentView
                shell.window = window
                defer {
                    if BeamController.isActive(in: window) {
                        BeamController.toggle(in: window, foreground: .white, background: .black, accent: .blue, cursor: .white)
                    }
                    originalWindow.contentView = window.contentView
                    shell.window = originalWindow
                    window.close()
                    originalWindow.close()
                }
                surface.drive.stopIngest()
                surface.feed(Data((0..<240).map { "beam-async-\($0)\r\n" }.joined().utf8))
                BeamController.toggle(in: window, foreground: .white, background: .black, accent: .blue, cursor: .white)
                guard let model = BeamController.modelForTesting(in: window) else {
                    t.expect(false, desc: "the palette has a live model")
                    return
                }
                model.handleFieldInput("/beam-async-")
                t.expect(
                    t.wait(until: { model.results.count == 200 && model.findStatus == "240 matches" }, timeout: 10),
                    desc: "quiet search publications fill the bounded list and report the complete count"
                )
                model.handleFieldInput("absent-beam-token")
                t.expect(model.results.isEmpty, desc: "a replacement immediately drops the previous query's rows")
                t.expect(t.wait(until: { model.findStatus == "No matches" }, timeout: 10), desc: "a miss completes through publication")
                model.handleFieldInput("re [")
                t.expect(
                    t.wait(until: { model.findStatus == "Invalid pattern" }, timeout: 10),
                    desc: "an invalid pattern reports its state"
                )
                model.handleFieldInput("re ")
                t.expect(t.wait(until: { model.findStatus == "No matches" }, timeout: 10), desc: "an empty expression clears the search")
                let clearedGeneration = surface.drive.readSnapshot().search.generation
                t.pump(0.1)
                t.expect(
                    surface.drive.readSnapshot().search.generation == clearedGeneration,
                    desc: "clear publications do not restart the empty query"
                )
                model.handleFieldInput("beam-async-")
                t.expect(t.wait(until: { !model.results.isEmpty }, timeout: 10), desc: "a subsequent query can publish again")
                window.hasKeyFocus = false
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                t.expect(!BeamController.isActive(in: window), desc: "losing focus dismisses the palette")
                t.expect(surface.searchStatus.totalMatches == 0, desc: "dismissing the palette clears its search")
            }
        }

        UBUITestRegister("swift_shell_beam_scopes_read_and_reveal_the_originating_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let surface = shell.focusedSurfaceForTesting,
                    let owner = BeamTerminalContext(shell)
                else { return }
                defer { shell.window?.close() }
                t.pump(0.3)
                surface.drive.stopIngest()
                let output = (0..<150).map { "beam-result-\($0)\r\n" }.joined()
                surface.feed(
                    Data(
                        ("\u{1b}[2J\u{1b}[H\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}echo beam-output\r\n\u{1b}]133;C\u{7}" + output
                            + "\u{1b}]133;D;0\u{7}\u{1b}]133;A\u{7}$ ")
                            .utf8
                    )
                )
                t.pump(0.1)
                let blocks = BeamTerminalProviders.commandBlocks(owner)
                guard let block = blocks.first(where: { $0.command.contains("echo beam-output") }) else {
                    t.expect(false, desc: "Beam lists the Swift pane's command blocks")
                    return
                }
                t.expect(
                    BeamTerminalProviders.blockOutput(owner, absoluteRow: block.absoluteRow).contains("beam-result-149"),
                    desc: "copy-output reads the command's complete output"
                )
                t.expect(BeamTerminalProviders.lastBlockRange(owner) != nil, desc: "the last-output scope is available")
                let actions = BeamController.blockCommands(BeamTerminalContext(shell))
                if let action = actions.first(where: { $0.title.contains("echo beam-output") }), case .run(let run) = action.action {
                    run()
                    t.expect(surface.viewOffset > 0, desc: "the selected action retains its context after palette teardown")
                    surface.performKeyAction(named: "scroll_to_bottom")
                } else {
                    t.expect(false, desc: "the command block supplies a runnable jump action")
                }
                shell.splitRight(nil)
                t.pump(0.2)
                let destinations = owner.beamPanes()
                t.expect(destinations.count == 2, desc: "go-to lists both split panes")
                shell.setCustomTitles(tab: "Beam destination")
                t.expect(
                    owner.beamTabs().contains { $0.isCurrent && $0.title.contains("Beam destination") },
                    desc: "go-to reads the tab's current name"
                )
                var matches: [BeamMatch] = []
                t.expect(
                    t.wait(
                        until: {
                            matches = BeamTerminalProviders.findMatches(owner, query: "beam-result-12", isRegex: false, limit: 200)
                            return !matches.isEmpty
                        },
                        timeout: 10
                    ),
                    desc: "search keeps the originating pane after focus moves to the new split"
                )
                if let match = matches.first {
                    owner.beamScroll(to: match.position)
                    t.expect(surface.viewOffset > 0, desc: "jump-to reveals the originating pane's history")
                }
                BeamTerminalProviders.clearFind(owner)
                var remaining: Int32 = -1
                owner.withTerminal { terminal, _ in
                    if let terminal { remaining = Ubiquitty.Screen.ScrollSearch.matchCount(terminal) }
                }
                t.expect(remaining == 0, desc: "leaving find removes the originating pane's highlights")
                if let original = destinations.first(where: { !$0.isCurrent }) {
                    owner.beamFocusPane(original.paneID)
                    t.expect(shell.focusedSurfaceForTesting === surface, desc: "go-to focuses the selected pane")
                }
            }
        }

        UBUITestRegister("beam_first_query_keeps_the_results_frame_fixed") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let commands = (0..<20)
                    .map { index in
                        BeamCommand(title: "Command \(index)", group: "Test", identity: "geometry.\(index)", run: {})
                    }
                let model = BeamModel(
                    palette: BeamPalette(foreground: .white, background: .black, accent: .blue, caret: .white, isDark: true),
                    sources: BeamSources(
                        actions: commands,
                        settings: [],
                        goTo: { [] },
                        blocks: { [] },
                        find: { _, _ in [] },
                        findLastBlockAvailable: { false },
                        terminalScopesAvailable: false
                    )
                )
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                let hosting = NSHostingView(rootView: BeamView(model: model))
                hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 700)
                let container = NSView(frame: hosting.frame)
                hosting.autoresizingMask = [.width, .height]
                container.addSubview(hosting)
                window.contentView = container
                window.orderFront(nil)
                hosting.layoutSubtreeIfNeeded()
                defer { window.close() }
                hosting.display()
                t.pump(0.3)
                @MainActor
                func scrollView(under view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView { return scroll }
                    for child in view.subviews {
                        if let scroll = scrollView(under: child) { return scroll }
                    }
                    return nil
                }
                let scroll = window.contentView.flatMap { scrollView(under: $0) }
                let origin = scroll?.contentView.bounds.origin
                let before = scroll?.frame
                model.handleFieldInput("c")
                t.pump(0.2)
                t.expect((before?.height ?? 0) > 0, desc: "the results have laid out")
                t.expect(
                    scroll?.contentView.bounds.origin == origin,
                    desc:
                        "the first query preserves the list's scroll origin: \(String(describing: origin)) to \(String(describing: scroll?.contentView.bounds.origin))"
                )
                t.expect(scroll?.frame == before, desc: "the first character preserves the results frame")
                model.handleFieldInput("")
                t.pump(0.2)
                t.expect(scroll?.frame == before, desc: "clearing the query preserves the results frame")
            }
        }

        UBUITestRegister("swift_shell_summons_beam_on_the_built_in_chord") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(surface)
                t.pump(0.2)

                guard let summon = keyPress("P", keyCode: 35, modifiers: [.command, .shift]) else {
                    t.expect(false, desc: "a ⌘⇧P event can be made")
                    return
                }
                t.expect(surface.performKeyEquivalent(with: summon), desc: "the surface claims the built-in chord")
                t.expect(beamHost(in: window) != nil, desc: "and the palette's card is in the window")
                t.expect(BeamController.isActive(in: window), desc: "which the controller agrees is up")

                let recorder = TransmitRecorder()
                let observer = surface.observer
                surface.observer = recorder
                if let letter = keyPress("x", keyCode: 7, modifiers: []) {
                    surface.keyDown(with: letter)
                    t.expect(recorder.transmitted.isEmpty, desc: "a key delivered behind Beam never reaches the shell")
                }
                if let nextTab = keyPress("}", keyCode: 30, modifiers: [.command, .shift]) {
                    t.expect(
                        !surface.performKeyEquivalent(with: nextTab),
                        desc: "the terminal yields other shortcuts while Beam owns input"
                    )
                }
                surface.observer = observer

                // The same chord again dismisses it, while the palette holds the
                // responder, which is the whole reason the claim lives on the
                // key-equivalent pass.
                t.expect(surface.performKeyEquivalent(with: summon), desc: "the chord is claimed again while the palette is up")
                t.expect(!BeamController.isActive(in: window), desc: "and the palette is down")
                t.expect(t.wait(until: { beamHost(in: window) == nil }, timeout: 6.0), desc: "and its card leaves the window")
            }
        }

        UBUITestRegister("swift_shell_beam_keyboard_commands_scroll_the_current_terminal") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let shell = TerminalWindowController.spawn(), let surface = shell.focusedSurfaceForTesting else { return }
                defer { shell.window?.close() }
                t.pump(0.3)
                surface.drive.stopIngest()
                surface.feed(Data((0..<200).map { "beam-history-\($0)\r\n" }.joined().utf8))
                t.pump(0.1)
                let commands = KeysActionCommandProvider(windowController: shell).commands()
                guard let top = commands.first(where: { $0.identity == "keys.scroll_to_top" }), case .run(let scrollUp) = top.action,
                    let bottom = commands.first(where: { $0.identity == "keys.scroll_to_bottom" }),
                    case .run(let scrollDown) = bottom.action
                else {
                    t.expect(false, desc: "Beam lists terminal scroll commands for a Swift window")
                    return
                }
                scrollUp()
                t.expect(
                    surface.viewOffset == Int(surface.drive.readSnapshot().history.retainedRows),
                    desc: "Beam reaches the oldest retained row"
                )
                scrollDown()
                t.expect(surface.viewOffset == 0, desc: "Beam returns the same terminal to the live tail")
            }
        }

        // ⌘⇧[ and ⌘⇧] cycle the group, the bracket pair every browser and
        // editor on this platform uses. The chord a shifted bracket produces is
        // the whole difficulty: the platform reports `{`, and a binding names
        // `[`, so a chord built from what was reported would match nothing.
        UBUITestRegister("swift_shell_bracket_chords_cycle_tabs") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard let first = TerminalWindowController.spawn(), let firstWindow = first.window else {
                    t.expect(false, desc: "a Swift-shell window opens")
                    return
                }
                defer { firstWindow.tabGroup?.windows.forEach { $0.close() } }
                firstWindow.makeKeyAndOrderFront(nil)
                t.pump(0.4)
                first.newWindowForTab(nil)
                t.expect(
                    t.wait(until: { (firstWindow.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
                    desc: "a second tab opens"
                )
                guard let group = firstWindow.tabGroup,
                    let second = group.windows.first(where: { $0 !== firstWindow }),
                    let content = firstWindow.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "the group has two tabs and a surface to type into")
                    return
                }
                group.selectedWindow = firstWindow
                firstWindow.makeFirstResponder(surface)
                t.pump(0.3)
                t.expect(group.selectedWindow === firstWindow, desc: "the first tab is selected to begin with")

                // Shift and the bracket key, spelled the way AppKit delivers it:
                // `characters` carries what shift produced, `charactersIgnoringModifiers`
                // keeps shift too, and the key code names the physical key.
                guard let forward = keyPress("}", keyCode: 30, modifiers: [.command, .shift]),
                    let back = keyPress("{", keyCode: 33, modifiers: [.command, .shift])
                else {
                    t.expect(false, desc: "the two chords can be made")
                    return
                }

                // The platform refuses `selectNextTab` for a window that is not
                // key, and no window here can be one, so what a scenario can see
                // is the request: which way the chord asked the group to move.
                // Driving AppKit's own selection directly moves nothing here
                // either.
                t.expect(surface.performKeyEquivalent(with: forward), desc: "the surface claims ⌘⇧]")
                t.expect(surface.lastTabSelectionDirectionForTesting == 1, desc: "and asks for the next tab")
                t.expect(surface.performKeyEquivalent(with: back), desc: "the surface claims ⌘⇧[")
                t.expect(surface.lastTabSelectionDirectionForTesting == -1, desc: "and asks for the previous tab")

                // The claim discriminates: a bracket without the shift is the
                // terminal's to type, and reaches no tab action.
                guard let unshifted = keyPress("]", keyCode: 30, modifiers: [.command]) else {
                    t.expect(false, desc: "a ⌘] event can be made")
                    return
                }
                t.expect(!surface.performKeyEquivalent(with: unshifted), desc: "⌘] alone is not a tab chord")
                t.expect(surface.lastTabSelectionDirectionForTesting == -1, desc: "and asked for nothing")
                _ = second
            }
        }

        UBUITestRegister("swift_shell_yields_the_beam_chord_to_a_rebind") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // The restore comes first, before anything that can return: the
                // table is process-wide and every later scenario reads it.
                let saved = t.configureAppending("[keys]\n\"ctrl+alt+b\" = \"toggle_beam\"\n")
                defer { t.restoreConfiguration(saved) }

                guard let shell = TerminalWindowController.spawn(),
                    let window = shell.window,
                    let content = window.contentView,
                    let surface = terminalSurface(under: content)
                else {
                    t.expect(false, desc: "a Swift-shell window opens with a surface")
                    return
                }
                defer { window.close() }
                t.pump(0.3)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(surface)
                t.pump(0.2)
                let recorder = TransmitRecorder()
                surface.observer = recorder

                guard let summon = keyPress("P", keyCode: 35, modifiers: [.command, .shift]),
                    let bound = keyPress("b", keyCode: 11, modifiers: [.control, .option])
                else {
                    t.expect(false, desc: "the two chords can be made")
                    return
                }
                // The built-in yields: a rebind of the action replaces it, so
                // ⌘⇧P is not claimed and reaches the terminal like any other key.
                t.expect(!surface.performKeyEquivalent(with: summon), desc: "the built-in chord yields to the rebind")
                surface.routeKeyPress(summon)
                t.expect(beamHost(in: window) == nil, desc: "and summons nothing on the key-down route either")
                t.pump(0.3)

                // The rebind summons, and runs an action rather than typing.
                let sentBefore = recorder.transmitted.count
                surface.routeKeyPress(bound)
                t.expect(beamHost(in: window) != nil, desc: "the bound chord summons the palette")
                t.expect(recorder.transmitted.count == sentBefore, desc: "and typed nothing")
                if beamHost(in: window) != nil {
                    // Dismissed the same turn, before the harness's focus-loss
                    // rule can: the pump after it is a drain, not a witness.
                    surface.routeKeyPress(bound)
                    t.expect(!BeamController.isActive(in: window), desc: "and the bound chord dismisses it again")
                    t.expect(t.wait(until: { beamHost(in: window) == nil }, timeout: 6.0), desc: "and its card leaves the window")
                }
            }
        }
    }
}
