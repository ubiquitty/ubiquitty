// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// RemoteWorkspaceScenarios.swift — a hosted workspace opened over Sync, against
// a ubiquitty-host this scenario forks with a home of its own.
//
// One claim: what the host holds is what the windows show, and what the user
// does to the windows is done on the host. The projection on attach, a split
// sent over the wire and mirrored back with a session behind the new pane, a
// tab added on the host arriving as a tab window, a pane whose shell exits
// leaving with the layout that dropped it, and closing a pane or tab while
// its siblings stay connected — each is asserted on the window, after the
// host answered.

/// Registers the hosted-workspace scenarios with the UI-test runner.
enum RemoteWorkspaceScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("remote_workspace_tabs_follow_host_order") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let windows = (0..<5).map { _ in NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false) }
                for window in windows { window.isReleasedWhenClosed = false }
                defer { for window in windows { window.close() } }
                for window in windows.dropFirst() { windows[0].addTabbedWindow(window, ordered: .above) }
                guard let group = windows[0].tabGroup else {
                    t.expect(false, desc: "AppKit creates a tab group")
                    return
                }
                TerminalWindowController.orderProjectedTabs(windows, in: group)
                t.expect(
                    group.windows.elementsEqual(windows, by: { $0 === $1 }),
                    desc: "new tabs follow host order instead of inserting second"
                )
                let desired = [windows[4], windows[1], windows[0], windows[3], windows[2]]
                TerminalWindowController.orderProjectedTabs([windows[4], windows[0], windows[2]], in: group)
                t.expect(group.windows.elementsEqual(desired, by: { $0 === $1 }), desc: "reordered remote tabs preserve foreign slots")
                TerminalWindowController.orderProjectedTabs([windows[4], windows[0], windows[2]], in: group)
                t.expect(group.windows.elementsEqual(desired, by: { $0 === $1 }), desc: "repeated projection leaves the order unchanged")

                let pair = (0..<2).map { _ in NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false) }
                for window in pair { window.isReleasedWhenClosed = false }
                defer { for window in pair { window.close() } }
                pair[0].addTabbedWindow(pair[1], ordered: .above)
                guard let pairGroup = pair[0].tabGroup else {
                    t.expect(false, desc: "AppKit creates a two-tab group")
                    return
                }
                pairGroup.selectedWindow = pair[1]
                TerminalWindowController.orderProjectedTabs([pair[1], pair[0]], in: pairGroup)
                t.expect(
                    pairGroup.windows.elementsEqual([pair[1], pair[0]], by: { $0 === $1 }),
                    desc: "a two-tab group can move its projected pills"
                )
                t.expect(pairGroup.selectedWindow === pair[1], desc: "reordering two tabs keeps the selected window")
            }
        }

        UBUITestRegister("remote_connection_status_is_visible_without_directory_key") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                guard
                    let controller = TerminalWindowController.spawnRemoteWindow(
                        shellCommand: "/bin/sleep 30",
                        hostLabel: "test host",
                        quicHost: "",
                        quicBootstrapCommand: "",
                        deploySSHHost: "",
                        deployBinaries: [:],
                        reattachSessionID: 0
                    ), let surface = controller.remoteSurface
                else {
                    t.expect(false, desc: "an isolated silent transport opens a status-bearing window")
                    return
                }
                defer { controller.shellCloseWindow() }
                let localWindowItem = NSMenuItem(
                    title: "New Local Window",
                    action: #selector(TerminalWindowController.newWindow(_:)),
                    keyEquivalent: "n"
                )
                let remoteWindowItem = NSMenuItem(
                    title: "",
                    action: #selector(TerminalWindowController.newRemoteWorkspaceWindow(_:)),
                    keyEquivalent: ""
                )
                t.expect(controller.validateMenuItem(localWindowItem), desc: "New Local Window stays enabled while connecting")
                t.expect(!controller.validateMenuItem(remoteWindowItem), desc: "remote window creation waits for a connected workspace")
                t.expect(
                    remoteWindowItem.title == "New Window on test host",
                    desc: "the remote command names its configured connection before attach"
                )
                t.expect(!remoteWindowItem.isHidden, desc: "a connecting remote workspace keeps its named command visible")
                controller.window?.performClose(nil)
                guard t.wait(until: { controller.window?.attachedSheet != nil }, timeout: 3),
                    let connectingQuestion = controller.window?.attachedSheet,
                    let connectingCancel = sheetButton("Cancel", in: connectingQuestion)
                else {
                    t.expect(false, desc: "a connecting remote window offers safe local detach")
                    return
                }
                t.expect(connectingQuestion.defaultButtonCell === connectingCancel.cell, desc: "a pending connection defaults to Cancel")
                t.expect(
                    sheetButton("Close Window", in: connectingQuestion)?.isEnabled == false,
                    desc: "no destructive close is available before acknowledgement"
                )
                t.expect(
                    sheetButton("Detach from Workspace", in: connectingQuestion)?.isEnabled == true,
                    desc: "local detach remains available while connecting"
                )
                connectingCancel.performClick(nil)
                t.expect(
                    t.wait(until: { controller.window?.attachedSheet == nil }, timeout: 3),
                    desc: "Cancel leaves the connection attempt alive"
                )
                let initial = surface.subviews.compactMap { $0 as? RemoteConnectionStatusView }.first
                t.expect(
                    initial?.message.stringValue.contains("Connecting") == true,
                    desc: "initial connecting status appears without a host directory key"
                )
                controller.presentRemoteConnectionStatus(on: surface, state: .Failed, detail: "Host refused the connection")
                let failed = surface.subviews.compactMap { $0 as? RemoteConnectionStatusView }.first
                t.expect(failed?.detailLabel.stringValue == "Host refused the connection", desc: "failure detail is visible and selectable")
                controller.presentRemoteConnectionStatus(on: surface, state: .Reconnecting, detail: "")
                t.expect(
                    failed?.message.stringValue.contains("Reconnecting") == true,
                    desc: "reconnect retains the terminal and updates its banner"
                )
                // The state is told to the banner here, while the transport
                // underneath stays silent. Core's link health is the one fact
                // that keeps a banner on a connected pane: a link it reports
                // as healthy takes the banner down, one it reports as quiet
                // keeps it, saying only that.
                controller.presentRemoteConnectionStatus(on: surface, state: .Connected, detail: "")
                let link = surface.drive.paneLinkIndicatorText
                let connected = surface.subviews.compactMap { $0 as? RemoteConnectionStatusView }.first
                if link.isEmpty {
                    t.expect(connected == nil, desc: "acknowledged connection on a healthy link removes the banner")
                } else {
                    t.expect(
                        connected?.message.stringValue.hasPrefix("Connected") == true && connected?.detailLabel.stringValue == link,
                        desc:
                            "acknowledged connection on a quiet link says only the link's health ('\(link)'; "
                            + "banner '\(connected?.message.stringValue ?? "none")', '\(connected?.detailLabel.stringValue ?? "")')"
                    )
                }
            }
        }
        UBUITestRegister("remote_detach_answers_while_the_link_moves") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                // A transport that drops a moment after it starts: the link
                // leaves the state the question is asked in, as a link that
                // keeps reconnecting does.
                guard
                    let controller = TerminalWindowController.spawnRemoteWindow(
                        shellCommand: "/bin/sleep 1",
                        hostLabel: "cycling host",
                        quicHost: "",
                        quicBootstrapCommand: "",
                        deploySSHHost: "",
                        deployBinaries: [:],
                        reattachSessionID: 0
                    ), let surface = controller.remoteSurface
                else {
                    t.expect(false, desc: "an isolated silent transport opens a remote window")
                    return
                }
                defer {
                    if !controller.isWindowClosed { controller.shellCloseWindow() }
                }
                controller.window?.performClose(nil)
                guard t.wait(until: { controller.window?.attachedSheet != nil }, timeout: 3),
                    let question = controller.window?.attachedSheet
                else {
                    t.expect(false, desc: "closing a window whose link is not up asks what to do")
                    return
                }
                // Each move of the link is reported; none of them is an answer,
                // and the question waits for one.
                let askedIn = surface.drive.remoteState
                t.expect(
                    t.wait(until: { surface.drive.remoteState != askedIn }, timeout: 8),
                    desc: "the link moves while the question is up (\(askedIn) → \(surface.drive.remoteState))"
                )
                for _ in 0..<3 {
                    controller.remoteSessionDidChange(on: surface)
                    t.pump(0.1)
                }
                t.expect(
                    controller.window?.attachedSheet === question,
                    desc: "the question stays up while the link moves under it (\(surface.drive.remoteState))"
                )
                t.expect(
                    sheetButton("Close Window", in: question)?.isEnabled == false,
                    desc: "closing on the host waits for a link that is up"
                )
                guard let detach = sheetButton("Detach from Workspace", in: question), detach.isEnabled else {
                    t.expect(false, desc: "detaching stays available while the link is down")
                    return
                }
                detach.performClick(nil)
                t.expect(
                    t.wait(until: { controller.isWindowClosed }, timeout: 3),
                    desc: "Detach closes the window though the link never came up"
                )
            }
        }
        UBUITestRegister("remote_quic_bootstrap_cancellation_is_prompt") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                let start = Date()
                guard
                    let controller = TerminalWindowController.spawnRemoteWindow(
                        shellCommand: "/bin/sleep 30",
                        hostLabel: "bootstrap cancellation",
                        quicHost: "127.0.0.1",
                        quicBootstrapCommand: "exec /bin/sleep 30",
                        deploySSHHost: "",
                        deployBinaries: [:],
                        reattachSessionID: 0
                    ), let surface = controller.remoteSurface
                else {
                    t.expect(false, desc: "a pending QUIC bootstrap opens a window")
                    return
                }
                defer { controller.shellCloseWindow() }
                t.expect(Date().timeIntervalSince(start) < 2, desc: "bootstrap does not block the owning event loop")
                _ = t.wait(until: { Date().timeIntervalSince(start) > 0.2 }, timeout: 1)
                let closing = Date()
                surface.drive.close()
                t.expect(
                    Date().timeIntervalSince(closing) < 1,
                    desc: "cancellation wakes the bootstrap worker without waiting for its deadline"
                )
            }
        }
        UBUITestRegister("remote_workspace_projections_are_scoped_to_daemon") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                verifyDaemonProjectionIsolation(t)
            }
        }
        UBUITestRegister("remote_workspace_uses_quic_from_swift") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                run(t, usesQUIC: true)
            }
        }
        UBUITestRegister("remote_workspace_transfers_panes_tabs_and_windows") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, transfersOnly: true) }
        }
        UBUITestRegister("remote_workspace_transfers_survive_a_slow_link") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, transfersOnly: true, linkDelayMilliseconds: 20...120) }
        }
        UBUITestRegister("remote_workspace_opens_as_windows_tabs_and_panes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                run(t)
            }
        }
        UBUITestRegister("remote_workspace_late_tab_keeps_its_process_title") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, processAttributionOnly: true) }
        }
        UBUITestRegister("remote_workspace_hidden_pane_holds_its_process_state_until_asked") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, processStateHoldOnly: true) }
        }
        UBUITestRegister("remote_workspace_tab_pills_follow_host_reorder") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, processAttributionOnly: true, reorderHostTabs: true) }
        }
        UBUITestRegister("remote_workspace_detached_tab_keeps_its_titlebar_band") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                run(t, processAttributionOnly: true, reorderHostTabs: true, detachHostTab: true)
            }
        }
        UBUITestRegister("remote_workspace_progress_follows_hosted_pane_focus") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, progressOnly: true) }
        }
        UBUITestRegister("remote_workspace_title_spells_its_directory_by_the_readers_settings") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, directoryOnly: true) }
        }
        UBUITestRegister("remote_workspace_drag_snaps_to_the_focused_panes_cells") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, snapOnly: true) }
        }
        UBUITestRegister("remote_workspace_window_verbs_reach_the_focused_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, verbsOnly: true) }
        }
        UBUITestRegister("remote_workspace_zoomed_pane_keeps_its_header_and_resizes_the_host_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, zoomOnly: true) }
        }
        UBUITestRegister("remote_workspace_hidden_title_bar_moves_every_hosted_panes_top_inset") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, topInsetOnly: true) }
        }
        UBUITestRegister("remote_workspace_full_screen_settle_reaches_every_hosted_pane") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, fullScreenOnly: true) }
        }
        UBUITestRegister("input_in_doubt_notice_offers_both_answers_without_taking_the_keyboard") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyInputInDoubtNotice(t) }
        }
        UBUITestRegister("remote_workspace_pane_title_bars_follow_the_setting_on_an_open_split") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { run(t, titleBarsOnly: true) }
        }
    }

    /// Pane Title Bars, this app's own setting, turned off and on again over
    /// an open hosted split takes the headers off and puts them back in
    /// place, as it does a local window's: each pane keeps its chrome and its
    /// view, and the view fills the frame its header gave up.
    ///
    /// The setting applies as it is written, so the headers have moved by the
    /// time the setter returns, before a run-loop turn could carry a layout
    /// from the host that builds the panes again.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - controller: The hosted window, its one pane projected.
    @MainActor
    private static func verifyHostedPaneTitleBars(_ t: UBUITestContext, controller: TerminalWindowController) {
        guard let app = NSApp.delegate as? UBAppDelegate else {
            t.expect(false, desc: "live UBAppDelegate reachable")
            return
        }
        app.settingsSetPaneTitleBars(true)
        defer { app.settingsSetPaneTitleBars(true) }
        guard let panes = splitHostedWindow(t, controller: controller) else { return }
        @MainActor
        func header(of pane: TerminalSurface) -> NSView? {
            (pane.superview as? PaneChrome)?.subviews.first { $0.accessibilityIdentifier() == "pane.titleBar" }
        }
        @MainActor
        func isWearingHeaders() -> Bool {
            panes.allSatisfy { header(of: $0).map { !$0.isHidden } ?? false }
        }
        @MainActor
        func isHeaderless() -> Bool {
            panes.allSatisfy { pane in
                (header(of: pane)?.isHidden ?? false) && pane.superview.map { pane.frame == $0.bounds } ?? false
            }
        }
        let chromes = panes.map { $0.superview.map(ObjectIdentifier.init) }
        t.expect(isWearingHeaders(), desc: "both panes of the hosted split wear a header")

        app.settingsSetPaneTitleBars(false)
        t.expect(isHeaderless(), desc: "turning Pane Title Bars off takes both hosted headers off, and each view fills its frame")
        t.expect(
            panes.map { $0.superview.map(ObjectIdentifier.init) } == chromes,
            desc: "in place: each hosted pane keeps the chrome it had"
        )
        t.pump(0.3)
        t.expect(isHeaderless(), desc: "and the headers stay off across the host's next layouts")

        // Read again: a host layout in the pump builds the panes' chromes anew.
        let headerlessChromes = panes.map { $0.superview.map(ObjectIdentifier.init) }
        app.settingsSetPaneTitleBars(true)
        t.expect(isWearingHeaders(), desc: "turning it on again puts both hosted headers back")
        t.expect(
            panes.map { $0.superview.map(ObjectIdentifier.init) } == headerlessChromes,
            desc: "in place again"
        )
    }

    /// Splits a hosted window by its host and waits for both panes.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - controller: The hosted window, its one pane projected.
    /// - Returns: The window's two panes, or nil when the host did not project them.
    @MainActor
    private static func splitHostedWindow(_ t: UBUITestContext, controller: TerminalWindowController) -> [TerminalSurface]? {
        controller.splitRight(nil)
        guard t.wait(until: { controller.remotePaneSurfaces.count == 2 }, timeout: 20) else {
            t.expect(false, desc: "the host projects two panes")
            return nil
        }
        t.pump(0.3)
        return Array(controller.remotePaneSurfaces.values)
    }

    /// Hiding a hosted window's title bar gives every pane of it the
    /// titleless top inset, and each re-fits its grid under it, as a local
    /// window's panes do; showing the bar again puts the inset back.
    ///
    /// The run configures a titleless top padding of 40 points, more than a
    /// row above the titled one, so a pane left on the other inset or on the
    /// other grid is a whole row off. `padding_top` stays at its default: a
    /// window's profile fold takes a configured top padding as its titleless
    /// one as well.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - controller: The hosted window, its one pane projected.
    @MainActor
    private static func verifyHostedTopInset(_ t: UBUITestContext, controller: TerminalWindowController) {
        guard let panes = splitHostedWindow(t, controller: controller), let window = controller.window else { return }
        let titled = panes.map { $0.gridFitBoxForTesting?.insets.top ?? -1 }
        @MainActor
        func fittingRows(_ pane: TerminalSurface) -> Int {
            guard let box = pane.gridFitBoxForTesting, box.cell.height > 0 else { return -1 }
            return Int(((pane.bounds.height - box.insets.top - box.insets.bottom) / box.cell.height).rounded(.down))
        }
        @MainActor
        func expectInset(_ shape: String, of expected: (Int) -> CGFloat) {
            window.contentView?.layoutSubtreeIfNeeded()
            for (index, pane) in panes.enumerated() {
                let top = pane.gridFitBoxForTesting?.insets.top ?? -1
                t.expect(
                    abs(top - expected(index)) < 0.01,
                    desc: "\(shape): hosted pane \(index + 1) is fitted under a top inset of \(expected(index)) points (\(top))"
                )
                t.expect(
                    t.wait(until: { Int(pane.publishedGrid.rows) == fittingRows(pane) }, timeout: 5),
                    desc:
                        "\(shape): hosted pane \(index + 1) holds the rows that fit under it (\(pane.publishedGrid.rows) of \(fittingRows(pane)))"
                )
            }
        }
        t.expect(
            titled.allSatisfy { $0 >= 0 && $0 < 40 },
            desc: "the titled panes are fitted under an inset below the titleless one (\(titled))"
        )
        controller.toggleHideTitleBar(nil)
        t.pump(0.3)
        expectInset("with the title bar hidden") { _ in 40 }
        controller.toggleHideTitleBar(nil)
        t.pump(0.3)
        expectInset("with the title bar shown again") { titled[$0] }
    }

    /// A full-screen exit settles every hosted pane on the scale the window
    /// has, as it settles a local window's panes: the animation can leave a
    /// layer at a scale the display does not have.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - controller: The hosted window, its one pane projected.
    @MainActor
    private static func verifyHostedFullScreenSettle(_ t: UBUITestContext, controller: TerminalWindowController) {
        guard let panes = splitHostedWindow(t, controller: controller), let window = controller.window else { return }
        let displayScale = window.backingScaleFactor
        // A scale the display does not have, standing in for the one the
        // animation's re-host can leave on the layer.
        let transitionalScale: CGFloat = displayScale == 1 ? 2 : 1
        controller.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: window))
        for pane in panes {
            pane.metalLayer.contentsScale = transitionalScale
        }
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        for (index, pane) in panes.enumerated() {
            t.expect(
                t.wait(until: { pane.metalLayer.contentsScale == displayScale }, timeout: 2),
                desc:
                    "hosted pane \(index + 1) settles on the window's scale (\(pane.metalLayer.contentsScale), the window's \(displayScale))"
            )
        }
    }

    /// The window verbs that address its focused pane reach a hosted window's
    /// pane: a script reads and writes it, Copy Special copies its selection,
    /// and Find insets and searches it.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - controller: The hosted window, its one pane projected.
    ///   - root: Its pane.
    @MainActor
    private static func verifyHostedPaneVerbs(_ t: UBUITestContext, controller: TerminalWindowController, root: TerminalSurface) {
        let marker = "hosted-verb-" + String(UUID().uuidString.prefix(6)).lowercased()
        func paneScreen() -> String {
            root.drive.withTerminal { String(Ubiquitty.Accessibility.visibleScreenText($0, 0)) } ?? ""
        }

        // The pane's output differs from the line that asks for it, so the
        // screen holding it is the program's answer and not the echo.
        root.send("printf '%s-%s\\n' \(marker) printed\n")
        t.expect(
            t.wait(until: { paneScreen().contains("\(marker)-printed") }, timeout: 20),
            desc: "the hosted pane prints the marker"
        )
        t.expect(
            controller.scriptScreenText().contains("\(marker)-printed"),
            desc: "a script reads the hosted pane's screen (\(controller.scriptScreenText().count) characters)"
        )
        controller.sendScriptText("printf '%s-%s\\n' \(marker) scripted\r")
        t.expect(
            t.wait(until: { paneScreen().contains("\(marker)-scripted") }, timeout: 20),
            desc: "a script's text reaches the hosted pane's session"
        )

        // Copy Special is the window's, not the surface's: the responder chain
        // passes it up, and the window answers for the pane it addresses.
        root.selectAll(nil)
        t.pump(0.2)
        let copyPlain = NSMenuItem(
            title: "Copy Plain Text",
            action: #selector(TerminalWindowController.copySelectionPlain(_:)),
            keyEquivalent: ""
        )
        t.expect(root.hasSelection, desc: "select-all made a selection in the hosted pane")
        t.expect(controller.validateEditMenuItem(copyPlain), desc: "Copy Plain Text enables over the hosted pane's selection")
        let savedPasteboard = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        controller.copySelectionPlain(nil)
        t.pump(0.2)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        NSPasteboard.general.clearContents()
        if let savedPasteboard {
            NSPasteboard.general.setString(savedPasteboard, forType: .string)
        }
        t.expect(
            copied.contains("\(marker)-scripted"),
            desc: "Copy Plain Text copies the hosted pane's selection (\(copied.count) characters)"
        )

        // Find insets the hosted pane as it does a local one, searches it, and
        // gives the rows back on close.
        let rowsBefore = root.publishedGrid.rows
        controller.performFindAction(nil)
        t.expect(
            t.wait(until: { root.publishedGrid.rows < rowsBefore }, timeout: 10),
            desc: "the find bar insets the hosted pane rather than painting over it (\(rowsBefore) -> \(root.publishedGrid.rows))"
        )
        controller.findBar.query = marker
        controller.findBarQueryDidChange(marker)
        t.expect(
            t.wait(
                until: {
                    root.searchStatus.totalMatches > 0
                        && controller.findBar.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(" of ") }
                },
                timeout: 10
            ),
            desc: "a query searches the hosted pane and the bar counts its matches (\(root.searchStatus.totalMatches) matches)"
        )
        controller.findBarClose()
        t.expect(
            t.wait(until: { root.publishedGrid.rows == rowsBefore }, timeout: 10),
            desc: "closing the bar gives the hosted pane its rows back (\(root.publishedGrid.rows) of \(rowsBefore))"
        )
    }

    /// A live drag on a hosted window moves it in whole cells of the pane the
    /// host has focused, alone and split, as a local window's drag moves in
    /// whole cells of its model's focused pane.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - controller: The hosted window, its one pane projected.
    ///   - root: Its pane.
    @MainActor
    private static func verifyHostedSnap(_ t: UBUITestContext, controller: TerminalWindowController, root: TerminalSurface) {
        guard let window = controller.window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            t.expect(false, desc: "the hosted window has a screen to be dragged on")
            return
        }
        t.expect(controller.snapsWindowResizeForTesting, desc: "the configured resize snap reaches a hosted window")

        // One bottom-right corner drag, in by four cells and back out a point
        // at a time, judged against the lattice of `pane`'s cells: the extent
        // the quantiser chooses and the one the window takes.
        @MainActor
        func expectWholeCellDrag(of pane: TerminalSurface, _ shape: String) {
            guard let box = pane.gridFitBoxForTesting, box.cell.width > 0, box.cell.height > 0 else {
                t.expect(false, desc: "\(shape): the focused pane has a cell to fit")
                return
            }
            let cell = box.cell
            // Everything along each axis that is not grid, as a local window's
            // drag reserves it: the chrome around the pane host, and the
            // focused pane's padding.
            let reserve = (
                width: window.frame.width - controller.paneHost.bounds.width + box.insets.left + box.insets.right,
                height: window.frame.height - controller.paneHost.bounds.height + box.insets.top + box.insets.bottom
            )
            // The nearest extent holding whole cells, rounded up to a whole
            // point: AppKit applies a frame extent in whole points.
            @MainActor
            func lattice(_ extent: CGFloat, _ cellExtent: CGFloat, _ reserve: CGFloat) -> CGFloat {
                (((extent - reserve) / cellExtent).rounded() * cellExtent + reserve).rounded(.up)
            }
            @MainActor
            func isOnLattice(_ size: NSSize) -> Bool {
                abs(size.width - lattice(size.width, cell.width, reserve.width)) < 1
                    && abs(size.height - lattice(size.height, cell.height, reserve.height)) < 1
            }

            // Clear of every edge, and on the lattice before the drag: the
            // slack a frame holds beyond its grid follows the pointer by
            // design, and the drag under test is the one between cells.
            let startSize = NSSize(
                width: lattice(window.frame.width, cell.width, reserve.width),
                height: lattice(window.frame.height, cell.height, reserve.height)
            )
            window.setFrame(
                NSRect(
                    x: window.frame.minX,
                    y: (visible.midY - startSize.height / 2).rounded(.down),
                    width: startSize.width,
                    height: startSize.height
                ),
                display: true
            )
            t.pump(0.2)
            let start = window.frame
            t.expect(
                isOnLattice(start.size),
                desc: "\(shape): the window a drag starts from holds whole cells (\(start.size), cell \(cell), reserve \(reserve))"
            )
            t.expect(
                start.minY - visible.minY > cell.height * 5 && visible.maxY - start.maxY > cell.height * 5,
                desc: "\(shape): the window is clear of the Dock and the menu bar (\(start), visible \(visible))"
            )

            controller.beginLiveResize(pressedAt: NSPoint(x: start.maxX, y: start.minY))
            pane.viewWillStartLiveResize()
            let travel = Int((4 * max(cell.width, cell.height)).rounded(.up))
            var offLattice: [String] = []
            var notApplied: [String] = []
            var heights = Set<CGFloat>()
            var widths = Set<CGFloat>()
            @MainActor
            func dragCorner(to proposed: NSSize, _ name: String) {
                let size = controller.snappedFrameSize(for: window, proposed: proposed, isLiveResize: true)
                window.setFrame(
                    NSRect(x: start.minX, y: start.maxY - size.height, width: size.width, height: size.height),
                    display: true
                )
                t.pump(0.01)
                if !isOnLattice(size) {
                    offLattice.append("\(name): asked \(proposed), quantised \(size)")
                }
                if window.frame.size != size {
                    notApplied.append("\(name): quantised \(size), applied \(window.frame.size)")
                }
                heights.insert(window.frame.height)
                widths.insert(window.frame.width)
            }
            for step in 1...travel {
                dragCorner(to: NSSize(width: start.width - CGFloat(step), height: start.height - CGFloat(step)), "in \(step)")
            }
            for step in stride(from: travel - 1, through: 0, by: -1) {
                dragCorner(to: NSSize(width: start.width - CGFloat(step), height: start.height - CGFloat(step)), "out \(step)")
            }
            pane.viewDidEndLiveResize()
            controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
            t.expect(
                offLattice.isEmpty,
                desc:
                    "\(shape): every step leaves the content box a whole grid of the focused pane's cells"
                    + " (\(offLattice.count) of \(2 * travel) did not: \(offLattice.prefix(4).joined(separator: "; ")))"
            )
            t.expect(
                notApplied.isEmpty,
                desc: "\(shape): every extent the quantiser chose is one the window takes (\(notApplied.prefix(4).joined(separator: "; ")))"
            )
            t.expect(
                heights.count >= 4 && widths.count >= 4,
                desc:
                    "\(shape): the drag crossed whole cells rather than holding the window (\(heights.count) heights, \(widths.count) widths)"
            )
            t.expect(
                window.frame.size == start.size,
                desc: "\(shape): out and back lands where it started (\(window.frame.size), \(start.size))"
            )
        }

        expectWholeCellDrag(of: root, "a lone hosted pane")

        // Split by the host: the pane the drag measures is the one the host
        // reports focused, the hosted counterpart of the model's focused pane.
        controller.splitRight(nil)
        @MainActor
        func hostFocusedPane() -> TerminalSurface? {
            let tree = root.drive.remoteWorkspacePaneTreeSnapshot(
                of: root.drive.remoteWorkspaceSurface,
                tab: controller.remoteWorkspaceTab
            )
            return controller.remotePaneSurfaces.values.first {
                tree.focusedPaneID() == Int32($0.drive.remoteWorkspacePane.rawValue)
            }
        }
        guard
            t.wait(
                until: {
                    controller.remotePaneSurfaces.count == 2 && hostFocusedPane().map { window.firstResponder === $0 } == true
                },
                timeout: 20
            ),
            let focused = hostFocusedPane()
        else {
            t.expect(false, desc: "the host projects two panes and focuses one of them")
            return
        }
        expectWholeCellDrag(of: focused, "a hosted split")
    }

    /// A hosted pane zoomed by its header's button, as a local pane is: the
    /// header stays with the button turned to contract, and the host sizes
    /// the pane's PTY to the grid the zoom draws, then to the split's again
    /// when the same button takes the zoom back.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - window: The hosted window, projecting the host's one pane.
    ///   - root: Its pane.
    ///   - base: A folder of the scenario's own to write the size reporter in.
    @MainActor
    private static func verifyHostedZoom(
        _ t: UBUITestContext,
        window: TerminalWindowController,
        root: TerminalSurface,
        under base: String
    ) {
        guard let reporter = PaneZoomCheck.installReporter(in: base + "/zoom") else {
            t.expect(false, desc: "the size reporter was written")
            return
        }
        root.send("python3 '\(reporter)'\n")
        t.expect(
            t.wait(until: { PaneZoomCheck.lastReport(in: root) != nil }, timeout: 20),
            desc: "the hosted pane runs the size reporter"
        )
        window.splitRight(nil)
        let rootPane = root.drive.remoteWorkspacePane
        guard t.wait(until: { window.remotePaneSurfaces.count == 2 }, timeout: 20),
            let sibling = window.remotePaneSurfaces.first(where: { $0.key != rootPane })?.value,
            t.wait(until: { sibling.drive.remoteState == .Connected && sibling.remoteSessionID != 0 }, timeout: 20)
        else {
            t.expect(false, desc: "a split sent over the wire came back as a second, attached pane")
            return
        }
        PaneZoomCheck.verifyZoomByHeader(
            t,
            in: window,
            pane: root,
            beside: sibling,
            isZoomed: { root.drive.remoteWorkspaceZoomedPane(of: root.drive.remoteWorkspaceSurface) == rootPane }
        )
    }

    /// What each answer of the notice was asked to do.
    @MainActor
    private final class InputInDoubtAnswers {
        var resent = 0
        var discarded = 0
    }

    /// A pane whose typing may not have reached its host shows Core's notice
    /// over its bottom edge, keeps the keyboard, and sends nothing again but
    /// at the person's click; a pane with nothing in doubt shows nothing.
    ///
    /// The notice is handed to the presentation rather than reached by a
    /// lost carrier: a live host reports a count for what it read, and a
    /// carrier that dies with an event unread is a race this harness cannot
    /// win every run. Core's tests drive the doubt itself.
    ///
    /// - Parameter t: The scenario's context.
    @MainActor
    private static func verifyInputInDoubtNotice(_ t: UBUITestContext) {
        guard let shell = TerminalWindowController.spawn() else {
            t.expect(false, desc: "a window opens")
            return
        }
        defer { shell.window?.close() }
        t.pump(0.3)
        guard let surface = shell.focusedSurfaceForTesting, let window = shell.window else {
            t.expect(false, desc: "the window has a pane")
            return
        }
        window.makeFirstResponder(surface)
        let notice = RuntimeDrive.InputInDoubtNotice(
            message: "Some of what you typed may not have reached the host",
            detail: "Sending it again could run a command twice. What you type next waits until you choose.",
            resendButton: "Send Again",
            discardButton: "Discard"
        )
        let answers = InputInDoubtAnswers()
        let present = {
            shell.presentInputInDoubt(notice, on: surface, resend: { answers.resent += 1 }, discard: { answers.discarded += 1 })
        }
        present()
        surface.layoutSubtreeIfNeeded()
        guard let view = surface.subviews.compactMap({ $0 as? InputInDoubtView }).first else {
            t.expect(false, desc: "the notice stands over the pane")
            return
        }
        t.expect(
            view.message.stringValue == notice.message && view.detailLabel.stringValue == notice.detail,
            desc: "the notice says what Core decided"
        )
        t.expect(
            view.resendButton.title == "Send Again" && view.discardButton.title == "Discard",
            desc: "its answers are Send Again and Discard"
        )
        t.expect(
            view.resendButton.keyEquivalent.isEmpty && view.discardButton.keyEquivalent.isEmpty,
            desc: "neither answer is a default that Return meant for the program would press"
        )
        t.expect(
            view.resendButton.refusesFirstResponder && view.discardButton.refusesFirstResponder,
            desc: "neither answer takes the keyboard from the pane"
        )
        t.expect(window.attachedSheet == nil, desc: "the notice is not a sheet")
        t.expect(window.firstResponder === surface, desc: "the pane keeps the keyboard while the notice stands")
        let isAtTheBottom = surface.isFlipped ? view.frame.maxY > surface.bounds.midY : view.frame.minY < surface.bounds.midY
        t.expect(isAtTheBottom && surface.bounds.contains(view.frame), desc: "the notice sits over the pane's lower half")
        present()
        t.expect(
            surface.subviews.compactMap({ $0 as? InputInDoubtView }).count == 1,
            desc: "a second report updates the notice rather than stacking another"
        )
        t.expect(answers.resent == 0 && answers.discarded == 0, desc: "nothing is answered unasked")
        view.discardButton.performClick(nil)
        t.expect(answers.discarded == 1 && answers.resent == 0, desc: "Discard answers discard and nothing else")
        view.resendButton.performClick(nil)
        t.expect(answers.resent == 1 && answers.discarded == 1, desc: "Send Again answers resend, once")
        // Core decides when the notice goes: this pane is local, so nothing
        // of its input is in doubt.
        t.expect(surface.drive.inputInDoubtNotice == nil, desc: "Core reports nothing in doubt for a local pane")
        shell.presentInputInDoubt(on: surface)
        t.expect(surface.subviews.compactMap({ $0 as? InputInDoubtView }).isEmpty, desc: "a pane with nothing in doubt shows no notice")
    }

    /// A hosted window spells its pane's directory by the reader's own
    /// `[title]` settings, as a local window does: the path with
    /// `window_directory_path` on, the folder alone with it off.
    ///
    /// - Parameters:
    ///   - t: The scenario's context.
    ///   - controller: The hosted window.
    ///   - root: Its pane.
    ///   - base: A folder of the scenario's own to make the pane's directory in.
    @MainActor
    private static func verifyHostedDirectory(
        _ t: UBUITestContext,
        controller: TerminalWindowController,
        root: TerminalSurface,
        under base: String
    ) {
        let folder = base + "/projects/hosted-title"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let saved = (shown: settingBool(.TitleWindowDirectory), path: settingBool(.TitleWindowDirectoryPath))
        defer {
            _ = setSetting(.TitleWindowDirectory, bool: saved.shown)
            _ = setSetting(.TitleWindowDirectoryPath, bool: saved.path)
        }
        _ = setSetting(.TitleWindowDirectory, bool: true)
        _ = setSetting(.TitleWindowDirectoryPath, bool: true)
        root.send("cd '\(folder)'\r")
        let title = { controller.window?.title ?? "" }
        t.expect(
            t.wait(until: { title().contains("projects/hosted-title") }, timeout: 12),
            desc: "with window_directory_path on, a hosted window names its directory's path ('\(title())')"
        )
        _ = setSetting(.TitleWindowDirectoryPath, bool: false)
        t.expect(
            t.wait(until: { title().contains("hosted-title") && !title().contains("projects/hosted-title") }, timeout: 12),
            desc: "and with it off, the folder alone ('\(title())')"
        )
    }

    @MainActor
    private static func sheetButton(_ title: String, in window: NSWindow?) -> NSButton? {
        func find(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return window?.contentView.flatMap { find(in: $0) }
    }

    @MainActor
    private static func paneCloseButton(_ pane: Ubiquitty.Session.Layout.PaneID, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == "pane.close", button.tag == Int(pane.rawValue) {
            return button
        }
        return view.subviews.lazy.compactMap { paneCloseButton(pane, in: $0) }.first
    }

    @MainActor
    private static func paneHeader(of surface: TerminalSurface) -> NSTextField? {
        guard let chrome = surface.superview as? PaneChrome, chrome.showsTitleBar,
            let window = surface.window, chrome.window === window
        else { return nil }
        func find(in view: NSView) -> NSTextField? {
            if view.accessibilityIdentifier() == "pane.title", !view.isHiddenOrHasHiddenAncestor,
                view.window === window
            {
                return view as? NSTextField
            }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return find(in: chrome)
    }

    /// A split window attached over Sync: neither pane header draws a tag the
    /// connection earns, which the chip carries, though each names it for a
    /// screen reader.
    ///
    /// A pane that went on to another machine is not driven here: the host's
    /// pane facts name the host's own machine, so nothing a pane's shell
    /// reports reaches this side for `Session::surfaceTagHost` to read.
    @MainActor
    private static func verifyPaneHeaderTags(
        _ t: UBUITestContext,
        window: TerminalWindowController,
        root: TerminalSurface,
        sibling: TerminalSurface
    ) {
        let saved = configureAppendingToLiveDocument("[[tags]]\nname = \"Header host\"\ncolor = \"green\"\nmatch_host = \"*\"\n")
        defer { restoreLiveDocument(saved) }
        func lead(of surface: TerminalSurface) -> TabTagMarkAttachment? {
            guard let title = paneHeader(of: surface)?.attributedStringValue, title.length > 0 else { return nil }
            return title.attribute(.attachment, at: 0, effectiveRange: nil) as? TabTagMarkAttachment
        }
        func spoken(_ surface: TerminalSurface) -> String { lead(of: surface)?.image?.accessibilityDescription ?? "" }
        t.expect(
            t.wait(
                until: {
                    window.refreshTitles()
                    return [root, sibling].allSatisfy { lead(of: $0)?.iconNames.isEmpty == true && spoken($0).contains("Header host") }
                },
                timeout: 8
            ),
            desc:
                "neither hosted pane's header draws the connection's tag, and each names it ('\(spoken(root))', '\(spoken(sibling))')"
        )
    }

    @MainActor
    private static func verifyPaneHeaders(
        _ t: UBUITestContext,
        window: TerminalWindowController,
        root: TerminalSurface,
        sibling: TerminalSurface
    ) {
        func weight(of surface: TerminalSurface) -> Int {
            guard let title = paneHeader(of: surface)?.attributedStringValue, title.length > 0,
                let font = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            else { return -1 }
            return NSFontManager.shared.weight(of: font)
        }
        func hasHostFocus(_ surface: TerminalSurface) -> Bool {
            let tree = root.drive.remoteWorkspacePaneTreeSnapshot(
                of: root.drive.remoteWorkspaceSurface,
                tab: window.remoteWorkspaceTab
            )
            return tree.focusedPaneID() == Int32(surface.drive.remoteWorkspacePane.rawValue)
        }

        root.send("sh -c 'printf \"\\033]0;Left hosted pane\\007\"; read -r line'\n")
        sibling.send("sh -c 'printf \"\\033]0;Right hosted pane\\007\"; read -r line'\n")
        defer {
            root.send("\n")
            sibling.send("\n")
        }
        t.expect(
            t.wait(
                until: {
                    paneHeader(of: root)?.stringValue.contains("Left hosted pane") == true
                        && paneHeader(of: sibling)?.stringValue.contains("Right hosted pane") == true
                },
                timeout: 20
            ),
            desc: "both hosted pane headers display their own synchronized titles"
        )
        t.expect(
            hasHostFocus(sibling) && weight(of: root) >= 0 && weight(of: sibling) > weight(of: root),
            desc: "the pane selected by the host alone has the selected header weight"
        )
        window.movePaneFocusLeft(nil)
        t.expect(
            t.wait(
                until: {
                    hasHostFocus(root) && window.window?.firstResponder === root
                        && weight(of: sibling) >= 0 && weight(of: root) > weight(of: sibling)
                },
                timeout: 10
            ),
            desc: "a host focus change moves the selected header styling to the other pane"
        )
        // As short as the other panes' titles: a header fits its label to the
        // pane's width, and this asks whether the header follows its pane, not
        // how a long title gives way.
        sibling.send("\nsh -c 'printf \"\\033]0;Background pane\\007\"; read -r line'\n")
        t.expect(
            t.wait(until: { paneHeader(of: sibling)?.stringValue.contains("Background pane") == true }, timeout: 20),
            desc:
                "an unfocused hosted pane updates its own header without taking focus (\(paneHeader(of: sibling)?.stringValue ?? "no header"))"
        )
        t.expect(hasHostFocus(root), desc: "a background title change preserves the host's focused pane")

        window.toggleZoomPane(nil)
        t.expect(
            t.wait(
                until: {
                    root.drive.remoteWorkspaceZoomedPane(of: root.drive.remoteWorkspaceSurface) == root.drive.remoteWorkspacePane
                        && root.superview?.superview === window.paneHost && sibling.window == nil
                        && paneHeader(of: root)?.stringValue.contains("Left hosted pane") == true
                },
                timeout: 10
            ),
            desc: "host zoom fills the window with the focused pane under its own header"
        )
        window.toggleZoomPane(nil)
        t.expect(
            t.wait(
                until: {
                    root.drive.remoteWorkspaceZoomedPane(of: root.drive.remoteWorkspaceSurface) == Ubiquitty.Session.Layout.invalidPane
                        && paneHeader(of: root)?.stringValue.contains("Left hosted pane") == true
                        && paneHeader(of: sibling)?.stringValue.contains("Background pane") == true
                        && weight(of: root) > weight(of: sibling)
                },
                timeout: 10
            ),
            desc:
                "unzoom restores both current pane titles and the host's selection styling (\(paneHeader(of: root)?.stringValue ?? "no header") | \(paneHeader(of: sibling)?.stringValue ?? "no header"))"
        )
        window.movePaneFocusRight(nil)
        t.expect(
            t.wait(until: { hasHostFocus(sibling) && window.window?.firstResponder === sibling }, timeout: 10),
            desc:
                "pane focus returns through the host before the remaining workspace operations (host focus on the sibling: \(hasHostFocus(sibling)), first responder is the sibling: \(window.window?.firstResponder === sibling), on the root: \(window.window?.firstResponder === root))"
        )
    }

    @MainActor
    private static func verifyDaemonProjectionIsolation(_ t: UBUITestContext) {
        guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
            FileManager.default.isExecutableFile(atPath: hostBinary)
        else {
            t.expect(false, desc: "the isolated projection test has a host binary")
            return
        }
        let hostHome = "/tmp/ubq-projection-" + String(UUID().uuidString.prefix(8))
        do {
            try FileManager.default.createDirectory(
                atPath: hostHome,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            t.expect(false, desc: "the isolated daemon directory was created")
            return
        }
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", hostHome, 1)
        var daemons: [Process] = []
        defer {
            t.closeAllWindows()
            for daemon in daemons {
                if daemon.isRunning { daemon.terminate() }
                daemon.waitUntilExit()
            }
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? FileManager.default.removeItem(atPath: hostHome)
        }
        let socketNames = ["host-1111111111111111.sock", "host-2222222222222222.sock"]
        for socketName in socketNames {
            let daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: hostBinary)
            daemon.arguments = ["--daemon", "--socket", socketName, "--quic-port", "-1"]
            daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": hostHome, "ZDOTDIR": hostHome]) { $1 }
            do { try daemon.run() } catch {
                t.expect(false, desc: "an isolated daemon started")
                return
            }
            daemons.append(daemon)
        }
        guard
            t.wait(
                until: {
                    socketNames.allSatisfy { FileManager.default.fileExists(atPath: hostHome + "/" + $0) }
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "both isolated daemon sockets became available")
            return
        }
        let quotedBinary = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let command =
            "SOCK=\"\"; if [ -n \"$SOCK\" ]; then exec " + quotedBinary
            + " --attach --socket \"$SOCK\"; else exec " + quotedBinary + " --attach; fi"
        var controllers: [TerminalWindowController] = []
        for socketName in socketNames {
            guard
                let controller = TerminalWindowController.spawnRemoteWindow(
                    shellCommand: command,
                    hostLabel: "projection isolation",
                    quicHost: "",
                    quicBootstrapCommand: "",
                    deploySSHHost: "",
                    deployBinaries: [:],
                    reattachSessionID: 0,
                    workspaceName: "same name",
                    hostKey: "",
                    daemonSocketName: socketName
                )
            else {
                t.expect(false, desc: "a distinct pinned daemon opened its workspace")
                return
            }
            controllers.append(controller)
        }
        guard
            t.wait(
                until: {
                    controllers.allSatisfy { $0.remotePaneSurfaces.count == 1 && $0.remoteSurface?.drive.remoteState == .Connected }
                },
                timeout: 20
            ),
            let first = controllers[0].remoteSurface,
            let second = controllers[1].remoteSurface
        else {
            t.expect(false, desc: "both daemon workspaces established their own pane")
            return
        }
        t.expect(
            first.drive.remoteWorkspaceID == second.drive.remoteWorkspaceID,
            desc: "the daemons have overlapping numeric workspace identities"
        )
        t.expect(
            !first.drive.sharesRemoteWorkspaceConnection(with: second.drive),
            desc: "different daemon identities own different carriers"
        )
        // What an attach of the first daemon's workspace reuses is that
        // daemon's projection: not the other daemon's equal-numbered one,
        // and not a local window, which projects a host's workspace only
        // once it is shared into this Mac's daemon.
        if let local = TerminalWindowController.spawn() {
            t.pump(0.2)
            let found = RemoteWindowRegistry.matches(
                for: RemoteWindowRegistry.Request(
                    shellCommand: command,
                    workspaceID: first.drive.remoteWorkspaceID,
                    sessionID: 0,
                    workspaceName: "",
                    daemonSocketName: socketNames[0],
                    daemonInstanceID: 0
                )
            )
            t.expect(found.contains { $0.controller === controllers[0] }, desc: "the first daemon's window projects its workspace")
            t.expect(
                !found.contains { $0.controller === controllers[1] },
                desc: "the other daemon's equal-numbered workspace is another authority's"
            )
            t.expect(!found.contains { $0.controller === local }, desc: "a local window that was never shared projects no host's workspace")
            local.window?.close()
            t.pump(0.2)
        } else {
            t.expect(false, desc: "a local window opens beside the hosted ones")
        }
        t.expect(first.drive.remoteWorkspaceAddTab(), desc: "the first daemon accepts another tab")
        t.expect(second.drive.remoteWorkspaceAddTab(), desc: "the second daemon accepts another tab")
        t.expect(
            t.wait(
                until: {
                    controllers.allSatisfy { ($0.window?.tabGroup?.windows.count ?? 1) == 2 }
                },
                timeout: 20
            ),
            desc: "each daemon projects its own pair of native tabs"
        )
        let firstWindows = controllers[0].window?.tabGroup?.windows ?? []
        let secondWindows = controllers[1].window?.tabGroup?.windows ?? []
        t.expect(
            !firstWindows.isEmpty && !secondWindows.isEmpty
                && !firstWindows.contains { firstWindow in secondWindows.contains { $0 === firstWindow } },
            desc: "equal workspace numbers on different daemons never merge native tab groups"
        )
        for (index, group) in [firstWindows, secondWindows].enumerated() {
            let source = index == 0 ? first : second
            t.expect(
                group.allSatisfy { window in
                    guard let member = (window.windowController as? TerminalWindowController)?.remoteSurface else { return false }
                    return member.drive.sharesRemoteWorkspaceConnection(with: source.drive)
                },
                desc: "every projected tab retains its own daemon's workspace carrier"
            )
        }

        controllers[1].window?.makeKeyAndOrderFront(nil)
        let menu = NSMenu(title: "Remote Workspaces")
        TerminalWindowController.populateRemoteWorkspaceMenu(menu)
        let detachItems = menu.items.filter { $0.title.hasPrefix("Detach from ") }
        t.expect(detachItems.count == 2, desc: "the menu includes both workspaces despite equal names and numeric IDs")
        t.expect(menu.items.filter { $0.title.hasPrefix("Close Window on ") }.count == 2, desc: "each host window has a close command")
        guard let detach = detachItems.first, let action = detach.action else { return }
        t.expect(
            NSApp.sendAction(action, to: detach.target, from: detach),
            desc: "an inactive workspace's menu action is routed explicitly"
        )
        guard t.wait(until: { controllers[0].window?.attachedSheet != nil }, timeout: 3),
            let question = controllers[0].window?.attachedSheet,
            let cancel = sheetButton("Cancel", in: question)
        else {
            t.expect(false, desc: "detach asks on the captured workspace rather than the key window")
            return
        }
        t.expect(question.defaultButtonCell === cancel.cell, desc: "Cancel is the native default")
        t.expect(controllers[1].window?.attachedSheet == nil, desc: "the other daemon receives no question")
        cancel.performClick(nil)
        t.expect(t.wait(until: { controllers[0].window?.attachedSheet == nil }, timeout: 3), desc: "Cancel dismisses without detaching")
        t.expect(first.drive.pendingRemoteWindowCloseToken == 0, desc: "Cancel consumes the captured operation")
        t.expect(
            first.drive.remoteState == .Connected && first.drive.remoteWorkspaceSurfaceCount == 1,
            desc: "Cancel leaves host state and attachment intact"
        )

        controllers[0].window?.performClose(nil)
        guard t.wait(until: { controllers[0].window?.attachedSheet != nil }, timeout: 3),
            let staleClose = sheetButton("Close Tab", in: controllers[0].window?.attachedSheet)
        else {
            t.expect(false, desc: "the window close presents its choice")
            return
        }
        t.expect(first.drive.remoteWorkspaceAddTab(), desc: "the host can change the window while its question stands")
        t.expect(
            t.wait(
                until: {
                    first.drive.remoteWorkspaceTabCount(of: first.drive.remoteWorkspaceSurface) == 3
                        && controllers[0].window?.attachedSheet == nil
                },
                timeout: 20
            ),
            desc: "a changed topology retires the question"
        )
        staleClose.performClick(nil)
        t.pump(0.2)
        t.expect(
            !controllers[0].isClosedForTesting && first.drive.remoteWorkspaceTabCount(of: first.drive.remoteWorkspaceSurface) == 3,
            desc: "an old button cannot close the changed host window"
        )
        t.expect(first.drive.remoteWorkspaceAddSurface(), desc: "the workspace creates another host window")
        t.expect(
            t.wait(
                until: {
                    first.drive.remoteWorkspaceSurfaceCount == 2
                        && TerminalWindowController.spawnedControllers
                            .filter { $0.remoteSurface?.drive.sharesRemoteWorkspaceConnection(with: first.drive) == true }.count == 4
                },
                timeout: 20
            ),
            desc: "both host windows and all their tabs have local projections"
        )
        let firstMembers = TerminalWindowController.spawnedControllers.filter {
            $0.remoteSurface?.drive.sharesRemoteWorkspaceConnection(with: first.drive) == true
        }
        let sessionID = first.remoteSessionID
        t.expect(
            NSApp.sendAction(action, to: detach.target, from: detach),
            desc: "the same menu identity opens a fresh question after topology changes"
        )
        guard t.wait(until: { controllers[0].window?.attachedSheet != nil }, timeout: 3),
            let approveDetach = sheetButton("Detach from Workspace", in: controllers[0].window?.attachedSheet)
        else {
            t.expect(false, desc: "detach has an explicit confirmation button")
            return
        }
        approveDetach.performClick(nil)
        t.expect(
            t.wait(until: { firstMembers.allSatisfy { $0.isClosedForTesting } }, timeout: 5),
            desc: "detach closes every local window and tab of that owner"
        )
        t.expect(
            second.drive.remoteState == .Connected && controllers[1].window?.isVisible == true,
            desc: "the other daemon's equal-numbered workspace remains attached"
        )
        _ = NSApp.sendAction(action, to: detach.target, from: detach)
        t.expect(controllers[1].window?.attachedSheet == nil, desc: "a stale menu target cannot act on the surviving workspace")
        guard
            let reopened = TerminalWindowController.spawnRemoteWindow(
                shellCommand: command,
                hostLabel: "projection isolation",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: sessionID,
                workspaceName: "",
                hostKey: "",
                daemonSocketName: socketNames[0]
            )
        else {
            t.expect(false, desc: "the detached session can be opened again")
            return
        }
        t.expect(
            t.wait(
                until: {
                    reopened.remoteSurface?.drive.remoteState == .Connected
                        && reopened.remoteSurface?.drive.remoteWorkspaceSurfaceCount == 2
                        && (reopened.window?.tabGroup?.windows.count ?? 0) == 3
                },
                timeout: 20
            ),
            desc: "detach leaves the same host session, both windows, and all tabs running"
        )
        t.expect(reopened.remoteSurface?.remoteSessionID == sessionID, desc: "reattach preserves the exact session identity")
    }

    @MainActor
    private static func verifyHostedProgress(_ t: UBUITestContext, controller: TerminalWindowController, root: TerminalSurface) {
        controller.splitRight(nil)
        guard t.wait(until: { controller.remotePaneSurfaces.count == 2 }, timeout: 20),
            let sibling = controller.remotePaneSurfaces.values.first(where: { $0 !== root }),
            let window = controller.window
        else {
            t.expect(false, desc: "the host projects two panes for progress focus")
            return
        }
        t.expect(controller.focusedSurfaceForTesting == nil, desc: "hosted panes have no local model focus")
        root.send("printf '\\033]9;4;1;40\\007'\n")
        sibling.send("printf '\\033]9;4;3;0\\007'\n")
        func band(_ surface: TerminalSurface) -> ProgressBar? {
            ProgressChromeScenarios.paneBand(over: surface)
        }
        guard
            t.wait(
                until: {
                    root.drive.readSnapshot().progressState == 1 && sibling.drive.readSnapshot().progressState == 3
                        && band(root)?.isHidden == false && band(sibling)?.isHidden == false
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "real host determinate and indeterminate reports both raise native pane bands")
            return
        }
        let inactive = ProgressTintPalette.color(for: .ProgressInactive, colors: root.drive.statusColors())
        if WindowContainment.isOffscreen {
            t.expect(
                band(root)?.tintColor == inactive && band(sibling)?.tintColor == inactive,
                desc: "offscreen hosted progress remains inactive"
            )
            return
        }
        let originalPolicy = NSApp.activationPolicy()
        let originalApplication = NSWorkspace.shared.frontmostApplication
        defer {
            NSApp.setActivationPolicy(originalPolicy)
            if originalApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                originalApplication?.activate(options: [])
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let activationDeadline = Date(timeIntervalSinceNow: 10)
        while (!NSApp.isActive || !window.isKeyWindow) && Date() < activationDeadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            t.pump(0.01)
        }
        window.makeFirstResponder(sibling)
        guard t.wait(until: { NSApp.isActive && window.isKeyWindow && window.firstResponder === sibling }, timeout: 10) else {
            t.expect(
                false,
                desc:
                    "the hosted split is actually active with its indeterminate pane focused (active=\(NSApp.isActive), key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder)), sibling=\(sibling))"
            )
            return
        }
        let accent = ProgressTintPalette.color(for: .Progress, colors: sibling.drive.statusColors())
        t.expect(accent != inactive, desc: "the fixture's active and inactive progress colors differ")
        t.expect(
            t.wait(until: { band(sibling)?.tintColor == accent && band(root)?.tintColor == inactive }, timeout: 5),
            desc: "focused hosted indeterminate progress uses accent while its sibling stays dim"
        )
        controller.movePaneFocusLeft(nil)
        t.expect(
            t.wait(
                until: { window.firstResponder === root && band(root)?.tintColor == accent && band(sibling)?.tintColor == inactive },
                timeout: 10
            ),
            desc: "the accent follows host focus to determinate progress"
        )
        controller.movePaneFocusRight(nil)
        t.expect(
            t.wait(
                until: { window.firstResponder === sibling && band(sibling)?.tintColor == accent && band(root)?.tintColor == inactive },
                timeout: 10
            ),
            desc: "the accent returns to the indeterminate pane without another progress report"
        )
        root.send("printf '\\033]9;4;2;0\\007'\n")
        let error = ProgressTintPalette.color(for: .ProgressError, colors: root.drive.statusColors())
        t.expect(
            t.wait(until: { root.drive.readSnapshot().progressState == 2 && band(root)?.tintColor == error }, timeout: 10),
            desc: "an unfocused hosted error remains an alert"
        )
    }

    /// A transport command whose bytes cross a slow link: each chunk, in each
    /// direction on its own, is held a random delay in the range before it is
    /// passed on.
    ///
    /// Order within a direction is kept, as a TCP link keeps it; what moves is
    /// when a host's events arrive against the client's requests, which is
    /// where an ordering race between the two shows.
    ///
    /// - Parameters:
    ///   - command: The transport command, run by `/bin/sh -c`.
    ///   - delayMilliseconds: The range each chunk's delay is drawn from.
    /// - Returns: The command wrapped in the relay.
    private static func delayedLink(_ command: String, delayMilliseconds: ClosedRange<Int>) -> String {
        let relay = """
            use strict; use IO::Handle;
            my ($lo, $hi, @cmd) = @ARGV;
            pipe(my $childIn, my $toChild) or die; pipe(my $fromChild, my $childOut) or die;
            my $pid = fork(); die unless defined $pid;
            if ($pid == 0) { open(STDIN, '<&', $childIn); open(STDOUT, '>&', $childOut); close $toChild; close $fromChild; exec { $cmd[0] } @cmd; exit 127; }
            close $childIn; close $childOut;
            sub relay { my ($in, $out) = @_; binmode $in; binmode $out; my $buffer;
              while (1) { my $n = sysread($in, $buffer, 65536); last unless $n;
                select(undef, undef, undef, ($lo + rand($hi - $lo)) / 1000);
                my $offset = 0; while ($offset < $n) { my $w = syswrite($out, $buffer, $n - $offset, $offset); exit 0 unless defined $w; $offset += $w; } } }
            my $up = fork(); die unless defined $up;
            if ($up == 0) { close $fromChild; relay(\\*STDIN, $toChild); close $toChild; exit 0; }
            close $toChild;
            relay($fromChild, \\*STDOUT);
            kill 'TERM', $up; waitpid($pid, 0); exit($? >> 8);
            """
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        return
            "exec /usr/bin/perl -e \(quote(relay)) \(delayMilliseconds.lowerBound) \(delayMilliseconds.upperBound) /bin/sh -c \(quote(command))"
    }

    /// A pane no window shows, whose observer declines process facts, holds a
    /// process-state move the host reports, and hands it over once the
    /// observer asks again or the pane is shown. Only a pane the host serves
    /// moves while declined: a local session whose observer declines samples
    /// nothing, so it has no move to hold.
    @MainActor
    private static func verifyHostedProcessStateHold(_ t: UBUITestContext, root: TerminalSurface) {
        guard t.wait(until: { !root.foregroundProgramName.isEmpty }, timeout: 20) else {
            t.expect(false, desc: "the host names the pane's shell")
            return
        }
        let shell = root.foregroundProgramName
        let appObserver = root.observer
        let probe = ProcessStateProbe()
        defer {
            root.observer = appObserver
            report(root, covered: false, pumpingWith: t)
        }
        root.observer = probe
        report(root, covered: true, pumpingWith: t)

        // Hidden and declined: the host's report moves the pane's facts, read
        // fresh, and the observer hears nothing of it.
        let heardBeforeProgram = probe.heard.count
        root.send("/bin/sleep 30\n")
        t.expect(
            t.wait(until: { root.foregroundProgramName == "sleep" }, timeout: 20),
            desc: "the host reports the program the hidden pane runs: \(root.foregroundProgramName)"
        )
        t.pump(0.5)
        t.expect(
            probe.heard.count == heardBeforeProgram,
            desc: "a hidden pane whose observer declines holds the move: heard \(probe.heard.dropFirst(heardBeforeProgram))"
        )
        // Asked again, the held move fires, still hidden.
        probe.needsProcessState = true
        root.observer = probe
        t.expect(
            t.wait(until: { probe.heard.dropFirst(heardBeforeProgram).contains("sleep") }, timeout: 5),
            desc: "asked again, the observer hears the held move: heard \(probe.heard.dropFirst(heardBeforeProgram))"
        )

        // Declined again, the shell takes the terminal back unheard, and
        // showing the pane hands that move over.
        probe.needsProcessState = false
        root.observer = probe
        let heardBeforeInterrupt = probe.heard.count
        root.send("\u{3}")
        t.expect(
            t.wait(until: { root.foregroundProgramName == shell }, timeout: 20),
            desc: "the host reports the shell \(shell) back: \(root.foregroundProgramName)"
        )
        t.pump(0.5)
        t.expect(
            probe.heard.count == heardBeforeInterrupt,
            desc: "declined again, the hidden pane holds the move: heard \(probe.heard.dropFirst(heardBeforeInterrupt))"
        )
        report(root, covered: false, pumpingWith: t)
        t.expect(
            t.wait(until: { probe.heard.dropFirst(heardBeforeInterrupt).contains(shell) }, timeout: 5),
            desc: "shown, the pane hands over the held move: heard \(probe.heard.dropFirst(heardBeforeInterrupt))"
        )
    }

    @MainActor
    private static func verifyHostedProcessAttribution(
        _ t: UBUITestContext,
        controller: TerminalWindowController,
        under root: String,
        shellCommand: String,
        reorderHostTabs: Bool,
        detachHostTab: Bool
    ) {
        guard #available(macOS 26.0, *), let firstWindow = controller.window,
            let first = controller.remoteSurface
        else {
            t.expect(false, desc: "the hosted process-title scenario requires the native glass tab strip")
            return
        }
        let markers = ["ALPHA", "BRAVO", "CHARLIE"]
        let programs = ["alpha-task", "bravo-task", "claude"]
        // The catalog keys Core resolves the host's programs to; the copy named
        // `claude` is Claude Code's, and the other two are in no catalog.
        let programKeys: [String?] = [nil, nil, "claude-code"]
        var members = [controller]
        var sessions: [UInt32] = []
        for index in markers.indices {
            if index != 0 {
                members[index - 1].newWindowForTab(nil)
                guard t.wait(until: { firstWindow.tabGroup?.windows.count == index + 1 }, timeout: 20),
                    let made = firstWindow.tabGroup?.windows.compactMap({ $0.windowController as? TerminalWindowController })
                        .first(where: { candidate in !members.contains(where: { $0 === candidate }) }),
                    t.wait(until: { made.remoteSurface?.drive.remoteState == .Connected }, timeout: 20)
                else {
                    t.expect(false, desc: "host tab \(index + 1) opens after the preceding tabs are connected")
                    return
                }
                members.append(made)
            }
            guard let pane = members[index].remoteSurface else { return }
            sessions.append(pane.remoteSessionID)
            if reorderHostTabs {
                pane.send("printf '\\033]0;\(markers[index])\\007\(markers[index])\\n'; read -r line\n")
            } else {
                let executable = root + "/" + programs[index]
                // Bash itself, not /bin/sh: sh hands its arguments to /bin/bash,
                // so a copy of it runs as the executable `bash`, which is the
                // name the host's foreground probe reads.
                do {
                    try FileManager.default.copyItem(atPath: "/bin/bash", toPath: executable)
                } catch {
                    t.expect(false, desc: "the named foreground fixture is copied (\(error))")
                    return
                }
                // macOS kills a copied platform binary at exec; an ad hoc
                // signature makes the copy an ordinary program under its own name.
                let sign = Process()
                sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                sign.arguments = ["--force", "--sign", "-", executable]
                try? sign.run()
                sign.waitUntilExit()
                guard sign.terminationStatus == 0 else {
                    t.expect(false, desc: "the named foreground fixture is signed (status \(sign.terminationStatus))")
                    return
                }
                pane.send("'\(executable)' -c 'printf \"\\033]0;\(markers[index])\\007\(markers[index])\\n\"; read -r line'\n")
            }
            guard
                t.wait(
                    until: {
                        (reorderHostTabs || pane.foregroundProgramName == programs[index])
                            && pane.gridTextForTesting().contains(markers[index])
                            && members[index].window?.tab.title.contains(markers[index]) == true
                    },
                    timeout: 20
                )
            else {
                t.expect(
                    false,
                    desc: "session \(pane.remoteSessionID) publishes \(programs[index]) and \(markers[index]); "
                        + "foreground \(pane.foregroundProgramName), grid \(pane.gridTextForTesting().contains(markers[index])), "
                        + "tab \(members[index].window?.tab.title ?? "missing")"
                )
                return
            }
            // The Kit's public values for a pane the host serves: the program
            // runs on the host, so nothing on this side could name it but the
            // host's report.
            if !reorderHostTabs {
                t.expect(pane.isRemoteAttached, desc: "tab \(index + 1)'s pane is served by the host")
                t.expect(
                    pane.foregroundProgramKey == programKeys[index],
                    desc: "the Kit keys tab \(index + 1)'s program as Core resolves the host's report: "
                        + "\(pane.foregroundProgramKey ?? "nil"), expected \(programKeys[index] ?? "nil")"
                )
                t.expect(
                    pane.foregroundProcessChain.contains(programs[index])
                        && pane.foregroundProcessChainWithArguments.contains(programs[index]),
                    desc: "the Kit's chains for tab \(index + 1) name the host's program: "
                        + "\(pane.foregroundProcessChain) / \(pane.foregroundProcessChainWithArguments)"
                )
            }
        }
        func icons(_ title: NSAttributedString?) -> [String] {
            guard let title else { return [] }
            var keys: [String] = []
            title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, _, _ in
                if let icon = value as? ProcessIconAttachment { keys.append(icon.key) }
            }
            return keys
        }
        func verify(_ phase: String, hostOrder: [Int] = [0, 1, 2]) {
            guard let group = firstWindow.tabGroup else {
                t.expect(false, desc: "the three tabs stay grouped \(phase)")
                return
            }
            let pills = TabStripStyling.tabPills(inGroupOf: firstWindow)
            let selected = TabStripStyling.pillContentsForTesting(inGroupOf: firstWindow)
            t.expect(
                pills.count == markers.count,
                desc: "one native pill belongs to each tab \(phase): \(pills.count) pills, \(group.windows.count) windows"
            )
            for index in markers.indices {
                let member = members[hostOrder[index]]
                let expectedTab = first.drive.remoteWorkspaceTab(of: first.drive.remoteWorkspaceSurface, at: index)
                let field = TabStripStyling.testTitleField(inGroupOf: firstWindow, at: index)
                let actual = field?.attributedStringValue
                let baked = member.window?.tab.attributedTitle
                t.expect(member.remoteWorkspaceTab == expectedTab, desc: "host tab identity \(index + 1) stays with its window \(phase)")
                t.expect(group.windows[index] === member.window, desc: "native tab order matches the host \(phase)")
                t.expect(
                    selected.indices.contains(index) && selected[index].isSelected == (group.selectedWindow === member.window),
                    desc: "the native selection belongs to tab \(index + 1) \(phase)"
                )
                t.expect(
                    member.remoteSurface?.remoteSessionID == sessions[hostOrder[index]],
                    desc: "session identity stays with tab \(index + 1) \(phase)"
                )
                if !reorderHostTabs {
                    t.expect(
                        member.remoteSurface?.foregroundProgramName == programs[hostOrder[index]],
                        desc: "the process belongs to tab \(index + 1) \(phase)"
                    )
                    t.expect(
                        member.remoteSurface?.foregroundProgramKey == programKeys[hostOrder[index]],
                        desc: "the program's catalog key belongs to tab \(index + 1) \(phase)"
                    )
                }
                t.expect(baked?.string.contains(markers[hostOrder[index]]) == true, desc: "tab \(index + 1) bakes its own title \(phase)")
                t.expect(
                    actual?.string.contains(markers[hostOrder[index]]) == true,
                    desc: "tab \(index + 1) displays its own title \(phase): \(actual?.string ?? "missing field")"
                )
                t.expect(icons(actual) == icons(baked), desc: "tab \(index + 1) displays its own process icon \(phase)")
                if !reorderHostTabs && hostOrder[index] == 2 {
                    t.expect(icons(baked) == ["claude-code"], desc: "the third process has its catalog icon")
                }
            }
        }
        t.pump(0.5)
        verify("after adding the third tab")
        if detachHostTab {
            guard let detached = members[2].window, let group = detached.tabGroup,
                let pane = members[2].remoteSurface
            else {
                t.expect(false, desc: "the hosted tab belongs to a native group before detaching")
                return
            }
            group.selectedWindow = detached
            t.pump(0.2)
            t.expect(titlebarWash(of: detached) != nil, desc: "the selected hosted tab has a themed titlebar band")
            detached.moveTabToNewWindow(nil)
            guard t.wait(until: { (detached.tabGroup?.windows.count ?? 1) == 1 }, timeout: 3) else {
                t.expect(false, desc: "AppKit has detached the hosted tab before extraction")
                return
            }
            t.pump(0.1)
            t.expect(
                titlebarWash(of: detached) != nil,
                desc: "the native tear-off keeps the themed titlebar band before host reconciliation"
            )
            let transfer = PaneTransferCoordinator.Transfer(controller: members[2], surface: pane, wholeTab: true)
            t.expect(PaneTransferCoordinator.shared.extract(transfer, newWindow: true), desc: "the host extracts the dragged tab")
            detached.makeKeyAndOrderFront(nil)
            t.expect(
                t.wait(until: { (detached.tabGroup?.windows.count ?? 1) == 1 }, timeout: 10),
                desc: "the detached hosted tab stands alone (\(detached.tabGroup?.windows.count ?? 1) windows)"
            )
            t.pump(0.4)
            t.expect(titlebarWash(of: detached) != nil, desc: "the detached hosted tab keeps its themed titlebar band")
            t.expect(
                titlebarStrip(of: detached).flatMap(titleField(in:))?.stringValue.contains(markers[2]) == true,
                desc: "the detached hosted tab's title stays in its own titlebar"
            )
            if let strip = titlebarStrip(of: detached), let field = titleField(in: strip),
                let zoom = detached.standardWindowButton(.zoomButton)
            {
                let titleFrame = field.convert(field.bounds, to: nil)
                let zoomFrame = zoom.convert(zoom.bounds, to: nil)
                t.expect(
                    titleFrame.minX >= zoomFrame.maxX,
                    desc: "the detached title clears the traffic lights (title \(titleFrame), zoom \(zoomFrame))"
                )
            } else {
                t.expect(false, desc: "the detached title and traffic lights are present")
            }
            return
        }
        if reorderHostTabs {
            let directory = HostDirectoryEndpoint(shellCommand: shellCommand)
            directory.refresh()
            guard t.wait(until: { directory.snapshot.phase == .Listed }, timeout: 20) else {
                t.expect(false, desc: "the private host lists its three tabs")
                return
            }
            let tab = HostOutlineIdentity(kind: .tab, number: UInt64(members[2].remoteWorkspaceTab.rawValue))
            let window = HostOutlineIdentity(kind: .window, number: UInt64(first.drive.remoteWorkspaceSurface.rawValue))
            t.expect(directory.moveTab(tab, toWindow: window, at: 0) != 0, desc: "the host accepts moving its last tab to the front")
            guard
                t.wait(
                    until: {
                        first.drive.remoteWorkspaceTab(of: first.drive.remoteWorkspaceSurface, at: 0) == members[2].remoteWorkspaceTab
                    },
                    timeout: 20
                )
            else {
                t.expect(false, desc: "the host publishes its changed tab order")
                return
            }
            t.pump(0.5)
            verify("after the host moved its last tab to the front", hostOrder: [2, 0, 1])
            for index in markers.indices {
                guard let window = members[[2, 0, 1][index]].window else { continue }
                t.expect(HostedTabScenarios.click(tabOf: window, t), desc: "host tab \(index + 1) has a clickable pill")
                t.expect(
                    t.wait(until: { firstWindow.tabGroup?.selectedWindow === window }, timeout: 3),
                    desc: "clicking host pill \(index + 1) selects its own window"
                )
            }
            return
        }
        let tabPills = TabStripStyling.tabPills(inGroupOf: firstWindow)
        if tabPills.count == 3, tabPills[1].button.superview === tabPills[2].button.superview,
            let secondField = TabStripStyling.testTitleField(inGroupOf: firstWindow, at: 1),
            let thirdField = TabStripStyling.testTitleField(inGroupOf: firstWindow, at: 2)
        {
            let secondFrame = tabPills[1].button.frame
            let thirdFrame = tabPills[2].button.frame
            let secondTitle = NSAttributedString(attributedString: secondField.attributedStringValue)
            let thirdTitle = NSAttributedString(attributedString: thirdField.attributedStringValue)
            // Native fields keep their owners while tab geometry is in transit.
            tabPills[1].button.setFrameOrigin(thirdFrame.origin)
            tabPills[2].button.setFrameOrigin(secondFrame.origin)
            TabStripStyling.restyleTitles(in: firstWindow)
            t.expect(
                secondField.attributedStringValue.isEqual(to: secondTitle),
                desc: "moving a field cannot give it another tab's title or icon"
            )
            t.expect(
                thirdField.attributedStringValue.isEqual(to: thirdTitle),
                desc: "the third field keeps its owner while positions disagree"
            )
            tabPills[1].button.frame = secondFrame
            tabPills[2].button.frame = thirdFrame
            TabStripStyling.restyleTitles(in: firstWindow)
        } else {
            t.expect(false, desc: "two native tab fields can be moved independently for the ownership check")
        }
        if let lastWindow = members.last?.window {
            lastWindow.setContentSize(NSSize(width: 1200, height: 700))
            t.pump(0.5)
            verify("after resizing")
        }
        for member in members {
            firstWindow.tabGroup?.selectedWindow = member.window
            member.window?.makeKeyAndOrderFront(nil)
            t.pump(0.5)
            verify("after selecting session \(member.remoteSurface?.remoteSessionID ?? 0)")
        }
    }

    @MainActor
    private static func run(
        _ t: UBUITestContext,
        usesQUIC: Bool = false,
        transfersOnly: Bool = false,
        progressOnly: Bool = false,
        directoryOnly: Bool = false,
        snapOnly: Bool = false,
        verbsOnly: Bool = false,
        zoomOnly: Bool = false,
        topInsetOnly: Bool = false,
        fullScreenOnly: Bool = false,
        titleBarsOnly: Bool = false,
        processAttributionOnly: Bool = false,
        processStateHoldOnly: Bool = false,
        reorderHostTabs: Bool = false,
        detachHostTab: Bool = false,
        linkDelayMilliseconds: ClosedRange<Int>? = nil
    ) {
        guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
            FileManager.default.isExecutableFile(atPath: hostBinary)
        else {
            t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
            return
        }
        // A home of its own, inherited by the daemon and by every attach the
        // app spawns, so nothing here touches the operator's daemon. Under
        // /tmp rather than the user's temporary directory: a Unix socket path
        // is capped at 103 bytes, and the daemon's socket lives in this home.
        let root = "/tmp/ubq-ui-" + String(UUID().uuidString.prefix(8))
        let home = root + "/.ubiquitty"
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
            return
        }
        let quotedHost = "'" + hostBinary.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let quotedHome = "'" + home.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let directAttach = "UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --attach"
        let attachCommand = linkDelayMilliseconds.map { delayedLink(directAttach, delayMilliseconds: $0) } ?? directAttach
        let bootstrapCommand = "sleep 0.1; UBIQUITTY_HOME=\(quotedHome) \(quotedHost) --quic-bootstrap"
        let previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        setenv("UBIQUITTY_HOME", home, 1)
        defer {
            if let previousHome {
                setenv("UBIQUITTY_HOME", previousHome, 1)
            } else {
                unsetenv("UBIQUITTY_HOME")
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: hostBinary)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        // ZDOTDIR too, so the panes' zsh reads none of the operator's startup
        // files: a program one of them starts holds the terminal, and what the
        // scenario types goes to it.
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home, "ZDOTDIR": home]) { $1 }
        do {
            try daemon.run()
        } catch {
            t.expect(false, desc: "the daemon started (\(error))")
            return
        }
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        let hasSocket = t.wait(
            until: {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
                return entries.contains { $0.hasPrefix("host-") && $0.hasSuffix(".sock") }
            },
            timeout: 20
        )
        t.expect(hasSocket, desc: "the daemon opened its socket")
        guard hasSocket else {
            return
        }

        // Opened under the rounded shape: a hosted root joins its window with
        // no pane layout, so the bar's lift has one place to come from, and
        // this window is the only kind that reaches it. The resize snap is off
        // by default; the snap leg opens its window with it on, as a reader
        // who has turned it on does. The top-inset leg sets the titleless
        // top inset more than a row above the titled one.
        let saved = t.configureAppending(
            "[security]\nclipboard_read = \"allow\"\n[appearance]\nsquare_bottom_corners = false\n"
                + (processAttributionOnly ? "process_icons = true\ntitlebar_style = \"themed\"\n" : "")
                + (snapOnly ? "snap_window_resize = true\n" : "")
                + (topInsetOnly ? "titleless_padding_top = 40\n" : "")
        )
        defer { t.restoreConfiguration(saved) }

        guard
            let window = TerminalWindowController.spawnRemoteWindow(
                shellCommand: attachCommand,
                hostLabel: "ui-test host",
                quicHost: usesQUIC ? "127.0.0.1" : "",
                quicBootstrapCommand: usesQUIC ? bootstrapCommand : "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: 0,
                workspaceName: "shared",
                hostKey: ""
            ),
            let rootSurface = window.remoteSurface
        else {
            t.expect(false, desc: "a remote window opened under a workspace name")
            return
        }
        defer { t.closeAllWindows() }

        let pendingAttach = TerminalWindowController.spawnRemoteWindow(
            shellCommand: attachCommand,
            hostLabel: "ui-test host",
            quicHost: usesQUIC ? "127.0.0.1" : "",
            quicBootstrapCommand: usesQUIC ? bootstrapCommand : "",
            deploySSHHost: "",
            deployBinaries: [:],
            reattachSessionID: 0,
            workspaceName: "shared",
            hostKey: ""
        )
        t.expect(pendingAttach === window, desc: "repeated connect before the first ACK reuses the pending workspace")

        // The root's bar learned the corner at birth, before any layout or
        // setting could have told it.
        let rootBar = rootSurface.subviews.compactMap { $0 as? TerminalScroller }.first
        t.expect(
            rootBar?.bottomInsetPoints == SquareBottomWindow.cornerRadiusInPoints,
            desc: "a hosted root born rounded lifts its bar off the corner (\(String(describing: rootBar?.bottomInsetPoints)))"
        )

        // Open: the host's one-pane projection reaches the window.
        t.expect(
            t.wait(
                until: { window.remotePaneSurfaces.count == 1 && window.remoteWorkspaceTab != Ubiquitty.Session.Layout.invalidTab },
                timeout: 20
            ),
            desc: "the window projected the workspace's one pane on attach"
        )
        t.expect(rootSurface.drive.isRemoteUsingQUIC == usesQUIC, desc: "Swift selects the requested native carrier")
        let rootPane = rootSurface.drive.remoteWorkspacePane
        let surface = rootSurface.drive.remoteWorkspaceSurface
        t.expect(
            window.remotePaneSurfaces[rootPane] === rootSurface,
            desc: "the attached surface is the pane the host bound its session to"
        )

        if progressOnly {
            verifyHostedProgress(t, controller: window, root: rootSurface)
            return
        }
        if directoryOnly {
            verifyHostedDirectory(t, controller: window, root: rootSurface, under: root)
            return
        }
        if snapOnly {
            verifyHostedSnap(t, controller: window, root: rootSurface)
            return
        }
        if verbsOnly {
            verifyHostedPaneVerbs(t, controller: window, root: rootSurface)
            return
        }
        if zoomOnly {
            verifyHostedZoom(t, window: window, root: rootSurface, under: root)
            return
        }
        if topInsetOnly {
            verifyHostedTopInset(t, controller: window)
            return
        }
        if fullScreenOnly {
            verifyHostedFullScreenSettle(t, controller: window)
            return
        }
        if titleBarsOnly {
            verifyHostedPaneTitleBars(t, controller: window)
            return
        }
        if processStateHoldOnly {
            verifyHostedProcessStateHold(t, root: rootSurface)
            return
        }
        if processAttributionOnly {
            verifyHostedProcessAttribution(
                t,
                controller: window,
                under: root,
                shellCommand: attachCommand,
                reorderHostTabs: reorderHostTabs,
                detachHostTab: detachHostTab
            )
            return
        }

        let workspaceIdentity = rootSurface.drive.remoteWorkspaceID
        let windowTitle = { window.window?.title ?? "" }
        let wovenWindowTitles = { window.wovenWindowTitlesForTesting }
        let spacedSeparator = String(Ubiquitty.Title.titleSeparatorText(Ubiquitty.PAL.Process.TitleSeparator.Spaced))
        // Keep the reporting process alive while checking its title; returning
        // to the shell legitimately retires a finished program's OSC title.
        rootSurface.send("sh -c 'printf \"\\033]0;Hosted title\\007\"; read -r line'\n")
        t.expect(
            t.wait(until: { windowTitle().contains("Hosted title") }, timeout: 20),
            desc: "the window title follows the hosted session rather than the host label (\(windowTitle()))"
        )
        t.expect(
            t.wait(
                until: {
                    guard let woven = wovenWindowTitles() else { return false }
                    return windowTitle() == woven.system && woven.system.contains(spacedSeparator)
                },
                timeout: 20
            ),
            desc: "the hosted system window title uses Core's spaced weave (\(windowTitle()))"
        )
        // The title row is styled as a local window's is. Its compact Core
        // weave gets visible separator gaps and a dimmed directory from the
        // styled field, which keys on the pane the title speaks for; a hosted
        // window holds no local pane.
        // The field is found when it is there to read: the strip lays its
        // field out on its own pass after the title lands. It composes the
        // dimensions after the title and the live connection before it. Locate
        // the exact woven title rather than treating the host attachment as
        // the directory's text or colour run.
        let styledField = { window.window.flatMap(titlebarStrip(of:)).flatMap(titleField(in:)) }
        let styledTitle = { styledField()?.attributedStringValue ?? NSAttributedString() }
        if t.wait(
            until: {
                guard let woven = wovenWindowTitles(), !woven.row.isEmpty else { return false }
                return window.rowTitleTextForTesting == woven.row
                    && styledTitle().string.contains(woven.row)
                    && styledTitle().string.contains("\u{2014}")
            },
            timeout: 20
        ),
            let field = styledField(),
            let woven = wovenWindowTitles()
        {
            let styled = styledTitle()
            let text = styled.string as NSString
            var dashes = 0
            var kernedDashes = 0
            var index = 0
            while index < text.length {
                let dash = text.range(of: "\u{2014}", options: [], range: NSRange(location: index, length: text.length - index))
                guard dash.location != NSNotFound else { break }
                if dash.location > 0, NSMaxRange(dash) < text.length {
                    dashes += 1
                    let before = styled.attribute(.kern, at: dash.location - 1, effectiveRange: nil) as? CGFloat ?? 0
                    let after = styled.attribute(.kern, at: dash.location, effectiveRange: nil) as? CGFloat ?? 0
                    if before > 0, after > 0 { kernedDashes += 1 }
                }
                index = NSMaxRange(dash)
            }
            t.expect(
                dashes > 0 && kernedDashes == dashes,
                desc:
                    "every separator in the hosted window's title row is spaced by the kern rule (\(kernedDashes) of \(dashes) in \(text))"
            )
            // The runs wear their own ink and faces: the directory dimmed in the
            // medium directory face, the title bright, each dash in the detail
            // colour, the dimensions in the lighter, smaller status face.
            let wovenTitle = text.range(of: woven.row)
            let firstDash =
                wovenTitle.location == NSNotFound
                ? NSRange(location: NSNotFound, length: 0)
                : text.range(of: "\u{2014}", options: [], range: wovenTitle)
            let lastDash = text.range(of: "\u{2014}", options: .backwards)
            if firstDash.location != NSNotFound, lastDash.location != NSNotFound, lastDash.location > firstDash.location {
                let weightOf = { (font: NSFont?) -> CGFloat? in
                    (font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
                }
                let directoryColor = styled.attribute(.foregroundColor, at: wovenTitle.location, effectiveRange: nil) as? NSColor
                let directoryFont = styled.attribute(.font, at: wovenTitle.location, effectiveRange: nil) as? NSFont
                let titleColor = styled.attribute(.foregroundColor, at: firstDash.location + 1, effectiveRange: nil) as? NSColor
                let dashColor = styled.attribute(.foregroundColor, at: firstDash.location, effectiveRange: nil) as? NSColor
                let statusFont = styled.attribute(.font, at: lastDash.location + 1, effectiveRange: nil) as? NSFont
                let titleFont = field.font
                t.expect(
                    directoryColor != nil && titleColor != nil && directoryColor != titleColor,
                    desc:
                        "the directory run is dimmed against the bright title (\(String(describing: directoryColor)) vs \(String(describing: titleColor)))"
                )
                t.expect(
                    dashColor != nil && dashColor != titleColor,
                    desc: "the separator wears the detail colour, not the title's"
                )
                t.expect(
                    directoryFont != nil && titleFont != nil && weightOf(directoryFont) != weightOf(titleFont),
                    desc:
                        "the directory run is set in its own weight (\(String(describing: weightOf(directoryFont))) vs \(String(describing: weightOf(titleFont))))"
                )
                t.expect(
                    statusFont != nil && titleFont != nil && statusFont!.pointSize < titleFont!.pointSize,
                    desc:
                        "the dimensions run wears the smaller status face (\(String(describing: statusFont?.pointSize)) vs \(String(describing: titleFont?.pointSize)))"
                )
            } else {
                t.expect(false, desc: "the composed row has a directory, a title and a dimensions run to compare (\(text))")
            }
        } else {
            t.expect(
                false,
                desc:
                    "the hosted window's title field carries Core's compact weave (\(styledTitle().string) for \(wovenWindowTitles()?.row ?? ""))"
            )
        }
        rootSurface.send("\n")
        let repeated = TerminalWindowController.spawnRemoteWindow(
            shellCommand: attachCommand,
            hostLabel: "ui-test host",
            quicHost: usesQUIC ? "127.0.0.1" : "",
            quicBootstrapCommand: usesQUIC ? bootstrapCommand : "",
            deploySSHHost: "",
            deployBinaries: [:],
            reattachSessionID: rootSurface.remoteSessionID,
            workspaceName: "shared",
            hostKey: ""
        )
        t.expect(
            repeated === window,
            desc: "connecting to an already projected session focuses its existing window"
        )
        t.expect(rootSurface.canChangeClipboardServing, desc: "negotiated host exposes clipboard source selection")
        t.expect(rootSurface.setClipboardServing(false), desc: "remote clipboard source can be selected")
        t.expect(!rootSurface.isServingClipboardToHost, desc: "revocation stops local serving before its acknowledgement")
        t.expect(rootSurface.setClipboardServing(true), desc: "local clipboard source can be requested")
        t.expect(
            t.wait(until: { rootSurface.isServingClipboardToHost && !rootSurface.isClipboardRoutingPending }, timeout: 10),
            desc: "local clipboard becomes effective after the host acknowledgement"
        )
        t.expect(rootSurface.setClipboardServing(false), desc: "local clipboard serving can be revoked again")
        t.expect(
            t.wait(until: { !rootSurface.isServingClipboardToHost && !rootSurface.isClipboardRoutingPending }, timeout: 10),
            desc: "a stale enable acknowledgement cannot undo the selected remote source"
        )

        rootSurface.send("printf 'remote-history-line\\n%.0s' {1..120}; printf 'REMOTE-HISTORY-READY\\n'\n")
        // Sync mirrors a screen of history eagerly and pulls older rows on scroll.
        t.expect(
            t.wait(
                until: {
                    let snapshot = rootSurface.drive.readSnapshot()
                    return snapshot.rows > 0 && snapshot.scrollbackCount >= 100
                        && rootSurface.gridTextForTesting().contains("REMOTE-HISTORY-READY")
                },
                timeout: 10
            ),
            desc:
                "host history reaches the remote mirror before wheel input "
                + "(\(rootSurface.drive.readSnapshot().scrollbackCount) history rows, \(rootSurface.drive.readSnapshot().rows) visible rows)"
        )
        let makeWheel = { () -> NSEvent? in
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0)
            else { return nil }
            return NSEvent(cgEvent: event)
        }
        if let wheel = makeWheel() {
            rootSurface.scrollWheel(with: wheel)
            t.expect(
                t.wait(until: { rootSurface.viewOffset > 0 }, timeout: 5),
                desc:
                    "remote primary-screen wheel reaches mirrored history (offset \(rootSurface.viewOffset), history \(rootSurface.drive.readSnapshot().scrollbackCount))"
            )
            t.pump(0.2)
            t.expect(
                t.wait(until: { rootSurface.drive.readSnapshot().scrollbackCount > 60 }, timeout: 10),
                desc: "scrolling pulls older host history into the remote mirror"
            )
            rootSurface.send("printf '\\033[?1049h\\033[?1007l'\n")
            t.expect(
                t.wait(until: { rootSurface.drive.readSnapshot().modes.alternateScreenActive }, timeout: 10),
                desc: "host alternate-screen state reaches the remote input route"
            )
            guard let alternateWheel = makeWheel() else {
                t.expect(false, desc: "a remote alternate-screen wheel event can be created")
                return
            }
            rootSurface.scrollWheel(with: alternateWheel)
            t.pump(0.2)
            t.expect(rootSurface.viewOffset == 0, desc: "remote alternate screen cannot expose primary history")
            t.expect(rootSurface.verticalOverscroll == 0, desc: "remote alternate screen does not bounce")
            rootSurface.send("printf '\\033[?1049lPRIMARY-READY'; read -r _\n")
            t.expect(
                t.wait(
                    until: {
                        let snapshot = rootSurface.drive.readSnapshot()
                        return !snapshot.modes.alternateScreenActive
                            && Ubiquitty.Runtime.viewOffsetLimit(snapshot) > 0
                            && rootSurface.gridTextForTesting().contains("PRIMARY-READY")
                    },
                    timeout: 10
                ),
                desc: "host return to primary screen reaches the remote mirror"
            )
            guard let returnWheel = makeWheel() else {
                t.expect(false, desc: "a remote primary-screen wheel event can be created")
                return
            }
            rootSurface.scrollWheel(with: returnWheel)
            t.expect(
                t.wait(until: { rootSurface.viewOffset > 0 }, timeout: 5),
                desc:
                    "remote history remains reachable after leaving alternate screen "
                    + "(offset \(rootSurface.viewOffset), limit \(Ubiquitty.Runtime.viewOffsetLimit(rootSurface.drive.readSnapshot())))"
            )
            rootSurface.send("\n")
        } else {
            t.expect(false, desc: "a remote scroll wheel event can be created")
        }

        // Split over the wire: the host mints a pane and a session, and the
        // window mirrors the split with a view attached to that session.
        let beforeSplitGeneration = rootSurface.drive.remoteWorkspaceMirrorGeneration
        window.splitRight(nil)
        t.expect(
            t.wait(until: { window.remotePaneSurfaces.count == 2 }, timeout: 20),
            desc: "a split sent over the wire came back as a second pane"
        )
        let split = window.paneHost.subviews.compactMap { $0 as? NSSplitView }.first
        t.expect(split?.arrangedSubviews.count == 2 && split?.isVertical == true, desc: "the window mirrors the host's column split")
        guard let sibling = window.remotePaneSurfaces.first(where: { $0.key != rootPane })?.value else {
            t.expect(false, desc: "the new pane has a view")
            return
        }
        t.expect(
            t.wait(until: { sibling.drive.remoteState == .Connected && sibling.remoteSessionID != 0 }, timeout: 20)
                && sibling.remoteSessionID != rootSurface.remoteSessionID,
            desc:
                "the new pane's view is attached to a session of its own (\(sibling.remoteSessionID) beside \(rootSurface.remoteSessionID))"
        )
        t.expect(
            t.wait(until: { window.window?.firstResponder === sibling }, timeout: 10),
            desc: "focus followed the host to the new pane"
        )

        t.expect(
            sibling.drive.sharesRemoteWorkspaceConnection(with: rootSurface.drive),
            desc: "split panes retain one Core workspace connection"
        )

        // Exercise the same completion called by the delayed drag callback,
        // with an intent captured before the split and after a surface switch.
        let dividerTree = rootSurface.drive.remoteWorkspacePaneTreeSnapshot(of: surface, tab: window.remoteWorkspaceTab)
        let dividerIndex = dividerTree.root()
        let currentGeneration = rootSurface.drive.remoteWorkspaceMirrorGeneration
        t.expect(
            beforeSplitGeneration != 0 && currentGeneration != beforeSplitGeneration,
            desc: "new topology retires the earlier divider generation"
        )
        window.pendingRemoteDivider = (rootSurface, beforeSplitGeneration, dividerIndex, 0.25)
        t.expect(
            !window.finishRemoteDividerRatio(surface: rootSurface, generation: beforeSplitGeneration, splitIndex: dividerIndex)
                && window.pendingRemoteDivider == nil,
            desc: "a stale delayed drag does not reinterpret its node index in the newer tree"
        )
        let originalRemoteSurface = window.remoteSurface
        window.pendingRemoteDivider = (rootSurface, currentGeneration, dividerIndex, 0.25)
        window.remoteSurface = sibling
        t.expect(
            !window.finishRemoteDividerRatio(surface: rootSurface, generation: currentGeneration, splitIndex: dividerIndex)
                && window.pendingRemoteDivider == nil,
            desc: "a delayed drag cannot transfer its command to another surface on the shared connection"
        )
        window.remoteSurface = originalRemoteSurface

        verifyPaneHeaders(t, window: window, root: rootSurface, sibling: sibling)
        verifyPaneHeaderTags(t, window: window, root: rootSurface, sibling: sibling)
        let settledSplit = rootSurface.drive.remoteWorkspacePaneTreeSnapshot(of: surface, tab: window.remoteWorkspaceTab)
        t.expect(
            abs(settledSplit.node(settledSplit.root()).ratio - 0.5) < 0.001,
            desc: "focus and asynchronous pane resizes preserve the host's equal divider ratio"
        )

        if transfersOnly {
            let coordinator = PaneTransferCoordinator.shared
            let sessionID = rootSurface.remoteSessionID
            let paneTransfer = PaneTransferCoordinator.Transfer(controller: window, surface: rootSurface, wholeTab: false)
            t.expect(coordinator.extract(paneTransfer, newWindow: true), desc: "the host accepts extracting the anchor pane to a window")
            var detached: TerminalWindowController?
            t.expect(
                t.wait(
                    until: {
                        detached = TerminalWindowController.spawnedControllers.first { candidate in
                            candidate !== window && candidate.remotePaneSurfaces.values.contains { $0 === rootSurface }
                        }
                        return detached != nil && window.remotePaneSurfaces.count == 1
                    },
                    timeout: 20
                ),
                desc: "the source keeps its tab identity while the anchor pane gets a window"
            )
            guard let detached else { return }
            defer { detached.window?.close() }
            t.expect((detached.window?.tabGroup?.windows.count ?? 1) == 1, desc: "the extracted Sync pane is a standalone window")
            t.expect(rootSurface.remoteSessionID == sessionID, desc: "extraction preserves the Sync session identity")
            let tabTransfer = PaneTransferCoordinator.Transfer(controller: detached, surface: rootSurface, wholeTab: true)
            if let sourceWindow = detached.window, let targetWindow = window.window {
                targetWindow.addTabbedWindow(sourceWindow, ordered: .above)
            }
            t.expect(
                coordinator.move(tabTransfer, to: window, target: sibling, placement: .tab),
                desc: "the host accepts a native tab drop after AppKit has already grouped its windows"
            )
            t.expect(
                t.wait(
                    until: {
                        detached.window?.tabGroup === window.window?.tabGroup
                            && rootSurface.drive.remoteWorkspaceSurface == sibling.drive.remoteWorkspaceSurface
                    },
                    timeout: 20
                ),
                desc: "the native group and host agree on the destination window"
            )
            window.splitRight(nil)
            t.expect(t.wait(until: { window.remotePaneSurfaces.count == 2 }, timeout: 20), desc: "the destination has two existing panes")
            t.expect(
                coordinator.move(tabTransfer, to: window, target: sibling, placement: .below, insertTarget: .Root),
                desc: "the host moves the tab below the complete destination layout"
            )
            t.expect(
                t.wait(until: { window.remotePaneSurfaces.count == 3 && detached.isClosedForTesting }, timeout: 20),
                desc: "the empty tab closes and all sessions survive"
            )
            let tree = rootSurface.drive.remoteWorkspacePaneTreeSnapshot(
                of: rootSurface.drive.remoteWorkspaceSurface,
                tab: window.remoteWorkspaceTab
            )
            let split = tree.node(tree.root())
            t.expect(
                split.orientation == .Horizontal && !tree.isLeaf(split.first) && tree.isLeaf(split.second),
                desc: "Sync preserves the existing pair above the incoming pane"
            )
            t.expect(window.remotePaneSurfaces.values.contains { $0 === rootSurface }, desc: "the moved pane keeps its view")
            t.expect(
                rootSurface.remoteSessionID == sessionID && rootSurface.drive.remoteState == .Connected,
                desc: "the moved session remains connected"
            )
            return
        }

        // A new tab: asked of the host, answered by a layout, opened as a tab window.
        window.newWindowForTab(nil)
        t.expect(
            t.wait(until: { (window.window?.tabGroup?.windows.count ?? 0) == 2 }, timeout: 20),
            desc: "a tab added on the host opened a tab window in the group"
        )
        t.expect(rootSurface.drive.remoteWorkspaceTabCount(of: surface) == 2, desc: "the host holds two tabs")
        // A hosted tab's title is the host's: asked over Sync, held once the
        // host's layout says so, and read from that layout, never cached here.
        let originalTitle = window.customTabTitle
        window.setCustomTitles(tab: "Build — 日本語")
        t.expect(window.customTabTitle == originalTitle, desc: "renaming waits for the authoritative host layout")
        t.expect(
            t.wait(until: { window.customTabTitle == "Build — 日本語" }, timeout: 10),
            desc: "the host's custom tab title reaches the native window"
        )
        t.expect(
            rootSurface.drive.remoteWorkspaceTabTitle(of: surface, tab: window.remoteWorkspaceTab) == "Build — 日本語",
            desc: "the portable mirror and native tab show the same name"
        )
        let hostedTabLabel = { window.window?.tab.title ?? "" }
        t.expect(
            t.wait(until: { hostedTabLabel().contains("Build — 日本語") }, timeout: 10),
            desc: "the tab's label follows the host's layout (\(hostedTabLabel()))"
        )

        // The window's name is this Mac's: Sync carries a tab's title and no
        // window's. It fills the window's title at once and leaves the host's
        // tab title where it is.
        window.setCustomTitles(window: "Local window name")
        t.expect(
            window.customWindowTitle == "Local window name" && (window.window?.title ?? "").contains("Local window name"),
            desc: "a hosted window's own name is held locally and shown at once (\(window.window?.title ?? ""))"
        )
        t.expect(
            window.customTabTitle == "Build — 日本語" && !hostedTabLabel().contains("Local window name"),
            desc: "the host's tab title stands apart from the window's name (\(hostedTabLabel()))"
        )

        // Cleared on the host, the tab follows the window's name until it is
        // named again; cleared here, the window is automatic again at once.
        window.setCustomTitles(tab: "")
        t.expect(
            t.wait(until: { window.customTabTitle.isEmpty && hostedTabLabel().contains("Local window name") }, timeout: 10),
            desc: "a tab the host no longer names follows its window's name (\(hostedTabLabel()))"
        )
        window.setCustomTitles(window: "")
        t.expect(
            !(window.window?.title ?? "").contains("Local window name") && !hostedTabLabel().contains("Local window name"),
            desc: "empty is automatic again for the window and the tab that followed it (\(hostedTabLabel()))"
        )
        t.expect(rootSurface.drive.remoteWorkspaceRename("Renamed Workspace"), desc: "the workspace rename is sent to the host")
        t.expect(
            t.wait(until: { window.remoteWorkspaceName == "Renamed Workspace" }, timeout: 10),
            desc: "workspace rename updates the window's reconnect metadata"
        )
        let tabWeight: (NSWindow) -> Int = { tabWindow in
            guard let baked = tabWindow.tab.attributedTitle, baked.length > 0,
                let font = baked.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            else { return -1 }
            return NSFontManager.shared.weight(of: font)
        }
        t.expect(
            t.wait(
                until: {
                    guard let group = window.window?.tabGroup, let selected = group.selectedWindow else { return false }
                    let others = group.windows.filter { $0 !== selected }
                    return !others.isEmpty && others.allSatisfy { tabWeight($0) >= 0 && tabWeight($0) < tabWeight(selected) }
                },
                timeout: 20
            ),
            desc: "the selected host tab alone is baked as selected"
        )

        // A theme applied to every open window reaches the hosted session
        // through its host, so two applies move the mirror's palette twice.
        // A hidden tab is Dormant and receives no palette block until revealed.
        window.activateRemotePane(rootSurface)
        guard t.wait(until: { window.window?.tabGroup?.selectedWindow === window.window && rootSurface.isRemotePaneShown }, timeout: 10)
        else {
            t.expect(false, desc: "the palette assertion reads the selected, live remote pane")
            return
        }
        let unthemed = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            t.restoreConfiguration(unthemed)
            TerminalWindowController.applyThemeToOpenWindows()
        }
        var foregrounds: [UInt32] = []
        for name in ["One Dark", "One Light"] {
            let before = window.themeForeground(of: rootSurface)
            t.restoreConfiguration(unthemed)
            t.configureAppending("[appearance]\ntheme = \(tomlQuoted(name))\n")
            TerminalWindowController.applyThemeToOpenWindows()
            t.expect(
                t.wait(until: { window.themeForeground(of: rootSurface) != before }, timeout: 20),
                desc: "the \(name) theme reaches the hosted session through the host"
            )
            foregrounds.append(window.themeForeground(of: rootSurface))
        }
        t.expect(foregrounds.count == 2 && foregrounds[0] != foregrounds[1], desc: "the two themes give the mirror two palettes")

        // A pane whose shell exits: the host ends its session and drops the
        // pane, and the window follows the layout that dropped it.
        sibling.send("exit\r")
        t.expect(
            t.wait(
                until: { window.remotePaneSurfaces.count == 1 && rootSurface.isDescendant(of: window.paneHost) },
                timeout: 20
            ),
            desc:
                "a pane whose session ended left the window with the host's next layout "
                + "(panes \(window.remotePaneSurfaces.count), root in pane host \(rootSurface.isDescendant(of: window.paneHost)))"
        )
        t.expect(window.window?.isVisible == true, desc: "the window stayed, one pane again")

        window.splitRight(nil)
        t.expect(t.wait(until: { window.remotePaneSurfaces.count == 2 }, timeout: 20), desc: "the root tab can split again")
        guard let survivor = window.remotePaneSurfaces.first(where: { $0.value !== rootSurface })?.value else {
            t.expect(false, desc: "the root has a surviving sibling")
            return
        }
        t.expect(
            t.wait(
                until: {
                    survivor.drive.remoteState == .Connected && survivor.remoteSessionID != 0 && window.window?.firstResponder === survivor
                },
                timeout: 20
            ),
            desc: "the surviving sibling is attached and focused"
        )
        guard let rootClose = paneCloseButton(rootSurface.drive.remoteWorkspacePane, in: window.paneHost) else {
            t.expect(false, desc: "the initial remote pane has a close button")
            return
        }
        rootClose.performClick(nil)
        t.expect(
            t.wait(until: { window.remoteSurface === survivor && window.remotePaneSurfaces.count == 1 }, timeout: 20),
            desc: "closing the initial pane from its header promotes its surviving sibling"
        )
        t.expect(window.window?.firstResponder === survivor, desc: "anchor promotion preserves the active pane")
        t.expect(survivor.drive.remoteWorkspaceID == workspaceIdentity, desc: "workspace identity survives its initial session")
        window.deliverRemoteEventsForTesting(layout: rootSurface)
        window.deliverRemoteEventsForTesting(exit: rootSurface)
        window.deliverRemoteEventsForTesting(layout: survivor)
        t.expect(
            window.remoteSurface === survivor && window.window?.isVisible == true,
            desc: "late layout and duplicate exit cannot replace the surviving anchor"
        )

        window.splitRight(nil)
        t.expect(t.wait(until: { window.remotePaneSurfaces.count == 2 }, timeout: 20), desc: "the surviving anchor can split")
        guard let extra = window.remotePaneSurfaces.first(where: { $0.value !== survivor }),
            let extraClose = paneCloseButton(extra.key, in: window.paneHost)
        else {
            t.expect(false, desc: "the non-anchor pane has a close button")
            return
        }
        window.activateRemotePane(survivor)
        extraClose.performClick(nil)
        t.expect(
            t.wait(until: { window.remotePaneSurfaces.count == 1 && window.remoteSurface === survivor }, timeout: 20),
            desc: "a background pane's header closes that pane without closing the focused anchor"
        )

        // A targeted tab close changes only that tab, unlike Close Window.
        guard let tabWindow = window.window?.tabGroup?.windows.first(where: { $0 !== window.window }),
            let closingTab = tabWindow.windowController as? TerminalWindowController
        else {
            t.expect(false, desc: "the tab window is in the group")
            return
        }
        tabWindow.performClose(nil)
        guard t.wait(until: { tabWindow.attachedSheet != nil }, timeout: 3),
            let tabClose = sheetButton("Close Tab", in: tabWindow.attachedSheet),
            let tabCancel = sheetButton("Cancel", in: tabWindow.attachedSheet)
        else {
            t.expect(false, desc: "the native tab close offers Close Tab")
            return
        }
        tabCancel.performClick(nil)
        t.expect(t.wait(until: { tabWindow.attachedSheet == nil }, timeout: 3), desc: "Cancel leaves both tabs attached")
        guard t.wait(until: { closingTab.remoteSurface?.drive.pendingRemoteWindowCloseToken == 0 }, timeout: 3) else {
            t.expect(false, desc: "Cancel consumes the first captured close before another is prepared")
            return
        }
        t.expect(survivor.drive.remoteWorkspaceTabCount(of: surface) == 2, desc: "cancelling closes no host tab")
        tabClose.performClick(nil)
        t.expect(!closingTab.isClosedForTesting, desc: "a cancelled close button cannot be reused")
        tabWindow.performClose(nil)
        guard t.wait(until: { tabWindow.attachedSheet != nil }, timeout: 3),
            let confirmedTabClose = sheetButton("Close Tab", in: tabWindow.attachedSheet)
        else {
            t.expect(false, desc: "closing again offers a fresh tab close choice")
            return
        }
        guard confirmedTabClose.isEnabled && closingTab.remoteSurface?.drive.pendingRemoteWindowCloseToken != 0 else {
            t.expect(false, desc: "the second close choice owns a current host tab")
            return
        }
        confirmedTabClose.performClick(nil)
        t.expect(
            t.wait(
                until: { survivor.drive.remoteWorkspaceTabCount(of: surface) == 1 && closingTab.isClosedForTesting },
                timeout: 20
            ),
            desc:
                "closing the host tab closes its native projection "
                + "(tabs \(survivor.drive.remoteWorkspaceTabCount(of: surface)), closed \(closingTab.isClosedForTesting), "
                + "outcome \(String(describing: closingTab.remoteSurface?.drive.remoteWorkspaceCloseOutcome)))"
        )
        t.expect((window.window?.tabGroup?.windows.count ?? 1) == 1, desc: "one window is left in the group")
        t.expect(
            !window.isClosedForTesting && window.remoteSurface === survivor && survivor.drive.remoteState == .Connected,
            desc: "closing another host tab preserves the requesting window and its connected pane"
        )

        t.expect(survivor.drive.remoteWorkspaceAddTab(), desc: "the surviving tab can create a sibling")
        t.expect(t.wait(until: { (window.window?.tabGroup?.windows.count ?? 1) == 2 }, timeout: 20), desc: "the new tab is projected")
        guard
            let lastPaneTab = window.window?.tabGroup?.windows
                .first(where: { $0 !== window.window })?
                .windowController as? TerminalWindowController
        else {
            t.expect(false, desc: "the new tab has its own controller")
            return
        }
        t.expect(
            t.wait(until: { lastPaneTab.remoteSurface?.drive.remoteState == .Connected }, timeout: 20),
            desc: "the last pane is attached before its close action"
        )
        lastPaneTab.closePane(nil)
        t.expect(
            t.wait(until: { lastPaneTab.isClosedForTesting && survivor.drive.remoteWorkspaceTabCount(of: surface) == 1 }, timeout: 20),
            desc: "Close Pane ends only the last pane's tab, without a whole-window choice"
        )
        t.expect(
            !window.isClosedForTesting && survivor.drive.remoteState == .Connected,
            desc: "the sibling stays attached after last-pane close"
        )

        let previousApplication = NSWorkspace.shared.frontmostApplication
        defer {
            if !WindowContainment.isOffscreen, let previousApplication,
                previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier
            {
                previousApplication.activate(options: [])
            }
        }
        window.window?.makeFirstResponder(survivor)
        let localWindowItem = NSMenuItem(
            title: "New Local Window",
            action: #selector(TerminalWindowController.newWindow(_:)),
            keyEquivalent: "n"
        )
        let previousControllers = Set(TerminalWindowController.spawnedControllers.map { ObjectIdentifier($0) })
        let previousRemoteWindows = survivor.drive.remoteWorkspaceSurfaceCount
        t.expect(window.validateMenuItem(localWindowItem), desc: "New Local Window stays enabled while a remote workspace is active")
        t.expect(
            survivor.tryToPerform(#selector(TerminalWindowController.newWindow(_:)), with: localWindowItem),
            desc: "New Local Window reaches the controller through the remote pane's responder chain"
        )
        guard
            let localWindow = TerminalWindowController.spawnedControllers.first(where: {
                !previousControllers.contains(ObjectIdentifier($0)) && !$0.isClosedForTesting
            })
        else {
            t.expect(false, desc: "New Local Window creates a separate local window")
            return
        }
        t.expect(localWindow.remoteSurface == nil, desc: "New Local Window does not inherit the remote workspace")
        t.expect(localWindow.focusedSurfaceForTesting?.drive.isRemoteAttached == false, desc: "the new window owns a local session")
        t.expect(
            survivor.drive.remoteWorkspaceSurfaceCount == previousRemoteWindows,
            desc: "opening a local window leaves remote topology unchanged"
        )
        let remoteWindowItem = NSMenuItem(
            title: "New Window on stale host",
            action: #selector(TerminalWindowController.newRemoteWorkspaceWindow(_:)),
            keyEquivalent: ""
        )
        t.expect(!localWindow.validateMenuItem(remoteWindowItem), desc: "a local window cannot create a remote workspace window")
        t.expect(remoteWindowItem.isHidden, desc: "a local window hides the remote command")
        t.expect(remoteWindowItem.title == "New Window on Remote Host", desc: "leaving the remote workspace clears its menu label")
        localWindow.shellCloseWindow()

        window.window?.makeFirstResponder(survivor)
        // Closing/re-grouping native tabs can send several viewport sizes.
        // A real hosted echo fences those transitions before this success-path
        // action; the Core suite separately pins a stale request's refusal.
        window.window?.contentView?.layoutSubtreeIfNeeded()
        let readySuffix = UUID().uuidString
        survivor.send("printf '\\n%s%s\\n' 'window-ready-' '\(readySuffix)'\n")
        t.expect(
            t.wait(until: { survivor.gridTextForTesting().contains("window-ready-\(readySuffix)") }, timeout: 10),
            desc: "the host answers after the native tab and window transitions"
        )
        // Both requests use the current mirror before the event loop can
        // receive the rename's newer revision. The second must be refused.
        t.expect(survivor.drive.remoteWorkspaceRename("Refusal fixture"), desc: "the first request changes the host revision")
        t.expect(survivor.drive.remoteWorkspaceAddSurface(), desc: "the old-revision window request is sent once")
        guard t.wait(until: { window.window?.attachedSheet != nil }, timeout: 10),
            let refusal = window.window?.attachedSheet,
            let acknowledgeRefusal = sheetButton("OK", in: refusal)
        else {
            t.expect(false, desc: "the refused window request presents a native notice")
            return
        }
        t.pump(0.2)
        t.expect(window.window?.sheets.count == 1, desc: "the correlated refusal presents exactly one notice")
        t.expect(survivor.drive.remoteWorkspaceSurfaceCount == previousRemoteWindows, desc: "a stale request creates no host window")
        acknowledgeRefusal.performClick(nil)
        t.expect(t.wait(until: { window.window?.attachedSheet == nil }, timeout: 3), desc: "the refusal notice can be dismissed")
        t.pump(0.2)
        t.expect(window.window?.attachedSheet == nil, desc: "later workspace events do not repeat the settled refusal")
        t.expect(
            survivor.drive.remoteWorkspaceSurfaceCount == previousRemoteWindows,
            desc: "dismissing the refusal does not retry the mutation"
        )
        let newWindowItem = remoteWindowItem
        t.expect(window.validateMenuItem(newWindowItem), desc: "remote window creation is enabled for a connected workspace")
        t.expect(!newWindowItem.isHidden, desc: "the connected workspace restores its remote command")
        t.expect(
            newWindowItem.title == "New Window on \(window.remoteHostLabel)",
            desc: "the remote command names the connection it will use"
        )
        if WindowContainment.isOffscreen {
            t.expect(
                survivor.tryToPerform(#selector(TerminalWindowController.newRemoteWorkspaceWindow(_:)), with: newWindowItem),
                desc: "the remote-window command traverses the active pane's responder chain under offscreen containment"
            )
        } else {
            window.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard
                t.wait(
                    until: { NSApp.keyWindow === window.window && window.window?.firstResponder === survivor },
                    timeout: 10
                )
            else {
                t.expect(false, desc: "the surviving remote window becomes key with its active pane before New Window")
                return
            }
            t.expect(
                NSApp.target(forAction: #selector(TerminalWindowController.newRemoteWorkspaceWindow(_:))) as AnyObject? === window,
                desc: "the remote-window command resolves to the active remote window controller"
            )
            t.expect(
                NSApp.sendAction(#selector(TerminalWindowController.newRemoteWorkspaceWindow(_:)), to: nil, from: newWindowItem),
                desc: "the remote-window responder action reaches the active workspace"
            )
        }
        var otherController: TerminalWindowController?
        t.expect(
            t.wait(
                until: {
                    otherController = TerminalWindowController.spawnedControllers.first { candidate in
                        guard candidate !== window, !candidate.isClosedForTesting,
                            let remote = candidate.remoteSurface
                        else { return false }
                        return remote.drive.remoteWorkspaceID == workspaceIdentity
                            && remote.drive.remoteWorkspaceSurface != Ubiquitty.Session.Layout.invalidSurface
                            && remote.drive.remoteWorkspaceSurface != surface
                            && remote.drive.remoteState == .Connected
                    }
                    return otherController != nil
                },
                timeout: 20
            ),
            desc:
                "another Core window projects into a separate native window "
                + "(host windows \(survivor.drive.remoteWorkspaceSurfaceCount), previously \(previousRemoteWindows), "
                + "session \(survivor.remoteSessionID), pane \(survivor.drive.remoteWorkspacePane), "
                + "state \(survivor.drive.remoteState))"
        )
        guard let otherController, let otherSurface = otherController.remoteSurface else { return }
        t.expect(
            otherSurface.drive.sharesRemoteWorkspaceConnection(with: survivor.drive),
            desc: "separate native windows share the workspace connection"
        )
        t.expect(
            otherController.window?.tabGroup !== window.window?.tabGroup
                || otherController.window?.tabGroup == nil,
            desc: "distinct Core windows do not merge into one native tab group"
        )

        let remainingWindowState = {
            "state \(otherSurface.drive.remoteState), detail \(otherSurface.remoteFailureDetail), closed \(otherController.isClosedForTesting), visible \(otherController.window?.isVisible == true), session \(otherSurface.remoteSessionID), workspace \(otherSurface.drive.remoteWorkspaceID), surface \(otherSurface.drive.remoteWorkspaceSurface), tab \(otherSurface.drive.remoteWorkspaceTab), pane \(otherSurface.drive.remoteWorkspacePane), mappedSession \(otherSurface.drive.remoteWorkspaceSession(for: otherSurface.drive.remoteWorkspacePane))"
        }
        t.expect(survivor.drive.remoteWorkspaceAddTab(), desc: "the window to close has another host tab")
        t.expect(
            t.wait(
                until: { survivor.drive.remoteWorkspaceTabCount(of: surface) == 2 && (window.window?.tabGroup?.windows.count ?? 0) == 2 },
                timeout: 20
            ),
            desc: "both tabs are projected before Close Window"
        )
        let closingWindows = window.window?.tabGroup?.windows.compactMap { $0.windowController as? TerminalWindowController } ?? [window]
        // Selecting a newly grouped tab reports its viewport and focus to
        // the host. Fence those facts before capturing this success-path
        // close question's exact structure revision.
        window.window?.makeKeyAndOrderFront(nil)
        window.window?.makeFirstResponder(survivor)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        let closeReadySuffix = UUID().uuidString
        survivor.send("printf '\\n%s%s\\n' 'close-ready-' '\(closeReadySuffix)'\n")
        t.expect(
            t.wait(until: { survivor.gridTextForTesting().contains("close-ready-\(closeReadySuffix)") }, timeout: 10),
            desc: "the host answers the selected tab after its new tab group settles"
        )
        let closeMenu = NSMenu(title: "Remote Workspaces")
        TerminalWindowController.populateRemoteWorkspaceMenu(closeMenu)
        guard
            let closeItem = closeMenu.items.first(where: { $0.title.hasPrefix("Close Window on ") && $0.toolTip == window.window?.title }),
            let closeAction = closeItem.action
        else {
            t.expect(false, desc: "the workspace menu offers an explicit whole-window close")
            return
        }
        t.expect(NSApp.sendAction(closeAction, to: closeItem.target, from: closeItem), desc: "the explicit command asks about every tab")
        guard t.wait(until: { window.window?.attachedSheet != nil }, timeout: 3),
            let closeSheet = window.window?.attachedSheet,
            let closeButton = sheetButton("Close Window", in: closeSheet),
            let cancelButton = sheetButton("Cancel", in: closeSheet)
        else {
            t.expect(false, desc: "remote Close Window presents the native choice")
            return
        }
        t.expect(closeSheet.defaultButtonCell === cancelButton.cell, desc: "ending host sessions is not the default")
        t.expect(
            sheetButton("Detach from Workspace", in: closeSheet) == nil,
            desc: "the explicit command stays scoped to closing the host window"
        )
        t.expect(survivor.drive.remoteWorkspaceTabCount(of: surface) == 2, desc: "no host tab closes before approval")
        t.expect(
            closeButton.isEnabled && survivor.drive.pendingRemoteWindowCloseToken != 0,
            desc: "the shown close question still owns the selected host window's current revision"
        )
        closeButton.performClick(nil)
        let didCloseWindow = t.wait(
            until: { closingWindows.allSatisfy { $0.isClosedForTesting } && otherSurface.drive.remoteWorkspaceSurfaceCount == 1 },
            timeout: 20
        )
        t.expect(
            didCloseWindow,
            desc: "Close Window waits for the host and closes every tab in only that host window "
                + "(closed \(closingWindows.map { $0.isClosedForTesting }), windows \(otherSurface.drive.remoteWorkspaceSurfaceCount), "
                + "outcome \(survivor.drive.remoteWorkspaceCloseOutcome), token \(survivor.drive.pendingRemoteWindowCloseToken), "
                + "sheet \(window.window?.attachedSheet != nil), state \(survivor.drive.remoteState))"
        )
        window.deliverRemoteEventsForTesting(exit: rootSurface)
        window.deliverRemoteEventsForTesting(layout: survivor)
        t.expect(window.isClosedForTesting, desc: "late host events cannot reopen a closed tab")
        t.expect(
            otherController.window?.isVisible == true && otherSurface.drive.remoteState == .Connected,
            desc: "closing the initial window preserves the other workspace window and connection (\(remainingWindowState()))"
        )
        t.expect(
            otherSurface.drive.remoteWorkspaceAddTab(),
            desc: "the remaining window can still send workspace commands (\(remainingWindowState()))"
        )
        t.expect(
            t.wait(
                until: {
                    otherSurface.drive.remoteWorkspaceTabCount(of: otherSurface.drive.remoteWorkspaceSurface)
                        == 2
                },
                timeout: 20
            ),
            desc: "the shared owner receives host replies after its initial window closes (\(remainingWindowState()))"
        )
    }
}

/// Records the foreground program each process-state move a surface announces
/// names, and answers whether it needs process facts as `needsProcessState`
/// says.
@MainActor
private final class ProcessStateProbe: TerminalSurfaceObserver {
    private(set) var heard: [String] = []
    var needsProcessState = false

    nonisolated func terminalSurfaceNeedsProcessState(_ surface: TerminalSurface) -> Bool {
        MainActor.assumeIsolated { needsProcessState }
    }

    nonisolated func terminalSurfaceDidChangeProcessState(_ surface: TerminalSurface) {
        MainActor.assumeIsolated { heard.append(surface.foregroundProgramName) }
    }
}
