// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CxxStdlib
import UbiquittyCore
import UbiquittyKit

// SessionLayoutScenarios.swift — the application's questions about its terminal
// windows, asked with only Swift-shell windows open.
//
// The capture a quit and Save Workspace run, and the menu items that follow the
// window in front, walk the terminal windows of both shells. A walk over one
// shell's roster keeps nothing of the other's windows — a quit and relaunch
// with only Swift-shell windows open loses every one — and answers the Session
// Log item, the Theme check, the Macros items and the inspector for no window,
// or for a window behind the one in front. The scenarios open Swift-shell
// windows only; the menu one then puts an Objective-C-controller window behind them and asks
// that it answer for nothing in front of it, and the quit one hands their
// shells to a real daemon and rejoins them.
//
// The harness runs as an accessory: no window becomes key, so the window in
// front is the one ordered front, which is the lookup's own answer while no
// terminal is key. A window that would be key is named to the lookup instead.

/// A menu item as AppKit validates it: the application delegate is asked, the
/// way it is for an action no window in front implements.
///
/// - Parameters:
///   - action: The item's action.
///   - tag: The item's tag.
/// - Returns: The validated item.
@MainActor
private func validatedByTheApplication(_ action: Selector, tag: Int = 0) -> NSMenuItem {
    let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
    item.tag = tag
    item.target = NSApp.delegate
    let menu = NSMenu()
    menu.autoenablesItems = true
    menu.addItem(item)
    menu.update()
    return item
}

/// The theme indices the Theme menu checks right now.
@MainActor
private func checkedThemes() -> Set<Int> {
    let chooseTheme = NSSelectorFromString("chooseTheme:")
    return Set(
        (0..<Int(Ubiquitty.Themes.count()))
            .filter {
                validatedByTheApplication(chooseTheme, tag: $0).state == .on
            }
    )
}

/// Puts a catalog theme on a window that paints neither the one the menu checks
/// with no window open nor one another window already paints.
///
/// - Parameters:
///   - shell: The window.
///   - excluded: Themes the window must not end up painting.
/// - Returns: The theme the window paints, or nil when none would take.
@MainActor
private func paintDistinctTheme(on shell: TerminalWindowController, avoiding excluded: Set<Int>) -> Int? {
    guard let surface = shell.focusedSurfaceForTesting else { return nil }
    for candidate in 0..<Int(Ubiquitty.Themes.count()) where !excluded.contains(candidate) {
        guard shell.applyInspectedTheme(candidate, to: surface) else { continue }
        let painted = shell.paintedThemeIndex
        if painted >= 0, !excluded.contains(painted) {
            return painted
        }
    }
    return nil
}

/// The first terminal surface in a view hierarchy.
///
/// - Parameter view: The root to search under.
/// - Returns: The surface, or nil when the hierarchy holds none.
@MainActor
private func terminalSurface(under view: NSView) -> TerminalSurface? {
    if let surface = view as? TerminalSurface {
        return surface
    }
    return view.subviews.lazy.compactMap { terminalSurface(under: $0) }.first
}

/// Whether a surface's buffer holds some text, read through the find route and
/// cleared afterwards so the pane keeps no highlight from the question.
///
/// - Parameters:
///   - text: The text to look for, verbatim.
///   - surface: The surface whose buffer is read.
/// - Returns: Whether the buffer holds the text.
@MainActor
private func bufferHolds(_ text: String, in surface: TerminalSurface) -> Bool {
    let holds = surface.searchScrollbackAndWait(text, isCaseSensitive: true).totalMatches > 0
    surface.drive.clearScrollbackSearch()
    return holds
}

/// Opens a Swift-shell window running a plain shell.
@MainActor
private func openSwiftShellWindow() -> TerminalWindowController? {
    TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild)
}

