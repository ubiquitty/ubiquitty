// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// SessionPlumbingScenarios.swift — what the Swift shell does between a session
// and the window showing it: the inspector hearing the session's events as
// they happen, a reload reaching the process-wide search normalizer, and a
// tmux window's panes released when the reader closes it or rebound to a new
// model when the pane's model changes.
//
// The tmux cases bind panes to local sessions' models rather than to a tmux
// server's. The binding takes a terminal and a lock and nothing else, so a
// local window's pair stands in for a session pane's, and the cases run
// without a server and name exactly the model each pane should be reading.

enum SessionPlumbingScenarios {
    static func register() {
        UBUITestRegister("swift_shell_native_inspector_follows_session_events") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { inspectorFollowsSessionEvents(t) }
        }
        UBUITestRegister("swift_shell_a_reload_sets_the_search_normalizer") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { reloadSetsTheSearchNormalizer(t) }
        }
        UBUITestRegister("swift_shell_its_own_settings_write_reloads_nothing") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { ownSettingsWriteReloadsNothing(t) }
        }
        UBUITestRegister("swift_tmux_a_closed_window_releases_its_panes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { closedWindowReleasesItsPanes(t) }
        }
        UBUITestRegister("swift_tmux_a_rebound_pane_gets_a_new_surface") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { reboundPaneGetsANewSurface(t) }
        }
    }

    /// A window running a shell that has printed `marker`, for a pane to adopt.
    @MainActor
    private static func owner(_ t: UBUITestContext, printing marker: String) -> (TerminalWindowController, TerminalSurface)? {
        guard
            let controller = TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild)
        else {
            t.expect(false, desc: "a Swift-shell window opens")
            return nil
        }
        t.pump(0.3)
        guard let surface = controller.focusedSurfaceForTesting else {
            t.expect(false, desc: "the window has a pane")
            controller.shellCloseWindow()
            return nil
        }
        // Assembled, so the echoed command line does not match before it runs.
        let head = String(marker.prefix(marker.count / 2))
        let tail = String(marker.dropFirst(marker.count / 2))
        surface.transmitAsUserInputForTesting("k=\(tail); echo \"\(head)${k}\"\r")
        t.expect(
            t.wait(until: { surface.searchScrollbackAndWait(marker).totalMatches > 0 }, timeout: 8),
            desc: "the owner printed \(marker)"
        )
        return (controller, surface)
    }

    /// The model and lock a pane bound to `surface` adopts.
    @MainActor
    private static func adoption(of surface: TerminalSurface) -> (terminal: UnsafeMutableRawPointer, lockAddress: UInt)? {
        guard let terminal = surface.drive.borrowTerminal() else { return nil }
        return (unsafeBitCast(terminal, to: UnsafeMutableRawPointer.self), surface.drive.modelLockAddress())
    }

    /// Binds `paneID`, as a pane of `session`, in `host` to `surface`'s model.
    @MainActor
    @discardableResult
    private static func bind(
        _ paneID: Int32,
        of session: UInt,
        in host: TerminalWindowController,
        to surface: TerminalSurface
    ) -> Bool {
        guard let adopted = adoption(of: surface) else { return false }
        return host.bindTmuxPane(
            paneID,
            terminal: adopted.terminal,
            lockAddress: adopted.lockAddress,
            rows: 24,
            columns: 80,
            clientAddress: 0,
            streamAddress: 0,
            sessionAddress: session
        )
    }

    // The session's own events drive the inspector: a directory report, a job
    // starting and ending, a resize. Nothing here asks the inspector to
    // refresh, so a value that arrives arrived by push.
    @MainActor
    private static func inspectorFollowsSessionEvents(_ t: UBUITestContext) {
        guard let (controller, surface) = owner(t, printing: "inspector-ready") else { return }
        defer { controller.shellCloseWindow() }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.toggleNativeInspector(nil)
        t.pump(0.4)
        guard let model = controller.inspectorModel else {
            t.expect(false, desc: "the native inspector opened")
            return
        }
        t.expect(model.columns > 0 && model.rows > 0, desc: "the inspector opened on the pane's grid")

        let directory = "/tmp/ubiquitty-native-inspector-event"
        surface.transmitAsUserInputForTesting("printf '\\033]7;file://localhost\(directory)\\007'\r")
        t.expect(
            t.wait(until: { model.directory == directory }, timeout: 3),
            desc: "a reported directory reaches the inspector without a refresh (it shows '\(model.directory)')"
        )
        surface.transmitAsUserInputForTesting("sleep 2\r")
        t.expect(
            t.wait(until: { model.processes.contains(where: { $0.name == "sleep" }) }, timeout: 3),
            desc: "a job taking the terminal reaches the inspector's process list"
        )
        t.expect(
            t.wait(until: { !model.processes.contains(where: { $0.name == "sleep" }) }, timeout: 5),
            desc: "and leaves it when the job ends"
        )
        let columns = model.columns == 83 ? 84 : 83
        controller.resizeWindow(toColumns: columns, rows: 21)
        t.expect(
            t.wait(until: { model.columns == columns && model.rows == 21 }, timeout: 3),
            desc: "a resize reaches the inspector's grid (it shows \(model.columns)x\(model.rows))"
        )
        controller.toggleNativeInspector(nil)
        t.pump(0.3)
    }

    // A reload changes compatibility matching; canonical equivalence remains
    // part of search even when no normalization form is configured.
    @MainActor
    private static func reloadSetsTheSearchNormalizer(_ t: UBUITestContext) {
        let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            t.restoreConfiguration(saved)
            TerminalWindowController.applyTerminalPreferencesToOpenWindows()
        }
        guard let (controller, surface) = owner(t, printing: "normalizer-ready") else { return }
        defer { controller.shellCloseWindow() }
        // Octal escapes keep both needles out of the echoed command.
        surface.transmitAsUserInputForTesting("printf 'caf\\145\\314\\201\\nreload-\\357\\254\\201xture\\n'\r")
        let precomposed = "caf\u{E9}"
        let compatibilityNeedle = "reload-fixture"

        t.configureAppending("[unicode]\nnormalization = \"none\"\n")
        TerminalWindowController.applyTerminalPreferencesToOpenWindows()
        t.expect(
            Ubiquitty.Screen.ScrollSearch.normalizationForm() == Ubiquitty.Unicode.NormalizationForm.None,
            desc: "a reload naming no form preserves the default search policy"
        )
        t.expect(
            t.wait(until: { surface.searchScrollbackAndWait(precomposed).totalMatches > 0 }, timeout: 3),
            desc: "and default search finds canonically equivalent output"
        )
        t.expect(
            t.wait(until: { surface.searchScrollbackAndWait("reload-\u{FB01}xture").totalMatches > 0 }, timeout: 3),
            desc: "the compatibility character has reached the pane"
        )
        t.expect(
            surface.searchScrollbackAndWait(compatibilityNeedle).totalMatches == 0,
            desc: "default search does not fold compatibility characters"
        )

        t.restoreConfiguration(saved)
        t.configureAppending("[unicode]\nnormalization = \"nfkc\"\n")
        TerminalWindowController.applyTerminalPreferencesToOpenWindows()
        t.expect(
            Ubiquitty.Screen.ScrollSearch.normalizationForm() == Ubiquitty.Unicode.NormalizationForm.NFKC,
            desc: "a reload naming nfkc sets the process-wide normalizer"
        )
        t.expect(
            t.wait(until: { surface.searchScrollbackAndWait(compatibilityNeedle).totalMatches > 0 }, timeout: 3),
            desc: "and the open window's find folds compatibility characters"
        )

        t.restoreConfiguration(saved)
        t.configureAppending("[unicode]\nnormalization = \"not-a-form\"\n")
        TerminalWindowController.applyTerminalPreferencesToOpenWindows()
        t.expect(
            Ubiquitty.Screen.ScrollSearch.normalizationForm() == Ubiquitty.Unicode.NormalizationForm.None,
            desc: "a name no form answers to falls back to none"
        )
        t.expect(
            surface.searchScrollbackAndWait(compatibilityNeedle).totalMatches == 0,
            desc: "and the same query stops folding compatibility characters after reload"
        )
    }

    // The app writing its own preferences is not a person editing them. A
    // settings row's write raises the file watcher's change event just as an
    // editor's save does, and the file then holds exactly the bytes the write
    // recorded in Core's self-write guard, so the event reloads nothing. What
    // says no reload ran is the configuration epoch, which every configure
    // moves and a reload would move again. A burst of writes that lands
    // before the watcher's handler runs raises one event for all of them; it
    // must reload nothing and must leave the next save unswallowed. An
    // editor's save reloads, and that is what says the watcher was listening
    // at all.
    @MainActor
    private static func ownSettingsWriteReloadsNothing(_ t: UBUITestContext) {
        guard let home = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] else {
            t.expect(false, desc: "the suite sandboxes the preferences directory")
            return
        }
        let savedBounce = settingBool(.MouseScrollBounce)
        defer {
            _ = setSetting(.MouseScrollBounce, bool: savedBounce)
            t.pump(0.3)
        }
        // Long enough for the watcher's handler to run for every write before it.
        let watcherTurn = 0.5

        // A settings row's write configures Core once; a reload of the file it
        // left would configure it again, so an epoch that holds after the
        // watcher's turn is a write that reloaded nothing.
        _ = setSetting(.MouseScrollBounce, bool: !savedBounce)
        let afterWrite = Ubiquitty.Preferences.configurationEpoch()
        t.pump(watcherTurn)
        t.expect(Ubiquitty.Preferences.configurationEpoch() == afterWrite, desc: "a settings row's write reloaded nothing")

        // Then a burst of them with no turn of the loop between.
        _ = setSetting(.MouseScrollBounce, bool: savedBounce)
        _ = setSetting(.MouseScrollBounce, bool: !savedBounce)
        _ = setSetting(.MouseScrollBounce, bool: savedBounce)
        let afterBurst = Ubiquitty.Preferences.configurationEpoch()
        t.pump(watcherTurn)
        t.expect(Ubiquitty.Preferences.configurationEpoch() == afterBurst, desc: "nor did a burst of them")
        t.expect(
            Ubiquitty.Preferences.selfWriteGuard().pointee.hasOwnWrite(),
            desc: "and the guard holds the burst's last bytes as the app's"
        )

        // An editor's save reloads: the live value takes the file's.
        _ = Ubiquitty.Preferences.writeKeyValue(
            std.string(home + "/ubiquitty/config.toml"),
            std.string("mouse"),
            std.string("scroll_bounce"),
            std.string(savedBounce ? "false" : "true")
        )
        t.expect(
            t.wait(
                until: {
                    settingBool(.MouseScrollBounce) == !savedBounce
                        && Ubiquitty.Preferences.configurationEpoch() > afterBurst
                },
                timeout: 3
            ),
            desc: "an editor's save after the burst reloads the file, so the watcher was listening and nothing swallowed it"
        )
    }

    // ⌘W on a tmux window is the reader's close, not tmux's, so no
    // %window-close unbinds its panes. The window releases them itself: each
    // surface stops reading the session's model, the pane registry forgets
    // the window, and a closed window refuses a late bind. A second attached
    // session numbers its panes from %0 too, and the registry holds each
    // session's window under its own key: neither session's bind takes the
    // other's routing, and neither session's unbind drops it. One model per
    // bound pane, as a session gives each pane its own.
    @MainActor
    private static func closedWindowReleasesItsPanes(_ t: UBUITestContext) {
        guard let (paneOwner, paneModel) = owner(t, printing: "release-owner") else { return }
        defer { paneOwner.shellCloseWindow() }
        guard let (sharedOwner, sharedModel) = owner(t, printing: "release-shared") else { return }
        defer { sharedOwner.shellCloseWindow() }
        guard let (otherOwner, otherModel) = owner(t, printing: "release-other") else { return }
        defer { otherOwner.shellCloseWindow() }
        guard let closing = TerminalWindowController.spawnTmuxHostingWindow(),
            let other = TerminalWindowController.spawnTmuxHostingWindow()
        else {
            t.expect(false, desc: "two tmux-hosting windows open")
            return
        }
        defer { other.shellCloseWindow() }
        let closingSession: UInt = 0x9101
        let otherSession: UInt = 0x9102
        let pane: Int32 = 90_101
        let shared: Int32 = 90_102
        t.expect(bind(pane, of: closingSession, in: closing, to: paneModel), desc: "the pane binds to its model")
        t.expect(bind(shared, of: closingSession, in: closing, to: sharedModel), desc: "the shared pane id binds in the closing window")
        t.expect(bind(shared, of: otherSession, in: other, to: otherModel), desc: "and in the other session's window")
        guard let adopted = closing.tmuxSurfaceForTesting(pane) else {
            t.expect(false, desc: "the bound pane has a surface")
            return
        }
        t.expect(adopted.searchScrollbackAndWait("release-owner").totalMatches > 0, desc: "the bound surface reads its model")
        t.expect(
            TerminalWindowController.repaintTmuxPane(pane, sessionAddress: closingSession),
            desc: "the registry routes the pane to its window"
        )

        // The other session's pane leaves, under the id both sessions use. It
        // takes its own registration and nothing else: a repaint for this
        // session's pane of that id still reaches this session's window.
        other.unbindTmuxPane(shared)
        t.expect(
            TerminalWindowController.repaintTmuxPane(shared, sessionAddress: closingSession),
            desc: "one session's pane leaving keeps the other session's pane of the same id registered"
        )
        t.expect(
            !TerminalWindowController.repaintTmuxPane(shared, sessionAddress: otherSession),
            desc: "and the pane that left is gone from its own session"
        )
        t.expect(bind(shared, of: otherSession, in: other, to: otherModel), desc: "the other session binds its pane again")

        closing.window?.close()
        t.pump(0.1)
        t.expect(closing.boundTmuxPaneIDs().isEmpty, desc: "a window the reader closed holds no pane")
        t.expect(
            !TerminalWindowController.repaintTmuxPane(pane, sessionAddress: closingSession),
            desc: "a repaint for its pane finds no window"
        )
        t.expect(
            adopted.searchScrollbackAndWait("release-owner").totalMatches == 0,
            desc: "the released surface no longer reads the session's model"
        )
        t.expect(!bind(pane, of: closingSession, in: closing, to: paneModel), desc: "a closed window binds nothing")
        t.expect(
            TerminalWindowController.repaintTmuxPane(shared, sessionAddress: otherSession) && other.tmuxSurfaceForTesting(shared) != nil,
            desc: "the other window's pane under the same id keeps its registration"
        )
    }

    // A pane bound again to the model it holds keeps its surface; bound to
    // another model it gets a new one, which reads only the new model, and the
    // surface that left stops reading the old.
    @MainActor
    private static func reboundPaneGetsANewSurface(_ t: UBUITestContext) {
        guard let (firstOwner, firstSurface) = owner(t, printing: "retarget-first") else { return }
        defer { firstOwner.shellCloseWindow() }
        guard let (secondOwner, secondSurface) = owner(t, printing: "retarget-second") else { return }
        defer { secondOwner.shellCloseWindow() }
        guard let host = TerminalWindowController.spawnTmuxHostingWindow() else {
            t.expect(false, desc: "a tmux-hosting window opens")
            return
        }
        defer { host.shellCloseWindow() }
        let session: UInt = 0x9103
        let pane: Int32 = 90_103
        t.expect(bind(pane, of: session, in: host, to: firstSurface), desc: "the pane binds to the first model")
        guard let before = host.tmuxSurfaceForTesting(pane) else {
            t.expect(false, desc: "the bound pane has a surface")
            return
        }
        t.expect(bind(pane, of: session, in: host, to: firstSurface), desc: "binding the same model again succeeds")
        t.expect(host.tmuxSurfaceForTesting(pane) === before, desc: "and keeps the surface a layout pass re-lists")

        t.expect(bind(pane, of: session, in: host, to: secondSurface), desc: "the pane binds to the second model")
        guard let after = host.tmuxSurfaceForTesting(pane) else {
            t.expect(false, desc: "the rebound pane has a surface")
            return
        }
        t.expect(after !== before, desc: "a retarget builds a new surface")
        t.expect(
            after.searchScrollbackAndWait("retarget-second").totalMatches > 0
                && after.searchScrollbackAndWait("retarget-first").totalMatches == 0,
            desc: "the new surface reads the new model and none of the old"
        )
        t.expect(
            before.searchScrollbackAndWait("retarget-first").totalMatches == 0,
            desc: "the surface that left stopped reading the old model"
        )
        t.expect(
            TerminalWindowController.repaintTmuxPane(pane, sessionAddress: session),
            desc: "the registry routes the pane to its window after the retarget"
        )
        host.unbindTmuxPane(pane)
    }
}
