// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import AppKit
import UbiquittyCore

// SessionLayoutStoreScenarios.swift — the named-workspace store the Workspaces
// menu and the Connect window rest on.
//
// The store is Foundation values and bounded JSON, so each check runs against a
// scratch control directory and opens no window:
//
//   1. A saved named workspace round-trips: frame, tabs, split layout and size.
//   2. The named list leaves out the reserved auto-restore entry, so no picker
//      lists the plumbing as a workspace.
//   3. Deleting removes exactly the named workspace and leaves every other one,
//      and the auto-restore entry, in place.
//   4. The control directory is owner-only and the store's file owner-only: the
//      directory also holds the daemon's sockets and audit logs.
//   5. A tab's socket name read from a crafted store is refused, because a
//      restore feeds it into the reattach command and it never passes the live
//      wire's own check.
//   6. A window in full screen round-trips as one, with the frame it had
//      before it went full screen.
//   7. The arrangement an update relaunch keeps is restored by the one launch
//      that reads it, and with session persistence off by no launch after
//      it; an ordinary quit's is restored only with persistence on.

/// Registers the session-layout store scenarios with the UI-test runner.
enum SessionLayoutStoreScenarios {
    /// Registers every scenario in this file.
    static func register() {
        UBUITestRegister("session_layout_store_round_trips_a_named_workspace") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { withScratchControlDirectory(t) { _ in checkRoundTrip(t) } }
        }
        UBUITestRegister("session_layout_store_lists_named_workspaces_without_the_current_layout") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { withScratchControlDirectory(t) { _ in checkNamedExcludesCurrent(t) } }
        }
        UBUITestRegister("session_layout_store_deletes_only_the_named_workspace") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { withScratchControlDirectory(t) { _ in checkTargetedDelete(t) } }
        }
        UBUITestRegister("session_layout_store_writes_owner_only_files") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { withScratchControlDirectory(t) { directory in checkOwnerOnlyFiles(t, directory: directory) } }
        }
        UBUITestRegister("session_layout_store_refuses_a_crafted_socket_name") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { withScratchControlDirectory(t) { _ in checkCraftedSocketNameRefused(t) } }
        }
        UBUITestRegister("session_layout_store_round_trips_a_full_screen_window") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { withScratchControlDirectory(t) { _ in checkFullScreenRoundTrip(t) } }
        }
        UBUITestRegister("session_layout_store_spends_an_update_relaunchs_mark_once") { context in
            guard let t = context else { return }
            MainActor.assumeIsolated { withScratchControlDirectory(t) { _ in checkUpdateRelaunchMarkIsSpentOnce(t) } }
        }
    }

    // Points the control directory at a fresh scratch directory for `body`, then
    // puts the application's own back: every daemon socket and audit log the
    // rest of the run reaches is under it.
    @MainActor
    private static func withScratchControlDirectory(_ t: UBUITestContext, _ body: (String) -> Void) {
        let previous = ProcessInfo.processInfo.environment["UBIQUITTY_HOME"]
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("ubq-wstest-\(UUID().uuidString)")
        defer {
            if let previous { setenv("UBIQUITTY_HOME", previous, 1) } else { unsetenv("UBIQUITTY_HOME") }
            try? FileManager.default.removeItem(atPath: directory)
        }
        guard (try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)) != nil else {
            t.expect(false, desc: "the scratch control directory is created")
            return
        }
        setenv("UBIQUITTY_HOME", directory, 1)
        SessionLayout.clear()
        body(directory)
    }

    private static func group(frame: NSRect, paneLayout: String?) -> LayoutGroup {
        let tab = LayoutTab()
        tab.sessionID = 0
        tab.hostLabel = "local"
        tab.columns = 80
        tab.rows = 24
        tab.paneLayout = paneLayout
        let group = LayoutGroup()
        group.frame = frame
        group.activeTab = 0
        group.tabs = [tab]
        return group
    }

    @discardableResult
    private static func saveNamed(_ name: String, _ groups: [LayoutGroup]) -> LayoutSession {
        let session = LayoutSession()
        session.identifier = UUID().uuidString
        session.name = name
        session.groups = groups
        try? SessionLayout.save(SessionLayout.allSessions() + [session])
        return session
    }

    @MainActor
    private static func checkRoundTrip(_ t: UBUITestContext) {
        let frame = NSRect(x: 120, y: 240, width: 1000, height: 700)
        let layout = "0000,80x24,0,0{40x24,0,0,1,39x24,41,0,2}"
        let saved = saveNamed("Dev Layout", [group(frame: frame, paneLayout: layout)])
        let named = SessionLayout.namedWorkspaces()
        t.expect(named.count, equals: 1, desc: "one named workspace is stored")
        guard let got = named.first, let group = got.groups.first, let tab = group.tabs.first else {
            t.expect(false, desc: "the workspace reads back with a window and a tab")
            return
        }
        t.expect(got.identifier == saved.identifier, desc: "the identifier round-trips")
        t.expect(got.name == "Dev Layout", desc: "the name round-trips")
        t.expect(got.groups.count, equals: 1, desc: "one window round-trips")
        t.expect(group.frame == frame, desc: "the window frame round-trips")
        t.expect(group.tabs.count, equals: 1, desc: "one tab round-trips")
        t.expect(tab.columns == 80 && tab.rows == 24, desc: "the tab size round-trips")
        t.expect(tab.paneLayout == layout, desc: "the split layout round-trips")
    }

    @MainActor
    private static func checkNamedExcludesCurrent(_ t: UBUITestContext) {
        SessionLayout.saveCurrentLayout([group(frame: NSRect(x: 0, y: 0, width: 800, height: 600), paneLayout: nil)])
        saveNamed("Work", [group(frame: NSRect(x: 10, y: 10, width: 900, height: 650), paneLayout: nil)])
        t.expect(SessionLayout.allSessions().count, equals: 2, desc: "the store holds the current layout and the workspace")
        let named = SessionLayout.namedWorkspaces()
        t.expect(named.count, equals: 1, desc: "the named list holds only the workspace")
        t.expect(named.first?.name == "Work", desc: "the named list's entry is the workspace")
        t.expect(SessionLayout.currentLayout()?.count ?? 0, equals: 1, desc: "the auto-restore still finds the current layout")
    }

    @MainActor
    private static func checkTargetedDelete(_ t: UBUITestContext) {
        SessionLayout.saveCurrentLayout([group(frame: NSRect(x: 0, y: 0, width: 800, height: 600), paneLayout: nil)])
        let first = saveNamed("A", [group(frame: NSRect(x: 1, y: 1, width: 800, height: 600), paneLayout: nil)])
        let second = saveNamed("B", [group(frame: NSRect(x: 2, y: 2, width: 800, height: 600), paneLayout: nil)])

        SessionLayout.deleteSession(withIdentifier: first.identifier)
        var named = SessionLayout.namedWorkspaces()
        t.expect(named.count, equals: 1, desc: "deleting one workspace leaves the other")
        t.expect(named.first?.identifier == second.identifier, desc: "the remaining workspace is the one not deleted")
        t.expect(SessionLayout.currentLayout()?.count ?? 0, equals: 1, desc: "the current layout survives a workspace's deletion")

        SessionLayout.deleteSession(withIdentifier: "does-not-exist")
        t.expect(SessionLayout.namedWorkspaces().count, equals: 1, desc: "deleting an unknown identifier changes nothing")
        SessionLayout.deleteSession(withIdentifier: "")
        t.expect(SessionLayout.namedWorkspaces().count, equals: 1, desc: "deleting an empty identifier never clears the store")

        SessionLayout.deleteSession(withIdentifier: second.identifier)
        named = SessionLayout.namedWorkspaces()
        t.expect(named.count, equals: 0, desc: "deleting the last workspace leaves none")
        t.expect(SessionLayout.currentLayout()?.count ?? 0, equals: 1, desc: "the current layout survives the last workspace's deletion")
    }

    @MainActor
    private static func checkOwnerOnlyFiles(_ t: UBUITestContext, directory: String) {
        SessionLayout.saveCurrentLayout([group(frame: NSRect(x: 0, y: 0, width: 800, height: 600), paneLayout: nil)])
        let directoryMode = (try? FileManager.default.attributesOfItem(atPath: directory))?[.posixPermissions] as? NSNumber
        t.expect(directoryMode?.intValue ?? -1, equals: 0o700, desc: "the control directory is owner-only")
        let file = (directory as NSString).appendingPathComponent("sessions.json")
        let fileMode = (try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions] as? NSNumber
        t.expect(fileMode?.intValue ?? -1, equals: 0o600, desc: "the store's file is owner-only")
    }

    @MainActor
    private static func checkCraftedSocketNameRefused(_ t: UBUITestContext) {
        // Written directly, past the save path, which never writes such a value.
        let crafted: [String: Any] = ["sessionID": 1, "socket": "host-x\"; rm -rf ~ #.sock", "columns": 80, "rows": 24]
        let benign: [String: Any] = ["sessionID": 2, "socket": "host-abc123.sock", "columns": 80, "rows": 24]
        let root: [String: Any] = ["sessions": [["id": "current", "groups": [["tabs": [crafted, benign], "activeTab": 0]]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
            (try? data.write(to: URL(fileURLWithPath: SessionLayout.sessionsFilePath()), options: .atomic)) != nil
        else {
            t.expect(false, desc: "the crafted store is written")
            return
        }
        let groups = SessionLayout.currentLayout() ?? []
        t.expect(groups.count, equals: 1, desc: "the crafted store reads back one window")
        let tabs = groups.first?.tabs ?? []
        t.expect(tabs.count, equals: 2, desc: "both tabs read back")
        guard tabs.count == 2 else { return }
        t.expect(tabs[0].socketName == nil, desc: "the crafted socket name is refused, not carried through")
        t.expect(tabs[1].socketName == "host-abc123.sock", desc: "a well-formed socket name is kept")
    }

    @MainActor
    private static func checkFullScreenRoundTrip(_ t: UBUITestContext) {
        let fullScreen = group(frame: NSRect(x: 40, y: 80, width: 900, height: 600), paneLayout: nil)
        fullScreen.isFullScreen = true
        let windowed = group(frame: NSRect(x: 60, y: 90, width: 700, height: 500), paneLayout: nil)
        saveNamed("Full Screen", [fullScreen, windowed])
        let groups = SessionLayout.namedWorkspaces().first?.groups ?? []
        t.expect(groups.map(\.isFullScreen) == [true, false], desc: "only the window that was in full screen reads back as one")
        t.expect(groups.first?.frame == fullScreen.frame, desc: "and it keeps the frame it had before it went full screen")
    }

    @MainActor
    private static func checkUpdateRelaunchMarkIsSpentOnce(_ t: UBUITestContext) {
        let saved = String(Ubiquitty.Preferences.liveDocument().pointee)
        defer { t.restoreConfiguration(saved) }
        func launch(persistence isOn: Bool) -> [LayoutGroup]? {
            t.restoreConfiguration(saved)
            t.configureAppending("[experimental]\nsession_persistence = \(isOn)\n")
            return SessionLayout.takeLayoutForLaunch(Ubiquitty.Preferences.values().pointee)
        }
        let back = group(frame: NSRect(x: 40, y: 80, width: 900, height: 600), paneLayout: nil)
        let windowed = group(frame: NSRect(x: 60, y: 90, width: 700, height: 500), paneLayout: nil)

        // Persistence off: only the launch after the update restores it, and
        // it takes the arrangement with the mark.
        SessionLayout.saveCurrentLayout([back, windowed], keptFor: .UpdateRelaunch)
        t.expect(
            SessionLayout.allSessions().first?.keptFor == .UpdateRelaunch,
            desc: "the update relaunch's mark is stored with the arrangement"
        )
        let restored = launch(persistence: false)
        t.expect(restored?.count ?? 0, equals: 2, desc: "the launch after the update restores both windows with persistence off")
        t.expect(SessionLayout.currentLayout() == nil, desc: "with persistence off the launch takes the arrangement with the mark")
        t.expect(launch(persistence: false) == nil, desc: "the launch after that restores nothing")

        // An ordinary quit's arrangement is restored only with persistence
        // on, and reading it changes nothing.
        SessionLayout.saveCurrentLayout([windowed])
        t.expect(launch(persistence: false) == nil, desc: "an ordinary quit's arrangement is not restored with persistence off")
        t.expect(SessionLayout.currentLayout()?.count ?? 0, equals: 1, desc: "and a launch that restores nothing leaves it as it was")

        // Persistence on: the mark goes, the arrangement stays, as every
        // persistent quit leaves it.
        SessionLayout.saveCurrentLayout([windowed], keptFor: .UpdateRelaunch)
        t.expect(launch(persistence: true)?.count ?? 0, equals: 1, desc: "with persistence on the launch after the update restores it")
        t.expect(
            SessionLayout.allSessions().first?.keptFor == .Ordinary && SessionLayout.currentLayout()?.count == 1,
            desc: "and spends the mark, keeping the arrangement persistence keeps"
        )
        t.expect(launch(persistence: false) == nil, desc: "so a later launch with persistence off restores nothing")
    }
}
