// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// HostedTabScenarios.swift — the tabs of a hosted workspace, against a
// ubiquitty-host each scenario forks with a home of its own.
//
// Two claims. The tab a person brings to the front is the host's active tab,
// whether a key or the pointer chose it, and it stays in front through every
// structure the host sends afterwards. And the window's frame is the person's:
// nothing a host says of a pane's grid moves it, on a switch, on another
// client's resize, or on attach.

/// Registers the hosted-tab scenarios with the UI-test runner.
enum HostedTabScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("hosted_tab_click_selects_the_tab_on_the_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyPointerAndKeySelection(t) }
        }
        UBUITestRegister("hosted_window_frame_is_never_the_hosts") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyFrameIsThePersons(t) }
        }
        UBUITestRegister("hosted_tabs_name_their_host_once") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyHostNamedOnce(t) }
        }
        UBUITestRegister("tab_hover_text_says_the_whole_status") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyHoverTextIsWhole(t) }
        }
        UBUITestRegister("hosted_progress_reaches_tab_chrome_without_later_output") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyProgressWithoutLaterOutput(t) }
        }
        UBUITestRegister("hosted_background_tab_restyles_with_the_theme") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyBackgroundTabRestyles(t) }
        }
    }

    /// A theme picked while a hosted tab stands behind another reaches that
    /// tab's chrome without the tab being shown.
    ///
    /// The hidden pane is `Dormant` on the host, sent no screen: its palette
    /// moves on the host and reaches the client's terminal as the one block a
    /// `Dormant` pane is sent, and the tab's label, its program's icon and its
    /// working mark follow it, while the pane stays hidden throughout.
    @MainActor
    private static func verifyBackgroundTabRestyles(_ t: UBUITestContext) {
        guard let app = SettingsBridge.app, let dark = catalogThemeIndex(named: "One Dark"),
            let light = catalogThemeIndex(named: "One Light")
        else {
            t.expect(false, desc: "the settings path and both comparison themes exist")
            return
        }
        let unthemed = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer {
            t.restoreConfiguration(unthemed)
            TerminalWindowController.applyThemeToOpenWindows()
        }
        app.settingsSelectTheme(dark)
        guard let host = Host(t) else { return }
        defer { host.stop() }
        defer { t.closeAllWindows() }
        guard let opened = host.open(label: "theme host"), let root = opened.remoteSurface,
            t.wait(until: { opened.remotePaneSurfaces.count == 1 && root.drive.remoteState == .Connected }, timeout: 20),
            let firstWindow = opened.window
        else {
            t.expect(false, desc: "a window attached to the forked daemon")
            return
        }
        // A program whose status names OpenCode: its icon is drawn in the title's
        // ink, and its working mark wears a system label colour, which resolves
        // under the appearance the theme gives the window.
        root.send("printf '\\033]7501;state=working:app=opencode\\a'; sleep 1000\r")
        t.expect(
            t.wait(until: { templateIconInk(of: firstWindow) != nil }, timeout: 15),
            desc: "the hosted tab leads with its program's icon"
        )
        t.expect(root.drive.remoteWorkspaceAddTab(), desc: "the host accepts a second tab")
        guard
            t.wait(
                until: {
                    let group = tabs(of: opened)
                    return group.count == 2 && group.allSatisfy { $0.controller.remoteSurface?.drive.remoteState == .Connected }
                        && firstWindow.tabGroup?.selectedWindow !== firstWindow && !root.isRemotePaneShown
                },
                timeout: 20
            ),
            let group = firstWindow.tabGroup, let selected = group.selectedWindow,
            let selectedController = selected.windowController as? TerminalWindowController,
            let selectedSurface = selectedController.remoteSurface
        else {
            t.expect(false, desc: "the host's second tab is in front, and the first stands hidden behind it")
            return
        }
        t.expect(
            t.wait(until: { statusMarkInk(of: firstWindow) != nil }, timeout: 10),
            desc: "the hidden tab shows its program's working mark"
        )
        let foreground = { selectedController.themeForeground(of: selectedSurface) }
        let darkInk = foreground()
        expectBackgroundTabsWear(
            t,
            windows: group.windows,
            foreground: darkInk,
            isDark: true,
            iconWindows: [firstWindow],
            markWindows: [firstWindow],
            state: "the dark theme on a hosted workspace"
        )

        app.settingsSelectTheme(light)
        t.expect(
            t.wait(until: { foreground() != darkInk }, timeout: 20),
            desc: "the light theme reached the shown hosted tab through its host"
        )
        expectBackgroundTabsWear(
            t,
            windows: group.windows,
            foreground: foreground(),
            isDark: false,
            iconWindows: [firstWindow],
            markWindows: [firstWindow],
            state: "a theme picked while a hosted tab stands hidden"
        )
        t.expect(!root.isRemotePaneShown, desc: "the hidden tab's pane was never shown to restyle it")
        t.expect(group.selectedWindow === selected, desc: "the hidden tab was never brought to the front")
    }

    /// A forked daemon in a home of its own, and the command that attaches to it.
    @MainActor
    final class Host {
        let root: String
        let attachCommand: String
        private let daemon: Process
        private let previousHome: String?

        /// Starts a daemon whose state lives under a scratch directory.
        ///
        /// - Parameter t: The scenario's context, which records why none started.
        init?(_ t: UBUITestContext) {
            guard let hostBinary = ProcessInfo.processInfo.environment["UBIQUITTY_UI_TEST_HOST"],
                FileManager.default.isExecutableFile(atPath: hostBinary)
            else {
                t.expect(false, desc: "UBIQUITTY_UI_TEST_HOST names a built ubiquitty-host (Scripts/run-ui-tests.sh sets it)")
                return nil
            }
            // Under /tmp: a Unix socket path is capped at 103 bytes, and the
            // daemon's socket lives in this home.
            root = "/tmp/ubq-tabs-" + String(UUID().uuidString.prefix(8))
            let home = root + "/.ubiquitty"
            do {
                try FileManager.default.createDirectory(
                    atPath: home,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                t.expect(false, desc: "an isolated UBIQUITTY_HOME was made (\(error))")
                return nil
            }
            let quoted = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            attachCommand = "UBIQUITTY_HOME=\(quoted(home)) \(quoted(hostBinary)) --attach"
            previousHome = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
            setenv("UBIQUITTY_HOME", home, 1)
            daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: hostBinary)
            daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24", "--quic-port", "-1"]
            daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home, "ZDOTDIR": home]) { $1 }
            do {
                try daemon.run()
            } catch {
                t.expect(false, desc: "the daemon started (\(error))")
                stop()
                return nil
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
                stop()
                return nil
            }
        }

        /// Ends the daemon this scenario started and removes its home.
        func stop() {
            if daemon.isRunning { daemon.terminate() }
            if daemon.processIdentifier != 0 { daemon.waitUntilExit() }
            if let previousHome { setenv("UBIQUITTY_HOME", previousHome, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? FileManager.default.removeItem(atPath: root)
        }

        /// Opens a window attached to the daemon's workspace.
        ///
        /// - Parameters:
        ///   - label: The host label the window opens under.
        ///   - prefix: Put before the transport command, so a second client is
        ///     a connection of its own rather than the first one's window.
        ///   - sessionID: The session to attach to, or zero for the workspace's own.
        func open(label: String, prefix: String = "", sessionID: UInt32 = 0) -> TerminalWindowController? {
            TerminalWindowController.spawnRemoteWindow(
                shellCommand: prefix + attachCommand,
                hostLabel: label,
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: sessionID,
                workspaceName: sessionID == 0 ? "tabs" : "",
                hostKey: ""
            )
        }
    }

    /// The tab buttons of a window's strip, in the group's window order.
    @MainActor
    private static func tabButtons(inGroupOf window: NSWindow) -> [NSView] {
        guard let strip = TabStripStyling.tabStripView(inGroupOf: window) else { return [] }
        var buttons: [NSView] = []
        func collect(_ view: NSView) {
            if NSStringFromClass(type(of: view)) == "NSTabButton" {
                buttons.append(view)
            } else {
                view.subviews.forEach(collect)
            }
        }
        collect(strip)
        return buttons.sorted {
            let left = $0.convert($0.bounds, to: strip).minX
            let right = $1.convert($1.bounds, to: strip).minX
            return strip.userInterfaceLayoutDirection == .rightToLeft ? left > right : left < right
        }
    }

    /// Presses and releases the pointer on a tab's face, through the
    /// application's queue as its run loop delivers a click: the press reaches
    /// the local monitors and then the strip, whose tracking loop takes the
    /// release that is already waiting.
    ///
    /// - Parameters:
    ///   - target: The tab's window.
    ///   - t: The scenario's context.
    /// - Returns: Whether the strip had a face for the tab to press.
    @MainActor
    static func click(tabOf target: NSWindow, _ t: UBUITestContext) -> Bool {
        guard let group = target.tabGroup, let index = group.windows.firstIndex(where: { $0 === target }),
            let host = group.selectedWindow
        else { return false }
        let buttons = tabButtons(inGroupOf: host)
        guard buttons.count == group.windows.count, let stripWindow = buttons[index].window else { return false }
        let button = buttons[index]
        // Left of centre: the face, clear of the close control at its leading
        // edge and of a title that centres.
        let point = button.convert(NSPoint(x: button.bounds.minX + button.bounds.width * 0.3, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: stripWindow.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                )
            else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        while let queued = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        t.pump(0.1)
        return true
    }

    /// Selects a tab as Command and its number does.
    ///
    /// The key's action finds the tab by its place in the key window's group
    /// and makes it the group's selected window. Where this harness has made
    /// one of the group's windows key, the action itself is sent; a harness
    /// whose windows never become key gives the action no group to act in, so
    /// the selection it would make is made directly. Either way the strip
    /// hears one selection with no pointer behind it.
    @MainActor
    private static func pressCommandNumber(for target: NSWindow) -> Bool {
        guard let group = target.tabGroup, let index = group.windows.firstIndex(where: { $0 === target }) else { return false }
        guard NSApp.keyWindow?.tabGroup === group else {
            group.selectedWindow = target
            return true
        }
        let item = NSMenuItem(title: "", action: NSSelectorFromString("selectTab:"), keyEquivalent: "")
        item.tag = index + 1
        return NSApp.sendAction(NSSelectorFromString("selectTab:"), to: nil, from: item)
    }

    /// The windows of a hosted group and the host tab each projects.
    @MainActor
    private static func tabs(of controller: TerminalWindowController) -> [(window: NSWindow, controller: TerminalWindowController)] {
        (controller.window?.tabGroup?.windows ?? [])
            .compactMap { window in
                (window.windowController as? TerminalWindowController).map { (window, $0) }
            }
    }

    /// Opens a window on the host and adds a second tab to its workspace.
    ///
    /// - Returns: The two tabs' controllers, in the strip's order, once both
    ///   are connected and tabbed together.
    @MainActor
    private static func openTwoTabs(
        on host: Host,
        label: String,
        _ t: UBUITestContext
    ) -> (first: TerminalWindowController, second: TerminalWindowController)? {
        guard let opened = host.open(label: label), let rootSurface = opened.remoteSurface else {
            t.expect(false, desc: "a window attached to the forked daemon")
            return nil
        }
        guard
            t.wait(
                until: { opened.remotePaneSurfaces.count == 1 && rootSurface.drive.remoteState == .Connected },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the window projected the workspace's one pane (\(rootSurface.remoteFailureDetail))")
            return nil
        }
        t.expect(rootSurface.drive.remoteWorkspaceAddTab(), desc: "the host accepts a second tab")
        guard
            t.wait(
                until: {
                    let group = tabs(of: opened)
                    return group.count == 2
                        && group.allSatisfy { $0.controller.remoteSurface?.drive.remoteState == .Connected }
                        && tabButtons(inGroupOf: opened.window!).count == 2
                },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the host's second tab arrived as a second native tab (\(tabs(of: opened).count) windows)")
            return nil
        }
        let group = tabs(of: opened)
        return (group[0].controller, group[1].controller)
    }

    /// The host's active tab of the surface a controller's tab stands on.
    @MainActor
    private static func hostActiveTab(of controller: TerminalWindowController) -> Ubiquitty.Session.Layout.TabID {
        guard let drive = controller.remoteSurface?.drive else { return Ubiquitty.Session.Layout.invalidTab }
        return drive.remoteWorkspaceActiveTab(of: drive.remoteWorkspaceSurface)
    }

    /// Reports from a hosted shell, then waits silently on a scratch marker.
    /// The ring must not need any later output to learn either progress edge.
    @MainActor
    private static func verifyProgressWithoutLaterOutput(_ t: UBUITestContext) {
        guard let host = Host(t) else { return }
        defer { host.stop() }
        defer { t.closeAllWindows() }
        guard let (first, second) = openTwoTabs(on: host, label: "progress host", t),
            let firstWindow = first.window, let secondWindow = second.window,
            let group = firstWindow.tabGroup, let surface = first.remoteSurface
        else { return }
        group.selectedWindow = secondWindow
        let clearMarker = host.root + "/clear-progress"
        let finishMarker = host.root + "/finish-progress"
        // The shell's typed command is already visible before the delayed
        // report. Both waits are silent, so neither edge is followed by a
        // prompt or another cell-bearing output that could publish it.
        surface.send(
            "sleep 1; printf '\\033]9;4;3\\033\\\\'; "
                + "while [ ! -e '\(clearMarker)' ]; do sleep 0.05; done; "
                + "printf '\\033]9;4;0\\033\\\\'; "
                + "while [ ! -e '\(finishMarker)' ]; do sleep 0.05; done\r"
        )
        t.expect(
            t.wait(
                until: {
                    surface.drive.readSnapshot().progressState == 3
                        && (firstWindow.tab.accessoryView as? TabStatusMark)?.progressStateForTesting == 3
                },
                timeout: 15
            ),
            desc: "a hosted records-only report publishes its snapshot and lights the background tab's ring"
        )
        t.expect((secondWindow.tab.accessoryView as? TabStatusMark)?.isShowingProgress != true, desc: "the other hosted pane stays clear")
        do {
            try Data().write(to: URL(fileURLWithPath: clearMarker))
        } catch {
            t.expect(false, desc: "the scratch marker releases the progress clear (\(error))")
            return
        }
        t.expect(
            t.wait(
                until: {
                    surface.drive.readSnapshot().progressState == 0
                        && (firstWindow.tab.accessoryView as? TabStatusMark)?.isShowingProgress != true
                },
                timeout: 15
            ),
            desc: "clearing hosted progress removes the ring before the shell prints anything else"
        )
        try? Data().write(to: URL(fileURLWithPath: finishMarker))
    }

    @MainActor
    private static func verifyPointerAndKeySelection(_ t: UBUITestContext) {
        guard let host = Host(t) else { return }
        defer { host.stop() }
        defer { t.closeAllWindows() }
        guard let (first, second) = openTwoTabs(on: host, label: "tab host", t), let firstWindow = first.window,
            let secondWindow = second.window, let group = firstWindow.tabGroup
        else { return }

        // The host put its new tab in front, and the strip agrees.
        t.expect(
            t.wait(until: { group.selectedWindow === secondWindow && hostActiveTab(of: first) == second.remoteWorkspaceTab }, timeout: 20),
            desc: "the tab the host just added is in front here and active on the host"
        )

        // The pointer: a press on the first tab's face.
        t.expect(click(tabOf: firstWindow, t), desc: "the strip has a face for the first tab")
        t.expect(
            t.wait(until: { hostActiveTab(of: first) == first.remoteWorkspaceTab }, timeout: 10),
            desc: "a click on a tab makes it the host's active tab (\(hostActiveTab(of: first)) for \(first.remoteWorkspaceTab))"
        )
        // Held through the turns the strip's own bookkeeping runs on, and
        // through a structure delivered again: the tab stays where the person
        // put it rather than returning to the one the host had in front.
        t.pump(0.5)
        first.deliverRemoteEventsForTesting(layout: first.remoteSurface!)
        second.deliverRemoteEventsForTesting(layout: second.remoteSurface!)
        t.pump(0.2)
        t.expect(group.selectedWindow === firstWindow, desc: "the clicked tab is in front and stays there")

        // And back, by the pointer again.
        t.expect(click(tabOf: secondWindow, t), desc: "the strip has a face for the second tab")
        t.expect(
            t.wait(until: { hostActiveTab(of: first) == second.remoteWorkspaceTab }, timeout: 10),
            desc: "a click on the other tab makes that one the host's active tab"
        )
        t.pump(0.5)
        t.expect(group.selectedWindow === secondWindow, desc: "the second clicked tab is in front and stays there")

        // The key: Command and the tab's number.
        t.expect(pressCommandNumber(for: firstWindow), desc: "the tab-number action found a target")
        t.expect(
            t.wait(until: { hostActiveTab(of: first) == first.remoteWorkspaceTab }, timeout: 10),
            desc: "a tab chosen by its number is the host's active tab too"
        )
        t.pump(0.3)
        second.deliverRemoteEventsForTesting(layout: second.remoteSurface!)
        t.pump(0.2)
        t.expect(group.selectedWindow === firstWindow, desc: "the tab chosen by its number is in front and stays there")
    }

    @MainActor
    private static func verifyFrameIsThePersons(_ t: UBUITestContext) {
        guard let host = Host(t) else { return }
        defer { host.stop() }
        defer { t.closeAllWindows() }
        guard let (first, second) = openTwoTabs(on: host, label: "frame host", t), let firstWindow = first.window,
            let secondWindow = second.window, let group = firstWindow.tabGroup,
            let firstSurface = first.remoteSurface, let secondSurface = second.remoteSurface
        else { return }
        let statements = { (surface: TerminalSurface) in surface.drive.syncTraceReport().totals.viewportsStated }
        let hostGrid = { (surface: TerminalSurface) -> (rows: Int, columns: Int) in
            let snapshot = surface.drive.readSnapshot()
            return (Int(snapshot.rows), Int(snapshot.columns))
        }

        // Both tabs settle on the grid their drawable holds, and the host has it.
        t.expect(
            t.wait(
                until: {
                    [firstSurface, secondSurface].allSatisfy { $0.publishedGrid.columns > 20 && hostGrid($0) == $0.publishedGrid }
                },
                timeout: 20
            ),
            desc:
                "each tab's pane is at the grid its drawable holds "
                + "(first \(hostGrid(firstSurface)) of \(firstSurface.publishedGrid), second \(hostGrid(secondSurface)) of \(secondSurface.publishedGrid))"
        )

        // Each tab is shown once. A tab that has stood behind another since
        // the strip appeared may never have been laid out at the group's
        // frame, so the first time it comes to the front its drawable can
        // change, and that is said to the host. The window's frame is not
        // part of that: it stays where it is from the first switch on.
        let frame = group.selectedWindow?.frame ?? .zero
        for target in [firstWindow, secondWindow, firstWindow] {
            t.expect(click(tabOf: target, t), desc: "the pointer chose a tab not shown since the strip appeared")
            t.expect(t.wait(until: { group.selectedWindow === target }, timeout: 10), desc: "that tab is in front")
            t.pump(0.4)
            t.expect(
                group.selectedWindow?.frame == frame,
                desc:
                    "showing a tab leaves the window's frame where it was (\(String(describing: group.selectedWindow?.frame)) for \(frame))"
            )
        }
        t.expect(
            t.wait(
                until: { [firstSurface, secondSurface].allSatisfy { hostGrid($0) == $0.publishedGrid } },
                timeout: 20
            ),
            desc: "each tab's pane is at the grid its drawable holds once it has been shown"
        )

        // A switch between two tabs whose drawables hold what they held: the
        // frame stays, and nothing is said to the host about either pane's size.
        var stated = (statements(firstSurface), statements(secondSurface))
        for (target, how) in [(secondWindow, "pointer"), (firstWindow, "pointer"), (secondWindow, "key"), (firstWindow, "key")] {
            let wasChosen = how == "pointer" ? click(tabOf: target, t) : pressCommandNumber(for: target)
            t.expect(wasChosen, desc: "the \(how) chose a tab")
            t.expect(t.wait(until: { group.selectedWindow === target }, timeout: 10), desc: "the tab chosen by \(how) is in front")
            t.pump(0.4)
            t.expect(
                group.selectedWindow?.frame == frame,
                desc:
                    "a switch by \(how) leaves the window's frame where it was (\(String(describing: group.selectedWindow?.frame)) for \(frame))"
            )
            t.expect(
                (statements(firstSurface), statements(secondSurface)) == stated,
                desc:
                    "a switch by \(how) states no size to the host "
                    + "(\(statements(firstSurface)), \(statements(secondSurface)) after \(stated))"
            )
        }

        // The person resizes the window: one statement per settle, for the
        // pane in front.
        t.expect(pressCommandNumber(for: firstWindow), desc: "the first tab is brought to the front")
        t.expect(t.wait(until: { group.selectedWindow === firstWindow }, timeout: 10), desc: "the first tab is in front")
        t.pump(0.3)
        stated = (statements(firstSurface), statements(secondSurface))
        let own = firstSurface.publishedGrid
        first.resizeWindow(toColumns: own.columns - 6, rows: own.rows - 3)
        t.expect(
            t.wait(until: { hostGrid(firstSurface) == (rows: own.rows - 3, columns: own.columns - 6) }, timeout: 20),
            desc: "the host took the grid the person's resize left the pane in front (\(hostGrid(firstSurface)))"
        )
        t.pump(0.4)
        t.expect(
            statements(firstSurface) == stated.0 + 1,
            desc: "one resize states the pane's size once (\(statements(firstSurface) - stated.0) statements)"
        )
        let resizedFrame = firstWindow.frame

        // Another client on the same workspace, a connection of its own, with
        // a window of another size. It types, which makes the size of what it
        // types into its to set.
        guard let peer = host.open(label: "frame peer", prefix: "UBQ_TAB_PEER=1 ", sessionID: firstSurface.remoteSessionID),
            let peerSurface = peer.remoteSurface, peer !== first, peer !== second
        else {
            t.expect(false, desc: "a second client attached to the workspace in a window of its own")
            return
        }
        guard
            t.wait(
                until: { peerSurface.drive.remoteState == .Connected && peerSurface.remoteSessionID == firstSurface.remoteSessionID },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the second client reached the first tab's session (\(peerSurface.remoteFailureDetail))")
            return
        }
        t.expect(
            !peerSurface.drive.sharesRemoteWorkspaceConnection(with: firstSurface.drive),
            desc: "the second client is a connection of its own"
        )
        t.pump(0.5)
        t.expect(
            firstWindow.frame == resizedFrame && group.selectedWindow?.frame == resizedFrame,
            desc: "another client attaching moves no window of this one (\(firstWindow.frame) for \(resizedFrame))"
        )
        let peerFrame = peer.window?.frame ?? .zero

        let wanted = (rows: own.rows - 8, columns: own.columns - 17)
        peer.resizeWindow(toColumns: wanted.columns, rows: wanted.rows)
        peerSurface.send("true\r")
        t.expect(
            t.wait(until: { hostGrid(peerSurface) == wanted && hostGrid(firstSurface) == wanted }, timeout: 20),
            desc:
                "the pane took the size of the client typing into it, and this client's mirror heard "
                + "(peer \(hostGrid(peerSurface)), first \(hostGrid(firstSurface)), wanted \(wanted))"
        )
        t.pump(0.6)
        t.expect(
            firstWindow.frame == resizedFrame,
            desc: "a pane resized by another client moves no window here (\(firstWindow.frame) for \(resizedFrame))"
        )
        t.expect(
            peer.window?.frame != peerFrame,
            desc: "the window the person resized is the one that moved"
        )

        // The two tabs now hold panes of different grids. Switching between
        // them, by pointer and by key, moves no frame.
        t.expect(hostGrid(firstSurface) != hostGrid(secondSurface), desc: "the two tabs' panes are at different grids")
        for (target, how) in [(secondWindow, "pointer"), (firstWindow, "pointer"), (secondWindow, "key"), (firstWindow, "key")] {
            let wasChosen = how == "pointer" ? click(tabOf: target, t) : pressCommandNumber(for: target)
            t.expect(wasChosen, desc: "the \(how) chose a tab between panes of different grids")
            t.expect(
                t.wait(until: { group.selectedWindow === target }, timeout: 10),
                desc: "the tab chosen by \(how) is in front, between panes of different grids"
            )
            t.pump(0.5)
            t.expect(
                group.selectedWindow?.frame == resizedFrame,
                desc:
                    "a switch by \(how) between panes of different grids leaves the frame "
                    + "(\(String(describing: group.selectedWindow?.frame)) for \(resizedFrame))"
            )
        }
    }

    @MainActor
    private static func verifyHostNamedOnce(_ t: UBUITestContext) {
        guard let host = Host(t) else { return }
        defer { host.stop() }
        defer { t.closeAllWindows() }
        guard let (first, second) = openTwoTabs(on: host, label: "named once", t), let firstWindow = first.window,
            let secondWindow = second.window, let group = firstWindow.tabGroup
        else { return }
        let front = { group.selectedWindow?.windowController as? TerminalWindowController }

        // The window says where it is, once, in its title row.
        t.expect(
            t.wait(until: { front()?.remoteConnectionIndicator?.readingForTesting == "named once" }, timeout: 20),
            desc:
                "the front tab's title row wears the host chip "
                + "(\(front()?.remoteConnectionIndicator?.readingForTesting ?? "no chip"))"
        )
        t.expect(group.selectedWindow?.subtitle == "named once", desc: "and the window's subtitle names the host")

        // Every tab of the window is on that host, so none of them says it again.
        let labels = { [firstWindow, secondWindow].map { $0.tab.title ?? "" } }
        t.expect(
            t.wait(until: { labels().allSatisfy { !$0.isEmpty && !$0.contains("named once") && !$0.contains(" \u{B7} ") } }, timeout: 20),
            desc: "no tab of a window that names its host repeats it (\(labels()))"
        )
        // Through a switch too: the chip then standing is the other tab's,
        // and it names the same host.
        t.expect(pressCommandNumber(for: firstWindow), desc: "the first tab is brought to the front")
        t.expect(t.wait(until: { group.selectedWindow === firstWindow }, timeout: 10), desc: "the first tab is in front")
        t.pump(0.6)
        t.expect(
            labels().allSatisfy { !$0.contains("named once") && !$0.contains(" \u{B7} ") },
            desc: "and none does after a switch (\(labels()))"
        )
        t.expect(
            firstWindow.title.isEmpty == false && firstWindow.subtitle == "named once",
            desc: "the window's own title and subtitle are a place of their own and still name the host"
        )

        // A name the person puts on a tab names it as they typed it, and the
        // host the window already says is not added to it.
        first.setCustomTitles(tab: "deploy \u{B7} staging")
        t.expect(
            t.wait(
                until: {
                    let label = firstWindow.tab.title ?? ""
                    return label.contains("deploy \u{B7} staging") && !label.contains("named once")
                },
                timeout: 10
            ),
            desc: "a tab the person named reads as they named it ('\(firstWindow.tab.title ?? "")')"
        )
    }

    @MainActor
    private static func verifyHoverTextIsWhole(_ t: UBUITestContext) {
        guard let host = Host(t) else { return }
        defer { host.stop() }
        defer { t.closeAllWindows() }
        guard let (first, second) = openTwoTabs(on: host, label: "hover host", t), let firstWindow = first.window,
            let secondWindow = second.window, let secondSurface = second.remoteSurface
        else { return }

        // A status of several hundred characters with a run of wide ones, and
        // in the middle of it what a program must not get into a label: a
        // direction override.
        let sentence = "Rebuilding the index for the archive and verifying every shard against its manifest before the old one is retired. "
        let wide = String(repeating: "\u{9032}\u{6357}\u{72B6}\u{6CC1}", count: 12)
        let visible = String(repeating: sentence, count: 4) + wide + " step 37 of 212, about nine minutes left."
        let hostile = visible.replacingOccurrences(of: "retired. ", with: "retired.\u{202E} ")
        t.expect(visible.count > 500, desc: "the status is several hundred characters long (\(visible.count))")
        guard let encoded = hostile.data(using: .utf8)?.base64EncodedString() else { return }
        // Reported as done, so the prompt that follows the report does not
        // end it the way it ends a report of work in progress.
        secondSurface.send("printf '\\033]7501;state=done:msg=%s\\033\\\\' '\(encoded)'\r")

        let expected = "Done \u{2014} " + visible
        t.expect(
            t.wait(until: { secondSurface.drive.statusHelpText() == expected }, timeout: 20),
            desc:
                "Core's help text is the whole status, with the override removed "
                + "(\(secondSurface.drive.statusHelpText().count) characters of \(expected.count))"
        )
        t.expect(
            String(secondSurface.drive.readSnapshot().tabStatusLabel()).utf8.count <= 48,
            desc: "while the label a title shows is still the few words it has room for"
        )
        t.expect(
            t.wait(until: { secondWindow.tab.toolTip?.hasSuffix(expected) == true }, timeout: 10),
            desc:
                "the tab's hover text ends with the whole status "
                + "(\(secondWindow.tab.toolTip?.count ?? 0) characters; expected \(expected.count) of status)"
        )
        t.expect(
            secondWindow.tab.toolTip?.unicodeScalars.contains { $0.value == 0x202E || $0.value < 0x20 && $0.value != 0x0A } == false,
            desc: "and carries no direction override and no control but the line breaks between its own parts"
        )

        // What the strip's own face for the tab says to the pointer and to an
        // assistive reader is that text, whole.
        t.pump(0.5)
        let buttons = tabButtons(inGroupOf: firstWindow)
        guard let index = firstWindow.tabGroup?.windows.firstIndex(where: { $0 === secondWindow }), buttons.indices.contains(index) else {
            t.expect(false, desc: "the strip has a face for the tab")
            return
        }
        let face = buttons[index]
        let said = [face.toolTip, face.accessibilityHelp()].compactMap { $0 }
        t.expect(
            said.contains { $0.hasSuffix(expected) },
            desc:
                "the tab's face carries the whole text as its help "
                + "(tool tip \(face.toolTip?.count ?? -1) characters, accessibility help \(face.accessibilityHelp()?.count ?? -1))"
        )

        // The text moves when the status does, past the words a title shows.
        let later = visible.replacingOccurrences(of: "step 37", with: "step 38")
        guard let encodedLater = later.data(using: .utf8)?.base64EncodedString() else { return }
        secondSurface.send("printf '\\033]7501;state=done:msg=%s\\033\\\\' '\(encodedLater)'\r")
        t.expect(
            t.wait(until: { secondWindow.tab.toolTip?.hasSuffix("Done \u{2014} " + later) == true }, timeout: 20),
            desc: "a change far past the label's few words still reaches the hover text"
        )
        _ = first
    }
}
