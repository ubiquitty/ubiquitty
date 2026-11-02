// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore
import UbiquittyKit
import UbiquittyRenderKit

// ShareSessionScenarios.swift — File ▸ Share This Window with Agents, and Stop
// Sharing This Window, on a Swift-shell window against a real daemon.
//
// Sharing re-homes the shell the window is running into the local daemon: the
// daemon adopts its PTY, the window becomes that session's client with the same
// chrome, and the shell is still this process's child. Stopping hands it back
// and the window reads its own PTY again, with no reconnect. The claims are all
// about one shell — a variable set in it before the share is read back through
// the daemon while shared and through the local PTY after — so the daemon is a
// real one and the shell is the window's own.
//
// The daemon trusts the app to hand it a PTY only when the app is the interface
// bundled beside it, so the harness's host is placed where a complete bundle
// carries it, Contents/Helpers, and the daemon is started from there. That is
// also where the share looks for it, so the scenario exercises the path a
// shipped app takes rather than one the harness names.

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

/// Who answers `action` for `window`, walking the chain AppKit walks once the
/// window is key: the harness runs the app as an accessory, so no window ever
/// becomes key and a nil-target send reaches nobody.
///
/// - Parameters:
///   - action: The selector the menu item sends.
///   - window: The window whose chain to walk.
/// - Returns: The first responder in the chain that answers, or nil.
@MainActor
private func answerer(of action: Selector, from window: NSWindow) -> NSResponder? {
    var walker: NSResponder? = window.firstResponder
    while let responder = walker {
        if responder.responds(to: action) {
            return responder
        }
        walker = responder.nextResponder
    }
    return nil
}

/// Whether the File menu item for `action` is enabled on `window`, asked of the
/// responder that would answer it.
///
/// - Parameters:
///   - action: The item's action.
///   - window: The window it would act on.
/// - Returns: The item's enabled state, or nil when nothing in the chain answers.
@MainActor
private func isMenuItemEnabled(_ action: Selector, on window: NSWindow) -> Bool? {
    guard let target = answerer(of: action, from: window) else {
        return nil
    }
    let item = NSMenuItem(title: NSStringFromSelector(action), action: action, keyEquivalent: "")
    guard let validating = target as? NSMenuItemValidation else {
        return true
    }
    return validating.validateMenuItem(item)
}