/// Registers the session-layout scenarios with the UI-test runner.
enum SessionLayoutScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("saved_workspace_survives_an_application_process_restart") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkApplicationRestart(t) }
        }
        UBUITestRegister("swift_shell_windows_survive_a_saved_workspace_round_trip") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkSavedWorkspaceRoundTrip(t) }
        }
        UBUITestRegister("saved_workspace_refusal_preserves_existing_processes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkRefusedRestoreKeepsExistingProcesses(t) }
        }
        UBUITestRegister("saved_arrangements_replace_windows_only_after_opening") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkExplicitReplacement(t) }
        }
        UBUITestRegister("saved_arrangements_require_a_choice_for_missing_profiles") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkMissingProfileChoice(t) }
        }
        UBUITestRegister("swift_shell_key_window_answers_the_application_menus") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkMenusFollowTheKeyWindow(t) }
        }
        UBUITestRegister("swift_shell_windows_hand_their_shells_to_the_daemon_at_quit") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkQuitHandsShellsToTheDaemon(t) }
        }
        UBUITestRegister("swift_shared_inspector_hides_when_its_window_closes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkSharedInspectorHidesWithItsWindow(t) }
        }
        UBUITestRegister("swift_update_relaunch_keeps_every_window_tab_split_and_shell", isInDefaultSuite: false) { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkUpdateRelaunchKeepsTheArrangement(t) }
        }
        UBUITestRegister("swift_update_verified_candidate_keeps_every_window_tab_split_and_shell", isInDefaultSuite: false) { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkUpdateRelaunchKeepsTheArrangement(t, path: .verifiedCandidate) }
        }
        UBUITestRegister("swift_update_not_now_returns_an_adopted_shell_to_the_app", isInDefaultSuite: false) { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkUpdateChoiceReturnsTheShell(t, acceptedRisk: false) }
        }
        UBUITestRegister("swift_update_restart_anyway_can_abort_without_losing_its_shell", isInDefaultSuite: false) { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkUpdateChoiceReturnsTheShell(t, acceptedRisk: true) }
        }
        UBUITestRegister("swift_update_adopts_a_plain_tmux_tab", isInDefaultSuite: false) { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkUpdateAdoptsPlainTmux(t) }
        }
        UBUITestRegister("an_older_local_host_hands_a_saved_workspace_to_the_bundled_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { checkOlderLocalHostHandsItsWorkspaceOver(t) }
        }
    }

    /// Captures and restores in separate application processes against one owned daemon.
    @MainActor
    private static func checkApplicationRestart(_ t: UBUITestContext) {
        let environment = ProcessInfo.processInfo.environment
        if let phase = environment["UBIQUITTY_UI_TEST_RESTART_PHASE"] {
            checkApplicationRestartPhase(t, phase: phase)
            return
        }
        t.closeAllWindows()
        let files = FileManager.default
        let root = "/tmp/ubq-restart-" + String(UUID().uuidString.prefix(8))
        let home = root + "/home"
        do { try files.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch {
            t.expect(false, desc: "the isolated restart fixture is created: \(error)")
            return
        }
        let previousHome = environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? files.removeItem(atPath: root)
        }
        // The restored process finds its daemon where a complete bundle
        // carries it; see `placeBundledHost`.
        guard let bundled = t.placeBundledHost() else { return }
        defer { bundled.remove() }
        let host = bundled.path
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: host)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        var childEnvironment = environment
        childEnvironment["UBIQUITTY_HOME"] = home
        childEnvironment["XDG_CONFIG_HOME"] = root + "/config"
        childEnvironment["UBIQUITTY_UI_TEST_RESTART_MARK"] = String(UUID().uuidString.prefix(8))
        daemon.environment = childEnvironment
        do { try daemon.run() } catch {
            t.expect(false, desc: "the restart daemon launches: \(error)")
            return
        }
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        let socket = String(Ubiquitty.Session.localDaemonSocketPath(std.string(host)))
        guard t.wait(until: { files.fileExists(atPath: socket) }, timeout: 20) else {
            t.expect(false, desc: "the isolated daemon becomes ready")
            return
        }
        for phase in ["capture", "restore"] {
            childEnvironment["UBIQUITTY_UI_TEST_RESTART_PHASE"] = phase
            guard
                t.runApplicationPhase(
                    "saved_workspace_survives_an_application_process_restart",
                    phase: phase,
                    environment: childEnvironment,
                    logDirectory: root,
                    timeout: 60
                )
            else { return }
        }
    }

    /// Runs one half of the restart fixture without retaining application memory.
    @MainActor
    private static func checkApplicationRestartPhase(_ t: UBUITestContext, phase: String) {
        t.closeAllWindows()
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["UBIQUITTY_HOME"], let marker = environment["UBIQUITTY_UI_TEST_RESTART_MARK"] else {
            t.expect(false, desc: "the restart phase has an isolated fixture")
            return
        }
        t.configureAppending("[experimental]\nsession_persistence = false\n")
        let processFile = URL(fileURLWithPath: home + "/capture-process")
        defer { t.closeAllWindows() }
        if phase == "capture" {
            guard let shared = TerminalWindowController.spawn(), let sharedSurface = shared.focusedSurfaceForTesting,
                let local = TerminalWindowController.spawn(), let localSurface = local.focusedSurfaceForTesting
            else {
                t.expect(false, desc: "the capture process opens both shells")
                return
            }
            for surface in [sharedSurface, localSurface] {
                surface.send("UBQ_APP_RESTART_MARK=\(marker); echo ready-$UBQ_APP_RESTART_MARK\n")
            }
            t.expect(
                t.wait(
                    until: {
                        bufferHolds("ready-\(marker)", in: sharedSurface) && bufferHolds("ready-\(marker)", in: localSurface)
                    },
                    timeout: 10
                ),
                desc: "both original shells hold their private variable"
            )
            shared.shareThisWindow(nil)
            if let window = shared.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
            guard t.wait(until: { sharedSurface.drive.sharedWorkspaceResult.workspaceID != 0 }, timeout: 20) else {
                t.expect(false, desc: "the shared shell reaches the daemon")
                return
            }
            let session = LayoutSession()
            session.identifier = "application-restart"
            session.name = "Application restart"
            session.groups = TerminalWindows.capturedGroupsForSavedWorkspace()
            t.expect(session.groups.flatMap(\.tabs).count == 2, desc: "capture stores a local recipe and a live reference")
            do {
                try SessionLayout.save([session])
                try String(ProcessInfo.processInfo.processIdentifier).write(to: processFile, atomically: true, encoding: .utf8)
            } catch { t.expect(false, desc: "the capture is durable on disk: \(error)") }
            return
        }
        guard phase == "restore", let originalProcess = try? String(contentsOf: processFile, encoding: .utf8),
            let session = SessionLayout.namedWorkspaces().first(where: { $0.identifier == "application-restart" })
        else {
            t.expect(false, desc: "the second application reads the durable capture")
            return
        }
        t.expect(
            originalProcess != String(ProcessInfo.processInfo.processIdentifier),
            desc: "restoration runs in a different application process"
        )
        var restored: Bool?
        Task { @MainActor in restored = await TerminalWindows.restoreArrangementGroups(session.groups) }
        t.expect(t.wait(until: { restored != nil }, timeout: 30) && restored == true, desc: "both saved tabs restore after process restart")
        guard let shared = TerminalWindowController.spawnedControllers.compactMap(\.remoteSurface).first,
            let local = TerminalWindowController.spawnedControllers.first(where: { $0.remoteAttachment == nil })?.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "the restored workspace exposes both terminal surfaces")
            return
        }
        shared.send("echo retained-$UBQ_APP_RESTART_MARK\n")
        local.send("echo fresh-${UBQ_APP_RESTART_MARK-missing}\n")
        t.expect(
            t.wait(
                until: {
                    bufferHolds("retained-\(marker)", in: shared) && bufferHolds("fresh-missing", in: local)
                },
                timeout: 10
            ),
            desc: "the live shell survives while the local recipe starts a fresh shell"
        )
    }

    /// Exercises both explicit choices when a saved profile no longer exists.
    ///
    /// - Parameter t: The native test harness.
    @MainActor
    private static func checkMissingProfileChoice(_ t: UBUITestContext) {
        t.closeAllWindows()
        guard let existing = openSwiftShellWindow(),
            let group = TerminalWindows.capturedGroupsForSavedWorkspace().first,
            let tab = group.tabs.first,
            var presentation = SavedTerminalPresentation.decoded(tab.paneLayout ?? "")
        else {
            t.expect(false, desc: "a local arrangement is captured")
            return
        }
        presentation.profileName = "missing-profile-" + UUID().uuidString
        tab.paneLayout = presentation.encoded()
        let answerPrompt: (NSApplication.ModalResponse) -> Timer = { response in
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if NSApp.modalWindow != nil { NSApp.stopModal(withCode: response) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
            return timer
        }
        let cancelTimer = answerPrompt(.alertSecondButtonReturn)
        defer {
            cancelTimer.invalidate()
            t.closeAllWindows()
        }
        var didRestoreCancelled: Bool?
        Task { @MainActor in didRestoreCancelled = await TerminalWindows.restoreArrangementGroups([group]) }
        t.expect(t.wait(until: { didRestoreCancelled != nil }, timeout: 10), desc: "Cancel resolves the missing-profile choice")
        t.expect(didRestoreCancelled == false && TerminalWindows.keptBySession().count == 1, desc: "Cancel launches no replacement shell")
        t.expect(!existing.isClosedForTesting, desc: "Cancel preserves the existing window")
        cancelTimer.invalidate()
        let defaultTimer = answerPrompt(.alertFirstButtonReturn)
        defer { defaultTimer.invalidate() }
        var didRestoreDefault: Bool?
        Task { @MainActor in didRestoreDefault = await TerminalWindows.restoreArrangementGroups([group]) }
        t.expect(t.wait(until: { didRestoreDefault != nil }, timeout: 10), desc: "Use Default Settings resolves the choice")
        t.expect(
            didRestoreDefault == true && TerminalWindows.keptBySession().count == 2,
            desc: "the explicit default choice opens the recipe additively"
        )
        t.expect(
            TerminalWindowController.spawnedControllers.filter { $0 !== existing }.allSatisfy { $0.appliedProfileName.isEmpty },
            desc: "the missing profile is not silently recreated or applied"
        )
    }

    /// Replaces available recipes while preserving old windows on partial failure.
    @MainActor
    private static func checkExplicitReplacement(_ t: UBUITestContext) {
        t.closeAllWindows()
        guard let existing = openSwiftShellWindow(), let surface = existing.focusedSurfaceForTesting else {
            t.expect(false, desc: "the original window opens")
            return
        }
        defer {
            for terminal in TerminalWindows.keptBySession() {
                if let window = terminal.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            t.closeAllWindows()
        }
        surface.send("UBQ_REPLACE_MARK=original; echo replacement-ready\n")
        t.expect(t.wait(until: { bufferHolds("replacement-ready", in: surface) }, timeout: 10), desc: "the original shell is ready")
        let groups = TerminalWindows.capturedGroupsForSavedWorkspace()
        let arrangement = LayoutSession()
        arrangement.groups = groups
        t.expect(TerminalWindows.summary(for: arrangement).contains("new shells"), desc: "the picker labels a launch recipe honestly")
        var didReplace: Bool?
        Task { @MainActor in didReplace = await TerminalWindows.replaceWindows(with: groups) }
        t.expect(t.wait(until: { didReplace != nil }, timeout: 10), desc: "explicit replacement completes")
        t.expect(didReplace == true, desc: "the available arrangement replaces the current windows")
        let current = TerminalWindows.keptBySession()
        t.expect(current.count == 1 && !current.contains(where: { $0 === existing }), desc: "only the replacement window remains")
        guard let replacement = current.first as? TerminalWindowController,
            let replacementSurface = replacement.focusedSurfaceForTesting
        else { return }
        replacementSurface.send("echo replacement-${UBQ_REPLACE_MARK-unset}\n")
        t.expect(
            t.wait(until: { bufferHolds("replacement-unset", in: replacementSurface) }, timeout: 10),
            desc: "the local recipe opens a fresh process"
        )

        guard let group = groups.first else { return }
        let invalid = LayoutTab()
        invalid.paneLayout = SavedTerminalPresentation.prefix + "{invalid"
        group.tabs.append(invalid)
        var didReplacePartial: Bool?
        Task { @MainActor in didReplacePartial = await TerminalWindows.replaceWindows(with: groups) }
        t.expect(
            t.wait(until: { didReplacePartial != nil }, timeout: 10),
            desc: "partial failure returns without waiting for a replacement"
        )
        t.expect(didReplacePartial == false, desc: "partial failure does not count as replacement")
        t.expect(
            TerminalWindows.keptBySession().contains(where: { $0 === replacement }),
            desc: "the previous window survives partial restore failure"
        )
    }

    /// Exercises refusal through the application's saved-session entry point.
    @MainActor
    private static func checkRefusedRestoreKeepsExistingProcesses(_ t: UBUITestContext) {
        t.closeAllWindows()
        guard let delegate = NSApp.delegate as? UBAppDelegate,
            let existing = openSwiftShellWindow(), let window = existing.window,
            let surface = existing.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "an existing shell opens")
            return
        }
        let home = NSTemporaryDirectory() + "ubq-refused-restore-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            t.closeAllWindows()
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? FileManager.default.removeItem(atPath: home)
        }
        surface.send("UBQ_RESTORE_MARK=original; echo ready-$UBQ_RESTORE_MARK\n")
        t.expect(t.wait(until: { bufferHolds("ready-original", in: surface) }, timeout: 10), desc: "the existing process holds its state")
        let invalid = LayoutTab()
        invalid.paneLayout = SavedTerminalPresentation.prefix + "{invalid"
        let group = LayoutGroup()
        group.tabs = [invalid]
        let session = LayoutSession()
        session.identifier = "refused"
        session.name = "Refused arrangement"
        session.groups = [group]
        do {
            try SessionLayout.save([session])
        } catch {
            t.expect(false, desc: "the test arrangement can be stored")
            return
        }
        delegate.openSession(withIdentifier: session.identifier)
        t.expect(t.wait(until: { window.attachedSheet != nil }, timeout: 5), desc: "the damaged arrangement is reported")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        t.pump(0.2)
        t.expect(TerminalWindows.keptBySession().count == 1, desc: "refusal does not substitute a fresh shell")
        surface.send("echo retained-$UBQ_RESTORE_MARK\n")
        t.expect(
            t.wait(until: { bufferHolds("retained-original", in: surface) }, timeout: 10),
            desc: "the original shell survives the refused restore"
        )

        let incomplete = LayoutTab()
        incomplete.paneLayout =
            SavedTerminalPresentation.prefix + """
                {"liveWorkspace":{"daemonInstanceID":0,"workspaceID":0,"sessionID":0,
                "bridgeCommand":"exit 97","hostLabel":"not-yet-connected","socketName":""},
                "profileName":"","tabTitle":"","windowTitle":""}
                """
        group.tabs = [incomplete]
        var didRestoreReference: Bool?
        Task { @MainActor in didRestoreReference = await TerminalWindows.restoreArrangementGroups([group]) }
        t.expect(t.wait(until: { didRestoreReference != nil }, timeout: 5), desc: "the unconfirmed reference finishes restoring")
        t.expect(didRestoreReference == false, desc: "an unconfirmed remote identity is refused")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        t.expect(TerminalWindows.keptBySession().count == 1, desc: "an unconfirmed remote reference cannot become a local shell")
    }

    /// Two Swift-shell windows — one of three tabs, the middle one selected
    /// and each of the last two carrying a hand-set tag of its own — saved
    /// through Save Workspace and opened again.
    @MainActor
    private static func checkSavedWorkspaceRoundTrip(_ t: UBUITestContext) {
        t.closeAllWindows()
        guard let delegate = NSApp.delegate as? UBAppDelegate else {
            t.expect(false, desc: "the application delegate is reachable")
            return
        }
        // The session store lives under UBIQUITTY_HOME; a scenario writing the
        // reader's own would leave a workspace in their picker.
        let home = NSTemporaryDirectory() + "ubiquitty-session-layout-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            t.closeAllWindows()
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? FileManager.default.removeItem(atPath: home)
        }

        guard let first = openSwiftShellWindow(), let second = openSwiftShellWindow(), let third = openSwiftShellWindow(),
            let other = openSwiftShellWindow(), let firstWindow = first.window, let secondWindow = second.window,
            let thirdWindow = third.window, let otherWindow = other.window
        else {
            t.expect(false, desc: "four Swift-shell windows open")
            return
        }
        // Three tabs, the middle one selected: a group of three is where an
        // assembly that anchors every tab on the lead window reverses the ones
        // after the first, and where the stored active tab then names another
        // tab than the reader left in front.
        firstWindow.addTabbedWindow(secondWindow, ordered: .above)
        secondWindow.addTabbedWindow(thirdWindow, ordered: .above)
        firstWindow.tabGroup?.selectedWindow = secondWindow
        t.pump(0.4)
        // Moved while the second tab is the one on screen: AppKit moves only
        // that tab, and the first keeps the frame it had when it was hidden.
        secondWindow.setFrame(NSRect(x: 90, y: 210, width: 720, height: 460), display: false)
        otherWindow.setFrame(NSRect(x: 170, y: 130, width: 600, height: 380), display: false)
        second.manualTags = ["uitest-layout"]
        third.manualTags = ["uitest-last"]
        third.setCustomTitles(window: "Saved custom window", tab: "Saved custom tab")
        other.splitRight(nil)
        t.expect(other.setRootSplitRatioForTesting(0.37), desc: "the arrangement has an unequal split")
        other.toggleZoomPane(nil)
        otherWindow.orderFront(nil)
        t.pump(0.4)
        t.expect(
            firstWindow.tabGroup?.windows == [firstWindow, secondWindow, thirdWindow]
                && firstWindow.tabGroup?.selectedWindow === secondWindow,
            desc: "the first window holds three tabs in order with the middle one selected"
        )
        t.expect(secondWindow.frame != otherWindow.frame, desc: "the two windows stand at distinct frames")
        t.expect(firstWindow.frame != secondWindow.frame, desc: "the tab behind kept the frame it had before the move")
        let tabbedFrame = secondWindow.frame
        let loneFrame = otherWindow.frame

        let name = "uitest-swift-shell-layout"
        t.expect(delegate.saveCurrentLayout(withName: name), desc: "Save Workspace captures the Swift-shell windows")
        guard let saved = SessionLayout.namedWorkspaces().first(where: { $0.name == name }) else {
            t.expect(false, desc: "the saved workspace is in the session store")
            return
        }
        let groups = saved.groups
        t.expect(Int(groups.count), equals: 2, desc: "one group per window")
        guard groups.count == 2 else { return }
        // Back to front: the window left in front is opened last, so it comes
        // back in front.
        let tabbed = groups[0]
        let lone = groups[1]
        t.expect(Int(tabbed.tabs.count), equals: 3, desc: "the window behind keeps all three of its tabs, in order")
        t.expect(Int(lone.tabs.count), equals: 1, desc: "the window in front keeps its one tab")
        t.expect(tabbed.frame == tabbedFrame, desc: "the tabbed window's frame is stored (\(tabbed.frame) vs \(tabbedFrame))")
        t.expect(lone.frame == loneFrame, desc: "the lone window's frame is stored (\(lone.frame) vs \(loneFrame))")
        t.expect(tabbed.activeTab, equals: 1, desc: "the selected tab is the middle one")
        guard tabbed.tabs.count == 3, lone.tabs.count == 1 else { return }
        t.expect(
            tabbed.tabs.map { $0.tags ?? [] } == [[], ["uitest-layout"], ["uitest-last"]],
            desc: "each hand-set tag rides its own tab, in the tabs' order (\(tabbed.tabs.map { $0.tags ?? [] }))"
        )
        t.expect(
            (tabbed.tabs + lone.tabs).allSatisfy { $0.sessionID == 0 && $0.bridgeCommand == nil && $0.hostLabel == "local" },
            desc: "a saved workspace hands nothing to the daemon: every local tab restores as a fresh shell"
        )

        // The tabbed window brought in front is stored last, so it reopens in
        // front: a group stands where its selected tab stands, not where the
        // tab behind it last stood.
        secondWindow.orderFront(nil)
        t.pump(0.3)
        let frontName = "uitest-swift-shell-layout-tabbed-front"
        t.expect(delegate.saveCurrentLayout(withName: frontName), desc: "Save Workspace captures the windows again")
        if let frontSaved = SessionLayout.namedWorkspaces().first(where: { $0.name == frontName }) {
            t.expect(
                frontSaved.groups.map(\.tabs.count) == [1, 3],
                desc: "the tabbed window in front is stored last (\(frontSaved.groups.map(\.tabs.count)))"
            )
            SessionLayout.deleteSession(withIdentifier: frontSaved.identifier)
        } else {
            t.expect(false, desc: "the second saved workspace is in the session store")
        }

        t.closeAllWindows()
        t.pump(0.5)
        t.expect(TerminalWindows.keptBySession().isEmpty, desc: "no terminal window is left before the restore")
        delegate.openSession(withIdentifier: saved.identifier)
        t.expect(
            t.wait(until: { TerminalWindows.keptBySession().count == 4 }, timeout: 8),
            desc: "the workspace opens its four tabs again (\(TerminalWindows.keptBySession().count))"
        )
        t.pump(0.6)
        let restored = TerminalWindows.keptBySession()
        t.expect(
            restored.allSatisfy { $0 is TerminalWindowController },
            desc: "each tab comes back in the Swift shell"
        )
        guard let restoredTabbed = restored.compactMap(\.window).first(where: { ($0.tabGroup?.windows.count ?? 1) == 3 }),
            let restoredGroup = restoredTabbed.tabGroup,
            let restoredLone = restored.compactMap(\.window).first(where: { ($0.tabGroup?.windows.count ?? 1) == 1 })
        else {
            t.expect(false, desc: "the restore rebuilds one window of three tabs and one of one")
            return
        }
        t.expect(restoredGroup.selectedWindow === restoredGroup.windows[1], desc: "the middle tab is selected again")
        let restoredTags = restoredGroup.windows.map { ($0.windowController as? any OpenTerminalWindow)?.handSetTags ?? [] }
        t.expect(
            restoredTags == [[], ["uitest-layout"], ["uitest-last"]],
            desc: "the tabs come back in their stored order, each carrying its own tag (\(restoredTags))"
        )
        if WindowContainment.isOffscreen {
            t.expect(
                restoredTabbed.frame.size == tabbedFrame.size && restoredTabbed.frame.minY == tabbedFrame.minY,
                desc: "the contained tabbed window retains size and vertical placement"
            )
            t.expect(
                restoredLone.frame.size == loneFrame.size && restoredLone.frame.minY == loneFrame.minY,
                desc: "the contained lone window retains size and vertical placement"
            )
        } else {
            t.expect(restoredTabbed.frame == tabbedFrame, desc: "the tabbed window reopens at its frame (\(restoredTabbed.frame))")
            t.expect(restoredLone.frame == loneFrame, desc: "the lone window reopens at its frame (\(restoredLone.frame))")
        }
        let restoredThird = restoredGroup.windows[2].windowController as? TerminalWindowController
        t.expect(restoredThird?.customTabTitle == "Saved custom tab", desc: "the custom tab title survives the saved arrangement")
        t.expect(restoredThird?.customWindowTitle == "Saved custom window", desc: "the custom window title survives the saved arrangement")
        if let restoredShell = restoredLone.windowController as? TerminalWindowController {
            let presentation = restoredShell.savedPresentation(needsLocalArrangement: true)
            var snapshot = Ubiquitty.Session.Workspace()
            guard let archive = presentation.localArrangement,
                Ubiquitty.Session.deserializeWorkspaceText(std.string(archive), &snapshot), !snapshot.windows.empty()
            else {
                t.expect(false, desc: "the restored window can be captured again")
                return
            }
            let window = snapshot.windows[0]
            let tab = window.tabs[0]
            t.expect(Int(tab.root.children.size()), equals: 2, desc: "the saved split reopens both panes")
            t.expect(abs(tab.root.ratio - 0.37) < 0.001, desc: "the saved split retains its logical ratio")
            t.expect(
                window.zoomedPaneIndex == tab.focusedPaneIndex && window.zoomedPaneIndex >= 0,
                desc: "the selected pane remains zoomed"
            )
            restoredShell.toggleZoomPane(nil)
            restoredLone.setFrame(restoredLone.frame.insetBy(dx: -40, dy: -20), display: false)
            t.pump(0.2)
            func firstSplit(under view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView { return split }
                return view.subviews.lazy.compactMap { firstSplit(under: $0) }.first
            }
            if let content = restoredLone.contentView, let split = firstSplit(under: content), let first = split.arrangedSubviews.first {
                t.expect(
                    abs(first.frame.width / split.bounds.width - 0.37) < 0.003,
                    desc: "resizing applies the saved ratio to the native divider"
                )
            } else {
                t.expect(false, desc: "unzooming recreates the native split view")
            }
            let offscreen = LayoutGroup()
            offscreen.frame = NSRect(x: 1_000_000, y: 1_000_000, width: 600, height: 380)
            TerminalWindows.settleRestoredGroup(offscreen, windows: [restoredLone])
            if WindowContainment.isOffscreen {
                t.expect(
                    !NSScreen.screens.contains { $0.frame.intersects(restoredLone.frame) },
                    desc: "restoring placement respects test-window containment"
                )
            } else {
                t.expect(
                    NSScreen.screens.contains { $0.visibleFrame.contains(restoredLone.frame) },
                    desc: "an unavailable display cannot leave the restored window offscreen"
                )
            }
        }
    }

    /// Session Log, the Theme check, Share and Stop Sharing, the Macros items
    /// and the inspector, each answered for the Swift-shell window in front.
    @MainActor
    private static func checkMenusFollowTheKeyWindow(_ t: UBUITestContext) {
        t.closeAllWindows()
        guard let delegate = NSApp.delegate as? UBAppDelegate else {
            t.expect(false, desc: "the application delegate is reachable")
            return
        }
        let restingThemes = checkedThemes()
        let logPath = NSTemporaryDirectory() + "ubiquitty-key-window-log-\(ProcessInfo.processInfo.processIdentifier).log"
        let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            t.restoreConfiguration(saved)
            try? FileManager.default.removeItem(atPath: logPath)
            t.closeAllWindows()
        }

        guard let logging = openSwiftShellWindow(), let quiet = openSwiftShellWindow(),
            let loggingWindow = logging.window, let quietWindow = quiet.window
        else {
            t.expect(false, desc: "two Swift-shell windows open")
            return
        }
        t.pump(0.5)
        guard let loggingTheme = paintDistinctTheme(on: logging, avoiding: restingThemes),
            let quietTheme = paintDistinctTheme(on: quiet, avoiding: restingThemes.union([loggingTheme]))
        else {
            t.expect(false, desc: "each window paints a theme of its own")
            return
        }
        t.expect(logging.startSessionLog(atPath: logPath), desc: "the first window keeps a session log")

        @MainActor
        func bringFront(_ window: NSWindow) -> Bool {
            window.makeKeyAndOrderFront(nil)
            t.pump(0.2)
            return TerminalWindows.keyTerminal()?.window === window
        }

        let sessionLog = #selector(TerminalWindowController.toggleSessionLog(_:))
        let chooseTheme = NSSelectorFromString("chooseTheme:")
        let editTheme = NSSelectorFromString("editCurrentTheme:")
        let share = NSSelectorFromString("shareThisWindow:")
        let stopSharing = NSSelectorFromString("stopSharingWindow:")

        t.expect(bringFront(loggingWindow), desc: "the logging window is the one in front")
        let logItem = validatedByTheApplication(sessionLog)
        t.expect(logItem.isEnabled, desc: "Session Log is offered for the Swift window in front")
        t.expect(
            logItem.title == "Stop Logging Session" && logItem.state == .on,
            desc: "and it follows that window's log (\(logItem.title))"
        )
        t.expect(
            validatedByTheApplication(chooseTheme, tag: loggingTheme).state == .on
                && validatedByTheApplication(chooseTheme, tag: quietTheme).state == .off,
            desc: "the Theme menu checks the theme the window in front paints"
        )
        // A Swift window answers Share itself, ahead of the application; the
        // application claims no Objective-C-controller window for it.
        t.expect(
            logging.validateMenuItem(NSMenuItem(title: "", action: share, keyEquivalent: "")),
            desc: "the Swift window in front offers to share its own shell"
        )
        t.expect(
            !logging.validateMenuItem(NSMenuItem(title: "", action: stopSharing, keyEquivalent: "")),
            desc: "and not to stop sharing, with nothing shared"
        )
        // Asked of the application, as it is whenever the window in front is
        // not a terminal: the answer is the window Session Log acts on.
        t.expect(
            validatedByTheApplication(share).isEnabled,
            desc: "the application offers Share for the Swift window in front"
        )
        t.expect(!validatedByTheApplication(stopSharing).isEnabled, desc: "and Stop Sharing for none, with nothing shared")
        t.expect(
            validatedByTheApplication(editTheme).isEnabled,
            desc: "Edit Current Theme opens the Swift Settings editor"
        )
        // A window on no remote session has nobody attached to manage.
        let sessionMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Session" })?.submenu
        sessionMenu.flatMap { $0.delegate?.menuNeedsUpdate?($0) }
        t.expect(
            sessionMenu?.items.map(\.title) == ["No Remote Session"],
            desc: "the Session menu says the Swift window in front is on no remote session (\(sessionMenu?.items.map(\.title) ?? []))"
        )

        t.expect(bringFront(quietWindow), desc: "the quiet window is the one in front")
        let quietItem = validatedByTheApplication(sessionLog)
        t.expect(
            quietItem.isEnabled && quietItem.title == "Log Session to File…" && quietItem.state == .off,
            desc: "Session Log offers to start a log for the window in front that keeps none (\(quietItem.title))"
        )
        t.expect(
            validatedByTheApplication(chooseTheme, tag: quietTheme).state == .on
                && validatedByTheApplication(chooseTheme, tag: loggingTheme).state == .off,
            desc: "and the Theme check moves with it"
        )
        logging.stopSessionLog()

        // A configured macro is offered while a Swift window is in front.
        let macroName = "uitest-key-window-macro"
        t.configureAppending("[macros]\n\(tomlQuoted(macroName)) = \"true\"\n")
        let macrosMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Macros" })?.submenu
        if let macrosMenu {
            macrosMenu.delegate?.menuNeedsUpdate?(macrosMenu)
        }
        t.expect(
            macrosMenu?.items.first(where: { $0.title == macroName })?.isEnabled == true,
            desc: "the Macros menu offers a macro to the Swift window in front"
        )

        // The inspector the window in front toggles is that window's own.
        delegate.toggleInspector(t)
        t.pump(0.5)
        let quietIdentity = quiet.focusedSurfaceForTesting.map { InspectorIdentity(owner: $0.drive.sessionIdentity) }
        t.expect(quietIdentity != nil, desc: "the Swift window in front has a pane to inspect")
        t.expect(
            quiet.inspectorModel?.target?.identity == quietIdentity && logging.inspectorModel == nil,
            desc: "the Inspector opens on the Swift window in front"
        )
        delegate.toggleInspector(t)
        t.pump(0.3)

        // The shared panel, when it is up, follows the Swift window in front,
        // and what that window's session reports reaches it with nothing polled.
        let panel = InspectorController()
        panel.toggle()
        t.expect(
            panel.inspectedModelForTesting.target?.identity == quietIdentity,
            desc: "the shared inspector panel targets the Swift window in front"
        )
        let directory = "/tmp/ubiquitty-shared-inspector-" + String(UUID().uuidString.prefix(6))
        quiet.focusedSurfaceForTesting?.send("printf '\\033]7;file://localhost\(directory)\\007'\r")
        t.expect(
            t.wait(until: { panel.inspectedModelForTesting.directory == directory }, timeout: 8),
            desc: "the shared panel shows the directory the Swift window's shell reported (\(panel.inspectedModelForTesting.directory))"
        )
        panel.toggle()

        // The drop-down panel is a terminal the reader works in while it is
        // key, though no session keeps it: the menus act on it, and the capture
        // leaves it out.
        guard let dropDown = TerminalWindowController.spawnUnshownPanel(), let dropDownWindow = dropDown.window else {
            t.expect(false, desc: "the drop-down panel's terminal opens")
            return
        }
        dropDownWindow.orderFront(nil)
        t.pump(0.4)
        t.expect(
            TerminalWindows.keyTerminal(keyWindow: dropDownWindow, mainWindow: dropDownWindow) === dropDown,
            desc: "the drop-down panel, key, is the terminal the menus act on"
        )
        t.expect(
            TerminalWindows.keyTerminal(keyWindow: nil, mainWindow: dropDownWindow) === dropDown,
            desc: "and so it is while a utility panel holds the keyboard over it"
        )
        t.expect(TerminalWindows.all().contains { $0 === dropDown }, desc: "the drop-down panel is listed among the terminal windows")
        t.expect(!TerminalWindows.keptBySession().contains { $0 === dropDown }, desc: "and no session keeps it")
        t.expect(
            TerminalWindows.capturedGroupsForSavedWorkspace().count == 2,
            desc: "Save Workspace keeps the two Swift windows and not the drop-down panel"
        )
        dropDownWindow.close()
        t.pump(0.3)

        // An Objective-C-controller window behind answers for nothing in front of it; in front,
        // it is the one the items act on.
        guard let classic = t.newWindowRunning(nil), let classicWindow = classic.window else {
            t.expect(false, desc: "a classic window opens behind")
            return
        }
        t.pump(0.6)
        t.expect(bringFront(quietWindow), desc: "the Swift window is back in front of the classic one")
        t.expect(
            validatedByTheApplication(chooseTheme, tag: quietTheme).state == .on,
            desc: "and the Theme check stays with the window in front"
        )
        // A split window can share every pane. The answer still belongs to
        // the window in front, not the classic window behind it.
        quiet.splitRight(nil)
        t.pump(0.6)
        t.expect(
            quiet.validateMenuItem(NSMenuItem(title: "", action: share, keyEquivalent: "")),
            desc: "the split window in front offers to share every pane"
        )
        t.expect(
            validatedByTheApplication(share).isEnabled,
            desc: "and the application offers Share for it with a classic window behind it"
        )
        t.expect(bringFront(classicWindow), desc: "the classic window comes in front")
        t.expect(validatedByTheApplication(share).isEnabled, desc: "and Share is offered for it there")
        t.expect(
            validatedByTheApplication(editTheme).isEnabled,
            desc: "and Edit Current Theme opens on the classic window it can edit"
        )
        // The quit's question reaches an Objective-C-controller window through the
        // same walk, reading the running-job fact off that window.
        t.expect(
            !TerminalWindows.windowsEndedByQuit().contains { $0 === classic },
            desc: "an idle classic window costs a quit no job"
        )
    }

    /// The shared inspector panel hides when the terminal window it follows
    /// closes, rather than standing on a window that is gone.
    @MainActor
    private static func checkSharedInspectorHidesWithItsWindow(_ t: UBUITestContext) {
        t.closeAllWindows()
        defer { t.closeAllWindows() }
        // The panel observes the close before the window's own delegate does,
        // which is the order a panel opened before the window is closed in:
        // the shell's roster still lists the window while the panel is asked.
        let panel = InspectorController()
        guard let shell = openSwiftShellWindow(), let window = shell.window else {
            t.expect(false, desc: "a Swift-shell window opens")
            return
        }
        t.pump(0.5)
        panel.toggle()
        t.expect(panel.isPanelShownForTesting, desc: "the shared inspector panel is up")
        t.expect(
            panel.inspectedModelForTesting.target != nil,
            desc: "and it targets the window in front"
        )
        // AppKit posts willClose with the window still key, still main and
        // still on its shell's roster.
        window.close()
        t.pump(0.6)
        t.expect(!panel.isPanelShownForTesting, desc: "closing the last terminal window hides the panel")
        t.expect(panel.inspectedModelForTesting.target == nil, desc: "and leaves it inspecting nothing")
    }

    /// An app update meets a workspace an older host on this Mac holds.
    ///
    /// The older host runs from the control directory's `ubiquitty-host`, as
    /// an SSH bootstrap installs one, and holds a workspace a window here
    /// saved. The launch's upgrade installs the bundled host over it and
    /// starts it; the older host hands every session over and exits, and the
    /// saved window comes back attached on the bundled host: the same
    /// workspace, its scrollback and its shell.
    @MainActor
    private static func checkOlderLocalHostHandsItsWorkspaceOver(_ t: UBUITestContext) {
        t.closeAllWindows()
        // The host where a complete bundle carries it; see `placeBundledHost`.
        guard let bundled = t.placeBundledHost() else { return }
        defer { bundled.remove() }
        let fileManager = FileManager.default

        // A home of its own under /tmp: a Unix socket path is capped at 103
        // bytes, and nothing here touches the operator's hosts or sessions.
        let root = "/tmp/ubq-lhu-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try fileManager.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            t.closeAllWindows()
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? fileManager.removeItem(atPath: root)
        }

        // The older host: another build, installed where an SSH bootstrap
        // installs one.
        let installed = home + "/ubiquitty-host"
        guard var older = fileManager.contents(atPath: bundled.path) else {
            t.expect(false, desc: "the bundled host can be read")
            return
        }
        older.append(contentsOf: Array("\nan older host\n".utf8))
        guard fileManager.createFile(atPath: installed, contents: older, attributes: [.posixPermissions: 0o755]) else {
            t.expect(false, desc: "the older host is installed in the control directory")
            return
        }
        let olderSocket = String(Ubiquitty.Session.localDaemonSocketPath(std.string(installed)))
        let bundledSocket = String(Ubiquitty.Session.localDaemonSocketPath(std.string(bundled.path)))
        t.expect(!olderSocket.isEmpty && olderSocket != bundledSocket, desc: "the two builds own two sockets")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: installed)
        holder.arguments = ["--daemon", "--quic-port", "-1", "--columns", "80", "--rows", "24"]
        // Shells that read none of the operator's files.
        holder.environment = ProcessInfo.processInfo.environment.merging([
            "UBIQUITTY_HOME": home, "HOME": root, "SHELL": "/bin/sh", "ENV": "/dev/null", "HISTFILE": "/dev/null",
        ]) { $1 }
        do {
            try holder.run()
        } catch {
            t.expect(false, desc: "the older host started (\(error))")
            return
        }
        defer {
            if holder.isRunning { holder.terminate() }
            holder.waitUntilExit()
        }
        defer {
            // The hosts the upgrade started are detached; each is ended by the
            // process ID it wrote in this private home, and killed if it has
            // not stopped in time.
            t.closeAllWindows()
            let started = ((try? fileManager.contentsOfDirectory(atPath: home)) ?? [])
                .filter { $0.hasPrefix("host-") && $0.hasSuffix(".pid") }
                .compactMap { try? String(contentsOfFile: home + "/" + $0, encoding: .utf8) }
                .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { $0 > 0 && $0 != holder.processIdentifier }
            for pid in started {
                kill(pid, SIGTERM)
            }
            for pid in started where !t.wait(until: { kill(pid, 0) != 0 }, timeout: 10) {
                kill(pid, SIGKILL)
                _ = t.wait(until: { kill(pid, 0) != 0 }, timeout: 5)
            }
        }
        guard t.wait(until: { fileManager.fileExists(atPath: olderSocket) }, timeout: 20) else {
            t.expect(false, desc: "the older host opened its socket (\(olderSocket))")
            return
        }

        // A window on it, in a named workspace, with a line in its scrollback.
        let marker = String(UUID().uuidString.prefix(8))
        let bridge = String(
            String(installed.withCxxStringView { Ubiquitty.Transport.shellSingleQuote($0) })
                .withCxxStringView { Ubiquitty.Session.localBridgeCommand($0) }
        )
        guard
            let original = TerminalWindowController.spawnRemoteWindow(
                shellCommand: bridge,
                hostLabel: TerminalWindowController.thisMacHostKey,
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: "uitest-upgrade-\(marker)",
                hostKey: TerminalWindowController.thisMacHostKey
            )
        else {
            t.expect(false, desc: "a window opens on the older host")
            return
        }
        guard
            t.wait(
                until: { original.remoteSurface?.drive.remoteState == .Connected && original.remotePaneSurfaces.count == 1 },
                timeout: 20
            ), let pane = original.remotePaneSurfaces.values.first, let drive = original.remoteSurface?.drive
        else {
            t.expect(
                false,
                desc: "the window reaches the older host and shows its pane (\(original.remoteSurface?.remoteFailureDetail ?? ""))"
            )
            return
        }
        pane.send("echo \"before:[\(marker)]\"\n")
        t.expect(t.wait(until: { bufferHolds("before:[\(marker)]", in: pane) }, timeout: 10), desc: "the older host's shell answers")
        let olderInstance = drive.remoteDaemonInstanceID
        let workspaceID = drive.remoteWorkspaceID
        t.expect(olderInstance != 0 && workspaceID != 0, desc: "the window knows the older host's instance and its workspace")

        // The window as the session store keeps it, then closed, as a quit
        // closes it; the workspace stays on the older host.
        let groups = TerminalWindows.capturedGroupsForSavedWorkspace()
        let saved = groups.flatMap(\.tabs).compactMap { SavedTerminalPresentation.decoded($0.paneLayout ?? "")?.liveWorkspace }
        t.expect(
            saved.count == 1 && saved.first?.daemonInstanceID == olderInstance && saved.first?.workspaceID == workspaceID,
            desc: "the saved window names the older host's instance and the workspace (\(saved.map(\.daemonInstanceID)))"
        )
        t.closeAllWindows()
        t.pump(0.5)
        t.expect(holder.isRunning, desc: "the older host keeps the workspace after its window closes")

        // The launch's upgrade.
        var report: LocalHostUpgradeReport?
        Task { @MainActor in report = await LocalHostUpgrade.now() }
        t.expect(t.wait(until: { report != nil }, timeout: 60), desc: "the upgrade finishes")
        t.expect(report?.title.isEmpty == true, desc: "the upgrade leaves nothing undone (\(report?.title ?? ""))")
        let installedFile = (try? fileManager.attributesOfItem(atPath: installed))?[.systemFileNumber] as? Int
        let bundledFile = (try? fileManager.attributesOfItem(atPath: bundled.path))?[.systemFileNumber] as? Int
        t.expect(installedFile != nil && installedFile == bundledFile, desc: "the bundled host is installed where the older one was")
        t.expect(t.wait(until: { !holder.isRunning }, timeout: 30), desc: "the older host hands its sessions over and exits")
        if !holder.isRunning {
            t.expect(holder.terminationStatus == 0, desc: "the older host exits cleanly (\(holder.terminationStatus))")
        }

        // The saved window comes back, attached on the bundled host. A local
        // window stays open throughout, so a restore that fails says so on a
        // sheet rather than in an alert that holds the run loop; what the
        // restoring window last reported is kept for the reader.
        guard let anchor = openSwiftShellWindow() else {
            t.expect(false, desc: "a local window opens beside the restore")
            return
        }
        defer { anchor.window?.close() }
        var didRestore: Bool?
        var restoring = ""
        Task { @MainActor in didRestore = await TerminalWindows.restoreArrangementGroups(groups) }
        t.expect(
            t.wait(
                until: {
                    if let surface = TerminalWindows.keptBySession().compactMap({ ($0 as? TerminalWindowController)?.remoteSurface })
                        .first(where: { $0.drive.remoteWorkspaceID == workspaceID || $0.drive.remoteState != .Connected })
                    {
                        restoring = "state \(surface.drive.remoteState.rawValue), \(surface.remoteFailureDetail)"
                    }
                    return didRestore != nil
                },
                timeout: 60
            ),
            desc: "the restore finishes"
        )
        t.expect(didRestore == true, desc: "the saved window is restored (\(restoring))")
        let reattached = TerminalWindows.keptBySession().compactMap { $0 as? TerminalWindowController }
            .first { $0.remoteSurface?.drive.remoteWorkspaceID == workspaceID }
        guard let reattached, let reattachedDrive = reattached.remoteSurface?.drive,
            t.wait(until: { reattachedDrive.remoteState == .Connected && reattached.remotePaneSurfaces.count == 1 }, timeout: 20),
            let reattachedPane = reattached.remotePaneSurfaces.values.first
        else {
            t.expect(false, desc: "the restored window reaches its workspace")
            return
        }
        t.expect(
            reattachedDrive.remoteDaemonInstanceID != 0 && reattachedDrive.remoteDaemonInstanceID != olderInstance,
            desc: "the restored window is attached on the bundled host's instance (\(reattachedDrive.remoteDaemonInstanceID))"
        )
        t.expect(
            reattached.remoteAttachment?.socketName == URL(fileURLWithPath: bundledSocket).lastPathComponent,
            desc: "and follows the bundled host's socket (\(reattached.remoteAttachment?.socketName ?? ""))"
        )
        t.expect(
            t.wait(until: { bufferHolds("before:[\(marker)]", in: reattachedPane) }, timeout: 10),
            desc: "the workspace keeps its scrollback across the upgrade"
        )
        reattachedPane.send("echo \"after:[\(marker)]\"\n")
        t.expect(
            t.wait(until: { bufferHolds("after:[\(marker)]", in: reattachedPane) }, timeout: 10),
            desc: "the shell the older host started takes input on the bundled host"
        )
    }

    /// A quit with plain shells, an already shared shell, and a running job.
    /// The quit confirms each daemon owner and saves their references before
    /// allowing termination; the next launch rejoins those same sessions.
    @MainActor
    private static func checkQuitHandsShellsToTheDaemon(_ t: UBUITestContext) {
        t.closeAllWindows()
        guard let delegate = NSApp.delegate as? UBAppDelegate else {
            t.expect(false, desc: "the application delegate is reachable")
            return
        }
        // The host where a complete bundle carries it; see `placeBundledHost`.
        guard let bundled = t.placeBundledHost() else { return }
        defer { bundled.remove() }
        let bundledHost = bundled.path
        let fileManager = FileManager.default

        // A home of its own under /tmp: a Unix socket path is capped at 103
        // bytes, and nothing here touches the operator's daemon or sessions.
        let root = "/tmp/ubq-quit-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try fileManager.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            t.closeAllWindows()
            t.restoreConfiguration(saved)
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? fileManager.removeItem(atPath: root)
        }

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: bundledHost)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do {
            try daemon.run()
        } catch {
            t.expect(false, desc: "the daemon started (\(error))")
            return
        }
        defer {
            // The windows first: a client still attached when its daemon goes
            // would redial, and its bridge would start another daemon here.
            t.closeAllWindows()
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        let socketPath = String(Ubiquitty.Session.localDaemonSocketPath(std.string(bundledHost)))
        guard !socketPath.isEmpty, t.wait(until: { fileManager.fileExists(atPath: socketPath) }, timeout: 20) else {
            t.expect(false, desc: "the daemon opened the socket a quit looks for (\(socketPath))")
            return
        }

        guard let kept = openSwiftShellWindow(), let shared = openSwiftShellWindow(),
            let keptSurface = kept.focusedSurfaceForTesting, let sharedSurface = shared.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "two Swift-shell windows open")
            return
        }
        t.pump(0.3)
        // A mark inside each shell, read back through its own expansion, so an
        // answer after the restore can only come from the shell that held it.
        let marker = String(UUID().uuidString.prefix(8))
        keptSurface.send("UBQ_QUIT_MARK=kept-\(marker); echo \"at:[$UBQ_QUIT_MARK]\"\n")
        sharedSurface.send("UBQ_QUIT_MARK=shared-\(marker); echo \"at:[$UBQ_QUIT_MARK]\"\n")
        t.expect(
            t.wait(
                until: { bufferHolds("at:[kept-\(marker)]", in: keptSurface) && bufferHolds("at:[shared-\(marker)]", in: sharedSurface) },
                timeout: 10
            ),
            desc: "each window's own shell holds its mark"
        )

        kept.manualTags = ["uitest-stored"]
        shared.manualTags = ["uitest-stored"]

        NSApp.sendAction(#selector(TerminalWindowController.shareThisWindow(_:)), to: shared, from: nil)
        if let sharedWindow = shared.window, let sheet = sharedWindow.attachedSheet {
            sharedWindow.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
        guard
            t.wait(
                until: { sharedSurface.drive.sharedWorkspaceResult.workspaceID != 0 },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the second window is shared into the daemon (\(sharedSurface.remoteFailureDetail))")
            return
        }
        let sharedSessionID = sharedSurface.remoteSessionID
        let localBridge = String(
            String(bundledHost.withCxxStringView { Ubiquitty.Transport.shellSingleQuote($0) })
                .withCxxStringView { Ubiquitty.Session.localBridgeCommand($0) }
        )
        let socketName = URL(fileURLWithPath: socketPath).lastPathComponent

        // The Session menu speaks for the window in front: the shared window's
        // roster as the daemon reports it, rather than "No remote session".
        shared.window?.orderFront(nil)
        t.pump(0.4)
        let sessionMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Session" })?.submenu
        sessionMenu.flatMap { $0.delegate?.menuNeedsUpdate?($0) }
        t.expect(
            sessionMenu?.items.first?.title == "Connected to This Session",
            desc: "the Session menu shows the shared Swift window's roster (\(sessionMenu?.items.map(\.title) ?? []))"
        )

        // The quit's confirmation answers by what the quit does. A job in a
        // window whose shell the daemon will adopt keeps running, so there is
        // nothing to warn about; with the session not persisted the same job
        // ends with the application and the reader is asked first.
        guard let busy = openSwiftShellWindow(), let busySurface = busy.focusedSurfaceForTesting else {
            t.expect(false, desc: "a third Swift-shell window opens to run a job in")
            return
        }
        busySurface.send("sleep 30\n")
        t.expect(t.wait(until: { busy.hasRunningProcesses }, timeout: 10), desc: "the third window runs a job")
        var prompts = 0
        let askedWithoutPersistence = TerminalWindows.terminationReply {
            prompts += 1
            t.expect($0.messageText == "Quit Ubiquitty?", desc: "the quit presents its confirmation")
            return .alertSecondButtonReturn
        }
        t.expect(
            askedWithoutPersistence == .terminateCancel && prompts == 1,
            desc: "with nothing persisted the quit warns that the job would end"
        )
        t.configureAppending("[experimental]\nsession_persistence = true\n")
        let persistentReply = TerminalWindows.terminationReply { _ in
            prompts += 1
            return .alertSecondButtonReturn
        }
        t.expect(
            persistentReply == .terminateNow && prompts == 1,
            desc: "and with the session persisted and the daemon up it warns about nothing: the shell is handed over"
        )
        guard let groups = SessionLayout.currentLayout() else {
            t.expect(false, desc: "the quit saved its confirmed session layout before allowing termination")
            return
        }
        let tabs = groups.flatMap(\.tabs)
        t.expect(Int(tabs.count), equals: 3, desc: "the quit keeps both marked shells and the running job")
        let busySessionID = busy.tabCaptureFacts.remoteSessionID
        t.expect(
            busySessionID != 0 && tabs.contains(where: { $0.sessionID == busySessionID }),
            desc: "the running job has a confirmed daemon session in the saved layout"
        )
        t.expect(
            TerminalWindows.windowsEndedByQuit().isEmpty,
            desc: "no window's job ends with this quit (\(TerminalWindows.windowsEndedByQuit().count))"
        )
        t.restoreConfiguration(saved)
        t.configureAppending("[experimental]\nsession_persistence = false\n")
        busy.window?.close()
        t.pump(0.4)

        guard let sharedTab = tabs.first(where: { $0.sessionID == sharedSessionID }) else {
            t.expect(false, desc: "the shared window is stored as the daemon session \(sharedSessionID) (\(tabs.map(\.sessionID)))")
            return
        }
        t.expect(
            sharedTab.hostLabel == "local" && sharedTab.bridgeCommand == localBridge,
            desc: "and is reached through this machine's bridge (\(sharedTab.hostLabel ?? "") \(sharedTab.bridgeCommand ?? ""))"
        )
        guard let keptTab = tabs.first(where: { $0.sessionID != sharedSessionID && $0.sessionID != busySessionID }) else { return }
        t.expect(keptTab.sessionID != 0, desc: "the plain shell was handed to the daemon at quit")
        t.expect(keptSurface.drive.isSharedIntoLocalDaemon, desc: "its window gave the daemon its PTY")
        t.expect(
            keptTab.hostLabel == "local" && keptTab.bridgeCommand == localBridge && keptTab.socketName == socketName,
            desc: "and the tab rejoins it through this machine's daemon on the socket it went to (\(keptTab.socketName ?? ""))"
        )

        let savedIdentities = tabs.compactMap { SavedTerminalPresentation.decoded($0.paneLayout ?? "")?.liveWorkspace?.daemonInstanceID }
        t.expect(
            savedIdentities.count == 3 && savedIdentities.allSatisfy { $0 != 0 },
            desc: "every live reference retains a daemon process identity"
        )
        t.expect(Set(savedIdentities).count == 1, desc: "all adopted shells name the same daemon process")

        // The next launch reaches the same shells and the running job.
        let openBefore = Set(TerminalWindows.keptBySession().map { ObjectIdentifier($0) })
        let session = LayoutSession()
        session.identifier = "uitest-quit-" + marker
        session.name = session.identifier
        session.groups = groups
        do {
            try SessionLayout.save(SessionLayout.allSessions() + [session])
        } catch {
            t.expect(false, desc: "the quit's layout is in the session store (\(error))")
            return
        }
        delegate.openSession(withIdentifier: session.identifier)
        t.expect(
            t.wait(until: { TerminalWindows.keptBySession().count == openBefore.count + 3 }, timeout: 10),
            desc: "the restore opens a window for each stored tab (\(TerminalWindows.keptBySession().count))"
        )
        let restoredSurfaces = TerminalWindows.keptBySession()
            .filter { !openBefore.contains(ObjectIdentifier($0)) }
            .compactMap { $0.window?.contentView.flatMap(terminalSurface(under:)) }
        t.expect(Int(restoredSurfaces.count), equals: 3, desc: "each restored window shows a terminal")
        for surface in restoredSurfaces {
            _ = t.wait(until: { surface.drive.remoteState == Ubiquitty.Session.State.Connected }, timeout: 20)
            surface.send("echo \"back:[$UBQ_QUIT_MARK]\"\n")
        }
        for name in ["kept", "shared"] {
            t.expect(
                t.wait(until: { restoredSurfaces.contains { bufferHolds("back:[\(name)-\(marker)]", in: $0) } }, timeout: 20),
                desc: "a restored window answers from the \(name) window's own shell"
            )
        }

        // The two tagged windows recover their stored tags; the running-job
        // window had none to recover. Reopening the same session brings each
        // live window forward with the tags the reader gave it since.
        let restoredTerminals = TerminalWindows.keptBySession().filter { !openBefore.contains(ObjectIdentifier($0)) }
        t.expect(
            restoredTerminals.filter { $0.handSetTags == ["uitest-stored"] }.count == 2
                && restoredTerminals.filter { $0.handSetTags.isEmpty }.count == 1,
            desc: "each restored window carries only its stored tags (\(restoredTerminals.map(\.handSetTags)))"
        )
        for terminal in restoredTerminals {
            terminal.handSetTags = ["uitest-retagged"]
        }
        let windowsBeforeReopen = Set(TerminalWindows.keptBySession().map(ObjectIdentifier.init))
        var didReopen: Bool?
        Task { @MainActor in didReopen = await TerminalWindows.restoreArrangementGroups(groups) }
        t.expect(t.wait(until: { didReopen != nil }, timeout: 40), desc: "the second restore finishes before its windows are inspected")
        t.expect(didReopen == true, desc: "the saved live sessions remain available")
        t.expect(
            Int(TerminalWindows.keptBySession().count),
            equals: openBefore.count + 3,
            desc: "opening the session again reaches the windows already showing its shells"
        )
        t.expect(
            Set(TerminalWindows.keptBySession().map(ObjectIdentifier.init)) == windowsBeforeReopen,
            desc: "opening the session again reuses every window already showing its shell"
        )
        t.expect(
            restoredTerminals.allSatisfy { $0.handSetTags == ["uitest-retagged"] },
            desc: "and keeps the tags given to them since (\(restoredTerminals.map(\.handSetTags)))"
        )

        t.closeAllWindows()
        t.pump(0.5)
        daemon.terminate()
        daemon.waitUntilExit()
        let replacement = Process()
        replacement.executableURL = daemon.executableURL
        replacement.arguments = daemon.arguments
        replacement.environment = daemon.environment
        do {
            try replacement.run()
        } catch {
            t.expect(false, desc: "a replacement daemon starts on the same socket (\(error))")
            return
        }
        defer {
            t.closeAllWindows()
            if replacement.isRunning { replacement.terminate() }
            replacement.waitUntilExit()
        }
        t.expect(
            t.wait(until: { fileManager.fileExists(atPath: socketPath) }, timeout: 20),
            desc: "the replacement daemon opens the original socket"
        )
        guard let survivor = openSwiftShellWindow(), let survivorSurface = survivor.focusedSurfaceForTesting else {
            t.expect(false, desc: "an existing local shell is available during replacement")
            return
        }
        survivorSurface.send("UBQ_RESTART_MARK=kept; echo restart-ready\n")
        t.expect(t.wait(until: { bufferHolds("restart-ready", in: survivorSurface) }, timeout: 10), desc: "the local shell is ready")
        var didReplace: Bool?
        Task { @MainActor in didReplace = await TerminalWindows.replaceWindows(with: groups) }
        t.expect(t.wait(until: { didReplace != nil }, timeout: 40), desc: "a stale daemon reference finishes with a decision")
        t.expect(didReplace == false, desc: "ended pane sessions cannot complete the saved arrangement")
        let savedWorkspaceID = SavedTerminalPresentation.decoded(sharedTab.paneLayout ?? "")?.liveWorkspace?.workspaceID ?? 0
        let oldDaemonID = savedIdentities.first ?? 0
        let afterReplacement = TerminalWindows.keptBySession()
        let restoredWorkspaces = afterReplacement.compactMap { $0 as? TerminalWindowController }
            .filter { controller in
                guard let surface = controller.remoteSurface else { return false }
                return savedWorkspaceID != 0 && surface.drive.remoteWorkspaceID == savedWorkspaceID
                    && surface.drive.remoteDaemonInstanceID != 0 && surface.drive.remoteDaemonInstanceID != oldDaemonID
                    && surface.drive.remoteRestoredFromDaemonInstanceID == oldDaemonID
                    && surface.remoteSessionID != 0 && surface.drive.remoteState == .Connected
            }
        // A Workspace answer may recreate the exact saved workspace from its
        // record on the successor daemon; an ended session answer cannot.
        t.expect(
            afterReplacement.count == 2 && restoredWorkspaces.count == 1,
            desc: "only the recorded workspace returns beside the original window"
        )
        if let restoredSurface = restoredWorkspaces.first?.remoteSurface {
            restoredSurface.send("echo \"fresh-\(marker):[$UBQ_QUIT_MARK]\"\n")
            t.expect(
                t.wait(until: { bufferHolds("fresh-\(marker):[]", in: restoredSurface) }, timeout: 10),
                desc: "the restored workspace has a fresh shell after its daemon restarted"
            )
        }
        let replacementIdentities = Set(afterReplacement.map(ObjectIdentifier.init))
        t.expect(!survivor.isClosedForTesting, desc: "failed replacement leaves the previous local window open")
        survivorSurface.send("echo survived-$UBQ_RESTART_MARK\n")
        t.expect(
            t.wait(until: { bufferHolds("survived-kept", in: survivorSurface) }, timeout: 10),
            desc: "the previous window still owns its original live process"
        )
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        t.pump(0.2)
        let localRecipes = TerminalWindows.capturedGroupsForSavedWorkspace()
        var didRestoreMixed: Bool?
        Task { @MainActor in didRestoreMixed = await TerminalWindows.restoreArrangementGroups(localRecipes + groups) }
        t.expect(t.wait(until: { didRestoreMixed != nil }, timeout: 40), desc: "an additive restore resolves unavailable live references")
        t.expect(didRestoreMixed == false, desc: "an unavailable daemon session is not reported as restored")
        let afterMixed = TerminalWindows.keptBySession()
        t.expect(
            afterMixed.count == afterReplacement.count + 1 && !survivor.isClosedForTesting
                && replacementIdentities.isSubset(of: Set(afterMixed.map(ObjectIdentifier.init)))
                && afterMixed.filter {
                    !replacementIdentities.contains(ObjectIdentifier($0)) && ($0 as? TerminalWindowController)?.remoteSurface == nil
                }
                .count == 1,
            desc: "partial failure adds only the local recipe and keeps the available windows"
        )
        guard let parent = NSApp.windows.first(where: { $0.attachedSheet != nil }), let sheet = parent.attachedSheet else {
            t.expect(false, desc: "the unavailable session offers an explicit fresh launch")
            return
        }
        parent.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        t.expect(
            t.wait(until: { TerminalWindows.keptBySession().count == afterMixed.count + 1 }, timeout: 10),
            desc: "only choosing Open New Terminal launches a fresh shell"
        )
    }

    /// A foreground tmux client keeps its local PTY through update capture.
    @MainActor
    private static func checkUpdateAdoptsPlainTmux(_ t: UBUITestContext) {
        t.closeAllWindows()
        guard let tmux = TerminalWindowController.tmuxExecutable else {
            t.refuse("The tmux update check needs tmux on this Mac.")
            return
        }
        guard let bundled = t.placeBundledHost() else { return }
        defer { bundled.remove() }
        let files = FileManager.default
        let root = "/tmp/ubq-update-tmux-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try files.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "the private update home is made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        let previousTmuxDirectory = ProcessInfo.processInfo.environment["TMUX_TMPDIR"]
        setenv("UBIQUITTY_HOME", home, 1)
        setenv("TMUX_TMPDIR", root, 1)
        defer {
            t.closeAllWindows()
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            if let previousTmuxDirectory { setenv("TMUX_TMPDIR", previousTmuxDirectory, 1) } else { unsetenv("TMUX_TMPDIR") }
            try? files.removeItem(atPath: root)
        }
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: bundled.path)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment
        do { try daemon.run() } catch {
            t.expect(false, desc: "the private update host starts (\(error))")
            return
        }
        defer {
            t.closeAllWindows()
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        let socket = String(Ubiquitty.Session.localDaemonSocketPath(std.string(bundled.path)))
        guard t.wait(until: { files.fileExists(atPath: socket) }, timeout: 20) else {
            t.expect(false, desc: "the private update host is ready")
            return
        }
        let tmuxSocket = "ubq-update-" + String(UUID().uuidString.prefix(8))
        defer { t.killTmuxServer(onSocket: tmuxSocket) }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: tmux)
        server.arguments = ["-L", tmuxSocket, "-f", "/dev/null", "new-session", "-d", "-s", "update", "/bin/sh"]
        server.environment = ProcessInfo.processInfo.environment
        do {
            try server.run()
            server.waitUntilExit()
        } catch {
            t.expect(false, desc: "the private tmux server starts (\(error))")
            return
        }
        guard server.terminationStatus == 0,
            let shell = TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .endsWithChild),
            let pane = shell.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "the local shell and private tmux server are ready")
            return
        }
        pane.send("\(tmux) -L \(tmuxSocket) a -t update\n")
        guard t.wait(until: { shell.tmuxPaneContext() == .rawAttach }, timeout: 10) else {
            t.expect(false, desc: "the local tab is attached to plain tmux")
            return
        }
        t.expect(shell.tabCaptureFacts.isShareableLocalSession, desc: "the foreground tmux tab is shareable at update capture")
        let capture = TerminalWindows.prepareUpdateCapture()
        t.expect(capture.localPanes.count == 1, desc: "the update finds the local tmux pane")
        t.expect(capture.adoptedLocalPaneCount == 1, desc: "the update adopts the foreground tmux pane")
        var didSettle: Bool?
        Task { @MainActor in didSettle = await TerminalWindows.settledUpdateAdoptions(capture) != nil }
        t.expect(
            t.wait(until: { didSettle != nil }, timeout: 12) && didSettle == true,
            desc: "the adopted tmux pane attaches to the private host"
        )
        var didReclaim = false
        Task { @MainActor in
            await TerminalWindows.reclaimUpdateAdoptions(capture)
            didReclaim = true
        }
        t.expect(t.wait(until: { didReclaim }, timeout: 12), desc: "the tmux pane returns to its local PTY")
        t.expect(!pane.drive.isSharedIntoLocalDaemon, desc: "the same pane is local after rollback")
    }

    /// A failed pre-install transfer returns the app's original local shell
    /// before a deferred installation or a cancelled explicit restart.
    @MainActor
    private static func checkUpdateChoiceReturnsTheShell(_ t: UBUITestContext, acceptedRisk: Bool) {
        t.closeAllWindows()
        guard let updater = (NSApp.delegate as? UBAppDelegate)?.updater else {
            t.refuse("This build has no updater.")
            return
        }
        guard let bundled = t.placeBundledHost() else { return }
        defer { bundled.remove() }
        let files = FileManager.default
        let root = "/tmp/ubq-update-choice-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do { try files.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch {
            t.expect(false, desc: "the isolated update home is made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            t.closeAllWindows()
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? files.removeItem(atPath: root)
        }
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: bundled.path)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do { try daemon.run() } catch {
            t.expect(false, desc: "the isolated host starts (\(error))")
            return
        }
        defer {
            t.closeAllWindows()
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        let socket = String(Ubiquitty.Session.localDaemonSocketPath(std.string(bundled.path)))
        guard t.wait(until: { files.fileExists(atPath: socket) }, timeout: 20),
            let shell = openSwiftShellWindow(), let pane = shell.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "the isolated host and local shell are ready")
            return
        }
        let marker = "update-choice-" + String(UUID().uuidString.prefix(8))
        pane.send("printf '\(marker)\\n'\n")
        t.expect(t.wait(until: { bufferHolds(marker, in: pane) }, timeout: 10), desc: "the local shell runs before the update")

        var questionCount = 0
        let answer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow != nil else { return }
                questionCount += 1
                t.expect(
                    !NSApp.windows.contains { $0.identifier?.rawValue == "updatePreparationProgress" && $0.isVisible },
                    desc: "the progress dialog closes before the restart choice"
                )
                NSApp.stopModal(withCode: acceptedRisk ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            }
        }
        RunLoop.main.add(answer, forMode: .modalPanel)
        defer { answer.invalidate() }
        var isInstallAuthorized: Bool?
        Task { @MainActor in isInstallAuthorized = await updater.prepareUpdateRelaunchForTesting() }
        t.expect(t.wait(until: { isInstallAuthorized != nil }, timeout: 40), desc: "a refused update asks for a choice")
        t.expect(updater.didShowUpdatePreparationForTesting, desc: "Install shows progress while the sessions are prepared")
        t.expect(isInstallAuthorized == acceptedRisk, desc: "the update follows the selected restart choice")
        t.expect(questionCount == 1, desc: "the update asks once before a risky restart (\(questionCount))")
        if acceptedRisk {
            t.expect(updater.mayTerminateAfterUpdatePreparation, desc: "Restart Anyway authorizes only the prepared quit")
            var didAbort = false
            Task { @MainActor in
                await updater.cancelPreparedUpdateForTesting()
                didAbort = true
            }
            t.expect(t.wait(until: { didAbort }, timeout: 20), desc: "a cancelled install restores the app's owners")
        }
        t.expect(
            t.wait(until: { !pane.drive.isSharedIntoLocalDaemon }, timeout: 10),
            desc: "the adopted shell is local again before Not Now returns"
        )
        t.expect(!updater.isRelaunchingForUpdate, desc: "Not Now leaves the application open")
        pane.send("printf 'alive-\(marker)\\n'\n")
        t.expect(t.wait(until: { bufferHolds("alive-\(marker)", in: pane) }, timeout: 10), desc: "the same local shell remains alive")
    }

    private enum UpdateRelaunchPath {
        case quitCapture
        case verifiedCandidate
    }

    /// Sparkle's Install and Relaunch with session persistence off, driven
    /// short of the relaunch: the notice through the updater's own delegate,
    /// the quit's reply and capture, every window closed as the exit closes
    /// them, then the two launches after it.
    ///
    /// The quit that cannot keep a job runs first: with no daemon that can
    /// start, the confirmation asks, and Cancel refuses the quit request.
    @MainActor
    private static func checkUpdateRelaunchKeepsTheArrangement(_ t: UBUITestContext, path: UpdateRelaunchPath = .quitCapture) {
        t.closeAllWindows()
        guard let delegate = NSApp.delegate as? UBAppDelegate else {
            t.expect(false, desc: "the application delegate is reachable")
            return
        }
        guard let updater = delegate.updater else {
            t.refuse("This build has no updater, so nothing relaunches it into an update; fetch Sparkle and build again.")
            return
        }
        guard let bundled = t.placeBundledHost() else { return }
        defer { bundled.remove() }
        let host = bundled.path
        let files = FileManager.default
        let root = "/tmp/ubq-update-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        // Past the 103 bytes a Unix socket's path may take: no daemon can
        // listen under it, so nothing can keep a shell there.
        let homeWithoutDaemon = root + "/" + String(repeating: "h", count: 110)
        do {
            for directory in [home, homeWithoutDaemon] {
                try files.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            t.expect(false, desc: "the isolated homes are made (\(error))")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        let savedConfiguration = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            t.closeAllWindows()
            t.restoreConfiguration(savedConfiguration)
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? files.removeItem(atPath: root)
        }
        t.configureAppending("[experimental]\nsession_persistence = false\n")

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: host)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do {
            try daemon.run()
        } catch {
            t.expect(false, desc: "the daemon started (\(error))")
            return
        }
        defer {
            // The windows first: a client still attached when its daemon goes
            // would redial, and its bridge would start another daemon here.
            t.closeAllWindows()
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        let socketPath = String(Ubiquitty.Session.localDaemonSocketPath(std.string(host)))
        guard !socketPath.isEmpty, t.wait(until: { files.fileExists(atPath: socketPath) }, timeout: 20) else {
            t.expect(false, desc: "the daemon opened the socket a quit looks for (\(socketPath))")
            return
        }
        let socketName = URL(fileURLWithPath: socketPath).lastPathComponent
        let localBridge = String(
            String(host.withCxxStringView { Ubiquitty.Transport.shellSingleQuote($0) })
                .withCxxStringView { Ubiquitty.Session.localBridgeCommand($0) }
        )
        let localHost = String(cString: Ubiquitty.Session.localHostLabel)
        func openSyncWindow(named workspace: String) -> TerminalWindowController? {
            TerminalWindowController.spawnRemoteWindow(
                shellCommand: localBridge,
                hostLabel: localHost,
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: workspace,
                hostKey: "",
                daemonSocketName: socketName
            )
        }

        let marker = String(UUID().uuidString.prefix(8))
        guard let backLone = openSwiftShellWindow(), let backSplit = openSwiftShellWindow(),
            let backLoneWindow = backLone.window, let backSplitWindow = backSplit.window,
            let backLonePane = backLone.focusedSurfaceForTesting, let splitLeft = backSplit.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "the back window's two local tabs open")
            return
        }
        backSplit.splitRight(nil)
        t.pump(0.3)
        guard let splitRight = backSplit.focusedSurfaceForTesting, splitRight !== splitLeft else {
            t.expect(false, desc: "the split focuses its new right pane")
            return
        }
        guard let middleSync = openSyncWindow(named: "uitest-update-middle-\(marker)"), let middleWindow = middleSync.window,
            let middlePane = middleSync.remoteSurface
        else {
            t.expect(false, desc: "the middle Sync window opens")
            return
        }
        guard let frontJob = openSwiftShellWindow(), let frontJobWindow = frontJob.window, let jobPane = frontJob.focusedSurfaceForTesting,
            let frontSync = openSyncWindow(named: "uitest-update-front-\(marker)"), let frontSyncWindow = frontSync.window,
            let frontSyncPane = frontSync.remoteSurface
        else {
            t.expect(false, desc: "the front window's local tab and Sync tab open")
            return
        }
        guard
            t.wait(
                until: { [middlePane, frontSyncPane].allSatisfy { $0.drive.remoteState == .Connected && $0.remoteSessionID != 0 } },
                timeout: 20
            )
        else {
            t.expect(
                false,
                desc: "both Sync windows reach the daemon (\(middlePane.remoteFailureDetail) \(frontSyncPane.remoteFailureDetail))"
            )
            return
        }
        // Each shell is marked while its window stands alone, since a tab
        // behind the one selected takes no typing.
        let shells: [(name: String, pane: TerminalSurface)] = [
            ("back-lone", backLonePane), ("split-left", splitLeft), ("split-right", splitRight), ("middle-sync", middlePane),
            ("front-sync", frontSyncPane),
        ]
        for (name, pane) in shells {
            pane.send("UBQ_UPDATE_MARK=\(name)-\(marker); echo \"at:[$UBQ_UPDATE_MARK]\"\n")
        }
        jobPane.send("UBQ_UPDATE_MARK=front-job-\(marker); echo \"at:[$UBQ_UPDATE_MARK]\"; awk '{ print \"job-said:\" $0; fflush() }'\n")
        t.expect(
            t.wait(
                until: {
                    (shells + [("front-job", jobPane)]).allSatisfy { bufferHolds("at:[\($0.name)-\(marker)]", in: $0.pane) }
                        && frontJob.hasRunningProcesses
                },
                timeout: 15
            ),
            desc: "every pane's own shell holds its mark, and the front tab runs its job"
        )
        backLoneWindow.addTabbedWindow(backSplitWindow, ordered: .above)
        backLoneWindow.tabGroup?.selectedWindow = backSplitWindow
        frontJobWindow.addTabbedWindow(frontSyncWindow, ordered: .above)
        frontJobWindow.tabGroup?.selectedWindow = frontJobWindow
        t.pump(0.3)
        backSplitWindow.setFrame(NSRect(x: 60, y: 240, width: 760, height: 470), display: false)
        middleWindow.setFrame(NSRect(x: 140, y: 170, width: 640, height: 400), display: false)
        frontJobWindow.setFrame(NSRect(x: 220, y: 100, width: 700, height: 430), display: false)
        for window in [backSplitWindow, middleWindow, frontJobWindow] { window.orderFront(nil) }
        t.pump(0.4)

        let backFrame = backSplitWindow.frame
        let middleFrame = middleWindow.frame
        let frontFrame = frontJobWindow.frame
        let middleSession = middlePane.remoteSessionID
        let frontSyncSession = frontSyncPane.remoteSessionID
        let localPanes = [backLonePane, splitLeft, splitRight, jobPane]

        if path == .verifiedCandidate {
            let environment = ProcessInfo.processInfo.environment
            guard let archive = environment["UBIQUITTY_UI_TEST_UPDATE_ARCHIVE"],
                let build = environment["UBIQUITTY_UI_TEST_UPDATE_BUILD"],
                let version = environment["UBIQUITTY_UI_TEST_UPDATE_VERSION"],
                files.isReadableFile(atPath: archive)
            else {
                t.refuse("A signed update archive, its build and its version are required for the migration rehearsal.")
                return
            }
            var questions = 0
            let answer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard NSApp.modalWindow != nil else { return }
                    questions += 1
                    NSApp.stopModal(withCode: .alertSecondButtonReturn)
                }
            }
            RunLoop.main.add(answer, forMode: .modalPanel)
            defer { answer.invalidate() }
            var isPrepared: Bool?
            Task { @MainActor in
                isPrepared = await updater.prepareUpdateRelaunchForTesting(
                    archive: URL(fileURLWithPath: archive),
                    build: build,
                    version: version
                )
            }
            t.expect(t.wait(until: { isPrepared != nil }, timeout: 90), desc: "the signed candidate preparation finishes")
            t.expect(
                isPrepared == true && questions == 0,
                desc: "every local session is retained for the verified update without a risky restart"
            )
            guard isPrepared == true else { return }
            t.expect(updater.didShowUpdatePreparationForTesting, desc: "Install shows progress during verified preparation")
            t.expect(daemon.isRunning, desc: "the predecessor retains its adoption outcomes until the app exits")
            t.expect(updater.mayTerminateAfterUpdatePreparation, desc: "confirmed host ownership authorizes the update quit")
            updater.deliverRelaunchNoticeForTesting()
            t.expect(
                delegate.applicationShouldTerminate(NSApp) == .terminateNow,
                desc: "Sparkle's actual quit commits the retained arrangement"
            )
        } else {
            // Sparkle's notice, through the delegate Sparkle calls.
            t.expect(delegate.quitReason == .Ordinary, desc: "before the notice a quit is an ordinary one")
            updater.deliverRelaunchNoticeForTesting()
            t.expect(
                updater.isRelaunchingForUpdate && delegate.quitReason == .UpdateRelaunch,
                desc: "Sparkle's relaunch notice makes the quit an update relaunch"
            )

            // No daemon can start: the update cannot keep the job, so the quit
            // asks, and Cancel refuses the updater's quit request.
            setenv("UBIQUITTY_HOME", homeWithoutDaemon, 1)
            var questions: [String] = []
            let postponed = TerminalWindows.terminationReply(for: delegate.quitReason) { alert in
                questions.append(alert.messageText)
                return .alertSecondButtonReturn
            }
            setenv("UBIQUITTY_HOME", home, 1)
            t.expect(
                postponed == .terminateCancel && questions == ["Quit Ubiquitty?"],
                desc: "with no daemon to keep the job, the update's quit asks first, and Cancel keeps the app running (\(questions))"
            )
            t.expect(!files.fileExists(atPath: homeWithoutDaemon + "/sessions.json"), desc: "the cancelled quit saved no arrangement")
            t.expect(!localPanes.contains { $0.drive.isSharedIntoLocalDaemon }, desc: "and handed no shell over")
            t.expect(delegate.quitReason == .UpdateRelaunch, desc: "the installer still waits, so the next quit is still the update's")

            // The update's quit with the daemon up: nothing to ask about, and
            // every local pane handed over.
            var asked = 0
            let reply = TerminalWindows.terminationReply(for: delegate.quitReason) { _ in
                asked += 1
                return .alertSecondButtonReturn
            }
            t.expect(reply == .terminateNow && asked == 0, desc: "the update's quit asks nothing about a job the update keeps (\(asked))")
        }
        for (index, pane) in localPanes.enumerated() {
            t.expect(pane.drive.isSharedIntoLocalDaemon, desc: "local pane \(index) handed its shell to the daemon")
        }
        guard let saved = SessionLayout.allSessions().first(where: { $0.identifier == SessionLayout.currentIdentifier }) else {
            t.expect(false, desc: "the update's quit saved the arrangement with session persistence off")
            return
        }
        t.expect(saved.keptFor == .UpdateRelaunch, desc: "the saved arrangement carries the update relaunch's mark")
        let groups = saved.groups
        t.expect(
            groups.map(\.tabs.count) == [2, 1, 2],
            desc: "three windows, back to front, keep their tabs (\(groups.map(\.tabs.count)))"
        )
        t.expect(groups.map(\.activeTab) == [1, 0, 0], desc: "each window keeps its selected tab (\(groups.map(\.activeTab)))")
        guard groups.map(\.tabs.count) == [2, 1, 2] else { return }
        t.expect(groups.map(\.frame) == [backFrame, middleFrame, frontFrame], desc: "each window keeps its frame")
        let backLoneSession = groups[0].tabs[0].sessionID
        let jobSession = groups[2].tabs[0].sessionID
        guard let split = SavedTerminalPresentation.decoded(groups[0].tabs[1].paneLayout ?? "")?.handedOverSplit,
            split.sessions.count == 2
        else {
            t.expect(false, desc: "the split tab stores both panes' sessions for the restore to regroup")
            return
        }
        t.expect(
            groups[0].tabs[1].sessionID == split.sessions[0] && backLoneSession != 0 && jobSession != 0,
            desc: "each local tab rejoins a session the daemon holds"
        )
        t.expect(
            groups[1].tabs[0].sessionID == middleSession && groups[2].tabs[1].sessionID == frontSyncSession,
            desc: "each Sync tab keeps the session it was attached to"
        )

        // The exit closes every window; the daemon keeps what it was handed.
        t.closeAllWindows()
        t.pump(0.5)
        t.expect(TerminalWindows.keptBySession().isEmpty, desc: "no terminal window is left before the relaunch")

        // The launch the update opens restores it, with persistence still off.
        guard let launch = TerminalWindows.restoreLaunchArrangement() else {
            t.expect(false, desc: "the launch the update opens restores the arrangement")
            return
        }
        var isRestored: Bool?
        Task { @MainActor in isRestored = await launch.value }
        t.expect(t.wait(until: { isRestored != nil }, timeout: 90) && isRestored == true, desc: "every saved tab opens again")
        func texts(under view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { texts(under: $0) }
        }
        // Another scenario's restore can leave a notice of its own on a
        // window, so only this restore's word on the split is asked after.
        let sheets = NSApp.windows.compactMap(\.attachedSheet).map { $0.contentView.map { texts(under: $0) } ?? [] }
        t.expect(
            !sheets.joined().contains("This split couldn’t be restored whole."),
            desc: "the restore never says the split came back short (\(sheets))"
        )
        t.expect(SessionLayout.currentLayout() == nil, desc: "the launch spent the mark, and with persistence off the arrangement with it")
        t.expect(TerminalWindows.restoreLaunchArrangement() == nil, desc: "the launch after that restores nothing")
        t.pump(0.5)

        let restored = TerminalWindows.keptBySession().compactMap { $0 as? TerminalWindowController }
        func window(showing session: UInt32) -> TerminalWindowController? {
            restored.first { $0.projectedSurfaces.contains { $0.remoteSessionID == session } }
        }
        func pane(showing session: UInt32) -> TerminalSurface? {
            restored.lazy.flatMap(\.projectedSurfaces).first { $0.remoteSessionID == session }
        }
        guard let restoredBackLone = window(showing: backLoneSession)?.window,
            let restoredSplit = window(showing: split.sessions[0]), let restoredSplitWindow = restoredSplit.window,
            let restoredMiddle = window(showing: middleSession)?.window,
            let restoredJob = window(showing: jobSession)?.window, let restoredFrontSync = window(showing: frontSyncSession)?.window
        else {
            t.expect(false, desc: "a window shows each saved session (\(restored.count) windows)")
            return
        }
        t.expect(Int(restored.count), equals: 5, desc: "five tabs come back, one window each")
        t.expect(
            restoredBackLone.tabGroup?.windows == [restoredBackLone, restoredSplitWindow]
                && restoredBackLone.tabGroup?.selectedWindow === restoredSplitWindow,
            desc: "the back window holds its two tabs in order with the split one selected"
        )
        t.expect((restoredMiddle.tabGroup?.windows.count ?? 1) == 1, desc: "the middle Sync window stands alone")
        t.expect(
            restoredJob.tabGroup?.windows == [restoredJob, restoredFrontSync] && restoredJob.tabGroup?.selectedWindow === restoredJob,
            desc: "the front window holds its local tab and its Sync tab, the local one selected"
        )
        let stack = NSApp.orderedWindows
        let positions = [restoredJob, restoredMiddle, restoredSplitWindow].map { shown in stack.firstIndex { $0 === shown } ?? Int.max }
        t.expect(
            positions == positions.sorted() && !positions.contains(Int.max),
            desc: "the windows stand front to back as they did (\(positions))"
        )
        for (restoredWindow, frame) in [(restoredSplitWindow, backFrame), (restoredMiddle, middleFrame), (restoredJob, frontFrame)] {
            if WindowContainment.isOffscreen {
                t.expect(
                    restoredWindow.frame.size == frame.size && restoredWindow.frame.minY == frame.minY,
                    desc: "a contained window keeps its size and vertical place (\(restoredWindow.frame) vs \(frame))"
                )
            } else {
                t.expect(restoredWindow.frame == frame, desc: "a window reopens at its frame (\(restoredWindow.frame) vs \(frame))")
            }
        }

        // The split: both panes, side by side in their order, the right one
        // focused.
        t.expect(
            Set(restoredSplit.projectedSurfaces.map(\.remoteSessionID)) == Set(split.sessions),
            desc: "the split window shows both of its panes (\(restoredSplit.projectedSurfaces.map(\.remoteSessionID)))"
        )
        func firstSplit(under view: NSView) -> NSSplitView? {
            if let found = view as? NSSplitView { return found }
            return view.subviews.lazy.compactMap { firstSplit(under: $0) }.first
        }
        if let content = restoredSplitWindow.contentView, let divider = firstSplit(under: content), divider.arrangedSubviews.count == 2 {
            t.expect(divider.isVertical, desc: "the panes stand side by side")
            t.expect(
                divider.arrangedSubviews.map { terminalSurface(under: $0)?.remoteSessionID ?? 0 } == split.sessions,
                desc: "the left pane is the left shell's and the right pane the right one's"
            )
        } else {
            t.expect(false, desc: "the restored split window shows a divider between two panes")
        }
        t.expect(
            restoredSplit.hostedFocusedPaneForTesting?.remoteSessionID == split.sessions[1],
            desc: "the right pane is focused, as it was"
        )

        // Each pane answers from its own shell, and the job is still running.
        let restoredShells: [(name: String, session: UInt32)] = [
            ("back-lone", backLoneSession), ("split-left", split.sessions[0]), ("split-right", split.sessions[1]),
            ("middle-sync", middleSession), ("front-sync", frontSyncSession),
        ]
        // A tab behind the one selected takes no typing, so each pane's tab
        // is brought forward before its shell is asked.
        func bringForward(_ shown: TerminalSurface) {
            if let window = shown.window, let group = window.tabGroup, group.selectedWindow !== window {
                group.selectedWindow = window
                t.pump(0.3)
            }
        }
        for (name, session) in restoredShells {
            guard let shell = pane(showing: session) else {
                t.expect(false, desc: "the \(name) pane is shown")
                continue
            }
            bringForward(shell)
            _ = t.wait(until: { shell.drive.remoteState == .Connected }, timeout: 20)
            shell.send("echo \"back:[$UBQ_UPDATE_MARK]\"\n")
            t.expect(
                t.wait(until: { bufferHolds("back:[\(name)-\(marker)]", in: shell) }, timeout: 15),
                desc: "the \(name) pane answers from its own shell"
            )
        }
        if let job = pane(showing: jobSession) {
            bringForward(job)
            job.send("ping-\(marker)\n")
            t.expect(
                t.wait(until: { bufferHolds("job-said:ping-\(marker)", in: job) }, timeout: 15),
                desc: "the front tab's job is still running"
            )
        } else {
            t.expect(false, desc: "the front tab's job is shown")
        }
    }
}
