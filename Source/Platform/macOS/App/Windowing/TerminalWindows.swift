// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The application's terminal-window roster and session capture policy.
// Core owns the stored tab shape; this file supplies each window's facts.

import AppKit
import CxxStdlib
import UbiquittyCore
import UbiquittyKit

private typealias TmuxProtocol = Ubiquitty.`Protocol`.Tmux

/// The session facts and actions the application needs from a terminal window.
@MainActor
protocol OpenTerminalWindow: NSWindowController {
    /// What the session capture decides this window's tab by.
    var tabCaptureFacts: Ubiquitty.Session.TabCaptureFacts { get }

    /// The focused pane's grid, which a restored tab opens at.
    var capturedGrid: (columns: Int, rows: Int) { get }

    /// The tags the reader set on this window by hand; rule-derived tags are
    /// recomputed and never stored.
    var handSetTags: [String] { get set }

    /// Whether this window appends its session to a log file.
    var isLoggingSession: Bool { get }

    /// Whether Share This Window can hand this window's shell to the local
    /// daemon.
    var isShareableIntoDaemon: Bool { get }

    /// Whether Stop Sharing This Window can take this window's shared shell
    /// back from the daemon.
    var isReclaimableFromDaemon: Bool { get }

    /// Whether closing this window would end a job running in it.
    var hasRunningProcesses: Bool { get }

    /// The catalog theme this window paints, or -1 for a palette no catalog
    /// theme matches.
    var paintedThemeIndex: Int { get }

    /// Hands this window's running shell to the local daemon, leaving the
    /// window as it is: the capture at quit, after which the daemon keeps the
    /// shell alive.
    ///
    /// - Parameters:
    ///   - socketPath: The daemon's control socket, already up.
    ///   - bridgeCommand: The same daemon's reconnect command, retained by Core.
    /// - Returns: The daemon's id for the shell, or zero when it did not take it.
    func handShellToDaemon(atSocketPath socketPath: String, bridgeCommand: String) -> UInt32

    /// Points an inspector at the pane this window would inspect.
    ///
    /// - Parameter model: The inspector's model.
    func inspect(in model: TerminalInspectorModel)

    /// Fills the application's Session menu with this window's presence
    /// roster.
    ///
    /// - Parameter menu: The Session menu.
    /// - Returns: Whether this window is on a session with a roster to show.
    func populateSessionMenu(_ menu: NSMenu) -> Bool
}

extension TerminalWindowController: OpenTerminalWindow {
    var handSetTags: [String] {
        get { manualTags }
        set { manualTags = newValue }
    }

    var isShareableIntoDaemon: Bool { isWindowShareable }

    var isReclaimableFromDaemon: Bool { sharedSurface?.drive.isReclaimableSharedSession == true }

    var hasRunningProcesses: Bool { !isSafeToClose }

    func populateSessionMenu(_ menu: NSMenu) -> Bool {
        guard let indicator = presenceIndicator, remoteSurface != nil || sharedSurface != nil else { return false }
        menu.removeAllItems()
        for item in indicator.rosterMenu(activitySubmenu: true).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
        return true
    }
}

/// The open terminal windows and their application-level actions.
@MainActor
@objc(UBTerminalWindows)
final class TerminalWindows: NSObject {
    /// The open window controllers presented by the Window menu.
    @objc
    static func openControllers() -> [NSWindowController] {
        keptBySession().map { $0 as NSWindowController }
    }

    @objc
    static func applyProfileToKeyTerminal(named name: String) {
        (keyTerminal() as? TerminalWindowController)?.applyProfile(named: name)
    }

    @objc
    static func runEditorCommand(_ command: String) {
        let existing = keyTerminal() as? TerminalWindowController
        if let surface = existing?.beamSurface, surface.drive.isForegroundLocalShell {
            existing?.sendScriptText(command)
            return
        }
        guard let controller = TerminalWindowController.spawn(arguments: ["/bin/sh"], localePolicy: .auto, sessionLifetime: .outlivesChild)
        else { return }
        if let window = existing?.window, let opened = controller.window {
            window.addTabbedWindow(opened, ordered: .above)
            opened.makeKeyAndOrderFront(nil)
        }
        controller.sendScriptText(command)
    }

    /// Every terminal window the application holds, front to back, each once,
    /// whichever shell drew it — the drop-down panel among them.
    ///
    /// Front to back is the on-screen stack, read from `orderedWindows`; the
    /// application's other windows follow it, so a miniaturized terminal or a
    /// tab behind its group's selected one is still listed, and so is a closed
    /// window whose controller has not gone yet. The windows a session keeps,
    /// all of them open, are `keptBySession()`. The scripting dictionary
    /// publishes this list as its `window` element, where `front window` is
    /// the one standing highest in that stack — a window kept on top stands
    /// above the key window, which is the one the menus act on
    /// (`keyTerminal()`).
    static func all() -> [any OpenTerminalWindow] {
        var found: [any OpenTerminalWindow] = []
        for window in NSApp.orderedWindows + NSApp.windows {
            guard let terminal = window.windowController as? any OpenTerminalWindow,
                !found.contains(where: { $0 === terminal })
            else {
                continue
            }
            found.append(terminal)
        }
        return found
    }

    /// The terminal windows a saved session keeps, front to back: every one
    /// but the drop-down panel, which comes back with its hotkey rather than
    /// with the session.
    static func keptBySession() -> [any OpenTerminalWindow] {
        let rostered: [any OpenTerminalWindow] =
            TerminalWindowController.spawnedControllers
        return all()
            .filter { terminal in
                (terminal as? TerminalWindowController)?.isArrangementControlClient != true
                    && rostered.contains { $0 === terminal }
            }
    }