/// Registers the share scenarios with the UI-test runner.
enum ShareSessionScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("swift_shell_shares_a_window_into_the_daemon_and_takes_it_back") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated {
                verifyShareAndReclaim(t)
            }
        }
        UBUITestRegister("swift_shell_shares_all_native_tabs_and_split_panes") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyShareAndReclaim(t, includesOtherPanes: true) }
        }
        UBUITestRegister("swift_connect_drops_a_stopped_running_sessions_host") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyShareAndReclaim(t, includesOtherPanes: true, endsAfterHostDiscovery: true) }
        }
        UBUITestRegister("swift_shell_shared_window_outlives_its_first_tab") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { verifyShareAndReclaim(t, includesOtherPanes: true, closesFirstTab: true) }
        }
    }

    @MainActor
    private static func verifyShareAndReclaim(
        _ t: UBUITestContext,
        includesOtherPanes: Bool = false,
        endsAfterHostDiscovery: Bool = false,
        closesFirstTab: Bool = false
    ) {
        // The host where a complete bundle carries it; see `placeBundledHost`.
        guard let bundled = t.placeBundledHost() else { return }
        defer { bundled.remove() }
        let bundledHost = bundled.path
        let fileManager = FileManager.default
        t.expect(
            ShareSessionSupport.localHostBinaryPath() == bundledHost,
            desc: "a share reaches the daemon through the bundled host (\(ShareSessionSupport.localHostBinaryPath() ?? "none"))"
        )

        // A home of its own under /tmp: a Unix socket path is capped at 103
        // bytes, and nothing here touches the operator's daemon.
        let root = "/tmp/ubq-share-" + String(UUID().uuidString.prefix(8))
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
            if let previousHome {
                setenv("UBIQUITTY_HOME", previousHome, 1)
            } else {
                unsetenv("UBIQUITTY_HOME")
            }
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
            t.expect(false, desc: "the daemon opened the socket a share looks for (\(socketPath))")
            return
        }

        if includesOtherPanes {
            checkOtherHostDiscovery(t, home: home, root: root, bundledHost: bundledHost)
            if endsAfterHostDiscovery { return }
        }

        guard let shell = TerminalWindowController.spawn(),
            let window = shell.window,
            let content = window.contentView,
            let surface = terminalSurface(under: content)
        else {
            t.expect(false, desc: "a Swift-shell window opens with a surface")
            return
        }
        defer {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        t.pump(0.3)
        if includesOtherPanes {
            shell.splitRight(nil)
            shell.newWindowForTab(nil)
            t.pump(0.3)
            window.tabGroup?.selectedWindow = window
        }
        let participants = (window.tabbedWindows ?? [window]).compactMap { $0.windowController as? TerminalWindowController }
        let sharedSurfaces = participants.flatMap(\.projectedSurfaces)
        t.expect(sharedSurfaces.count == (includesOtherPanes ? 3 : 1), desc: "the fixture holds every native tab and split pane")
        for (index, pane) in sharedSurfaces.enumerated() {
            pane.send("UBQ_WINDOW_PANE=\(index); echo pane-local:$UBQ_WINDOW_PANE\n")
            t.expect(
                t.wait(until: { bufferHolds("pane-local:\(index)", in: pane) }, timeout: 10),
                desc: "pane \(index) keeps a distinct running shell"
            )
        }

        // A mark inside the shell, read back through its own expansion and
        // wrapped, so an answer can only come from the shell holding it.
        let marker = "share-" + String(UUID().uuidString.prefix(8))
        surface.send("UBQ_SHARE_MARK=\(marker); echo \"local:[$UBQ_SHARE_MARK]\"\n")
        t.expect(
            t.wait(until: { bufferHolds("local:[\(marker)]", in: surface) }, timeout: 10),
            desc: "the window's own shell holds the mark"
        )

        // The menu: the window answers both items itself, and only Share is on.
        t.expect(
            answerer(of: #selector(TerminalWindowController.shareThisWindow(_:)), from: window) === shell,
            desc: "Share This Window reaches this window's controller rather than the application"
        )
        t.expect(
            answerer(of: #selector(TerminalWindowController.stopSharingWindow(_:)), from: window) === shell,
            desc: "and so does Stop Sharing"
        )
        t.expect(
            isMenuItemEnabled(#selector(TerminalWindowController.shareThisWindow(_:)), on: window) == true,
            desc: "Share is enabled on a local shell"
        )
        t.expect(
            isMenuItemEnabled(#selector(TerminalWindowController.stopSharingWindow(_:)), on: window) == false,
            desc: "and Stop Sharing is not, with nothing shared"
        )
        let openWindowsBeforeShare = TerminalWindowController.spawnedControllers.filter { !$0.isClosedForTesting }.count

        shell.shareThisWindow(nil)
        if let cancelled = window.attachedSheet { window.endSheet(cancelled, returnCode: .alertSecondButtonReturn) }
        t.pump(0.1)
        t.expect(sharedSurfaces.allSatisfy { !$0.drive.isSharedIntoLocalDaemon }, desc: "cancelling the chooser leaves every shell local")
        t.expect(
            isMenuItemEnabled(#selector(TerminalWindowController.shareThisWindow(_:)), on: window) == true,
            desc: "sharing can be chosen after cancel"
        )

        // Share: the daemon adopts the PTY and this window becomes its client.
        NSApp.sendAction(#selector(TerminalWindowController.shareThisWindow(_:)), to: shell, from: nil)
        guard let chooser = window.attachedSheet else {
            t.expect(false, desc: "sharing asks which workspace to use")
            return
        }
        window.endSheet(chooser, returnCode: .alertFirstButtonReturn)
        guard t.wait(until: { sharedSurfaces.allSatisfy { $0.drive.isSharedIntoLocalDaemon } }, timeout: 20) else {
            func messages(_ view: NSView) -> [String] {
                (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(messages)
            }
            let detail = window.attachedSheet?.contentView.map { messages($0).joined(separator: " · ") } ?? "no sheet"
            t.expect(false, desc: "the daemon adopted every pane in the window: \(detail)")
            return
        }
        // Every pane is committed before any attaches; the first attaches at
        // once, and the others join its connection once the host confirms
        // the window.
        t.expect(
            t.wait(until: { sharedSurfaces.allSatisfy(\.isRemoteAttached) }, timeout: 20),
            desc: "and every pane in the window is its session's client"
        )
        t.expect(
            TerminalWindowController.spawnedControllers.filter { !$0.isClosedForTesting }.count == openWindowsBeforeShare,
            desc: "in the same window — the share opened none of its own"
        )
        guard
            t.wait(
                until: { surface.drive.remoteState == Ubiquitty.Session.State.Connected && surface.remoteSessionID != 0 },
                timeout: 20
            )
        else {
            t.expect(false, desc: "the window reached the adopted session (\(surface.remoteFailureDetail))")
            return
        }
        t.expect(
            t.wait(until: { sharedSurfaces.contains { $0.drive.sharedWorkspaceResult.workspaceID != 0 } }, timeout: 20),
            desc: "the host confirmed one workspace for the complete window (\(String(surface.drive.sharedWorkspaceResult.detail)))"
        )
        // The window publishes its share when it next reads the host's answer,
        // on its connection's event or its own short timer, which can be a
        // turn after the answer reads confirmed here. What each tab saves is
        // the published share.
        t.expect(
            t.wait(until: { participants.allSatisfy(\.isSharePublishedForTesting) }, timeout: 20),
            desc: "every native tab's window publishes the confirmed share"
        )
        // One connection carries the whole window: every pane rides it, and
        // the host's roster of each pane names one attachment of this app.
        if let first = sharedSurfaces.first {
            t.expect(
                sharedSurfaces.allSatisfy { $0.drive.sharesRemoteWorkspaceConnection(with: first.drive) },
                desc: "every native tab and split pane rides the window's one connection"
            )
        }
        for (index, pane) in sharedSurfaces.enumerated() {
            t.expect(
                t.wait(
                    until: { pane.drive.attendees.filter(\.isHuman).count == 1 && pane.drive.attendees.contains(where: \.isSelf) },
                    timeout: 10
                ),
                desc: "pane \(index) is bound to this app once (\(pane.drive.attendees.filter(\.isHuman).count) human attendees)"
            )
        }
        let attachments = Set(sharedSurfaces.flatMap { $0.drive.attendees.filter(\.isHuman).map(\.attachmentID) })
        t.expect(attachments.count == 1, desc: "the window's panes share one attachment of this app (\(attachments.count))")
        for controller in participants {
            let saved = controller.savedPresentation(needsLocalArrangement: true).liveWorkspace
            t.expect(
                saved?.workspaceID
                    == sharedSurfaces.first(where: { $0.drive.sharedWorkspaceResult.workspaceID != 0 })?.drive.sharedWorkspaceResult
                    .workspaceID,
                desc: "every native tab saves the confirmed hosted workspace"
            )
            t.expect(
                saved?.sessionID != 0 && saved?.bridgeCommand.isEmpty == false,
                desc: "the saved shared window can reattach without launching replacement shells"
            )
            t.expect(controller.tabCaptureFacts.paneLayout.empty(), desc: "shared splits restore from the host's layout")
        }
        for (index, pane) in sharedSurfaces.enumerated() {
            pane.send("echo pane-shared:$UBQ_WINDOW_PANE\n")
            t.expect(
                t.wait(until: { bufferHolds("pane-shared:\(index)", in: pane) }, timeout: 10),
                desc: "pane \(index) answers from the same shell through the host"
            )
        }
        if let badge = shell.remoteConnectionIndicator {
            t.expect(
                t.wait(until: { badge.isShownForTesting && badge.readingForTesting == "This Mac (shared)" }, timeout: 10),
                desc: "the title row names the window shared into this Mac's daemon (\(badge.readingForTesting))"
            )
        } else {
            t.expect(false, desc: "the window wears the connection badge")
        }
        t.expect(window.attachedSheet != nil, desc: "the share is announced on the window it shared")
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
        }

        // The daemon drives the same shell: typed input crosses to it, and the
        // answer, read from the mark set before the share, comes back through it.
        surface.send("echo \"shared:[$UBQ_SHARE_MARK]\"\n")
        t.expect(
            t.wait(until: { bufferHolds("shared:[\(marker)]", in: surface) }, timeout: 20),
            desc: "the shared session is the window's own shell, answering through the daemon"
        )
        t.expect(
            bufferHolds("local:[\(marker)]", in: surface),
            desc: "and the window kept what it was showing before the share"
        )
        t.expect(
            isMenuItemEnabled(#selector(TerminalWindowController.shareThisWindow(_:)), on: window) == false,
            desc: "Share is off on a shared window"
        )
        t.expect(
            isMenuItemEnabled(#selector(TerminalWindowController.stopSharingWindow(_:)), on: window) == true,
            desc: "and Stop Sharing is on"
        )
        if closesFirstTab {
            checkFirstTabClose(t, participants: participants)
            return
        }
        if includesOtherPanes, let reference = shell.savedPresentation(needsLocalArrangement: true).liveWorkspace {
            checkIndependentWorkspaceAttachment(t, reference: reference, original: sharedSurfaces, participants: participants)
            for pane in sharedSurfaces { pane.drive.suspendRemote() }
            for pane in sharedSurfaces { pane.drive.resumeAfterSuspension(secondsSuspended: 120) }
            for (index, pane) in sharedSurfaces.enumerated() {
                t.expect(
                    t.wait(until: { pane.drive.remoteState == .Connected }, timeout: 20),
                    desc: "shared pane \(index) reconnects to its published workspace: \(pane.remoteFailureDetail)"
                )
                pane.send("echo pane-resumed:$UBQ_WINDOW_PANE\n")
                t.expect(
                    t.wait(until: { bufferHolds("pane-resumed:\(index)", in: pane) }, timeout: 10),
                    desc: "shared pane \(index) resumes the original shell"
                )
            }
        }
        var addedWindow: TerminalWindowController?
        if includesOtherPanes {
            let workspaceID =
                sharedSurfaces.first(where: { $0.drive.sharedWorkspaceResult.workspaceID != 0 })?.drive.sharedWorkspaceResult.workspaceID
                ?? 0
            addedWindow = addAnotherWindow(t, workspaceID: workspaceID)
        }
        defer { addedWindow?.window?.close() }

        let sharedSessionID = surface.remoteSessionID

        // Stop Sharing: the daemon hands the session back and the window reads
        // its own PTY again.
        NSApp.sendAction(#selector(TerminalWindowController.stopSharingWindow(_:)), to: shell, from: nil)
        t.expect(
            t.wait(until: { sharedSurfaces.allSatisfy { !$0.drive.isSharedIntoLocalDaemon } }, timeout: 20),
            desc: "stopping sharing reclaims every native tab and split pane"
        )
        for (index, pane) in sharedSurfaces.enumerated() where pane.drive.isSharedIntoLocalDaemon {
            t.expect(false, desc: "pane \(index) remained shared: \(pane.drive.remoteState), \(pane.remoteFailureDetail)")
        }
        t.expect(
            t.wait(until: { !surface.drive.isSharedIntoLocalDaemon && !surface.isRemoteAttached }, timeout: 20),
            desc: "the daemon handed session \(sharedSessionID) back and the window went local"
        )
        if let badge = shell.remoteConnectionIndicator {
            // The chrome comes down on the turn the hand-back's event reaches
            // the window, a turn after the session reads local here.
            t.expect(t.wait(until: { !badge.isShownForTesting }, timeout: 10), desc: "the title row no longer names a host")
        }
        surface.send("echo \"back:[$UBQ_SHARE_MARK]\"\n")
        t.expect(
            t.wait(until: { bufferHolds("back:[\(marker)]", in: surface) }, timeout: 10),
            desc: "the same shell answers through the window's own PTY — no new shell, no reconnect"
        )
        if let addedWindow, let pane = addedWindow.focusedSurfaceForTesting {
            t.expect(pane.drive.isSharedIntoLocalDaemon, desc: "reclaiming this window preserves the window added to its workspace")
            addedWindow.stopSharingWindow(nil)
            t.expect(
                t.wait(until: { !pane.drive.isSharedIntoLocalDaemon }, timeout: 20),
                desc: "the added window can also return to its original shell"
            )
        }
        t.expect(surface.drive.isShareableLocalSession, desc: "the shell is still this process's child, and shareable again")
        t.expect(isMenuItemEnabled(#selector(TerminalWindowController.shareThisWindow(_:)), on: window) == true, desc: "Share is back on")
        t.expect(
            isMenuItemEnabled(#selector(TerminalWindowController.stopSharingWindow(_:)), on: window) == false,
            desc: "and Stop Sharing off"
        )
    }
    /// Closing the native tab that attached the window's connection leaves
    /// the connection serving the panes of the tabs that remain, each of
    /// which still reaches its own shell and is still taken back alone.
    @MainActor
    private static func checkFirstTabClose(_ t: UBUITestContext, participants: [TerminalWindowController]) {
        guard participants.count == 2, let first = participants.first, let rest = participants.last else {
            t.expect(false, desc: "the shared window has two native tabs")
            return
        }
        let remaining = rest.projectedSurfaces
        first.window?.close()
        t.expect(t.wait(until: { first.isClosedForTesting }, timeout: 10), desc: "the first native tab closed")
        guard let anchor = remaining.first else {
            t.expect(false, desc: "the other native tab keeps a pane")
            return
        }
        for (index, pane) in remaining.enumerated() {
            t.expect(
                t.wait(until: { pane.drive.remoteState == .Connected && pane.drive.isSharedIntoLocalDaemon }, timeout: 20),
                desc: "remaining pane \(index) stays on the window's connection: \(pane.remoteFailureDetail)"
            )
            t.expect(
                pane.drive.sharesRemoteWorkspaceConnection(with: anchor.drive),
                desc: "remaining pane \(index) rides the same connection"
            )
            pane.send("echo pane-after-close:$UBQ_WINDOW_PANE\n")
            t.expect(
                t.wait(until: { bufferHolds("pane-after-close:", in: pane) }, timeout: 10),
                desc: "remaining pane \(index) still reaches its shell through the host"
            )
        }
        rest.stopSharingWindow(nil)
        t.expect(
            t.wait(until: { remaining.allSatisfy { !$0.drive.isSharedIntoLocalDaemon } }, timeout: 20),
            desc: "the remaining tab's panes are taken back after the first tab closed"
        )
    }

    /// The same authority opening the shared workspace in this app is shown
    /// the window that carries it; a second client, under an authority of its
    /// own, sees the published layout and drives the original shells.
    @MainActor
    private static func checkIndependentWorkspaceAttachment(
        _ t: UBUITestContext,
        reference: SavedTerminalPresentation.LiveWorkspace,
        original: [TerminalSurface],
        participants: [TerminalWindowController]
    ) {
        let openBefore = TerminalWindowController.spawnedControllers.filter { !$0.isClosedForTesting }.count
        let reopened = TerminalWindowController.spawnRemoteWindow(
            shellCommand: reference.bridgeCommand,
            hostLabel: "Shared window",
            quicHost: "",
            quicBootstrapCommand: "",
            deploySSHHost: "",
            deployBinaries: [:],
            reattachSessionID: reference.sessionID,
            workspaceName: "",
            reattachPolicy: .attachOnly,
            hostKey: "",
            workspaceID: reference.workspaceID,
            daemonSocketName: reference.socketName,
            daemonInstanceID: reference.daemonInstanceID
        )
        t.expect(
            reopened.map { opened in participants.contains { $0 === opened } } == true,
            desc: "opening the shared workspace here shows the window whose connection carries it"
        )
        t.expect(
            TerminalWindowController.spawnedControllers.filter { !$0.isClosedForTesting }.count == openBefore,
            desc: "and opens no window or connection of its own"
        )
        // Another device reaches the same daemon under an authority of its
        // own; a transport command spelled differently stands in for it.
        guard
            let remote = TerminalWindowController.spawnRemoteWindow(
                shellCommand: ": another device; " + reference.bridgeCommand,
                hostLabel: "Shared window",
                quicHost: "",
                quicBootstrapCommand: "",
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: reference.sessionID,
                workspaceName: "",
                reattachPolicy: .attachOnly,
                hostKey: "",
                workspaceID: reference.workspaceID,
                daemonSocketName: reference.socketName,
                daemonInstanceID: reference.daemonInstanceID
            ), let surface = remote.remoteSurface
        else {
            t.expect(false, desc: "a second client can open the shared workspace")
            return
        }
        defer { TerminalWindowController.detachRemoteWorkspaceForTesting(from: surface.drive) }
        func panes() -> [TerminalSurface] {
            (remote.window?.tabbedWindows ?? [remote.window].compactMap { $0 })
                .compactMap { $0.windowController as? TerminalWindowController }.flatMap(\.projectedSurfaces)
        }
        guard t.wait(until: { panes().count == original.count && panes().allSatisfy { $0.drive.remoteState == .Connected } }, timeout: 20)
        else {
            t.expect(false, desc: "another client receives every published native tab and split pane")
            return
        }
        let attached = panes()
        t.expect(remote.window?.tabbedWindows?.count == 2, desc: "the other client receives both tabs")
        for (index, pane) in original.enumerated() {
            // A pane reads connected when the workspace's structure names it,
            // and its picture follows the binding the host sends after that.
            t.expect(
                t.wait(until: { attached.contains { bufferHolds("pane-shared:\(index)", in: $0) } }, timeout: 10),
                desc: "the other client receives pane \(index)'s existing terminal state"
            )
            let mirror = attached.first { $0.remoteSessionID == pane.remoteSessionID }
            t.expect(mirror != nil, desc: "pane \(index) keeps its session identity across clients")
            mirror?.send("echo pane-remote:$UBQ_WINDOW_PANE\n")
            t.expect(
                t.wait(until: { bufferHolds("pane-remote:\(index)", in: pane) }, timeout: 10),
                desc: "the other client drives pane \(index)'s original shell"
            )
        }
    }

    @MainActor
    private static func addAnotherWindow(_ t: UBUITestContext, workspaceID: UInt32) -> TerminalWindowController? {
        guard workspaceID != 0, let controller = TerminalWindowController.spawn(), let window = controller.window,
            let surface = controller.focusedSurfaceForTesting
        else {
            t.expect(false, desc: "another local window opens")
            return nil
        }
        t.pump(0.3)
        controller.shareThisWindow(nil)
        guard let sheet = window.attachedSheet else {
            t.expect(false, desc: "the second window offers a sharing destination")
            return controller
        }
        func picker(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton { return popup }
            return view.subviews.lazy.compactMap { picker(in: $0) }.first
        }
        guard let popup = sheet.contentView.flatMap({ picker(in: $0) }),
            t.wait(until: { popup.menu?.item(withTag: Int(workspaceID)) != nil }, timeout: 20)
        else {
            t.expect(false, desc: "the existing workspace appears in the destination picker")
            window.endSheet(sheet)
            return controller
        }
        popup.selectItem(withTag: Int(workspaceID))
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        t.expect(
            t.wait(until: { surface.drive.sharedWorkspaceResult.workspaceID == workspaceID }, timeout: 20),
            desc: "Add to appends the new window to the selected workspace"
        )
        if let notice = window.attachedSheet { window.endSheet(notice) }
        return controller
    }

    /// Two installations remain separate owners, and either can list the other.
    @MainActor
    private static func checkOtherHostDiscovery(_ t: UBUITestContext, home: String, root: String, bundledHost: String) {
        let other = URL(fileURLWithPath: root).resolvingSymlinksInPath().appendingPathComponent("other/ubiquitty-host").path
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: other).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(atPath: bundledHost, toPath: other)
        } catch {
            t.expect(false, desc: "a separate host installation was prepared: \(error)")
            return
        }
        // Socket names identify binary contents. A distinct ad-hoc signature
        // gives the fixture another build identity without changing its code.
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", "--identifier", "org.ubiquitty.discovery-fixture", other]
        do { try signer.run() } catch {
            t.expect(false, desc: "the other fixture could be signed: \(error)")
            return
        }
        signer.waitUntilExit()
        guard signer.terminationStatus == 0 else {
            t.expect(false, desc: "the other fixture received a distinct build identity")
            return
        }
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: other)
        daemon.arguments = ["--daemon", "--columns", "80", "--rows", "24"]
        daemon.environment = ProcessInfo.processInfo.environment.merging(["UBIQUITTY_HOME": home]) { $1 }
        do { try daemon.run() } catch {
            t.expect(false, desc: "the other installation started: \(error)")
            return
        }
        defer {
            if daemon.isRunning { daemon.terminate() }
            daemon.waitUntilExit()
        }
        let socket = String(Ubiquitty.Session.localDaemonSocketPath(std.string(other)))
        guard t.wait(until: { FileManager.default.fileExists(atPath: socket) }, timeout: 20) else {
            t.expect(false, desc: "the other installation opened its own socket")
            return
        }
        let quoted = bundledHost.withCString { Ubiquitty.Transport.shellSingleQuote(std.string_view($0)) }
        let command = String(quoted).withCString { Ubiquitty.Session.localBridgeCommand(std.string_view($0)) }
        var directory = Ubiquitty.Runtime.HostDirectoryClient(command, Ubiquitty.Apple.mainQueueLoop())
        _ = directory.refresh()
        guard t.wait(until: { directory.snapshot().phase == .Listed }, timeout: 20) else {
            t.expect(false, desc: "the default installation answered its directory: \(String(directory.snapshot().error))")
            return
        }
        let instances = directory.hostInstances()
        let found = (0..<Int(instances.count())).map { instances.instanceAt($0) }
            .first { String($0.socketName) == URL(fileURLWithPath: socket).lastPathComponent }
        guard let found else {
            t.expect(false, desc: "the default directory discovered the other live installation")
            return
        }
        let quotedBundled = String(quoted)
        let plan = ""
            .withCString { host in
                quotedBundled.withCString { Ubiquitty.Session.hostInstanceTransportPlan(std.string_view(host), found, std.string_view($0)) }
            }
        var selected = Ubiquitty.Runtime.HostDirectoryClient(plan.shellCommand, Ubiquitty.Apple.mainQueueLoop())
        _ = selected.refresh()
        t.expect(
            t.wait(until: { selected.snapshot().phase == .Listed }, timeout: 20),
            desc: "the selected installation answers through its own helper"
        )
        t.expect(selected.snapshot().daemonSocketName == found.socketName, desc: "selection reaches the exact discovered socket")
        t.expect(
            selected.snapshot().daemonInstanceID != directory.snapshot().daemonInstanceID,
            desc: "the two installation identities remain distinct"
        )
        let model = ConnectModel()
        defer { model.directory.stopFollowing() }
        model.select(.thisMacHost)
        t.expect(
            t.wait(
                until: {
                    model.noteDirectoryChanged()
                    return model.otherHostInstances.contains { $0.socketName == String(found.socketName) }
                },
                timeout: 20
            ),
            desc: "Connect exposes the other installation in Running Sessions"
        )
        model.selectHostInstance(String(found.socketName))
        t.expect(
            t.wait(until: { model.directory.daemonInstanceID == selected.snapshot().daemonInstanceID }, timeout: 20),
            desc: "Connect switches its directory to the selected installation"
        )
        model.select(.thisMacHost)
        t.expect(
            t.wait(until: { model.directory.daemonInstanceID == selected.snapshot().daemonInstanceID }, timeout: 20),
            desc: "selecting the same sidebar place preserves the chosen installation"
        )
        model.selectHostInstance("")
        t.expect(
            t.wait(until: { model.directory.daemonInstanceID == directory.snapshot().daemonInstanceID }, timeout: 20),
            desc: "Default Host returns to the bundled installation"
        )
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: socket)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socket) }
            _ = directory.refresh()
            t.expect(
                t.wait(
                    until: {
                        let current = directory.hostInstances()
                        return directory.snapshot().phase == .Listed
                            && !(0..<Int(current.count())).contains { current.instanceAt($0).socketName == found.socketName }
                    },
                    timeout: 20
                ),
                desc: "discovery refuses an endpoint whose socket is accessible to other users"
            )
        } catch {
            t.expect(false, desc: "the isolated socket permission fixture was prepared: \(error)")
        }

        // The picked installation stops without handing over. Its pinned
        // listing is told it is gone, and Connect returns to the host's
        // current daemon instead of dialling the stopped one again.
        model.selectHostInstance(String(found.socketName))
        t.expect(
            t.wait(until: { model.directory.daemonInstanceID == selected.snapshot().daemonInstanceID }, timeout: 20),
            desc: "Connect lists the other installation again"
        )
        daemon.terminate()
        daemon.waitUntilExit()
        t.expect(!FileManager.default.fileExists(atPath: socket), desc: "the stopped installation removed its socket")
        model.directory.refresh()
        t.expect(
            t.wait(
                until: {
                    model.noteDirectoryChanged()
                    return model.selectedHostSocket.isEmpty && model.directory.daemonInstanceID == directory.snapshot().daemonInstanceID
                },
                timeout: 20
            ),
            desc: "a picked installation that stopped gives way to the host's current daemon"
        )
        t.expect(
            !model.otherHostInstances.contains { $0.socketName == String(found.socketName) },
            desc: "Running Sessions no longer offers the stopped installation"
        )
    }
}