    /// The terminal window the reader is working in, judged by the
    /// application's own key and main windows (`keyTerminal(keyWindow:mainWindow:)`).
    ///
    /// - Returns: The terminal, or nil when none is open.
    static func keyTerminal() -> (any OpenTerminalWindow)? {
        keyTerminal(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
    }

    /// The terminal window the reader is working in.
    ///
    /// The key window's, else the main window's — the one under a utility
    /// panel that holds the keyboard — whichever terminal it is, the drop-down
    /// panel included. With neither a terminal — the application inactive, or
    /// a settings window in front — it is the frontmost window a session keeps,
    /// which is the one a menu acts on then.
    ///
    /// - Parameters:
    ///   - keyWindow: The window holding the keyboard.
    ///   - mainWindow: The window the key one works for.
    ///   - closingWindow: A window that is going, which is no answer even while
    ///     it is key: AppKit posts `willClose` before it orders the window out,
    ///     so it is still key, still main and still on its shell's roster
    ///     there, and a reader pointed at it is pointed at nothing.
    /// - Returns: The terminal, or nil when none is open.
    static func keyTerminal(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        besides closingWindow: NSWindow? = nil
    ) -> (any OpenTerminalWindow)? {
        for candidate in [keyWindow, mainWindow] {
            guard let candidate, candidate !== closingWindow else { continue }
            if let terminal = candidate.windowController as? any OpenTerminalWindow {
                return terminal
            }
        }
        return keptBySession().first { $0.window !== closingWindow }
    }

    /// The terminal window the reader is working in once a window that is
    /// closing has been left out (`keyTerminal(keyWindow:mainWindow:besides:)`).
    ///
    /// - Parameter closingWindow: The window that is going.
    /// - Returns: The terminal, or nil when the closing one was the last.
    static func keyTerminal(besides closingWindow: NSWindow?) -> (any OpenTerminalWindow)? {
        keyTerminal(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow, besides: closingWindow)
    }

    /// Whether a terminal window of either shell is open to act on.
    @objc
    static var hasKeyTerminal: Bool {
        keyTerminal() != nil
    }

    /// The catalog theme the key terminal window paints.
    ///
    /// - Returns: The theme's index, -1 for a palette no catalog theme
    ///   matches, or nil when no terminal window is open.
    @objc
    static func keyTerminalThemeIndex() -> NSNumber? {
        keyTerminal().map { NSNumber(value: $0.paintedThemeIndex) }
    }

    /// Names File ▸ Log Session to File… for the key terminal window: the
    /// title and check follow whether that window keeps a log.
    ///
    /// - Parameter item: The menu item.
    /// - Returns: Whether the item is enabled, which it is while a terminal
    ///   window is open.
    @objc
    static func validateSessionLogItem(_ item: NSMenuItem) -> Bool {
        let terminal = keyTerminal()
        TerminalWindowController.labelSessionLogItem(item, for: terminal?.isLoggingSession == true ? .on : .off)
        return terminal != nil
    }

    /// Starts or stops the session log of the key terminal window when the
    /// Swift shell drew it.
    ///
    /// - Returns: Whether a Swift terminal took the command; any other window
    ///   answers it in the app delegate.
    @objc
    static func toggleSessionLogOfKeySwiftTerminal() -> Bool {
        guard let terminal = keyTerminal() as? TerminalWindowController else { return false }
        terminal.toggleSessionLog(nil)
        return true
    }

    /// Names File ▸ Share This Window with Agents and File ▸ Stop Sharing This
    /// Window for the key terminal window, whichever shell drew it.
    ///
    /// The application is asked for these two whenever the window in front is
    /// not a terminal — a settings window holds the keyboard, and the terminal
    /// behind it answers nothing itself. The Session Log item beside them is
    /// answered for that same window, and two items in one menu acting on two
    /// different windows is worse than either answer.
    ///
    /// - Parameter item: The menu item.
    /// - Returns: Whether the item is enabled.
    @objc
    static func validateSharingItem(_ item: NSMenuItem) -> Bool {
        guard let terminal = keyTerminal() else { return false }
        if let controller = terminal as? TerminalWindowController { return controller.validateMenuItem(item) }
        return item.action == NSSelectorFromString("stopSharingWindow:")
            ? terminal.isReclaimableFromDaemon
            : terminal.isShareableIntoDaemon
    }

    /// Sends a menu action to the key terminal window when the Swift shell
    /// drew it, which implements these actions itself.
    ///
    /// The window answers for itself while it is key, ahead of the
    /// application; this is the route for the rest — a settings window in
    /// front, or a window that is main under a utility panel.
    ///
    /// - Parameter action: The action the menu item carries.
    /// - Returns: Whether a Swift terminal took it; any other window is
    ///   answered in the app delegate.
    @objc(sendActionToKeySwiftTerminal:)
    static func sendAction(toKeySwiftTerminal action: Selector) -> Bool {
        guard let terminal = keyTerminal() as? TerminalWindowController, terminal.responds(to: action) else { return false }
        NSApp.sendAction(action, to: terminal, from: nil)
        return true
    }

    /// Opens a tab on the key terminal window when the Swift shell drew it.
    ///
    /// A tab joins the window it is opened from, and a window of one shell
    /// cannot host a tab of the other: ⌘T asks the window the menus act on,
    /// which is the one the reader was last typing in even while a settings
    /// window holds the keyboard.
    ///
    /// - Parameter profileName: The profile the tab opens under, empty for the
    ///   configuration's own answer.
    /// - Returns: Whether that shell took the command.
    @objc(openTabInKeySwiftTerminalWithProfileNamed:)
    static func openTabInKeySwiftTerminal(profileNamed profileName: String) -> Bool {
        guard let terminal = keyTerminal() as? TerminalWindowController else { return false }
        guard !profileName.isEmpty else {
            terminal.newWindowForTab(nil)
            return true
        }
        guard let window = terminal.window, let sibling = TerminalWindowController.spawn(profileNamed: profileName, as: .tab),
            let siblingWindow = sibling.window
        else {
            return true
        }
        window.addTabbedWindow(siblingWindow, ordered: .above)
        siblingWindow.makeKeyAndOrderFront(nil)
        return true
    }

    /// Fills the application's Session menu with the key terminal window's
    /// presence roster, whichever shell drew it.
    ///
    /// The roster is a property of one session, so the menu speaks for the
    /// window the reader is working in; a window on no remote session has
    /// nobody attached to show.
    ///
    /// - Parameter menu: The Session menu.
    @objc
    static func populateSessionMenu(_ menu: NSMenu) {
        if keyTerminal()?.populateSessionMenu(menu) == true { return }
        menu.removeAllItems()
        let none = NSMenuItem(title: "No Remote Session", action: nil, keyEquivalent: "")
        none.isEnabled = false
        menu.addItem(none)
    }

    /// Whether View ▸ Theme ▸ Edit Current Theme… has a window to edit.
    ///
    /// The Settings editor seeds its draft from the active terminal theme.
    @objc
    static var canEditKeyTerminalTheme: Bool {
        keyTerminal() != nil
    }

    /// Toggles the inspector of the key terminal window when the Swift shell
    /// drew it, which keeps its inspector beside the grid.
    ///
    /// - Returns: Whether a Swift terminal took the command; any other window's
    ///   inspector is the application's shared panel.
    @objc
    static func toggleInspectorOfKeySwiftTerminal() -> Bool {
        guard let terminal = keyTerminal() as? TerminalWindowController else { return false }
        terminal.toggleNativeInspector(nil)
        return true
    }

    /// Describes fresh launches separately from references to running hosted sessions.
    static func summary(for arrangement: LayoutSession) -> String {
        let tabs = arrangement.groups.flatMap(\.tabs)
        let liveCount =
            tabs.filter {
                let presentation = SavedTerminalPresentation.decoded($0.paneLayout ?? "")
                return presentation?.liveWorkspace != nil || presentation?.tmuxWindow != nil || $0.sessionID != 0
            }
            .count
        let recipeCount = tabs.count - liveCount
        var parts: [String] = []
        if recipeCount != 0 { parts.append("\(recipeCount) local tab\(recipeCount == 1 ? "" : "s"): new shells") }
        if liveCount != 0 { parts.append("\(liveCount) hosted tab\(liveCount == 1 ? "" : "s"): reconnect") }
        return parts.joined(separator: " · ")
    }

    /// Saves launch recipes and live references without changing the open windows.
    @objc(saveArrangementWithName:)
    static func saveArrangement(named name: String) -> Bool {
        let groups = capturedGroupsForSavedWorkspace()
        guard !groups.isEmpty else { return false }
        let session = LayoutSession()
        session.identifier = UUID().uuidString
        session.name = name.isEmpty ? "Arrangement" : name
        session.groups = groups
        do {
            try SessionLayout.save(SessionLayout.allSessions() + [session])
            return true
        } catch {
            return false
        }
    }

    @objc
    static func promptToSaveArrangement() {
        let alert = NSAlert()
        alert.messageText = "Save Arrangement"
        alert.informativeText =
            "Local panes will open new shells in their saved folders. Hosted panes will reconnect to their running sessions."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "Arrangement name"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !saveArrangement(named: name) {
            let failure = NSAlert()
            failure.messageText = "The arrangement couldn’t be saved."
            failure.informativeText = "Make sure a terminal window is open and the session store is writable."
            presentRestoreAlert(failure)
        }
    }

    @objc(appendArrangementActionsToMenu:)
    static func appendArrangementActions(to menu: NSMenu) {
        let replace = NSMenuItem(title: "Replace Current Windows…", action: #selector(replaceCurrentWindows(_:)), keyEquivalent: "")
        replace.target = TerminalWindows.self
        menu.addItem(replace)
        let remote = menu.addItem(withTitle: "Remote Workspaces", action: nil, keyEquivalent: "")
        remote.submenu = TerminalWindowController.makeRemoteWorkspaceMenu()
    }

    @objc
    private static func replaceCurrentWindows(_ sender: Any?) {
        let arrangements = SessionLayout.namedWorkspaces()
        guard !arrangements.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No saved arrangements."
            alert.informativeText = "Save an arrangement before replacing your current windows."
            presentRestoreAlert(alert)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Replace Current Windows"
        alert.informativeText =
            "Local panes open new shells; hosted panes reconnect. After the arrangement opens, existing windows close using their normal confirmation rules. Closing a window can end its processes."
        alert.addButton(withTitle: "Open and Replace")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        picker.addItems(withTitles: arrangements.map(\.name))
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn,
            arrangements.indices.contains(picker.indexOfSelectedItem)
        else { return }
        let groups = arrangements[picker.indexOfSelectedItem].groups
        Task { @MainActor in _ = await replaceWindows(with: groups) }
    }

    /// Closes previous windows only after every replacement is available.
    ///
    /// - Parameter groups: The arrangement chosen explicitly for replacement.
    /// - Returns: Whether the replacement opened and normal close actions were requested.
    static func replaceWindows(with groups: [LayoutGroup]) async -> Bool {
        guard !isRestoringArrangement else { return false }
        isRestoringArrangement = true
        defer { isRestoringArrangement = false }
        let existing = keptBySession().compactMap(\.window)
        guard let opened = await openArrangementGroups(groups), !opened.isEmpty else { return false }
        for attempt in 0..<300 {
            let controllers = opened.compactMap { $0.windowController as? TerminalWindowController }
            if controllers.count != opened.count || controllers.contains(where: { $0.arrangementReadiness == .unavailable }) {
                break
            }
            if controllers.allSatisfy({ $0.arrangementReadiness == .ready }) {
                let supporting = controllers.compactMap(\.arrangementSupportingWindow)
                for window in existing where !(opened + supporting).contains(where: { $0 === window }) {
                    window.performClose(nil)
                }
                return true
            }
            if attempt < 299 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let alert = NSAlert()
        alert.messageText = "Your current windows have been kept."
        alert.informativeText =
            "Some saved sessions couldn’t connect. The arrangement’s available windows remain open, and no previous window was closed."
        presentRestoreAlert(alert)
        return false
    }

    private static func presentRestoreAlert(
        _ alert: NSAlert,
        completion: (@MainActor @Sendable (NSApplication.ModalResponse) -> Void)? = nil
    ) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? keptBySession().compactMap(\.window).first {
            if window.attachedSheet == nil {
                alert.beginSheetModal(for: window) { response in completion?(response) }
            }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }

    private static var isRestoringArrangement = false

    /// Schedules restoration without blocking the native event loop.
    ///
    /// - Parameter groups: The captured groups to restore additively.
    static func restoreGroups(_ groups: [LayoutGroup]) {
        Task { @MainActor in _ = await restoreArrangementGroups(groups) }
    }

    /// Restores each available tab and preserves existing windows when any tab is refused.
    ///
    /// - Parameter groups: The saved window groups.
    /// - Returns: Whether every tab opened or activated an existing live window.
    @discardableResult
    static func restoreArrangementGroups(_ groups: [LayoutGroup]) async -> Bool {
        // A window saved on a host the launch's upgrade replaces reattaches
        // where that host's sessions went, so it waits for the upgrade, and
        // holds no other restore off while it waits.
        await LocalHostUpgrade.settledAtLaunch()
        guard !isRestoringArrangement else { return false }
        isRestoringArrangement = true
        defer { isRestoringArrangement = false }
        return await openArrangementGroups(groups) != nil
    }

    /// The arrangement this launch restores, opening.
    ///
    /// Core decides whether a launch restores the arrangement the last quit
    /// kept (`Session::isSessionKeptByQuit`, asked of the reason it was kept
    /// for), and the store gives it up once (`SessionLayout.takeLayoutForLaunch`).
    ///
    /// - Returns: The restore in flight, answering whether every tab opened,
    ///   or nil when this launch restores nothing.
    @discardableResult
    static func restoreLaunchArrangement() -> Task<Bool, Never>? {
        guard let groups = SessionLayout.takeLayoutForLaunch(Ubiquitty.Preferences.values().pointee), !groups.isEmpty else {
            return nil
        }
        return Task { @MainActor in await restoreArrangementGroups(groups) }
    }

    /// Opens each available tab before applying its group's device-local placement.
    ///
    /// Groups open in saved order, each above the last, and the ones that were
    /// in full screen go back into it once every group stands where it did.
    ///
    /// - Parameter groups: The groups to open in saved order.
    /// - Returns: The restored windows, or nil when any tab was unavailable.
    private static func openArrangementGroups(_ groups: [LayoutGroup]) async -> [NSWindow]? {
        var didRestoreAll = true
        var restored: [NSWindow] = []
        var fullScreen: [NSWindow] = []
        let existingControllers = Set(TerminalWindowController.spawnedControllers.map(ObjectIdentifier.init))
        for group in groups {
            var windows: [NSWindow] = []
            var selectedIndex = 0
            for (index, tab) in group.tabs.enumerated() {
                guard !Task.isCancelled, let window = await openRestoredTab(tab, existingControllers: existingControllers) else {
                    didRestoreAll = false
                    continue
                }
                let windowIndex = windows.firstIndex(where: { $0 === window }) ?? windows.count
                if index == group.activeTab { selectedIndex = windowIndex }
                if windowIndex == windows.count { windows.append(window) }
            }
            let placement = LayoutGroup()
            placement.frame = group.frame
            placement.activeTab = selectedIndex
            settleRestoredGroup(placement, windows: windows)
            if group.isFullScreen, let shown = windows.indices.contains(selectedIndex) ? windows[selectedIndex] : windows.first {
                fullScreen.append(shown)
            }
            restored.append(contentsOf: windows)
        }
        for window in fullScreen {
            await enterFullScreen(window)
        }
        return didRestoreAll ? restored : nil
    }

    /// Puts a restored window back into full screen.
    ///
    /// One window at a time: each transition is an animation into a Space of
    /// its own, and the next starts once the last has settled. The wait is
    /// bounded, so a transition the window manager refuses costs the restore
    /// a few seconds rather than the rest of the arrangement.
    ///
    /// - Parameter window: The window, already at its windowed frame.
    private static func enterFullScreen(_ window: NSWindow) async {
        guard !window.styleMask.contains(.fullScreen), window.isVisible else { return }
        window.toggleFullScreen(nil)
        for _ in 0..<50 {
            if window.styleMask.contains(.fullScreen) { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    /// Opens a saved launch recipe or reconnects its explicitly identified live workspace.
    ///
    /// - Parameters:
    ///   - tab: The saved tab and its presentation.
    ///   - existingControllers: The controllers that predate the whole restore operation.
    /// - Returns: The restored window, or nil when its reference cannot be opened.
    private static func openRestoredTab(_ tab: LayoutTab, existingControllers: Set<ObjectIdentifier>) async -> NSWindow? {
        let presentationText = tab.paneLayout ?? ""
        var presentation = SavedTerminalPresentation.decoded(presentationText)
        if presentationText.hasPrefix(SavedTerminalPresentation.prefix), presentation == nil {
            let alert = NSAlert()
            alert.messageText = "This arrangement couldn’t be opened."
            alert.informativeText = "Its saved layout is damaged. Your open windows haven’t been changed."
            presentRestoreAlert(alert)
            return nil
        }
        if let profileName = presentation?.profileName, !profileName.isEmpty,
            !Ubiquitty.Preferences.values().pointee.profiles.contains(where: { String($0.name) == profileName })
        {
            let alert = NSAlert()
            alert.messageText = "The profile “\(profileName)” is unavailable."
            alert.informativeText = "Open this arrangement using your current default settings?"
            alert.addButton(withTitle: "Use Default Settings")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            presentation?.profileName = ""
        }
        var stored = Ubiquitty.Session.RestoredTab()
        stored.sessionID = tab.sessionID
        stored.bridgeCommand = std.string(tab.bridgeCommand ?? "")
        stored.socketName = std.string(tab.socketName ?? "")
        stored.hostLabel = std.string(tab.hostLabel ?? "")
        stored.paneLayout = std.string(tab.paneLayout ?? "")
        for session in tab.reclaimSessionIDsAfterUpdate {
            stored.reclaimSessionIDsAfterUpdate.push_back(session)
        }
        if let live = presentation?.liveWorkspace {
            guard live.sessionID != 0, live.daemonInstanceID != 0, !live.bridgeCommand.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "This live session couldn’t be restored."
                alert.informativeText =
                    "The saved arrangement doesn’t identify a session on \(live.hostLabel). Connect to that host to choose a workspace."
                presentRestoreAlert(alert)
                return nil
            }
            stored.sessionID = live.sessionID
            stored.bridgeCommand = std.string(live.bridgeCommand)
            stored.socketName = std.string(live.socketName)
            stored.hostLabel = std.string(live.hostLabel)
        } else if presentation != nil, stored.sessionID != 0 {
            let alert = NSAlert()
            alert.messageText = "This live session couldn’t be restored."
            alert.informativeText =
                "The saved arrangement doesn’t identify the host it belongs to. Connect to the host to choose a workspace."
            presentRestoreAlert(alert)
            return nil
        }
        let quotedBinary = (ShareSessionSupport.localHostBinaryPath() ?? "")
            .withCxxStringView {
                Ubiquitty.Transport.shellSingleQuote($0)
            }
        let plan = Ubiquitty.Session.planRestoredTab(stored, quotedBinary)

        let openBefore = existingControllers
        let opened: TerminalWindowController?
        if let tmux = presentation?.tmuxWindow {
            opened = await openRestoredTmuxWindow(tmux)
            guard opened != nil else { return nil }
        } else if plan.action == .Reattach {
            // A tab re-homed to this Mac's daemon goes back under the key the
            // This Mac row dials, so it is placed on this machine as it was
            // before the restart rather than on a remote host called "local".
            let hostLabel = String(plan.hostLabel)
            // A handed-over split is regrouped over the connection the window
            // attaches through, which the daemon admits only from a local
            // stream: the bridge, not the QUIC carrier.
            let isHandedOverSplit = presentation?.handedOverSplit != nil
            opened = TerminalWindowController.spawnRemoteWindow(
                shellCommand: String(plan.bridgeCommand),
                hostLabel: hostLabel,
                quicHost: isHandedOverSplit ? "" : String(plan.transport.quicHost),
                quicBootstrapCommand: isHandedOverSplit ? "" : String(plan.transport.quicBootstrapCommand),
                deploySSHHost: "",
                deployBinaries: [:],
                reattachSessionID: plan.sessionID,
                workspaceName: "",
                hostKey: hostLabel == TerminalWindowController.thisMacHostKey ? hostLabel : "",
                workspaceID: presentation?.liveWorkspace?.workspaceID ?? 0,
                daemonSocketName: String(stored.socketName),
                daemonInstanceID: presentation?.liveWorkspace?.daemonInstanceID ?? 0
            )
        } else if let archive = presentation?.localArrangement {
            opened = TerminalWindowController.spawn(restoringArrangement: archive)
        } else {
            opened = TerminalWindowController.spawn(restoringLayout: String(plan.paneLayout))
        }
        guard var opened else {
            let alert = NSAlert()
            alert.messageText = "This arrangement couldn’t be opened."
            alert.informativeText = "A saved pane couldn’t be started. Check that its folder is available, then try again."
            presentRestoreAlert(alert)
            return nil
        }
        let savedPresentation = presentation
        func dress(_ controller: TerminalWindowController) {
            guard !openBefore.contains(ObjectIdentifier(controller)) else { return }
            if let savedPresentation {
                if !savedPresentation.profileName.isEmpty {
                    controller.applyProfile(named: savedPresentation.profileName)
                }
                // A hosted tab's title is the host's and arrives with its
                // layout; asking the host to rename it to what it already
                // holds would be a verb with no effect, or a stale one if it
                // was renamed since.
                controller.setCustomTitles(
                    window: savedPresentation.windowTitle,
                    tab: savedPresentation.liveWorkspace == nil ? savedPresentation.tabTitle : nil
                )
            }
            if let tags = tab.tags, !tags.isEmpty {
                controller.handSetTags = tags
            }
        }
        dress(opened)
        if plan.action == .Reattach, !(await isRestoredWindowReady(opened)) {
            if !openBefore.contains(ObjectIdentifier(opened)) { opened.window?.close() }
            presentUnavailableSession(
                title: "This hosted session couldn’t be restored.",
                detail: "The saved session on \(String(plan.hostLabel)) is unavailable."
            )
            return nil
        }
        if plan.action == .Reattach, let split = presentation?.handedOverSplit {
            if let whole = await regroupHandedOverSplit(split, in: opened) {
                if whole !== opened { dress(whole) }
                opened = whole
            } else {
                // The tab keeps its place in its window with the pane it has.
                let alert = NSAlert()
                alert.messageText = "This split couldn’t be restored whole."
                alert.informativeText =
                    "The window shows its first pane. The other panes are still running on this Mac, each in a workspace of its own."
                presentRestoreAlert(alert)
            }
        }
        if let tmux = presentation?.tmuxWindow, !openBefore.contains(ObjectIdentifier(opened)) {
            opened.focusRestoredHostedPane(tmux.focusedPaneID)
        }
        return opened.window
    }

    /// Puts a split a quit handed over back together on the local daemon,
    /// starting from the window that rejoined its first pane.
    ///
    /// The quit handed each pane over on its own, so the daemon holds each in
    /// a workspace of its own until this asks it for one workspace holding
    /// the split, from the bridge connection attached to the first pane
    /// (`TerminalSession::publishSharedWorkspace`). The daemon arranges the
    /// split under a host tab of its own, focused pane included, and the
    /// projection shows a new host tab in a window of its own, closing the
    /// one that rejoined the first pane. That new window is the one the
    /// restore places. A split some window already shows, because a restore
    /// reached it before, asks nothing.
    ///
    /// - Parameters:
    ///   - split: The split and its sessions, as the quit stored them.
    ///   - controller: The window attached to the first pane's session.
    /// - Returns: The window showing every pane of the split, or nil when the
    ///   daemon did not regroup it.
    private static func regroupHandedOverSplit(
        _ split: SavedTerminalPresentation.HandedOverSplit,
        in controller: TerminalWindowController
    ) async -> TerminalWindowController? {
        let showingEveryPane = {
            TerminalWindowController.spawnedControllers.first { candidate in
                !candidate.isWindowClosed
                    && Set(candidate.projectedSurfaces.map(\.remoteSessionID)).isSuperset(of: split.sessions)
                    && candidate.projectedSurfaces.allSatisfy { $0.drive.remoteState == .Connected }
            }
        }
        if let whole = showingEveryPane() { return whole }
        guard let surface = controller.remoteSurface else { return nil }
        var request = Ubiquitty.Session.SharedWorkspace()
        guard Ubiquitty.Session.deserializeWorkspaceText(std.string(split.arrangement), &request.arrangement) else { return nil }
        for session in split.sessions {
            request.sessions.push_back(session)
        }
        var isSent = false
        for _ in 0..<300 {
            if Task.isCancelled { return nil }
            if !isSent {
                if controller.arrangementReadiness == .unavailable { return nil }
                // Connected precedes the pane binding that admits the call,
                // so a refusal to send is retried.
                isSent = surface.drive.publishSharedWorkspace(request)
            } else {
                let result = surface.drive.sharedWorkspaceResult
                if !result.isPending, result.workspaceID == 0 { return nil }
                if !result.isPending, let whole = showingEveryPane() { return whole }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        return nil
    }

    /// Waits for an actual connection before reporting a saved session as restored.
    ///
    /// - Parameter controller: The window opening the saved reference.
    /// - Returns: Whether the saved session became available before cancellation or timeout.
    private static func isRestoredWindowReady(_ controller: TerminalWindowController) async -> Bool {
        for _ in 0..<300 {
            if Task.isCancelled { return false }
            switch controller.arrangementReadiness {
            case .ready: return true
            case .unavailable: return false
            case .waiting: break
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }

    /// Offers a fresh local process only after the user explicitly chooses one.
    ///
    /// - Parameters:
    ///   - title: The unavailable session kind.
    ///   - detail: The host or connection that could not be restored.
    private static func presentUnavailableSession(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText =
            detail
            + " Your existing windows have been kept. Opening a new terminal starts a fresh local shell; it doesn’t recover the saved process."
        alert.addButton(withTitle: "Keep Existing Windows")
        alert.addButton(withTitle: "Open New Terminal")
        presentRestoreAlert(alert) { response in
            if response == .alertSecondButtonReturn { _ = TerminalWindowController.spawn() }
        }
    }

    /// Reattaches a verified tmux session and waits for its actual hosted window.
    ///
    /// - Parameter reference: The saved server, session, and window identity.
    /// - Returns: The hosted controller, or nil after a refused or failed attach.
    private static func openRestoredTmuxWindow(_ reference: SavedTerminalPresentation.TmuxWindow) async -> TerminalWindowController? {
        let unavailable = {
            presentUnavailableSession(
                title: "This tmux window couldn’t be restored.",
                detail: "Its original session or connection is unavailable."
            )
        }
        guard reference.canReconnectLocally || !reference.sshHost.isEmpty, reference.windowID >= 0 else {
            unavailable()
            return nil
        }
        let current = TerminalWindowController.spawnedControllers
        if let existing = current.first(where: { $0.savedTmuxWindow?.identifiesSameWindow(as: reference) == true }) {
            return existing
        }
        let owner =
            current.first(where: { $0.savedTmuxWindow?.identifiesSameSession(as: reference) == true })?
            .arrangementSupportingWindow?
            .windowController as? TerminalWindowController
        let primary: TerminalWindowController
        let didCreateClient: Bool
        if let owner {
            primary = owner
            didCreateClient = false
        } else {
            let arguments: [String]
            if !reference.sshHost.isEmpty {
                arguments = "/usr/bin/ssh"
                    .withCxxStringView { executable in
                        reference.sshHost.withCxxStringView {
                            Ubiquitty.Network.buildRemoteRestoreArguments(executable, $0, reference.coreReference).map { String($0) }
                        }
                    }
            } else if let executable = TerminalWindowController.tmuxExecutable {
                arguments = executable.withCxxStringView {
                    TmuxProtocol.restoreSessionArguments($0, reference.coreReference).map { String($0) }
                }
            } else {
                unavailable()
                return nil
            }
            guard !arguments.isEmpty,
                let opened = TerminalWindowController.spawn(
                    arguments: arguments,
                    localePolicy: .auto,
                    sessionLifetime: .endsWithChild,
                    showing: .hiddenControlClient,
                    tmuxControlHost: reference.sshHost
                )
            else {
                unavailable()
                return nil
            }
            primary = opened
            didCreateClient = true
            if !reference.sshHost.isEmpty {
                primary.showTmuxAuthentication()
            }
        }
        for _ in 0..<(reference.sshHost.isEmpty ? 300 : 1200) {
            if Task.isCancelled || primary.arrangementReadiness == .unavailable { break }
            if let hosted = primary.liveHostedWindows.first(where: {
                $0.savedTmuxWindow?.identifiesSameWindow(as: reference) == true && !$0.boundTmuxPaneIDs().isEmpty
            }) {
                if didCreateClient { primary.window?.orderOut(nil) }
                return hosted
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        if didCreateClient { primary.window?.close() }
        unavailable()
        return nil
    }

    /// Rebuilds a restored window from the windows its tabs opened as: one tab
    /// group in the stored order, the tab that was selected, and the frame it
    /// was captured at.
    ///
    /// Each tab joins the one before it rather than the first: `.above` places
    /// a tab directly after the window it is added to, so a group assembled
    /// around the lead window comes back with every tab after the first in
    /// reverse. The selected tab is named by where it stood in the stored
    /// order, which is the order these windows are in, rather than by an index
    /// into whatever order AppKit ended up with.
    ///
    /// The frame goes on last because it was captured with the tab strip
    /// inside it. A window given it before its second tab joins grows by the
    /// strip when the tab arrives, since a Swift-shell window keeps its grid
    /// through that change.
    ///
    /// - Parameters:
    ///   - group: The stored window.
    ///   - windows: The window each of its tabs opened as, in the stored
    ///     order.
    static func settleRestoredGroup(_ group: LayoutGroup, windows: [NSWindow]) {
        guard let leadWindow = windows.first else { return }
        var previous = leadWindow
        for window in windows.dropFirst() where window !== previous {
            previous.addTabbedWindow(window, ordered: .above)
            previous = window
        }
        let selected = windows.indices.contains(group.activeTab) ? windows[group.activeTab] : leadWindow
        selected.tabGroup?.selectedWindow = selected
        if group.frame != .zero {
            let screen =
                NSScreen.screens.max {
                    let first = $0.visibleFrame.intersection(group.frame)
                    let second = $1.visibleFrame.intersection(group.frame)
                    return first.width * first.height < second.width * second.height
                } ?? selected.screen
            var frame = group.frame
            if let visible = screen?.visibleFrame {
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            }
            selected.setFrame(frame, display: false)
        }
    }

    // MARK: - Quit

    /// Answers whether the application may terminate, asking about the
    /// terminal windows of both shells.
    ///
    /// - Parameter reason: Why the application quits, as the app delegate
    ///   learned it.
    /// - Returns: Whether to quit, once a reader who would lose a job has
    ///   said.
    static func terminationReply(for reason: Ubiquitty.Session.QuitReason) -> NSApplication.TerminateReply {
        terminationReply(for: reason, present: { $0.runModal() })
    }

    /// Confirms destructive quit choices, then performs capture while quit can
    /// still be cancelled. A ready daemon is not proof it accepted a session:
    /// only the completed handoff permits persistence and normal termination.
    ///
    /// Whether the quit keeps the session is Core's
    /// (`Session::isSessionKeptByQuit`): with session persistence on, or for
    /// an update relaunch whatever that setting says. A cancel is the
    /// person's answer to the quit, whatever asked for it. The updater asks
    /// with a quit request the app may cancel, and its installer waits for
    /// this process to end however it ends, so a cancel postpones the
    /// update rather than abandoning it.
    ///
    /// - Parameters:
    ///   - reason: Why the application quits.
    ///   - present: Presents the confirmation and returns the answer.
    /// - Returns: Whether the application may terminate.
    static func terminationReply(
        for reason: Ubiquitty.Session.QuitReason = .Ordinary,
        present: (NSAlert) -> NSApplication.ModalResponse
    ) -> NSApplication.TerminateReply {
        guard Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount() == 0 else {
            return cancelQuitForUnresolvedHandoff(present: present)
        }
        let persistsSession = Ubiquitty.Session.isSessionKeptByQuit(Ubiquitty.Preferences.values().pointee, reason)
        let confirmedJobLoss = !windowsEndedByQuit(for: reason).isEmpty
        if confirmedJobLoss, !confirmQuitEndingJobs(present: present) { return .terminateCancel }
        guard Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount() == 0 else {
            return cancelQuitForUnresolvedHandoff(present: present)
        }

        let groups = persistsSession ? capturedGroupsAtQuit() : []
        guard Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount() == 0 else {
            reattachCommittedLocalAdoptions()
            return cancelQuitForUnresolvedHandoff(present: present)
        }
        // A daemon that answered preflight can still refuse an individual
        // session. Ask about actual unadopted jobs before letting them end.
        if persistsSession, !confirmedJobLoss,
            keptBySession().contains(where: { !$0.tabCaptureFacts.isRemote && $0.hasRunningProcesses }),
            !confirmQuitEndingJobs(present: present)
        {
            reattachCommittedLocalAdoptions()
            return .terminateCancel
        }
        // A modal confirmation can dispatch another explicit handoff. Check
        // again before saving or authorizing process exit.
        guard Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount() == 0 else {
            reattachCommittedLocalAdoptions()
            return cancelQuitForUnresolvedHandoff(present: present)
        }
        if persistsSession { SessionLayout.saveCurrentLayout(groups, keptFor: reason) }
        // Each remote window stores its newest picture and tells its host it
        // is going, so the next launch resumes the attachment.
        RemoteSessionLifecycle.shared.suspendForTermination()
        return .terminateNow
    }

    /// The arrangement and original local owners held while Sparkle waits to
    /// install. No saved session is published until the successor has taken
    /// every adopted session.
    struct PreparedUpdateCapture {
        let groups: [LayoutGroup]
        let localPanes: [TerminalSurface]
        let foregroundPrograms: [String]
        let adoptedLocalPaneCount: Int
    }

    static func prepareUpdateCapture() -> PreparedUpdateCapture {
        let controllers = keptBySession().compactMap { $0 as? TerminalWindowController }
        var seen: Set<ObjectIdentifier> = []
        let localPanes = controllers.filter { !$0.isRenderOnly && $0.remoteSurface == nil }
            .flatMap(\.projectedSurfaces)
            .filter { surface in
                guard seen.insert(ObjectIdentifier(surface)).inserted else { return false }
                return !surface.drive.isRemoteAttached && !surface.drive.isSharedIntoLocalDaemon
            }
        let foregroundPrograms = localPanes.map { $0.drive.foregroundProcessName }
        let wasShareable = localPanes.map { $0.drive.isShareableLocalSession }
        let daemon = Ubiquitty.Session.readyLocalDaemon(std.string(ShareSessionSupport.localHostBinaryPath() ?? ""))
        let groups = capturedGroups(
            Ubiquitty.Session.CaptureConditions(
                occasion: .UpdateRelaunch,
                isLocalDaemonReady: !daemon.socketPath.empty()
            ),
            daemon: daemon,
            localBeforeUpdate: Set(localPanes.map { ObjectIdentifier($0) })
        )
        for controller in controllers {
            controller.reattachCommittedLocalAdoptions()
        }
        for (index, pane) in localPanes.enumerated() {
            let reason: String
            if pane.drive.isSharedIntoLocalDaemon {
                reason = "handoff committed"
            } else if daemon.socketPath.empty() {
                reason = "local host unavailable"
            } else if !wasShareable[index] {
                reason = "Core found no shareable local PTY"
            } else if pane.drive.hasUnresolvedLocalAdoption {
                reason = "handoff outcome unresolved"
            } else {
                reason = "handoff did not commit"
            }
            Ubiquitty.SwiftBridge.writeDiagnostic(
                std.string("Update pane \(index + 1) (\(foregroundPrograms[index])): \(reason)")
            )
        }
        return PreparedUpdateCapture(
            groups: groups,
            localPanes: localPanes,
            foregroundPrograms: foregroundPrograms,
            adoptedLocalPaneCount: localPanes.filter { $0.drive.isSharedIntoLocalDaemon }.count
        )
    }

    /// Each adopted pane must have an established attachment before the
    /// successor is started, so its exact session and predecessor are known.
    static func settledUpdateAdoptions(_ capture: PreparedUpdateCapture) async -> [UInt64]? {
        for _ in 0..<100 {
            let attached = capture.localPanes.allSatisfy { pane in
                pane.drive.isSharedIntoLocalDaemon && pane.drive.remoteState == .Connected
                    && pane.drive.remoteSessionID == pane.drive.sharedSessionID
                    && pane.drive.remoteDaemonInstanceID != 0
            }
            if attached { return capture.localPanes.map { $0.drive.remoteDaemonInstanceID } }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// A matching session on a new daemon, reached through the original
    /// attachment, is evidence that the successor took this pane.
    static func movedUpdateAdoptionCount(_ capture: PreparedUpdateCapture, from predecessors: [UInt64]) async -> Int {
        guard predecessors.count == capture.localPanes.count else { return 0 }
        var moved = 0
        for _ in 0..<100 {
            moved =
                zip(capture.localPanes, predecessors)
                .filter { pair in
                    let pane = pair.0
                    let predecessor = pair.1
                    return pane.drive.isSharedIntoLocalDaemon && pane.drive.remoteState == .Connected
                        && pane.drive.remoteSessionID == pane.drive.sharedSessionID
                        && pane.drive.remoteDaemonInstanceID != 0
                        && pane.drive.remoteDaemonInstanceID != predecessor
                }
                .count
            if moved == capture.localPanes.count { return moved }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return moved
    }

    /// A refused update keeps the old app alive. Reclaim is requested only
    /// after each adopted pane has attached to its original local daemon.
    static func reclaimUpdateAdoptions(_ capture: PreparedUpdateCapture) async {
        reattachCommittedLocalAdoptions()
        var requested: Set<ObjectIdentifier> = []
        for _ in 0..<100 {
            for pane in capture.localPanes where pane.drive.isSharedIntoLocalDaemon {
                let identity = ObjectIdentifier(pane)
                if !requested.contains(identity), pane.drive.requestReclaim() {
                    requested.insert(identity)
                }
            }
            if capture.localPanes.allSatisfy({ !$0.drive.isSharedIntoLocalDaemon }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func commitUpdateCapture(_ capture: PreparedUpdateCapture) {
        SessionLayout.saveCurrentLayout(capture.groups, keptFor: .UpdateRelaunch)
        RemoteSessionLifecycle.shared.suspendForTermination()
    }

    private static func confirmQuitEndingJobs(present: (NSAlert) -> NSApplication.ModalResponse) -> Bool {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Quit Ubiquitty?"
        alert.informativeText = "Some terminals have running processes. Quitting terminates them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return present(alert) == .alertFirstButtonReturn
    }

    private static func cancelQuitForUnresolvedHandoff(
        present: (NSAlert) -> NSApplication.ModalResponse
    ) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "A Session Handoff Is Unresolved"
        alert.informativeText = String(Ubiquitty.Session.shareFailureDetail(.unresolved))
        let visible = all().compactMap { $0 as? TerminalWindowController }.filter(\.hasUnresolvedLocalAdoption)
        if !visible.isEmpty { alert.addButton(withTitle: "Retry Handoff") }
        alert.addButton(withTitle: "Keep Open")
        if present(alert) == .alertFirstButtonReturn, !visible.isEmpty {
            for controller in visible { controller.retryUnresolvedLocalAdoptions() }
        }
        // Even a successful explicit retry does not silently restart quit.
        // Unseen escrow owners remain retained and continue to forbid exit.
        return .terminateCancel
    }

    private static func reattachCommittedLocalAdoptions() {
        for controller in all().compactMap({ $0 as? TerminalWindowController }) {
            controller.reattachCommittedLocalAdoptions()
        }
    }

    /// The terminal windows whose running jobs a quit would end.
    ///
    /// The daemon is brought up only when a window's answer turns on it: a
    /// session that is not persisted hands it nothing, and a quit that would
    /// end nothing has nothing to ask. The quit's own capture finds the daemon
    /// this brought up already answering.
    ///
    /// - Parameter reason: Why the application quits, which decides whether
    ///   the quit keeps the session (`Session::isSessionKeptByQuit`).
    /// - Returns: The windows, empty when a quit costs the reader nothing.
    static func windowsEndedByQuit(for reason: Ubiquitty.Session.QuitReason = .Ordinary) -> [any OpenTerminalWindow] {
        let running = keptBySession().filter(\.hasRunningProcesses)
        guard !running.isEmpty else { return [] }
        var quit = Ubiquitty.Session.QuitConditions()
        quit.isSessionPersistent = Ubiquitty.Session.isSessionKeptByQuit(Ubiquitty.Preferences.values().pointee, reason)
        if quit.isSessionPersistent {
            let daemon = Ubiquitty.Session.readyLocalDaemon(std.string(ShareSessionSupport.localHostBinaryPath() ?? ""))
            quit.isLocalDaemonReady = !daemon.socketPath.empty()
        }
        return running.filter { !Ubiquitty.Session.isTabKeptRunningByQuit($0.tabCaptureFacts, quit) }
    }

    // MARK: - Session capture

    /// Every terminal window's tabs, captured for a saved workspace: the live
    /// windows are left as they are, so a local shell restores fresh.
    ///
    /// - Returns: One group per window.
    static func capturedGroupsForSavedWorkspace() -> [LayoutGroup] {
        capturedGroups(
            Ubiquitty.Session.CaptureConditions(occasion: .SavedWorkspace, isLocalDaemonReady: false),
            daemon: Ubiquitty.Session.LocalDaemonTarget()
        )
    }

    /// Every terminal window's tabs, captured at quit: a local shell the
    /// daemon can adopt is handed to it, so the next launch rejoins it.
    ///
    /// The daemon is the one the bundled host binary owns, brought up when
    /// nothing answers (`Session::readyLocalDaemon`); with none, every local
    /// tab restores as a fresh shell.
    ///
    /// - Returns: One group per window.
    static func capturedGroupsAtQuit() -> [LayoutGroup] {
        guard Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount() == 0 else { return [] }
        let daemon = Ubiquitty.Session.readyLocalDaemon(std.string(ShareSessionSupport.localHostBinaryPath() ?? ""))
        return capturedGroups(
            Ubiquitty.Session.CaptureConditions(occasion: .Quit, isLocalDaemonReady: !daemon.socketPath.empty()),
            daemon: daemon
        )
    }

    /// The walk both captures share.
    ///
    /// Groups run back to front: a restore opens each group above the last,
    /// so the window the reader left in front comes back in front. Tabs run in
    /// their group's order, and a group records which of them was selected
    /// and the frame that tab stands at. A group in full screen records that,
    /// and the frame it had before it went full screen, which is the one it
    /// comes back to when it leaves full screen again.
    ///
    /// A daemon that refuses a shell is offered no other
    /// (`Session::conditionsAfterHandOff`): the walk runs on the thread the
    /// application quits from, and one that accepts a connection and never
    /// answers costs the whole handoff deadline for every window.
    private static func capturedGroups(
        _ startingConditions: Ubiquitty.Session.CaptureConditions,
        daemon: Ubiquitty.Session.LocalDaemonTarget,
        localBeforeUpdate: Set<ObjectIdentifier> = []
    ) -> [LayoutGroup] {
        var conditions = startingConditions
        var groups: [LayoutGroup] = []
        for selected in shownTabsFrontToBack().reversed() {
            var tabs: [LayoutTab] = []
            var activeTab = 0
            for tabWindow in selected.tabGroup?.windows ?? [selected] {
                guard let tabTerminal = tabWindow.windowController as? any OpenTerminalWindow else { continue }
                let facts = tabTerminal.tabCaptureFacts
                let action = Ubiquitty.Session.planCapturedTab(facts, conditions)
                guard action != .Excluded else { continue }
                if tabWindow === selected {
                    activeTab = tabs.count
                }
                var reHomedSessionID: UInt32 = 0
                if action == .ReHomes {
                    reHomedSessionID = tabTerminal.handShellToDaemon(
                        atSocketPath: String(daemon.socketPath),
                        bridgeCommand: String(daemon.bridgeCommand)
                    )
                    conditions = Ubiquitty.Session.conditionsAfterHandOff(conditions, reHomedSessionID)
                    if Ubiquitty.Runtime.TerminalSession.unresolvedLocalAdoptionCount() != 0 { return [] }
                }
                let tab = layoutTab(Ubiquitty.Session.storedTab(facts, action, daemon, reHomedSessionID), of: tabTerminal)
                if conditions.occasion == .UpdateRelaunch, let shell = tabTerminal as? TerminalWindowController {
                    tab.reclaimSessionIDsAfterUpdate = shell.projectedSurfaces.compactMap { pane in
                        guard localBeforeUpdate.contains(ObjectIdentifier(pane)) else { return nil }
                        let session = pane.drive.sharedSessionID
                        return session == 0 ? nil : session
                    }
                }
                tabs.append(tab)
            }
            guard !tabs.isEmpty else { continue }
            let group = LayoutGroup()
            group.isFullScreen = selected.styleMask.contains(.fullScreen)
            let windowedFrame = (selected.tabGroup?.windows ?? [selected]).lazy
                .compactMap { ($0.windowController as? TerminalWindowController)?.frameBeforeFullScreen }.first
            group.frame = group.isFullScreen ? windowedFrame ?? selected.frame : selected.frame
            group.tabs = tabs
            group.activeTab = activeTab
            groups.append(group)
        }
        return groups
    }

    /// The window each group of session-kept terminal windows shows, front to
    /// back, each group once.
    ///
    /// A group stands where its selected tab stands. A tab behind it keeps the
    /// place in the stack it had when it was last selected, or none, and it
    /// keeps the frame it had then too: AppKit moves and resizes only the tab
    /// on screen. So the selected tabs are placed first, and a group reached
    /// only through a tab behind it — its selected tab is no terminal a session
    /// keeps — follows them.
    private static func shownTabsFrontToBack() -> [NSWindow] {
        let windows = keptBySession().compactMap(\.window)
        let isShown = { (window: NSWindow) in (window.tabGroup?.selectedWindow ?? window) === window }
        var shown: [NSWindow] = []
        var visited: Set<ObjectIdentifier> = []
        for window in windows.filter(isShown) + windows.filter({ !isShown($0) }) where !visited.contains(ObjectIdentifier(window)) {
            let tabWindows = window.tabGroup?.windows ?? [window]
            tabWindows.forEach { visited.insert(ObjectIdentifier($0)) }
            shown.append(window.tabGroup?.selectedWindow ?? window)
        }
        return shown
    }

    /// One stored tab in the session store's own shape.
    private static func layoutTab(_ stored: Ubiquitty.Session.RestoredTab, of terminal: any OpenTerminalWindow) -> LayoutTab {
        let tab = LayoutTab()
        tab.sessionID = stored.sessionID
        tab.hostLabel = String(stored.hostLabel)
        tab.bridgeCommand = stored.bridgeCommand.empty() ? nil : String(stored.bridgeCommand)
        tab.socketName = stored.socketName.empty() ? nil : String(stored.socketName)
        tab.paneLayout = stored.paneLayout.empty() ? nil : String(stored.paneLayout)
        if let shell = terminal as? TerminalWindowController {
            tab.paneLayout = shell.savedPresentation(needsLocalArrangement: stored.sessionID == 0, liveReference: stored).encoded()
        }
        let grid = terminal.capturedGrid
        tab.columns = UInt16(clamping: grid.columns)
        tab.rows = UInt16(clamping: grid.rows)
        let tags = terminal.handSetTags
        tab.tags = tags.isEmpty ? nil : tags
        return tab
    }
}
